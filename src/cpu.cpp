// Dynarmic wiring: one A32 Jit per host->guest nesting level, flat memory
// through g_base, SVC-based host calls, and guest thread bring-up.
#include "cpu.h"
#include "elf.h"

#include <pthread.h>
#include <unistd.h>

#include <atomic>
#include <mutex>
#include <algorithm>
#include <thread>
#include <unordered_map>
#include <cstring>
#include <string>
#include <csignal>

#include "dynarmic/interface/A32/a32.h"
#include "dynarmic/interface/A32/config.h"
#include "dynarmic/interface/exclusive_monitor.h"
#include "thunks_ctx.h"

using namespace Dynarmic;

namespace wst {

static ExclusiveMonitor* g_monitor;

// Halt reasons we raise ourselves.
static constexpr auto HR_RETURN = HaltReason::UserDefined1;  // guest returned to the sentinel
static constexpr auto HR_SVC = HaltReason::UserDefined2;     // an SVC asked to unwind to C++
static constexpr auto HR_SIGNAL = HaltReason::UserDefined3;  // a guest signal is pending
static constexpr auto HR_INVAL = HaltReason::UserDefined4;   // guest code was patched (hooks)

// Guest code patches (hooks.cpp): every JIT drops its translations of the changed ranges
// before it runs again. Ranges only grow; each JIT remembers how many it has applied.
static std::mutex g_inv_mu;
static std::vector<std::pair<u32, u32>> g_inv;
static std::atomic<u32> g_inv_n{0};

struct Callbacks final : A32::UserCallbacks {
    JitSlot* slot = nullptr;

    u8 MemoryRead8(u32 a) override { return *(g_base + a); }
    u16 MemoryRead16(u32 a) override { return rd16(a); }
    u32 MemoryRead32(u32 a) override { return rd32(a); }
    u64 MemoryRead64(u32 a) override { return rd64(a); }
    void MemoryWrite8(u32 a, u8 v) override { *(g_base + a) = v; }
    void MemoryWrite16(u32 a, u16 v) override { std::memcpy(g_base + a, &v, 2); }
    void MemoryWrite32(u32 a, u32 v) override { wr32(a, v); }
    void MemoryWrite64(u32 a, u64 v) override { wr64(a, v); }

    // Exclusive (LDREX/STREX): a real host compare-and-swap on the guest word, so
    // concurrent guest threads (Unity job/render threads) can't both "win".
    template <typename T> static bool cas(u32 a, T v, T e) {
        return __atomic_compare_exchange_n(reinterpret_cast<T*>(g_base + a), &e, v, false,
                                           __ATOMIC_SEQ_CST, __ATOMIC_SEQ_CST);
    }
    bool MemoryWriteExclusive8(u32 a, u8 v, u8 e) override { return cas<u8>(a, v, e); }
    bool MemoryWriteExclusive16(u32 a, u16 v, u16 e) override { return cas<u16>(a, v, e); }
    bool MemoryWriteExclusive32(u32 a, u32 v, u32 e) override { return cas<u32>(a, v, e); }
    bool MemoryWriteExclusive64(u32 a, u64 v, u64 e) override { return cas<u64>(a, v, e); }

