// Guest hooks + the C surface the in-app Frida agent's shim drives (see
// work/mods/android-035/t64/). The agent runs in the 64-bit host; everything it does to
// the 32-bit game goes through these exports:
//
//   wst_gbase()                         host address of guest address 0
//   wst_gcall(fn, args, n)              call guest code (r0-r3 + stack), r0|r1<<32 back
//   wst_gsym(lib, name)                 a guest module's export (Thumb bit kept)
//   wst_gmodule(lib, &base, &size)      where a guest module sits
//   wst_galloc(n) / wst_gfree(p)        guest heap
//   wst_ghook(addr, cb, leave)          patch a guest function's entry -> cb
//   wst_ghook_orig(id)                  callable copy of the entry (the original)
//   wst_gunhook(id)
//
// A hook overwrites the first 8 bytes of the function with a jump to an SVC stub. The stub
// hands the registers to the host callback, which either lets the original run (through a
// trampoline: the relocated first instructions + a jump back) or returns at once with r0/r1
// it set. On the hooking thread, a call to the same function made from inside its own
// callback goes straight to the original, like Frida's Interceptor.replace.
#include "cpu.h"
#include "elf.h"
#include "thunks_ctx.h"

#include <mutex>
#include <unordered_map>
#include <vector>

#include "dynarmic/interface/A32/a32.h"

