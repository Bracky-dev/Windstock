// Guest address space: one 4 GB PROT_NONE reservation, a first-fit page
// allocator over it, and a size-class heap for the guest's malloc.
#include "guest.h"

#include <sys/mman.h>
#include <unistd.h>

#include <cstdarg>
#include <cstdio>
#include <map>
#include <mutex>

#ifdef __ANDROID__
#include <android/log.h>
#endif

namespace wst {

u8* g_base = nullptr;
int g_verbose = 0;
bool g_stderr_is_logcat = false;   // set by the Android app once fds 1/2 are piped to logcat

static void vlog(const char* fmt, va_list ap) {
    char buf[2048];
    vsnprintf(buf, sizeof buf, fmt, ap);
    if (!g_stderr_is_logcat) fprintf(stderr, "%s\n", buf);
#ifdef __ANDROID__
    __android_log_write(ANDROID_LOG_INFO, "wst64", buf);
#endif
}

void logf(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    vlog(fmt, ap);
    va_end(ap);
}

void fatal(const char* fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    char buf[2048];
    vsnprintf(buf, sizeof buf, fmt, ap);
    va_end(ap);
    logf("FATAL: %s", buf);
    abort();
}

// ---- page allocator ----
static constexpr u64 kSpace = u64(1) << 32;
static constexpr gaddr kLow = 0x00100000;   // below: null guard + thunks
static constexpr gaddr kHigh = 0xFFF00000;
static std::mutex g_va_mu;
static std::map<gaddr, u32> g_free;          // start -> length
static std::map<gaddr, u32> g_used;

static inline u32 page_up(u32 n) { return (n + 0xFFF) & ~0xFFFu; }

bool mem_init() {
    void* p = mmap(nullptr, kSpace, PROT_NONE, MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    if (p == MAP_FAILED) return false;
    g_base = static_cast<u8*>(p);
    g_free[kLow] = kHigh - kLow;
    return true;
}

static bool map_rw(gaddr a, u32 len) {
    return mmap(g_base + a, len, PROT_READ | PROT_WRITE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS, -1, 0) != MAP_FAILED;
}

gaddr va_alloc(u32 len, u32 align) {
    len = page_up(len);
    if (align < 0x1000) align = 0x1000;
    std::lock_guard<std::mutex> lk(g_va_mu);
    for (auto it = g_free.begin(); it != g_free.end(); ++it) {
        gaddr start = it->first;
        u64 end = u64(start) + it->second;
        gaddr a = (start + align - 1) & ~(align - 1);
        if (u64(a) + len > end) continue;
        g_free.erase(it);
        if (a > start) g_free[start] = a - start;
        if (u64(a) + len < end) g_free[a + len] = u32(end - (u64(a) + len));
        if (!map_rw(a, len)) fatal("mmap of guest range %08x+%x failed", a, len);
        g_used[a] = len;
        return a;
    }
    fatal("guest address space exhausted (wanted %u bytes)", len);
}

bool va_alloc_at(gaddr at, u32 len) {
    len = page_up(len);
    std::lock_guard<std::mutex> lk(g_va_mu);
    auto it = g_free.upper_bound(at);
    if (it == g_free.begin()) return false;
    --it;
    u64 end = u64(it->first) + it->second;
    if (at < it->first || u64(at) + len > end) return false;
    gaddr start = it->first;
    g_free.erase(it);
    if (at > start) g_free[start] = at - start;
    if (u64(at) + len < end) g_free[at + len] = u32(end - (u64(at) + len));
    if (!map_rw(at, len)) return false;
    g_used[at] = len;
    return true;
}

void va_free(gaddr a, u32 len) {
    len = page_up(len);
    std::lock_guard<std::mutex> lk(g_va_mu);
    mmap(g_base + a, len, PROT_NONE, MAP_FIXED | MAP_PRIVATE | MAP_ANONYMOUS | MAP_NORESERVE, -1, 0);
    g_used.erase(a);
    // insert and merge with neighbours
    auto it = g_free.emplace(a, len).first;
    auto next = std::next(it);
    if (next != g_free.end() && it->first + it->second == next->first) {
        it->second += next->second;
        g_free.erase(next);
    }
    if (it != g_free.begin()) {
        auto prev = std::prev(it);
        if (prev->first + prev->second == it->first) {
            prev->second += it->second;
            g_free.erase(it);
        }
    }
}

bool va_is_mapped(gaddr a) {
    std::lock_guard<std::mutex> lk(g_va_mu);
    auto it = g_used.upper_bound(a);
    if (it == g_used.begin()) return false;
    --it;
    return a < u64(it->first) + it->second;
}

// ---- heap ----
// Each block has an 8-byte header: {u32 size, u32 tag}. Small blocks come from
// per-class slabs with free lists; large ones get their own pages.
static constexpr u32 kTagSmall = 0x5A110C00;  // | class index
static constexpr u32 kTagLarge = 0x5A11B16B;
static constexpr u32 kTagAligned = 0x5A11A119;  // size = offset back to the real block
static const u32 kClass[] = {16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048,
                             3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768};
static constexpr int kNumClass = sizeof(kClass) / sizeof(kClass[0]);
static constexpr u32 kSlab = 1 << 20;

static std::mutex g_heap_mu;
static gaddr g_freelist[kNumClass];
static gaddr g_bump[kNumClass], g_bump_end[kNumClass];

static gaddr small_alloc(int c) {
    if (gaddr p = g_freelist[c]) {
        g_freelist[c] = rd32(p);
        return p;
    }
    u32 bs = kClass[c] + 8;
    if (g_bump[c] + bs > g_bump_end[c] || !g_bump[c]) {
        g_bump[c] = va_alloc(kSlab);
        g_bump_end[c] = g_bump[c] + kSlab;
    }
    gaddr blk = g_bump[c];
    g_bump[c] += bs;
    wr32(blk, kClass[c]);
    wr32(blk + 4, kTagSmall | c);
    return blk + 8;
}

gaddr gmalloc(u32 n) {
    if (n == 0) n = 1;
    for (int c = 0; c < kNumClass; ++c) {
        if (n <= kClass[c]) {
            std::lock_guard<std::mutex> lk(g_heap_mu);
            return small_alloc(c);
        }
    }
    gaddr blk = va_alloc(n + 8);
    wr32(blk, n);
    wr32(blk + 4, kTagLarge);
    return blk + 8;
}

static u32 block_size(gaddr p) {
    u32 tag = rd32(p - 4);
    if (tag == kTagAligned) return block_size(p - rd32(p - 8)) - rd32(p - 8);
    return rd32(p - 8);
}

void gfree(gaddr p) {
    if (!p) return;
    u32 tag = rd32(p - 4);
    if (tag == kTagAligned) { gfree(p - rd32(p - 8)); return; }
    if (tag == kTagLarge) { va_free(p - 8, rd32(p - 8) + 8); return; }
    if ((tag & ~0xFFu) != kTagSmall || (tag & 0xFF) >= kNumClass)
        fatal("guest free() of bad pointer %08x (tag %08x)", p, tag);
    std::lock_guard<std::mutex> lk(g_heap_mu);
    int c = tag & 0xFF;
    wr32(p, g_freelist[c]);
    g_freelist[c] = p;
}

gaddr gcalloc(u32 n, u32 sz) {
    u64 t = u64(n) * sz;
    if (t >> 32) return 0;
    gaddr p = gmalloc(u32(t));
    std::memset(H(p), 0, t);
    return p;
}

gaddr grealloc(gaddr p, u32 n) {
    if (!p) return gmalloc(n);
    if (n == 0) { gfree(p); return 0; }
    u32 have = block_size(p);
    if (n <= have) return p;
    gaddr q = gmalloc(n);
    std::memcpy(H(q), H(p), have);
    gfree(p);
    return q;
}

gaddr gmemalign(u32 align, u32 n) {
    if (align <= 8) return gmalloc(n);
    gaddr raw = gmalloc(n + align + 8);
    gaddr p = (raw + 8 + align - 1) & ~(align - 1);
    wr32(p - 8, p - raw);
    wr32(p - 4, kTagAligned);
    return p;
}

gaddr gstrdup(const char* s) { return gdup(s, u32(strlen(s) + 1)); }

gaddr gdup(const void* p, u32 n) {
    gaddr g = gmalloc(n);
    std::memcpy(H(g), p, n);
    return g;
}

}  // namespace wst
