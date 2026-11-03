// Host implementations of the native libraries the guest imports, reached
// through ARM "svc #index" stubs the loader binds its imports to.
#include "cpu.h"
#include "thunks_ctx.h"
#include "elf.h"

#include <ctype.h>
#include <errno.h>
#include <pthread.h>
#include <sys/mman.h>
#include <sched.h>
#include <stdarg.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#include <algorithm>
#include <atomic>
#include <string>
#include <unordered_map>
#include <vector>

#include "dynarmic/interface/A32/a32.h"

namespace wst {

// ---- thunk region ----
static constexpr u32 kStubStride = 8;            // svc #i ; bx lr  (ARM)
static constexpr u32 kSvcReturn = 0xFFFFFE;      // the host->guest return sentinel
static gaddr g_thunk_base, g_thunk_end;
static gaddr g_halt_stub;

static std::vector<Handler> g_handlers;          // index -> fn
static std::vector<std::string> g_hnames;
static std::unordered_map<std::string, int> g_by_name;
static std::unordered_map<std::string, Handler> g_registry;         // name -> fn
static std::unordered_map<std::string, gaddr (*)()> g_data_reg;     // name -> data factory
static std::unordered_map<std::string, gaddr> g_data_cache;

static gaddr emit_stub(u32 svc_imm) {
    gaddr a = g_thunk_base;
    if (a + kStubStride > g_thunk_end) fatal("thunk region full");
    g_thunk_base += kStubStride;
    wr32(a, 0xEF000000u | (svc_imm & 0xFFFFFF));   // svc #imm
    wr32(a + 4, 0xE12FFF1Eu);                       // bx lr
    return a;                                       // ARM (bit0 == 0)
}

void register_handler(const char* name, Handler fn) { g_registry[name] = fn; }
void register_data(const char* name, gaddr (*make)()) { g_data_reg[name] = make; }
bool have_handler(const std::string& n) { return g_registry.count(n) != 0; }

// Thunks that return quickly, never block and never call guest code (see dispatch_svc).
static u8 g_fast[1 << 16];   // fixed: read lock-free by every guest thread
static bool fast_name(const std::string& n) {
    static const char* const kFast[] = {
        "pthread_getspecific", "pthread_setspecific", "pthread_self", "gettid", "getpid", "__errno",
        "pthread_mutex_unlock", "pthread_mutex_trylock", "pthread_cond_signal", "pthread_cond_broadcast", "sem_post",
        "memcpy", "memmove", "memset", "memcmp", "memchr", "memrchr", "strcmp", "strncmp", "strlen", "strnlen",
        "strchr", "strrchr", "strcpy", "strncpy", "strcat", "strncat", "strstr", "strcasecmp", "strncasecmp",
        "strdup", "strtol", "strtoul", "strtod", "strtof", "atoi", "atof", "tolower", "toupper", "isspace",
        "malloc", "free", "calloc", "realloc", "memalign", "posix_memalign",
        "gettimeofday", "clock_gettime", "time", "sqrt", "sqrtf", "sin", "cos", "sinf", "cosf", "tan", "tanf",
        "atan2", "atan2f", "pow", "powf", "exp", "expf", "log", "logf", "floor", "floorf", "ceil", "ceilf", "fmod", "fmodf",
        "__aeabi_memcpy", "__aeabi_memcpy4", "__aeabi_memcpy8", "__aeabi_memmove", "__aeabi_memmove4", "__aeabi_memmove8",
        "__aeabi_memset", "__aeabi_memset4", "__aeabi_memset8", "__aeabi_memclr", "__aeabi_memclr4", "__aeabi_memclr8",
    };
    if (n.rfind("gl:", 0) == 0)   // forwarded GL, except the calls that wait on the GPU
        return n != "gl:glFinish" && n != "gl:glClientWaitSync" && n != "gl:glWaitSync" && n != "gl:glReadPixels";
    for (const char* f : kFast) if (n == f) return true;
    return false;
}
bool svc_is_fast(u32 swi) { return swi < (1u << 16) && g_fast[swi]; }

static int handler_index(const std::string& name, Handler fn) {
    auto it = g_by_name.find(name);
    if (it != g_by_name.end()) return it->second;
    int i = int(g_handlers.size());
    g_handlers.push_back(fn);
    if (i < (1 << 16)) g_fast[i] = fast_name(name) ? 1 : 0;
    g_hnames.push_back(name);
    g_by_name[name] = i;
    emit_stub(u32(i));   // stub i sits at g_thunk region start + i*stride
    return i;
}

// Recompute a stub address from its index using the fixed region start.
static gaddr g_region_start;
static thread_local u32 g_cur_svc = 0;   // index of the handler currently running (per host thread)
static gaddr stub_for_index(int i) { return g_region_start + u32(i) * kStubStride; }

gaddr halt_stub() { return g_halt_stub; }

static void lazy_unimplemented(Ctx& c);

gaddr thunk_for_import(const std::string& name, bool is_object) {
    if (is_object) {
        auto cached = g_data_cache.find(name);
        if (cached != g_data_cache.end()) return cached->second;
        gaddr a;
        auto f = g_data_reg.find(name);
        if (f != g_data_reg.end()) {
            a = f->second();
        } else {
            VLOG("[data] unknown object import '%s' -> zeroed blob", name.c_str());
            a = va_alloc(0x1000);
        }
        g_data_cache[name] = a;
        return a;
    }
    auto r = g_registry.find(name);
    Handler fn = r != g_registry.end() ? r->second : lazy_unimplemented;
    int i = handler_index(name, fn);
    return stub_for_index(i);
}

gaddr make_thunk(const char* name, Handler fn) {
    return stub_for_index(handler_index(name, fn));
}

static u32 g_range_base = 0, g_range_count = 0;
static void (*g_range_fn)(u32, Ctx&) = nullptr;
void svc_register_range(u32 base, u32 count, void (*fn)(u32, Ctx&)) {
    g_range_base = base; g_range_count = count; g_range_fn = fn;
}

// Per-import call counters + a reporter thread (WST_PROFILE) for "what is the guest doing".
static constexpr u32 kMaxCount = 1 << 16;
static std::atomic<u64> g_counts[kMaxCount];
struct ThreadSlot { std::atomic<int> tid{0}; std::atomic<u32> in{0}; std::atomic<u32> lr{0}; std::atomic<u32> sp{0}; std::atomic<u32> a0{0}; };
static ThreadSlot g_slots[256];
static std::atomic<int> g_nslots{0};
static ThreadSlot* my_slot() {
    static thread_local ThreadSlot* s = nullptr;
    if (!s) { int i = g_nslots.fetch_add(1); s = &g_slots[i < 256 ? i : 255]; s->tid = gettid(); }
    return s;
}
static void* profile_thread(void*) {
    std::vector<u64> last(kMaxCount, 0);
    for (;;) {
        sleep(5);
        std::vector<std::pair<u64, u32>> d;
        for (u32 i = 0; i < g_hnames.size() && i < kMaxCount; ++i) {
            u64 v = g_counts[i].load(); if (v != last[i]) d.push_back({v - last[i], i}); last[i] = v;
        }
        std::sort(d.rbegin(), d.rend());
        std::string line;
        for (size_t k = 0; k < d.size() && k < 12; ++k) { line += g_hnames[d[k].second] + "=" + std::to_string(d[k].first) + " "; }
        logf("[prof] 5s: %s", line.empty() ? "(no host calls)" : line.c_str());
        static int round = 0;
        if (++round % 3 == 0) {
            std::string b;
            for (int i = 0; i < g_nslots.load() && i < 256; ++i) {
                u32 in = g_slots[i].in.load();
                if (!in) continue;
                char a0[16]; snprintf(a0, sizeof a0, "(%08x)", g_slots[i].a0.load());
                b += std::to_string(g_slots[i].tid.load()) + ":" + g_hnames[in - 1] + a0 + "@" + describe_addr(g_slots[i].lr.load() & ~1u) + "  ";
                const std::string& hn = g_hnames[in - 1];
                if (hn == "usleep" || hn == "nanosleep" || hn == "pthread_cond_wait" || hn == "pthread_cond_timedwait" || (hn == "sem_wait" && describe_addr(g_slots[i].lr.load()).find("il2cpp") != std::string::npos)) {
                    std::string st;
                    u32 sp = g_slots[i].sp.load(); int n = 0;
                    for (u32 a = sp; a < sp + 0x8000 && n < 40 && va_is_mapped(a); a += 4) {
                        std::string d = describe_addr(rd32(a) & ~1u);
                        if (is_guest_code(rd32(a) & ~1u)) { st += d + " "; ++n; }
                    }
                    logf("[prof]   %d %s stack: %s", g_slots[i].tid.load(), hn.c_str(), st.c_str());
                }
            }
            logf("[prof] blocked: %s", b.c_str());
            extern void sem_stats_dump(); sem_stats_dump();
        }
    }
    return nullptr;
}
void profile_start() { pthread_t t; pthread_create(&t, nullptr, profile_thread, nullptr); pthread_detach(t); }

// Per-thread import trace: svc_trace_thread(n) logs this thread's next n imported calls
// (name, first args, r0 on return, caller) -- for following a module past a thunk.
static thread_local int t_trace_left = 0;
static std::atomic<int> g_trace_all{0};   // all threads, noisy calls skipped
void svc_trace_thread(int n) { t_trace_left = 0; g_trace_all = n; }
static bool trace_noisy(const std::string& n) {
    static const char* k[] = {"pthread_mutex_lock", "pthread_mutex_unlock", "pthread_mutex_trylock", "malloc", "free", "calloc",
        "realloc", "memalign", "memcpy", "memset", "memcmp", "memmove", "memchr", "strlen", "strcmp", "strncmp", "__aeabi_memcpy",
        "__aeabi_memcpy4", "__aeabi_memcpy8", "__aeabi_memset", "__aeabi_memset4", "__aeabi_memset8", "__aeabi_memclr",
        "__aeabi_memclr4", "__aeabi_memclr8", "__aeabi_memmove", "__aeabi_memmove4", "__aeabi_memmove8", "gettimeofday",
        "clock_gettime", "pthread_getspecific", "pthread_setspecific", "pthread_self", "ceilf", "floorf", "sqrtf", "sinf",
        "cosf", "pthread_cond_wait", "pthread_cond_signal", "pthread_cond_broadcast", "pthread_cond_timedwait", "sem_wait",
        "sem_post", "nanosleep", "usleep", "sched_yield", "eglSwapBuffers", "__errno", "pthread_equal", "strchr", "atan2f",
        "powf", "expf", "logf", "fmodf", "sin", "cos", "sqrt", "pow", "exp", "log", "floor", "ceil", "fmod", "atan2", "glGetError"};
    for (const char* x : k) if (n == x) return true;
    return n.rfind("gl", 0) == 0 || n.rfind("__aeabi", 0) == 0;
}

void svc_run(u32 swi, Ctx& c) {
    if (swi == kSvcReturn) { c.halt_return(); return; }
    if (g_range_fn && swi >= g_range_base && swi < g_range_base + g_range_count) {
        g_range_fn(swi - g_range_base, c);
        return;
    }
    if (swi >= g_handlers.size()) fatal("bad svc #%u", swi);
    if (swi < kMaxCount) g_counts[swi].fetch_add(1, std::memory_order_relaxed);
    g_cur_svc = swi;
    VLOG("[call] %s", g_hnames[swi].c_str());
    ThreadSlot* ts = my_slot();
    u32 prev = ts->in;
    ts->in = swi + 1;
    ts->lr = c.jit() ? c.jit()->Regs()[14] : 0;
    ts->sp = c.jit() ? c.jit()->Regs()[13] : 0;
    ts->a0 = c.jit() ? c.jit()->Regs()[0] : 0;
    if (((t_trace_left > 0) || (g_trace_all.load(std::memory_order_relaxed) > 0 && !trace_noisy(g_hnames[swi]))) && c.jit()) {
        if (t_trace_left > 0) --t_trace_left; else --g_trace_all;
        auto& R = c.jit()->Regs(); u32 a0 = R[0], a1 = R[1], a2 = R[2], lr = R[14];
        g_handlers[swi](c);
        logf("[trace] %s(%08x, %08x, %08x) -> %08x  from %s", g_hnames[swi].c_str(), a0, a1, a2, c.jit()->Regs()[0],
             describe_addr(lr).c_str());
        ts->in = prev;
        return;
    }
    g_handlers[swi](c);
    ts->in = prev;
}

static void lazy_unimplemented(Ctx& c) {
    const char* nm = g_cur_svc < g_hnames.size() ? g_hnames[g_cur_svc].c_str() : "?";
    fatal("unimplemented import '%s' called from %s",
          nm, describe_addr(c.jit()->Regs()[14]).c_str());
}

// =====================================================================
// Handlers.  Each reads AAPCS args from the Ctx and writes r0 (/r1).
// =====================================================================
#define DEF(name) static void h_##name(Ctx& c)

// ---------- heap ----------
DEF(malloc)    { c.retp(gmalloc(c.arg(0))); }
DEF(free)      { gfree(c.argp(0)); }
DEF(calloc)    { c.retp(gcalloc(c.arg(0), c.arg(1))); }
DEF(realloc)   { c.retp(grealloc(c.argp(0), c.arg(1))); }
DEF(memalign)  { c.retp(gmemalign(c.arg(0), c.arg(1))); }
DEF(posix_memalign) {
    gaddr p = gmemalign(c.arg(1), c.arg(2));
    wr32(c.argp(0), p);
    c.ret(p ? 0 : 12);
}
DEF(strdup)    { c.retp(gstrdup(HS(c.argp(0)))); }

// ---------- mem/str (operate directly on flat guest memory) ----------
DEF(memcpy)  { memcpy(H(c.argp(0)), H(c.argp(1)), c.arg(2)); c.retp(c.argp(0)); }
DEF(memmove) { memmove(H(c.argp(0)), H(c.argp(1)), c.arg(2)); c.retp(c.argp(0)); }
DEF(memset)  { memset(H(c.argp(0)), int(c.arg(1)), c.arg(2)); c.retp(c.argp(0)); }
DEF(memcmp)  { c.ret(u32(memcmp(H(c.argp(0)), H(c.argp(1)), c.arg(2)))); }
DEF(memchr)  { void* p = memchr(H(c.argp(0)), int(c.arg(1)), c.arg(2)); c.retp(p ? G(p) : 0); }
DEF(strlen)  { c.ret(u32(strlen(HS(c.argp(0))))); }
DEF(strcmp)  { c.ret(u32(strcmp(HS(c.argp(0)), HS(c.argp(1))))); }
DEF(strncmp) { c.ret(u32(strncmp(HS(c.argp(0)), HS(c.argp(1)), c.arg(2)))); }
DEF(strcpy)  { strcpy(reinterpret_cast<char*>(H(c.argp(0))), HS(c.argp(1))); c.retp(c.argp(0)); }
DEF(strncpy) { strncpy(reinterpret_cast<char*>(H(c.argp(0))), HS(c.argp(1)), c.arg(2)); c.retp(c.argp(0)); }
DEF(strcat)  { strcat(reinterpret_cast<char*>(H(c.argp(0))), HS(c.argp(1))); c.retp(c.argp(0)); }
DEF(strncat) { strncat(reinterpret_cast<char*>(H(c.argp(0))), HS(c.argp(1)), c.arg(2)); c.retp(c.argp(0)); }
DEF(strchr)  { char* p = strchr(const_cast<char*>(HS(c.argp(0))), int(c.arg(1))); c.retp(p ? G(p) : 0); }
DEF(strrchr) { char* p = strrchr(const_cast<char*>(HS(c.argp(0))), int(c.arg(1))); c.retp(p ? G(p) : 0); }
DEF(strstr)  { char* p = strstr(const_cast<char*>(HS(c.argp(0))), HS(c.argp(1))); c.retp(p ? G(p) : 0); }
DEF(strtol)  {
    char* end = nullptr;
    long v = strtol(HS(c.argp(0)), &end, int(c.arg(2)));
    if (c.argp(1)) wr32(c.argp(1), G(end));
    c.ret(u32(v));
}

// ---------- __aeabi memory aliases ----------
DEF(aeabi_memcpy)  { memcpy(H(c.argp(0)), H(c.argp(1)), c.arg(2)); }
DEF(aeabi_memmove) { memmove(H(c.argp(0)), H(c.argp(1)), c.arg(2)); }
DEF(aeabi_memset)  { memset(H(c.argp(0)), int(c.arg(2)), c.arg(1)); }      // note arg order
DEF(aeabi_memclr)  { memset(H(c.argp(0)), 0, c.arg(1)); }

// ---------- errno / TLS ----------
DEF(__errno) {
    c.retp(guest_errno_addr());
}

// ---------- stack protector ----------
DEF(__stack_chk_fail) {
    auto& R = c.jit()->Regs();
    logf("guest __stack_chk_fail in %s  SP=%08x", describe_addr(R[14] & ~1u).c_str(), R[13]);
    int n = 0;
    for (u32 a = R[13]; a < R[13] + 0x1000 && n < 16 && va_is_mapped(a); a += 4)
        if (is_guest_code(rd32(a) & ~1u)) { logf("  stk %s", describe_addr(rd32(a) & ~1u).c_str()); ++n; }
    fatal("guest __stack_chk_fail (stack smashing detected)");
}

// ---------- logging ----------
static int g_prio_map(int p) { return p; }
DEF(__android_log_print) {
    int prio = int(c.arg(0));
    const char* tag = HS(c.argp(1));
    const char* fmt = HS(c.argp(2));
    // Minimal printf: handle the common %s/%d/%p by copying to host and letting
    // host vsnprintf read from already-materialised guest strings is unsafe for
    // pointers, so just emit tag+fmt verbatim unless there are no args.
    logf("[guest:%s] %s", tag ? tag : "", fmt ? fmt : "");
    (void)prio; (void)g_prio_map;
    c.ret(0);
}
DEF(__android_log_write) {
    logf("[guest:%s] %s", HS(c.argp(1)), HS(c.argp(2)));
    c.ret(0);
}

// ---------- atexit / cxa ----------
DEF(__cxa_atexit) { c.ret(0); }       // we never run guest destructors in the PoC
DEF(__cxa_finalize) { c.ret(0); }
DEF(__aeabi_atexit) { c.ret(0); }
DEF(atexit) { c.ret(0); }

// ---------- misc no-ops / trivials ----------
DEF(__gnu_Unwind_Find_exidx) {
    // Return the guest .ARM.exidx base+count for the PC. The loader records them.
    extern bool exidx_for(gaddr pc, gaddr* base, u32* count);
    gaddr base = 0; u32 count = 0;
    exidx_for(c.argp(0), &base, &count);
    if (c.argp(1)) wr32(c.argp(1), count);
    c.retp(base);
}
DEF(__system_property_get) {
    // name in r0, value buffer in r1; report empty.
    if (c.argp(1)) *reinterpret_cast<char*>(H(c.argp(1))) = 0;
    c.ret(0);
}
DEF(pthread_once) {
    gaddr once = c.argp(0);
    if (rd32(once) == 0) {
        wr32(once, 1);
        call_guest(c.argp(1), {});
    }
    c.ret(0);
}
DEF(pthread_self)       { c.retp(cur_thread()->self); }
DEF(pthread_getspecific){ c.retp(cur_thread()->specific[c.arg(0) & 127]); }
DEF(pthread_setspecific){ cur_thread()->specific[c.arg(0) & 127] = c.arg(1); c.ret(0); }
static u32 g_next_key = 1;
DEF(pthread_key_create) { wr32(c.argp(0), g_next_key++ & 127); c.ret(0); }
DEF(pthread_key_delete) { c.ret(0); }
DEF(pthread_mutex_lock) { c.ret(0); }     // single-threaded enough for JNI_OnLoad
DEF(pthread_mutex_unlock){ c.ret(0); }
DEF(pthread_mutex_init) { c.ret(0); }
DEF(pthread_mutex_destroy){ c.ret(0); }
DEF(gettid)             { c.ret(cur_thread()->tid); }
DEF(getpid)             { c.ret(u32(getpid())); }
DEF(sched_yield)        { sched_yield(); c.ret(0); }
DEF(clock_gettime) {
    struct timespec ts; clock_gettime(c.arg(0), &ts);
    wr32(c.argp(1), u32(ts.tv_sec));
    wr32(c.argp(1) + 4, u32(ts.tv_nsec));
    c.ret(0);
}
DEF(gettimeofday) {
    struct timeval tv; gettimeofday(&tv, nullptr);
    if (c.argp(0)) { wr32(c.argp(0), u32(tv.tv_sec)); wr32(c.argp(0) + 4, u32(tv.tv_usec)); }
    c.ret(0);
}
DEF(abort) { fatal("guest called abort()"); }
DEF(snprintf_stub) {
    // Not a real varargs impl; copy the format if it has no conversions.
    char* dst = reinterpret_cast<char*>(H(c.argp(0)));
    u32 n = c.arg(1);
    const char* fmt = HS(c.argp(2));
    if (!strchr(fmt, '%')) { strncpy(dst, fmt, n); if (n) dst[n - 1] = 0; c.ret(u32(strlen(fmt))); }
    else { if (n) dst[0] = 0; c.ret(0); }
}

// ---------- data symbols ----------
static gaddr make_u32(u32 v) { gaddr a = va_alloc(0x1000); wr32(a, v); return a; }
static gaddr d_stack_chk_guard() { return make_u32(0xDEADBEEF); }
static gaddr d_environ() { gaddr a = va_alloc(0x1000); wr32(a, 0); /* empty */ return a; }
static gaddr d_sF() { return va_alloc(0x1000); }   // stdio FILEs: zeroed
static gaddr d_ctype() {
    gaddr a = va_alloc(0x400);
    u8* t = reinterpret_cast<u8*>(H(a));
    for (int i = -1; i < 256; ++i) {
        int ch = i < 0 ? 0 : i;
        u8 f = 0;
        if (isupper(ch)) f |= 0x01;
        if (islower(ch)) f |= 0x02;
        if (isdigit(ch)) f |= 0x04;
        if (isspace(ch)) f |= 0x08;
        if (ispunct(ch)) f |= 0x10;
        if (iscntrl(ch)) f |= 0x20;
        if (isxdigit(ch)) f |= 0x40;
        if (ch == ' ') f |= 0x80;
        t[i + 1] = f;
    }
    return a + 1;   // pointer is biased so index -1 (EOF) is valid
}
static gaddr d_tolower() {
    gaddr a = va_alloc(0x400);
    short* t = reinterpret_cast<short*>(H(a));
    for (int i = -1; i < 256; ++i) t[i + 1] = short(i < 0 ? -1 : tolower(i));
    return a + 2;
}
static gaddr d_toupper() {
    gaddr a = va_alloc(0x400);
    short* t = reinterpret_cast<short*>(H(a));
    for (int i = -1; i < 256; ++i) t[i + 1] = short(i < 0 ? -1 : toupper(i));
    return a + 2;
}

template <gaddr (*Make)()> static gaddr d_ptr_to() { gaddr v = va_alloc(0x1000); wr32(v, Make()); return v; }

// ARM Linux "kuser helpers" page at 0xffff0000 (old-ABI atomics / TLS that
// pre-ARMv7-aware code, e.g. libNianticLabsPlugin's libgcc, calls at fixed
// addresses). Same contract as the kernel's, implemented with LDREX/STREX so the
// translator's exclusive monitor makes them atomic.
static void kuser_init() {
    const gaddr page = 0xffff0000u;
    if (mprotect(g_base + page, 0x1000, PROT_READ | PROT_WRITE) != 0) { logf("[kuser] map failed"); return; }
    static const u32 cmpxchg64[] = {0xe92d00f0, 0xe1c040d0, 0xe1c160d0, 0xe1b20f9f, 0xe0303004, 0x00313005,
                                    0x01a23f96, 0x03330001, 0x0afffff9, 0xe2730000, 0xe8bd00f0, 0xe12fff1e};
    static const u32 barrier[] = {0xf57ff05b, 0xe12fff1e};
    static const u32 cmpxchg[] = {0xe1923f9f, 0xe0533000, 0x01823f91, 0x03330001, 0x0afffffa, 0xe2730000, 0xe12fff1e};
    static const u32 get_tls[] = {0xee1d0f70, 0xe12fff1e};
    auto put = [&](gaddr at, const u32* w, size_t n) { for (size_t i = 0; i < n; ++i) wr32(at + u32(i) * 4, w[i]); };
    put(page + 0xf60, cmpxchg64, 12);
    put(page + 0xfa0, barrier, 2);
    put(page + 0xfc0, cmpxchg, 7);
    put(page + 0xfe0, get_tls, 2);
    wr32(page + 0xffc, 5);   // __kuser_helper_version
}

// =====================================================================
void thunks_init() {
    kuser_init();
    // Fixed thunk region so stub addresses are stable and labelable.
    gaddr region = va_alloc(2 << 20);       // room for ~256k stubs
    g_region_start = region;
    g_thunk_base = region;
    g_thunk_end = region + (2 << 20);

    // Return sentinel first (its own svc immediate).
    g_halt_stub = emit_stub(kSvcReturn);
    // From here, emit_stub() is only called through handler_index so index==slot.
    // Reset the cursor past the sentinel and keep region_start aligned to it:
    g_region_start = g_thunk_base;          // index 0 starts after the sentinel

#define REG(sym) register_handler(#sym, h_##sym)
    REG(malloc); REG(free); REG(calloc); REG(realloc); REG(memalign);
    register_handler("posix_memalign", h_posix_memalign);
    REG(strdup);
    REG(memcpy); REG(memmove); REG(memset); REG(memcmp); REG(memchr);
    REG(strlen); REG(strcmp); REG(strncmp); REG(strcpy); REG(strncpy);
    REG(strcat); REG(strncat); REG(strchr); REG(strrchr); REG(strstr); REG(strtol);
    register_handler("__aeabi_memcpy", h_aeabi_memcpy);
    register_handler("__aeabi_memcpy4", h_aeabi_memcpy);
    register_handler("__aeabi_memcpy8", h_aeabi_memcpy);
    register_handler("__aeabi_memmove", h_aeabi_memmove);
    register_handler("__aeabi_memmove4", h_aeabi_memmove);
    register_handler("__aeabi_memmove8", h_aeabi_memmove);
    register_handler("__aeabi_memset", h_aeabi_memset);
    register_handler("__aeabi_memset4", h_aeabi_memset);
    register_handler("__aeabi_memset8", h_aeabi_memset);
    register_handler("__aeabi_memclr", h_aeabi_memclr);
    register_handler("__aeabi_memclr4", h_aeabi_memclr);
    register_handler("__aeabi_memclr8", h_aeabi_memclr);
    register_handler("__errno", h___errno);
    register_handler("__stack_chk_fail", h___stack_chk_fail);
    register_handler("__android_log_print", h___android_log_print);
    register_handler("__android_log_write", h___android_log_write);
    register_handler("__cxa_atexit", h___cxa_atexit);
    register_handler("__cxa_finalize", h___cxa_finalize);
    register_handler("__aeabi_atexit", h___aeabi_atexit);
    REG(atexit);
    register_handler("__gnu_Unwind_Find_exidx", h___gnu_Unwind_Find_exidx);
    register_handler("__system_property_get", h___system_property_get);
    REG(pthread_once); REG(pthread_self); REG(pthread_getspecific); REG(pthread_setspecific);
    REG(pthread_key_create); REG(pthread_key_delete);
    REG(pthread_mutex_lock); REG(pthread_mutex_unlock); REG(pthread_mutex_init); REG(pthread_mutex_destroy);
    REG(gettid); REG(getpid); REG(sched_yield); REG(clock_gettime); REG(gettimeofday); REG(abort);
    register_handler("snprintf", h_snprintf_stub);
#undef REG

    register_data("__stack_chk_guard", d_stack_chk_guard);
    register_data("environ", d_environ);
    register_data("__sF", d_sF);
    // bionic LP32: `extern const char* _ctype_;` / `const short* _tolower_tab_` —
    // pointer VARIABLES holding the (EOF-biased) table address, not the tables.
    register_data("_ctype_", d_ptr_to<d_ctype>);
    register_data("_tolower_tab_", d_ptr_to<d_tolower>);
    register_data("_toupper_tab_", d_ptr_to<d_toupper>);
}

gaddr guest_errno_addr() {
    // One guest word per host thread, kept in the TLS page (offset 0x40).
    return cur_thread()->tls + 0x40;
}

}  // namespace wst

namespace wst {
u32 thunk_cur_index() { return g_cur_svc; }
u32 thunk_index_of(gaddr stub) { return (stub - g_region_start) / kStubStride; }
}  // namespace wst

namespace wst {
const char* thunk_cur_name() { return g_cur_svc < g_hnames.size() ? g_hnames[g_cur_svc].c_str() : "?"; }
}  // namespace wst