    void InterpreterFallback(u32 pc, size_t n) override {
        fatal("no interpreter: undecoded instruction at %s (%zu)", describe_addr(pc).c_str(), n);
    }
    void CallSVC(u32 swi) override { dispatch_svc(swi); }
    // Dynarmic's ASIMD decoder has VADDHN/VRADDHN/VSUBHN/VRSUBHN commented out, so they surface
    // as an "unpredictable instruction". Unity's colour/skinning code uses VADDHN.I16, so do it
    // here in software: Dd = high half of (Qn +/- Qm), optionally rounded, then resume at pc+4.
    // ARM state only (the guest only uses the ARM encoding of these).
    bool emulate_narrow_addsub(u32 pc) {
        auto* j = cur_jit();
        if (j->Cpsr() & 0x20) return false;                         // Thumb: not handled
        u32 op = rd32(pc);
        if ((op & 0xFE800000u) != 0xF2800000u) return false;        // 1111 001U 1 D size ...
        u32 opc = (op >> 8) & 0xF, size = (op >> 20) & 3;
        if ((opc != 4 && opc != 6) || (op & 0x50u) != 0 || size == 3) return false;
        bool sub = opc == 6, rnd = (op >> 24) & 1;
        u32 vd = ((op >> 22) & 1) << 4 | ((op >> 12) & 0xF);
        u32 vn = ((op >> 7) & 1) << 4 | ((op >> 16) & 0xF);
        u32 vm = ((op >> 5) & 1) << 4 | (op & 0xF);
        if ((vn & 1) || (vm & 1)) return false;                     // Q registers: even D index
        auto& X = j->ExtRegs();                                     // d(n) = X[2n], X[2n+1]
        auto dword = [&](u32 d) { return u64(X[2 * d]) | u64(X[2 * d + 1]) << 32; };
        u64 res = 0;
        const int bits = 16 << size, nlanes = 64 / (bits / 2);      // narrow dest lane = bits/2
        for (int i = 0; i < nlanes; ++i) {
            // source lane i lives in the low (i < nlanes/2) or high D register of the Q pair
            int per = 64 / bits;
            u32 dn = vn + (i >= per), dm = vm + (i >= per);
            int sh = (i % per) * bits;
            u64 mask = bits == 64 ? ~0ull : ((1ull << bits) - 1);
            u64 a = (dword(dn) >> sh) & mask, b = (dword(dm) >> sh) & mask;
            u64 r = sub ? (a - b) : (a + b);
            if (rnd) r += 1ull << (bits / 2 - 1);
            r &= mask;
            res |= ((r >> (bits / 2)) & ((1ull << (bits / 2)) - 1)) << (i * (bits / 2));
        }
        X[2 * vd] = u32(res); X[2 * vd + 1] = u32(res >> 32);
        j->Regs()[15] = pc + 4;
        return true;
    }
    void ExceptionRaised(u32 pc, A32::Exception e) override {
        // Hints (WFE/WFI/YIELD/SEV/ISB/NOP-likes) are benign; just continue.
        if (e == A32::Exception::WaitForInterrupt || e == A32::Exception::WaitForEvent ||
            e == A32::Exception::Yield || e == A32::Exception::SendEvent ||
            e == A32::Exception::SendEventLocal)
            return;
        auto& R = cur_jit()->Regs();
        if (emulate_narrow_addsub(pc)) return;
        logf("cpu exception %d at %s", int(e), describe_addr(pc).c_str());
        logf("  LR=%s  SP=%08x", describe_addr(R[14] & ~1u).c_str(), R[13]);
        for (int i = 0; i < 13; ++i) logf("  r%-2d=%08x %s", i, R[i], describe_addr(R[i] & ~1u).c_str());
        // gcc ARM frames: push {.., r11, lr}; add r11, sp, #N  ->  [r11] = lr, [r11-4] = caller r11.
        u32 fp = R[11];
        for (int i = 0; i < 24 && fp > 4 && va_is_mapped(fp - 4) && va_is_mapped(fp); ++i) {
            u32 lr = rd32(fp), prev = rd32(fp - 4);
            logf("  #%-2d lr=%s", i, describe_addr(lr & ~1u).c_str());
            if (prev <= fp) break;
            fp = prev;
        }
        // Heuristic: every stack word that points into a loaded module.
        u32 sp = R[13];
        int shown = 0;
        for (u32 a = sp; a < sp + 0x2000 && shown < 48 && va_is_mapped(a); a += 4) {
            u32 w = rd32(a);
            std::string d = describe_addr(w & ~1u);
            if (is_guest_code(w & ~1u)) { logf("  stk[%04x] %s", a - sp, d.c_str()); ++shown; }
        }
        fatal("cpu exception %d at %s", int(e), describe_addr(pc).c_str());
    }
    void AddTicks(u64) override {}
    u64 GetTicksRemaining() override { return u64(1) << 60; }
};

// One translation context (Jit + its callbacks). Threads nest these when a
// host callback re-enters guest code (pthread start, comparators, ...).
struct JitSlot {
    Callbacks cb;
    std::unique_ptr<A32::Jit> jit;
    u32 inv_seen = 0;
    explicit JitSlot(size_t proc_id) {
        A32::UserConfig c;
        c.callbacks = &cb;
        c.global_monitor = g_monitor;   // arm64 backend needs this for LDREX/STREX
        c.processor_id = proc_id;       // one id per guest thread
        c.arch_version = A32::ArchVersion::v8;
        c.enable_cycle_counting = false;
        c.wall_clock_cntpct = true;   // CNTPCT reads track the host clock, so guest
                                      // timer-calibration spin loops terminate
        c.define_unpredictable_behaviour = true;
        // fastmem: ordinary loads/stores go straight to g_base + addr instead of through
        // the C++ callbacks. The whole 4 GB is reserved, so a stray access faults and
        // Dynarmic falls back to the callbacks for that instruction.
        c.fastmem_pointer = reinterpret_cast<uintptr_t>(g_base);
        c.recompile_on_fastmem_failure = true;
        cb.slot = this;
        jit = std::make_unique<A32::Jit>(c);
        // FPSCR = FZ|DN (flush-to-zero, default NaN), i.e. NEON's "standard FPSCR value"
        // for VFP code too. With any other mode Dynarmic brackets EVERY NEON float op with
        // two FPCR writes (serialising on Apple/ARM cores): Unity's NEON skinning loop ran
        // ~40 of them per vertex. Games don't depend on denormals or NaN payloads.
        jit->SetFpscr(0x03000000);
        inv_seen = g_inv_n.load();      // a fresh JIT has nothing stale
    }
    void apply_inval() {
        u32 n = g_inv_n.load(std::memory_order_acquire);
        if (n == inv_seen) return;
        std::lock_guard<std::mutex> l(g_inv_mu);
        for (u32 i = inv_seen; i < n; ++i) jit->InvalidateCacheRange(g_inv[i].first, g_inv[i].second);
        inv_seen = n;
    }
};

static thread_local GuestThread* t_thread = nullptr;

// --- thread registration ---
// ExclusiveMonitor processor ids: one per LIVE guest thread. Two threads sharing an id
// overwrite each other's LDREX reservation, and two such LDREX/STREX loops on different
// words livelock forever (seen 2026-10-16: render + worker thread at 100% CPU).
static constexpr size_t kProcs = 128;   // ~65 live guest threads in play; every STREX scans all slots
static std::mutex g_proc_mu;
static bool g_proc_used[kProcs];
static size_t proc_take() {
    std::lock_guard<std::mutex> l(g_proc_mu);
    for (size_t i = 0; i < kProcs; ++i) if (!g_proc_used[i]) { g_proc_used[i] = true; return i; }
    fatal("more than %zu live guest threads", kProcs);
}
static void proc_give(size_t i) { std::lock_guard<std::mutex> l(g_proc_mu); if (i < kProcs) g_proc_used[i] = false; }
static gaddr new_tls() {
    // Bionic TLS: a small slot array; slot 1 (TLS_SLOT_THREAD_ID) -> pthread.
    gaddr tls = va_alloc(0x1000);
    wr32(tls + 4, tls);        // pthread_t == TLS base is fine for our libc
    return tls;
}
static GuestThread* attach_current(gaddr stack_lo = 0, u32 stack_size = 0, gaddr tls = 0) {
    auto* gt = new GuestThread();
    gt->jits.reserve(32);      // never reallocated: the signal service reads it from other threads
    gt->tid = u32(gettid());
    gt->proc_id = proc_take();
    if (!stack_lo) {
        stack_size = 8 << 20;
        stack_lo = va_alloc(stack_size);
    }
    gt->stack_lo = stack_lo;
    gt->stack_size = stack_size;
    gt->stack_top = stack_lo + stack_size;
    gt->tls = tls ? tls : new_tls();
    gt->self = gt->tls;
    t_thread = gt;
    sig_register(gt);
    return gt;
}

// A stand-in: a fresh JIT context on another host thread that carries `owner`'s
// identity (pthread_t, TLS, tid, keys) and runs on owner's guest stack below `sp`.
GuestThread* make_standin(GuestThread* owner, gaddr sp) {
    auto* gt = new GuestThread();
    gt->jits.reserve(32);
    gt->tid = owner->tid;
    gt->proc_id = owner->proc_id;   // owner runs no guest code while its stand-in does
    gt->tls = owner->tls; gt->self = owner->self;
    gt->stack_lo = owner->stack_lo; gt->stack_size = owner->stack_size;
    gt->stack_top = sp;
    memcpy(gt->specific, owner->specific, sizeof gt->specific);
    gt->owner = owner;
    t_thread = gt;
    return gt;
}
void drop_standin(GuestThread* gt) { t_thread = nullptr; delete gt; }

// The guest SP a signal would interrupt at (innermost JIT, or the stack top).
gaddr guest_sp_of(GuestThread* gt) {
    return gt->depth > 0 ? gt->jits[gt->depth - 1]->jit->Regs()[13] : gt->stack_top;
}
// Interrupted registers r0-r12, lr of the innermost JIT (for the handler's stack copy).
void guest_regs_of(GuestThread* gt, u32 out[14]) {
    if (gt->depth <= 0) { memset(out, 0, 14 * 4); return; }
    auto& R = gt->jits[gt->depth - 1]->jit->Regs();
    for (int i = 0; i < 13; ++i) out[i] = R[i];
    out[13] = R[14];
}
void set_guest_sp(GuestThread* gt, gaddr sp) {
    if (gt->depth > 0) gt->jits[gt->depth - 1]->jit->Regs()[13] = sp; else gt->stack_top = sp;
}

// ---- guest PC sampler (WST_SAMPLE=0 turns it off): which guest code the threads run ----
static std::mutex g_samp_mu;
static std::unordered_map<u32, std::unordered_map<u32, u32>> g_samp;   // tid -> pc -> hits
void sample_record(u32 tid, u32 pc) {
    std::lock_guard<std::mutex> l(g_samp_mu);
    ++g_samp[tid][pc & ~0x3Fu];                       // 64-byte buckets
}
std::vector<GuestThread*> sig_threads();             // signals.cpp
static void sampler() {
    for (int tick = 1;; ++tick) {
        usleep(5000);
        for (GuestThread* t : sig_threads()) {
            if (!t->run.held.load()) continue;        // not in guest code right now
            t->sample = true;
            jits_halt_signal(t);
        }
        if (tick % 1000) continue;                   // every ~5 s
        std::unordered_map<u32, std::unordered_map<u32, u32>> snap;
        { std::lock_guard<std::mutex> l(g_samp_mu); snap.swap(g_samp); }
        for (auto& kv : snap) {
            u32 total = 0; std::vector<std::pair<u32, u32>> v;
            for (auto& e : kv.second) { total += e.second; v.push_back({e.second, e.first}); }
            if (total < 100) continue;
            std::sort(v.begin(), v.end(), [](auto& a, auto& b) { return a.first > b.first; });
            std::string line;
            for (size_t i = 0; i < v.size() && i < 8; ++i) {
                char b[96]; snprintf(b, sizeof b, " %s=%u%%", describe_addr(v[i].second).c_str(), v[i].first * 100 / total);
                line += b;
            }
            logf("[samp] tid %u (%u samples):%s", kv.first, total, line.c_str());
        }
    }
}
void sampler_start() {
    const char* e = getenv("WST_SAMPLE");
    if (e && !strcmp(e, "0")) return;
    std::thread(sampler).detach();
}

void guest_code_changed(u32 addr, u32 len) {
    {
        std::lock_guard<std::mutex> l(g_inv_mu);
        g_inv.emplace_back(addr, len);
        g_inv_n.store(u32(g_inv.size()), std::memory_order_release);
    }
    for (GuestThread* t : sig_threads())
        for (size_t i = 0, n = t->jits.size(); i < n; ++i) t->jits[i]->jit->HaltExecution(HR_INVAL);
}

// From a thunk: continue the guest at `target` (bit 0 = Thumb) instead of the stub's return.
void guest_jump(Ctx& c, u32 target) {
    auto* j = c.jit();
    j->Regs()[15] = target & ~1u;
    u32 cpsr = j->Cpsr() & ~(1u << 5);
    if (target & 1) cpsr |= 1u << 5;
    j->SetCpsr(cpsr);
    c.unwind();
}

void jits_halt_signal(GuestThread* gt) {
    size_t n = gt->jits.size();
    for (size_t i = 0; i < n; ++i) gt->jits[i]->jit->HaltExecution(HR_SIGNAL);
}

GuestThread* cur_thread() { return t_thread ? t_thread : attach_current(); }

A32::Jit* cur_jit() {
    GuestThread* gt = cur_thread();
    return gt->jits[gt->depth - 1]->jit.get();   // innermost running JIT
}

u64 call_guest_v(gaddr fn, const u32* args, int n) {
    GuestThread* gt = cur_thread();
    // Released inside each SVC, below. Already held when a handler runs at a signal halt
    // (or under deliver_as_self): nested calls then keep it.
    bool took = !gt->run_mine;
    if (took) { gt->run.acquire(); gt->run_mine = true; }
    int slot = gt->depth;                         // 0 for the outermost call
    if (int(gt->jits.size()) <= slot)
        gt->jits.emplace_back(std::make_unique<JitSlot>(gt->proc_id));
    A32::Jit* jit = gt->jits[slot]->jit.get();
    gt->depth++;                                  // nested calls use the next slot
    auto& R = jit->Regs();

    // Lay out AAPCS args: r0-r3, remainder on an 8-byte-aligned stack.
    u32 sp = (slot == 0 ? gt->stack_top : gt->jits[slot - 1]->jit->Regs()[13]);
    int on_stack = n > 4 ? n - 4 : 0;
    sp -= on_stack * 4;
    sp &= ~7u;
    for (int i = 0; i < on_stack; ++i) wr32(sp + i * 4, args[4 + i]);
    for (int i = 0; i < n && i < 4; ++i) R[i] = args[i];
    R[13] = sp;
    R[14] = halt_stub();              // return sentinel (ARM stub, bit0 = 0)
    R[15] = fn & ~1u;
    u32 cpsr = jit->Cpsr() & ~(1u << 5);
    if (fn & 1) cpsr |= (1u << 5);    // T bit
    jit->SetCpsr(cpsr);

    JitSlot* js = gt->jits[slot].get();
    for (;;) {
        js->apply_inval();
        HaltReason hr = jit->Run();
        jit->ClearHalt(hr);
        if (u32(hr) & u32(HR_RETURN)) break;
        // any mix of these just resumes (stale code is dropped at the top of the loop)
        u32 h = u32(hr) & ~(u32(HR_INVAL) | u32(HaltReason::CacheInvalidation));
        if (h & u32(HR_SIGNAL)) {
            if (gt->sample.exchange(false)) sample_record(gt->tid, R[15]);
            sig_on_halt(gt);
            h &= ~u32(HR_SIGNAL);
        }
        h &= ~u32(HR_SVC);                    // an SVC handler already ran
        if (h == 0) continue;
        fatal("guest halted unexpectedly: %08x at %s", u32(hr), describe_addr(jit->Regs()[15]).c_str());
    }
    u64 ret = R[0] | (u64(R[1]) << 32);
    gt->depth--;
    if (took) { gt->run_mine = false; gt->run.release(); }
    return ret;
}

u64 call_guest(gaddr fn, std::initializer_list<u32> args) {
    return call_guest_v(fn, args.begin(), int(args.size()));
}

// Ctx helpers used by thunk handlers.
A32::Jit* Ctx::jit() const { return j; }
u32 Ctx::arg(int i) const {
    if (i < 4) return j->Regs()[i];
    return rd32(j->Regs()[13] + (i - 4) * 4);
}
u64 Ctx::arg64(int i) const {
    // 64-bit args are even-register / 8-byte-stack aligned (AAPCS).
    i = (i + 1) & ~1;
    return u64(arg(i)) | (u64(arg(i + 1)) << 32);
}
void Ctx::ret(u32 v) { j->Regs()[0] = v; }
void Ctx::ret64(u64 v) { j->Regs()[0] = u32(v); j->Regs()[1] = u32(v >> 32); }
void Ctx::halt_return() { j->HaltExecution(HR_RETURN); }
void Ctx::unwind() { j->HaltExecution(HR_SVC); }

static Ctx make_ctx() { Ctx c; c.j = cur_jit(); return c; }

// SVC dispatch lives here so it can build a Ctx.
void dispatch_svc(u32 swi) {
    Ctx c = make_ctx();
    GuestThread* gt = t_thread;
    // Host code that may block (or call back into the guest) lets go of the run lock, so a
    // signal can be handled for this thread meanwhile. Short calls keep it: a signal then
    // waits for the next JIT halt, a few microseconds away.
    if (svc_is_fast(swi)) { svc_run(swi, c); return; }
    gt->run_mine = false; gt->run.release();
    svc_run(swi, c);
    gt->run.acquire(); gt->run_mine = true;
}

// --- new guest thread trampoline ---
namespace {
struct StartArgs { gaddr fn, arg; gaddr stack; u32 size; gaddr tls; };
void* thread_trampoline(void* p) {
    auto* sa = static_cast<StartArgs*>(p);
    GuestThread* gt = attach_current(sa->stack, sa->size, sa->tls);
    gt->start_fn = sa->fn;
    gt->start_arg = sa->arg;
    u32 a = sa->arg;
    delete sa;
    gt->retval = u32(call_guest_v(gt->start_fn, &a, 1));
    g_monitor->ClearProcessor(gt->proc_id);
    proc_give(gt->proc_id);
    return nullptr;
}
}  // namespace

int spawn_guest_thread(gaddr start_fn, gaddr arg, u32 stack_size, gaddr* out_tid) {
    if (!stack_size) stack_size = 1 << 20;
    gaddr stack = va_alloc(stack_size);
    gaddr tls = new_tls();     // made here so pthread_create can hand back the real pthread_t
    auto* sa = new StartArgs{start_fn, arg, stack, stack_size, tls};
    pthread_t h;
    int rc = pthread_create(&h, nullptr, thread_trampoline, sa);
    if (rc) { delete sa; va_free(stack, stack_size); return rc; }
    if (out_tid) *out_tid = tls;   // == the new thread's pthread_self()
    return 0;
}

void cpu_init() {
    g_monitor = new ExclusiveMonitor(kProcs);
}

static struct sigaction g_old_segv;
static void segv_reporter(int sig, siginfo_t* si, void* uc) {
    long d = reinterpret_cast<u8*>(si->si_addr) - g_base;
    GuestThread* gt = t_thread;
    std::string where = "?";
    if (gt && gt->depth > 0) where = describe_addr(gt->jits[gt->depth - 1]->jit->Regs()[15]);
    bool in_guest_space = d >= 0 && d < (s64(1) << 32);
    logf("FAULT sig=%d host_addr=%p guest_addr=%s0x%lx guest_pc=%s",
         sig, si->si_addr, in_guest_space ? "" : "(outside) ", in_guest_space ? d : long(intptr_t(si->si_addr)),
         where.c_str());
    if (gt && gt->depth > 0) {
        auto& R = gt->jits[gt->depth - 1]->jit->Regs();
        for (int i = 0; i < 16; ++i)
            logf("  r%-2d = %08x  %s", i, R[i], describe_addr(R[i] & ~1u).c_str());
        // Unwind guest call chain via the ARM frame-pointer (r11) chain:
        // each frame does `push {r11,lr}; mov r11,sp` so [r11]=prev fp, [r11+4]=lr.
        logf("  LR  -> %s", describe_addr(R[14] & ~1u).c_str());
        logf("  --- guest backtrace (fp chain) ---");
        u32 fp = R[11];
        for (int i = 0; i < 24 && fp && va_is_mapped(fp) && va_is_mapped(fp + 4); ++i) {
            u32 prev = rd32(fp), lr = rd32(fp + 4);
            logf("  #%-2d lr=%s", i, describe_addr(lr & ~1u).c_str());
            if (prev <= fp) break;  // must grow upward
            fp = prev;
        }
        // For each register that points at a struct, scan its first 32 words for
        // a guest pointer to an ASCII string (e.g. Il2CppClass::name) and print it.
        auto try_str = [&](u32 p) -> std::string {
            if (!p || !va_is_mapped(p)) return {};
            const char* s = reinterpret_cast<const char*>(g_base + p);
            int n = 0; for (; n < 64; ++n) { char c = s[n]; if (c == 0) break; if (c < 0x20 || c > 0x7e) return {}; }
            if (n < 2) return {};
            return std::string(s, n);
        };
        // Surface any class/method names reachable from the registers (e.g.
        // Il2CppClass::name, MethodInfo::name) — invaluable for pinning a crash
        // to a specific managed type.
        logf("  --- string fields reachable from registers ---");
        for (int r = 0; r < 12; ++r) {
            u32 base = R[r];
            if (!base || !va_is_mapped(base)) continue;
            for (int w = 0; w < 32; ++w) {
                if (!va_is_mapped(base + w * 4 + 3)) break;
                u32 fieldp = rd32(base + w * 4);
                std::string s = try_str(fieldp);
                if (!s.empty()) logf("  r%d+0x%x -> \"%s\"", r, w * 4, s.c_str());
            }
        }
    }
    if (g_old_segv.sa_sigaction) g_old_segv.sa_sigaction(sig, si, uc);
    _exit(42);
}
void install_fault_reporter() {
    struct sigaction sa{};
    sa.sa_sigaction = segv_reporter;
    sa.sa_flags = SA_SIGINFO;
    sigemptyset(&sa.sa_mask);
    sigaction(SIGSEGV, &sa, &g_old_segv);   // installed last -> called first
}

}  // namespace wst