namespace wst {

void guest_code_changed(u32 addr, u32 len);   // cpu.cpp
void guest_jump(Ctx& c, u32 target);

// regs: r0..r15, cpsr. Returns 0 = run the original, 1 = return now (r0/r1 as set),
// 2 = run the original and call back again (kind 1) when it returns.
// kind: 0 = entry, 1 = leave (only for hooks asked to see the return).
using HookCb = int (*)(int id, int kind, u32* regs);

struct Hook {
    u32 addr = 0;            // with the Thumb bit
    u32 tramp = 0;           // callable original, with the Thumb bit
    HookCb cb = nullptr;
    bool leave = false;
    bool live = false;
    u8 saved[12] = {};
    u32 saved_len = 0;
};
static std::mutex g_mu;
static std::vector<Hook> g_hooks;
static std::unordered_map<u32, int> g_by_stub;        // thunk index -> hook id
static gaddr g_leave_stub = 0;

struct Pending { u32 lr; int id; u32 sp; };
static thread_local std::vector<Pending> t_leave;      // returns we are waiting for
static thread_local std::vector<int> t_in_cb;          // hooks whose callback runs on this thread

// ---- relocation of the overwritten entry ----
struct Emit {
    std::vector<u8> code;
    std::vector<std::pair<size_t, u32>> lits;   // (offset of the 32-bit LDR, value)
    void h(u16 v) { code.push_back(u8(v)); code.push_back(u8(v >> 8)); }
    void w(u32 v) { for (int i = 0; i < 4; ++i) code.push_back(u8(v >> (8 * i))); }
};

static bool thumb32(u16 hw) { return (hw >> 11) == 0x1D || (hw >> 11) == 0x1E || (hw >> 11) == 0x1F; }

// Thumb: LDR.W Rt, [PC, #lit] -- fixed up once the literal pool position is known.
static void t_ldr_lit(Emit& e, int rt, u32 value) {
    e.lits.emplace_back(e.code.size(), value);
    e.h(0xF8DF); e.h(u16(rt << 12));
}

static bool reloc_thumb(u32 pc, u32 need, Emit& e, u32* consumed) {
    u32 off = 0;
    while (off < need) {
        u32 a = pc + off;
        u16 hw = rd16(a);
        if (thumb32(hw)) {
            u16 hw2 = rd16(a + 2);
            if ((hw & 0xFF7F) == 0xF85F) {                     // LDR.W Rt, [PC, #+-imm12]
                int rt = hw2 >> 12; u32 imm = hw2 & 0xFFF;
                u32 base = (a + 4) & ~3u;
                u32 src = (hw & 0x80) ? base + imm : base - imm;
                t_ldr_lit(e, rt, src);
                e.h(u16(0xF8D0 | rt)); e.h(u16(rt << 12));    // LDR.W Rt, [Rt]
            } else if ((hw & 0xF800) == 0xF000 && (hw2 & 0xC000) == 0xC000) {
                return false;                                  // BL/BLX: not in a prologue we handle
            } else if ((hw & 0xF800) == 0xF000 && (hw2 & 0x8000) == 0x8000) {
                return false;                                  // B.W / Bcc.W
            } else {
                e.h(hw); e.h(hw2);
            }
            off += 4;
        } else {
            if (hw == 0x4770 || (hw & 0xFF00) == 0xBD00) {     // BX LR / POP {..,pc}: function ends
                e.h(hw); off += 2;
                if (off < need) return false;                  // shorter than the patch
                continue;
            }
            if ((hw & 0xF800) == 0x4800) {                     // LDR Rt, [PC, #imm8*4]
                int rt = (hw >> 8) & 7;
                u32 src = ((a + 4) & ~3u) + (hw & 0xFF) * 4;
                t_ldr_lit(e, rt, src);
                e.h(u16(0x6800 | (rt << 3) | rt));             // LDR Rt, [Rt]
            } else if ((hw & 0xFF78) == 0x4478) {              // ADD Rdn, PC
                int rd = (hw & 7) | ((hw >> 4) & 8);
                t_ldr_lit(e, 12, a + 4);
                e.h(u16(0x4400 | ((rd & 8) << 4) | (12 << 3) | (rd & 7)));   // ADD Rd, r12
            } else if ((hw & 0xF800) == 0xA000) {              // ADR Rd, #imm8*4
                int rd = (hw >> 8) & 7;
                t_ldr_lit(e, rd, ((a + 4) & ~3u) + (hw & 0xFF) * 4);
            } else if ((hw & 0xF000) == 0xD000 || (hw & 0xF800) == 0xE000 || (hw & 0xF500) == 0xB100 ||
                       (hw & 0xFF00) == 0xBF00 && (hw & 0xF) != 0 || (hw & 0xFF87) == 0x4687 ||
                       (hw & 0xFF00) == 0x4700) {
                return false;                                  // branches, IT blocks, writes to PC
            } else {
                e.h(hw);
            }
            off += 2;
        }
    }
    *consumed = off;
    return true;
}

static bool reloc_arm(u32 pc, u32 need, Emit& e, u32* consumed) {
    for (u32 off = 0; off < need; off += 4) {
        u32 a = pc + off, i = rd32(a);
        u32 cond = i >> 28;
        if (cond == 0xF) return false;
        if ((i & 0x0F7F0000) == 0x051F0000 && cond == 0xE) {   // LDR Rt, [PC, #+-imm12]
            int rt = (i >> 12) & 15;
            if (rt == 15) return false;
            u32 src = (i & (1u << 23)) ? a + 8 + (i & 0xFFF) : a + 8 - (i & 0xFFF);
            e.lits.emplace_back(e.code.size(), src);
            e.w(0xE59F0000u | (u32(rt) << 12));                // LDR Rt, [PC, #lit]
            e.w(0xE5900000u | (u32(rt) << 16) | (u32(rt) << 12));   // LDR Rt, [Rt]
            continue;
        }
        if (i == 0xE12FFF1Eu || (i & 0xFFFF8000u) == 0xE8BD8000u) {   // BX LR / POP {..,pc}
            e.w(i);
            if (off + 4 < need) return false;
            continue;
        }
        if ((i & 0x0E000000) == 0x0A000000) return false;      // B / BL
        bool dp = (i & 0x0C000000) == 0;
        if (dp && (((i >> 16) & 15) == 15 || ((i >> 12) & 15) == 15 || (!(i & (1u << 25)) && (i & 15) == 15)))
            return false;                                      // data processing touching PC
        if ((i & 0x0C000000) == 0x04000000 && (((i >> 16) & 15) == 15 || ((i >> 12) & 15) == 15))
            return false;                                      // other loads/stores with PC
        if ((i & 0x0E000000) == 0x08000000 && (i & (1u << 15))) return false;   // LDM ... pc
        e.w(i);
    }
    *consumed = need;
    return true;
}

// Builds the trampoline in guest memory: relocated entry, jump back, literal pool.
static u32 build_tramp(u32 addr, u32* patched_len) {
    bool thumb = addr & 1;
    u32 pc = addr & ~1u;
    Emit e; u32 used = 0;
    if (thumb) {
        if (!reloc_thumb(pc, 8, e, &used)) return 0;
        if (e.code.size() & 2) e.h(0xBF00);                    // NOP: LDR.W PC below 4-aligned
        e.h(0xF8DF); e.h(0xF000);                              // LDR.W PC, [PC, #0]
        e.w((pc + used) | 1);
    } else {
        if (!reloc_arm(pc, 8, e, &used)) return 0;
        e.w(0xE51FF004u);                                      // LDR PC, [PC, #-4]
        e.w(pc + used);
    }
    size_t pool = e.code.size();
    for (size_t k = 0; k < e.lits.size(); ++k) e.w(0);
    gaddr t = gmalloc(u32(e.code.size()) + 8);
    t = (t + 3) & ~3u;
    memcpy(H(t), e.code.data(), e.code.size());
    // patch each LDR literal's offset now that the pool sits at t + pool
    for (size_t k = 0; k < e.lits.size(); ++k) {
        size_t at = e.lits[k].first;
        u32 lit = t + u32(pool + 4 * k);
        if (thumb) {
            u32 base = (t + u32(at) + 4) & ~3u;
            u16 hw2 = rd16(t + u32(at) + 2);
            wr16(t + u32(at) + 2, u16((hw2 & 0xF000) | (lit - base)));
        } else {
            u32 ins = rd32(t + u32(at));
            wr32(t + u32(at), (ins & ~0xFFFu) | (lit - (t + u32(at) + 8)));
        }
        wr32(lit, e.lits[k].second);   // LDR-literal: the source address (then [Rt]); ADR/ADD-PC: the value
    }
    *patched_len = used;
    guest_code_changed(t, u32(e.code.size()));
    return thumb ? (t | 1) : t;
}

static void h_hook(Ctx& c);
static void h_leave(Ctx& c);

static void regs_out(Ctx& c, u32* r) {
    auto& R = c.jit()->Regs();
    for (int i = 0; i < 16; ++i) r[i] = R[i];
    r[16] = c.jit()->Cpsr();
}
static void regs_in(Ctx& c, const u32* r) {
    auto& R = c.jit()->Regs();
    for (int i = 0; i < 13; ++i) R[i] = r[i];
    R[14] = r[14];
}

static void h_hook(Ctx& c) {
    int id;
    Hook h;
    {
        std::lock_guard<std::mutex> l(g_mu);
        auto it = g_by_stub.find(thunk_cur_index());
        if (it == g_by_stub.end()) fatal("hook stub without hook");
        id = it->second; h = g_hooks[id];
    }
    bool nested = false;
    for (int x : t_in_cb) if (x == id) { nested = true; break; }
    if (!h.live || nested || !h.cb) { guest_jump(c, h.tramp); return; }
    u32 r[17]; regs_out(c, r);
    t_in_cb.push_back(id);
    int act = h.cb(id, 0, r);
    t_in_cb.pop_back();
    regs_in(c, r);
    if (act == 1) { guest_jump(c, r[14]); return; }          // replaced: back to the caller
    if (act == 2) {                                          // run the original, then see its return
        t_leave.push_back({r[14], id, r[13]});
        c.jit()->Regs()[14] = g_leave_stub;                  // the original returns into h_leave
    }
    guest_jump(c, h.tramp);
}

static void h_leave(Ctx& c) {
    u32 sp = c.jit()->Regs()[13];
    // drop records of frames that never returned here (longjmp / exceptions)
    while (!t_leave.empty() && t_leave.back().sp < sp) t_leave.pop_back();
    if (t_leave.empty()) fatal("hook leave with nothing pending");
    Pending p = t_leave.back(); t_leave.pop_back();
    HookCb cb; { std::lock_guard<std::mutex> l(g_mu); cb = g_hooks[p.id].cb; }
    u32 r[17]; regs_out(c, r);
    r[14] = p.lr;
    if (cb) { t_in_cb.push_back(p.id); cb(p.id, 1, r); t_in_cb.pop_back(); }
    regs_in(c, r);
    guest_jump(c, p.lr);
}

}  // namespace wst

