// Guest signals: sigaction / pthread_kill / sigsuspend / masks, delivered at safe points.
//
// Only guest code ever needs them -- chiefly Boehm GC's stop-the-world, which
// pthread_kill()s every registered thread with SIG_SUSPEND, waits for each handler
// to record its stack pointer and post an ack, and later wakes them with
// SIG_THR_RESTART (il2cpp's Liveness pass, run by Unity's UnloadUnusedAssets, does
// this even while collection is off).
//
// Delivery, without host signals:
//   * a thread executing guest code holds its RunLock; the signal service halts its
//     JIT (HR_SIGNAL) and the thread runs the handler itself at that instruction
//     boundary (cpu.cpp -> sig_on_halt);
//   * a thread in host code (blocked in a thunk, or not in guest code at all) has
//     released its RunLock; the service takes it and a stand-in host thread runs the
//     handler with that thread's identity on that thread's guest stack, below its SP.
//     The real thread can't re-enter guest code until the stand-in is done -- which is
//     exactly "suspended" for Boehm.
// In both cases the interrupted r0-r12/lr are first pushed on the guest stack, so a
// conservative stack scan sees pointers that only lived in registers.
#include "cpu.h"
#include "guest.h"

#include <errno.h>
#include <string.h>
#include <unistd.h>

#include <chrono>
#include <thread>
#include <unordered_map>

#include "dynarmic/interface/A32/a32.h"

