// Guest threads, the per-thread JIT stack and host <-> guest calls.
#pragma once

#include <atomic>
#include <condition_variable>
#include <memory>
#include <mutex>
#include <vector>

#include "guest.h"

namespace Dynarmic::A32 { class Jit; }

namespace wst {

struct JitSlot;

// Held by a guest thread while it executes guest code (released inside every SVC).
// Not owner-bound: the signal service may take it for a thread and hand it to a
// stand-in that runs a signal handler while the real thread waits in host code.
struct RunLock {
    std::atomic<bool> held{false};
    std::atomic<int> waiters{0};
    std::mutex m; std::condition_variable cv;
    bool try_acquire() { bool e = false; return held.compare_exchange_strong(e, true, std::memory_order_acquire); }
    void acquire() {
        if (try_acquire()) return;                    // the common, uncontended case: one CAS
        waiters.fetch_add(1);
        { std::unique_lock<std::mutex> l(m); cv.wait(l, [&] { return try_acquire(); }); }
        waiters.fetch_sub(1);
    }
    void release() {
        held.store(false, std::memory_order_release);
        if (waiters.load()) { std::lock_guard<std::mutex> l(m); cv.notify_all(); }
    }
};
struct GuestThread {
    u32 tid = 0;              // host kernel tid
    size_t proc_id = 0;       // Dynarmic ExclusiveMonitor processor slot
    gaddr self = 0;           // guest pthread_t (points at the TLS block)
    gaddr tls = 0;            // bionic-style TLS slot array (TPIDRURO)
    gaddr stack_lo = 0, stack_top = 0;
    u32 stack_size = 0;
    std::vector<std::unique_ptr<JitSlot>> jits;  // one per host->guest nesting level
    int depth = 0;
    u32 specific[128] = {};   // pthread_key values
    gaddr start_fn = 0, start_arg = 0;
    gaddr retval = 0;
    bool detached = false;
    // ---- guest signals (signals.cpp) ----
    RunLock run;
    bool run_mine = false;                // this host thread holds `run` (only it touches this)
    std::atomic<u64> sig_pending{0};      // bit n = signal n
    std::atomic<u64> sig_blocked{0};
    std::atomic<bool> sig_waiting{false}; // in sigsuspend: consumes its own signals
    std::atomic<bool> sig_proxy{false};   // a stand-in is running a handler for it
    std::atomic<bool> sample{false};      // sampler: record the guest PC at the next halt
    std::mutex sig_mu; std::condition_variable sig_cv;
    GuestThread* owner = nullptr;         // set on a stand-in: the thread it acts as
};

// signals.cpp
GuestThread* sig_owner(GuestThread* gt);          // the thread whose signal state applies
void sig_register(GuestThread* gt);
void sig_on_halt(GuestThread* gt);                // the JIT stopped for a pending signal
bool sig_deliver_now(GuestThread* owner);         // runs deliverable handlers on this thread
int  sig_kill(gaddr self_or_zero, u32 tid, int sig);
void jits_halt_signal(GuestThread* gt);           // cpu.cpp
void sample_record(u32 tid, u32 pc);
void sampler_start();

GuestThread* cur_thread();          // attaches the calling host thread on first use
Dynarmic::A32::Jit* cur_jit();      // innermost running JIT of this thread
gaddr guest_errno_addr();

// Calls guest code; up to 4 args in r0-r3, the rest on the guest stack.
u64 call_guest(gaddr fn, std::initializer_list<u32> args);
u64 call_guest_v(gaddr fn, const u32* args, int n);

// Where an address falls, for crash reports: "libunity.so+0x1234".
std::string describe_addr(gaddr a);

// ---- thunks.cpp ----
struct Ctx;
using Handler = void (*)(Ctx&);

void thunks_init();
gaddr thunk_for_import(const std::string& name, bool is_object);  // never fails
gaddr make_thunk(const char* name, Handler fn);                    // anonymous thunks
gaddr halt_stub();
u32 thunk_cur_index();
u32 thunk_index_of(gaddr stub);   // inverse of make_thunk's address   // svc index of the handler running on this thread
const char* thunk_cur_name();
void dispatch_svc(u32 swi);
bool svc_is_fast(u32 swi);   // short, never blocks, never re-enters guest code
bool have_handler(const std::string& name);
void register_handler(const char* name, Handler fn);
void register_data(const char* name, gaddr (*make)());

}  // namespace wst