using namespace wst;

extern "C" {

__attribute__((visibility("default"))) void* wst_gbase() { return g_base; }

__attribute__((visibility("default"))) uint64_t wst_gcall(uint32_t fn, const uint32_t* args, int n) {
    return call_guest_v(fn, args, n);
}

__attribute__((visibility("default"))) uint32_t wst_gsym(const char* lib, const char* name) {
    Module* m = elf_find(lib);
    gaddr a = 0;
    if (m && m->find(name, &a)) return a;
    return 0;
}

__attribute__((visibility("default"))) int wst_gmodule(const char* lib, uint32_t* base, uint32_t* size) {
    Module* m = elf_find(lib);
    if (!m) return 0;
    *base = m->base; *size = m->span;
    return 1;
}

__attribute__((visibility("default"))) uint32_t wst_galloc(uint32_t n) { return gcalloc(1, n ? n : 1); }
__attribute__((visibility("default"))) void wst_gfree(uint32_t p) { gfree(p); }

__attribute__((visibility("default"))) int wst_ghook(uint32_t addr, HookCb cb, int leave) {
    std::lock_guard<std::mutex> l(g_mu);
    for (size_t i = 0; i < g_hooks.size(); ++i)
        if (g_hooks[i].addr == addr && g_hooks[i].live) { logf("[hook] %s already hooked", describe_addr(addr & ~1u).c_str()); return -1; }
    if (!g_leave_stub) g_leave_stub = make_thunk("wst_hook_leave", h_leave);
    Hook h; h.addr = addr; h.cb = cb; h.leave = leave != 0;
    u32 len = 0;
    h.tramp = build_tramp(addr, &len);
    if (!h.tramp) { logf("[hook] %s: entry not relocatable", describe_addr(addr & ~1u).c_str()); return -1; }
    int id = int(g_hooks.size());
    char name[32]; snprintf(name, sizeof name, "wst_hook_%d", id);
    gaddr stub = make_thunk(name, h_hook);
    g_by_stub[thunk_index_of(stub)] = id;
    u32 pc = addr & ~1u;
    h.saved_len = len;
    memcpy(h.saved, H(pc), len);
    if (addr & 1) {
        if (pc & 2) { wr16(pc, 0xF8DF); wr16(pc + 2, 0xF002); wr32(pc + 4, stub); }   // literal at pc+4 (base pc+2... aligned)
        else { wr16(pc, 0xF8DF); wr16(pc + 2, 0xF000); wr32(pc + 4, stub); }
    } else {
        wr32(pc, 0xE51FF004u); wr32(pc + 4, stub);
    }
    for (u32 k = 8; k < len; k += 2) wr16(pc + k, 0xBF00);    // a split instruction's tail: NOPs (never run)
    h.live = true;
    g_hooks.push_back(h);
    guest_code_changed(pc, len < 8 ? 8 : len);
    logf("[hook] #%d %s (%s, %u bytes moved)", id, describe_addr(pc).c_str(), (addr & 1) ? "thumb" : "arm", len);
    return id;
}

__attribute__((visibility("default"))) uint32_t wst_ghook_orig(int id) {
    std::lock_guard<std::mutex> l(g_mu);
    return id >= 0 && id < int(g_hooks.size()) ? g_hooks[id].tramp : 0;
}

__attribute__((visibility("default"))) void wst_gunhook(int id) {
    std::lock_guard<std::mutex> l(g_mu);
    if (id < 0 || id >= int(g_hooks.size()) || !g_hooks[id].live) return;
    Hook& h = g_hooks[id];
    u32 pc = h.addr & ~1u;
    memcpy(H(pc), h.saved, h.saved_len);
    h.live = false;                     // a call already inside the stub still finds its trampoline
    guest_code_changed(pc, h.saved_len);
}

}  // extern "C"