namespace wst {

GuestThread* make_standin(GuestThread* owner, gaddr sp);   // cpu.cpp
void drop_standin(GuestThread* gt);
gaddr guest_sp_of(GuestThread* gt);
void guest_regs_of(GuestThread* gt, u32 out[14]);
void set_guest_sp(GuestThread* gt, gaddr sp);

struct SigAct { gaddr handler = 0; u32 mask = 0; u32 flags = 0; };
static SigAct g_act[65];
static std::mutex g_act_mu;
static constexpr u32 kSA_SIGINFO = 0x4, kSA_NODEFER = 0x40000000, kSA_RESETHAND = 0x80000000;

static std::mutex g_reg_mu;
static std::unordered_map<gaddr, GuestThread*> g_by_self;
static std::unordered_map<u32, GuestThread*> g_by_tid;
static std::mutex g_svc_mu;
static std::condition_variable g_svc_cv;
static std::atomic<int> g_log{0};

GuestThread* sig_owner(GuestThread* gt) { return gt->owner ? gt->owner : gt; }

static void service();
void sig_register(GuestThread* gt) {
    static std::once_flag once;
    std::call_once(once, [] { std::thread(service).detach(); });
    std::lock_guard<std::mutex> l(g_reg_mu);
    g_by_self[gt->self] = gt;
    g_by_tid[gt->tid] = gt;
}

static u64 deliverable(GuestThread* o) { return o->sig_pending.load() & ~o->sig_blocked.load(); }

// Runs one handler on the current host thread (`exec`, which acts as `o`).
static void run_handler(GuestThread* exec, GuestThread* o, int sig) {
    SigAct a;
    { std::lock_guard<std::mutex> l(g_act_mu); a = g_act[sig]; if (a.flags & kSA_RESETHAND) g_act[sig] = SigAct{}; }
    if (a.handler <= 1) return;                       // SIG_DFL / SIG_IGN: nothing to run
    // Push the interrupted registers + room for siginfo/ucontext below the guest SP.
    gaddr sp0 = guest_sp_of(exec);
    u32 regs[14]; guest_regs_of(exec == o ? exec : o, regs);
    gaddr sp = (sp0 - 64 - 128 - 512) & ~7u;
    gaddr regs_at = sp + 128 + 512, info = sp, uctx = sp + 128;
    for (int i = 0; i < 14; ++i) wr32(regs_at + i * 4, regs[i]);
    memset(H(info), 0, 128 + 512);
    wr32(info, u32(sig));                             // si_signo
    wr32(info + 8, u32(-6));                          // si_code = SI_TKILL
    set_guest_sp(exec, sp);
    u64 old = o->sig_blocked.load();
    u64 during = old | u64(a.mask) << 1;              // sigset bit n-1 = signal n
    if (!(a.flags & kSA_NODEFER)) during |= u64(1) << sig;
    o->sig_blocked = during;
    if (g_log++ < 100000) logf("[sig] %d -> tid %u (%s) run", sig, o->tid, exec == o ? "self" : "stand-in");
    call_guest(a.handler, {u32(sig), info, uctx});
    if (g_log++ < 100000) logf("[sig] %d -> tid %u done", sig, o->tid);
    o->sig_blocked = old;
    set_guest_sp(exec, sp0);
}

bool sig_deliver_now(GuestThread* o) {
    GuestThread* exec = cur_thread();
    bool any = false;
    for (u64 d; (d = deliverable(o)) != 0;) {
        int sig = __builtin_ctzll(d);
        u64 bit = u64(1) << sig;
        if (!(o->sig_pending.fetch_and(~bit) & bit)) continue;   // another executor took it
        run_handler(exec, o, sig);
        any = true;
    }
    return any;
}

void sig_on_halt(GuestThread* gt) {
    // Halted at an instruction boundary while holding our RunLock: we are the target.
    GuestThread* o = sig_owner(gt);
    if (o == gt) sig_deliver_now(o);
}

static void kick() { g_svc_cv.notify_one(); }

// Delivery from host code inside a (slow) thunk: the real thread has let go of its run
// lock there, so a stand-in may be running a handler for it on the same guest stack.
// Take the lock first; a stand-in caller already holds its owner's.
void deliver_as_self(GuestThread* o) {
    GuestThread* me = cur_thread();
    if (me != o || me->run_mine) { sig_deliver_now(o); return; }
    o->run.acquire(); o->run_mine = true;
    sig_deliver_now(o);
    o->run_mine = false; o->run.release();
}

std::vector<GuestThread*> sig_threads() {
    std::lock_guard<std::mutex> l(g_reg_mu);
    std::vector<GuestThread*> v;
    for (auto& kv : g_by_self) v.push_back(kv.second);
    return v;
}

int sig_kill(gaddr self, u32 tid, int sig) {
    if (sig < 0 || sig > 64) return EINVAL;
    GuestThread* t = nullptr;
    {
        std::lock_guard<std::mutex> l(g_reg_mu);
        if (self) { auto it = g_by_self.find(self); if (it != g_by_self.end()) t = it->second; }
        else { auto it = g_by_tid.find(tid); if (it != g_by_tid.end()) t = it->second; }
    }
    if (!t) return 3;                                 // ESRCH
    if (sig == 0) return 0;
    t->sig_pending.fetch_or(u64(1) << sig);
    if (g_log++ < 100000) logf("[sig] kill %d -> tid %u (from %u)", sig, t->tid, cur_thread()->tid);
    { std::lock_guard<std::mutex> l(t->sig_mu); }
    t->sig_cv.notify_all();                           // a sigsuspend on it
    kick();
    return 0;
}

// The stand-in: act as `o` until nothing deliverable is left, then let `o` go.
static void standin(GuestThread* o) {
    GuestThread* me = make_standin(o, guest_sp_of(o) & ~7u);
    sig_deliver_now(o);
    drop_standin(me);
    o->sig_proxy = false;
    o->run.release();
    kick();
}

static void service() {
    for (;;) {
        {
            std::unique_lock<std::mutex> l(g_svc_mu);
            g_svc_cv.wait_for(l, std::chrono::milliseconds(2));
        }
        std::vector<GuestThread*> ts;
        {
            std::lock_guard<std::mutex> l(g_reg_mu);
            for (auto& kv : g_by_self) if (deliverable(kv.second)) ts.push_back(kv.second);
            // a signal that stays pending: say who and why (stuck stop-the-world diagnosis)
            static auto last = std::chrono::steady_clock::now();
            auto now = std::chrono::steady_clock::now();
            if (now - last > std::chrono::seconds(3)) {
                last = now;
                for (auto& kv : g_by_self) {
                    GuestThread* t = kv.second;
                    if (!t->sig_pending.load()) continue;
                    logf("[sig] stuck? tid %u pending %llx blocked %llx waiting %d proxy %d run %d depth %d", t->tid,
                         (unsigned long long)t->sig_pending.load(), (unsigned long long)t->sig_blocked.load(),
                         int(t->sig_waiting.load()), int(t->sig_proxy.load()), int(t->run.held.load()), t->depth);
                }
            }
        }
        for (GuestThread* t : ts) {
            if (t->sig_waiting || t->sig_proxy) continue;   // it handles its own
            if (t->run.try_acquire()) {
                if (!deliverable(t) || t->sig_waiting) { t->run.release(); continue; }
                t->sig_proxy = true;
                std::thread(standin, t).detach();
            } else {
                jits_halt_signal(t);                      // running guest code: stop it at the next block
            }
        }
    }
}

// ---------------- the libc surface ----------------
// bionic LP32: struct sigaction { handler; sigset_t mask (32 bit); int flags; restorer; }
int sig_action(int sig, gaddr act, gaddr oldact) {
    if (sig < 1 || sig > 64) return EINVAL;
    std::lock_guard<std::mutex> l(g_act_mu);
    if (oldact) { wr32(oldact, g_act[sig].handler); wr32(oldact + 4, g_act[sig].mask); wr32(oldact + 8, g_act[sig].flags); wr32(oldact + 12, 0); }
    if (act) {
        g_act[sig] = SigAct{rd32(act), rd32(act + 4), rd32(act + 8)};
        logf("[sig] sigaction(%d) handler %s flags %x", sig, describe_addr(g_act[sig].handler).c_str(), g_act[sig].flags);
    }
    return 0;
}
gaddr sig_signal(int sig, gaddr h) {
    if (sig < 1 || sig > 64) return gaddr(-1);
    std::lock_guard<std::mutex> l(g_act_mu);
    gaddr old = g_act[sig].handler; g_act[sig] = SigAct{h, 0, 0};
    return old;
}
// how: 0 BLOCK, 1 UNBLOCK, 2 SETMASK (32-bit guest sigset)
int sig_procmask(int how, gaddr set, gaddr oldset) {
    GuestThread* o = sig_owner(cur_thread());
    u64 cur = o->sig_blocked.load();
    if (oldset) wr32(oldset, u32(cur >> 1));
    if (set) {
        u64 m = u64(rd32(set)) << 1;
        if (how == 0) cur |= m; else if (how == 1) cur &= ~m; else if (how == 2) cur = m; else return EINVAL;
        o->sig_blocked = cur;
        if (deliverable(o)) deliver_as_self(o);
    }
    return 0;
}
// Returns after running a handler (always -1/EINTR, like the real one).
void sig_suspend(gaddr maskp) {
    GuestThread* o = sig_owner(cur_thread());
    bool real = cur_thread() == o && !o->run_mine;    // a stand-in already holds o's lock
    auto lock = [&] { if (real) { o->run.acquire(); o->run_mine = true; } };
    auto unlock = [&] { if (real) { o->run_mine = false; o->run.release(); } };
    lock();                           // no stand-in is mid-handler for us past here
    u64 old = o->sig_blocked.load();
    o->sig_waiting = true;            // before unblocking: the service must leave these to us
    o->sig_blocked = maskp ? u64(rd32(maskp)) << 1 : 0;
    for (;;) {
        unlock();
        {
            std::unique_lock<std::mutex> l(o->sig_mu);
            o->sig_cv.wait(l, [&] { return deliverable(o) != 0; });
        }
        lock();
        if (sig_deliver_now(o)) break;
    }
    o->sig_waiting = false;
    o->sig_blocked = old;
    unlock();
    if (deliverable(o)) kick();
}

}  // namespace wst
