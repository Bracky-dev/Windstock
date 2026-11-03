// Windstock translator64: runs 32-bit ARM (armeabi-v7a) native libraries on
// 64-bit-only Android by JIT-translating them with Dynarmic.
//
// Guest memory is one 4 GB host reservation: guest address g lives at
// g_base + g on the host, so guest pointers translate with one add.
#pragma once

#include <cstdint>
#include <cstring>
#include <string>

namespace wst {

using u8 = std::uint8_t;
using u16 = std::uint16_t;
using u32 = std::uint32_t;
using u64 = std::uint64_t;
using s32 = std::int32_t;
using s64 = std::int64_t;
using gaddr = std::uint32_t;  // a guest (32-bit) address

extern u8* g_base;

[[noreturn]] void fatal(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
void logf(const char* fmt, ...) __attribute__((format(printf, 1, 2)));
extern int g_verbose;  // 1 = log every import call
#define VLOG(...) do { if (wst::g_verbose) wst::logf(__VA_ARGS__); } while (0)

// guest -> host. 0 stays NULL.
inline void* H(gaddr a) { return a ? g_base + a : nullptr; }
template <class T> inline T* HP(gaddr a) { return reinterpret_cast<T*>(H(a)); }
inline const char* HS(gaddr a) { return reinterpret_cast<const char*>(H(a)); }

inline bool in_guest(const void* p) {
    auto d = reinterpret_cast<const u8*>(p) - g_base;
    return d >= 0 && d < (s64(1) << 32);
}
// host -> guest. The pointer must lie inside the guest space.
inline gaddr G(const void* p) {
    if (!p) return 0;
    if (!in_guest(p)) fatal("host pointer %p escaped into the guest", p);
    return gaddr(reinterpret_cast<const u8*>(p) - g_base);
}

inline u32 rd32(gaddr a) { u32 v; std::memcpy(&v, g_base + a, 4); return v; }
inline u16 rd16(gaddr a) { u16 v; std::memcpy(&v, g_base + a, 2); return v; }
inline void wr16(gaddr a, u16 v) { std::memcpy(g_base + a, &v, 2); }
inline u64 rd64(gaddr a) { u64 v; std::memcpy(&v, g_base + a, 8); return v; }
inline void wr32(gaddr a, u32 v) { std::memcpy(g_base + a, &v, 4); }
inline void wr64(gaddr a, u64 v) { std::memcpy(g_base + a, &v, 8); }

// ---- memory.cpp ----
bool mem_init();
gaddr va_alloc(u32 len, u32 align = 0x1000);          // maps RW, zeroed
bool va_alloc_at(gaddr at, u32 len);                  // fixed placement
void va_free(gaddr a, u32 len);
bool va_is_mapped(gaddr a);
gaddr gmalloc(u32 n);
gaddr gcalloc(u32 n, u32 sz);
gaddr grealloc(gaddr p, u32 n);
gaddr gmemalign(u32 align, u32 n);
void gfree(gaddr p);
gaddr gstrdup(const char* s);
gaddr gdup(const void* p, u32 n);

}  // namespace wst
