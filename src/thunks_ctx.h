// The call context a thunk handler sees, plus the SVC entry point.
#pragma once

#include "guest.h"

namespace Dynarmic::A32 { class Jit; }

namespace wst {

struct Ctx {
    Dynarmic::A32::Jit* j = nullptr;
    Dynarmic::A32::Jit* jit() const;
    u32 arg(int i) const;       // i-th 32-bit AAPCS argument
    u64 arg64(int i) const;     // i-th slot as a 64-bit argument
    gaddr argp(int i) const { return arg(i); }
    void ret(u32 v);
    void ret64(u64 v);
    void retp(gaddr v) { ret(v); }
    void halt_return();         // used only by the return sentinel
    void unwind();              // leave Run() but keep the guest PC (re-enter)
};

void svc_run(u32 swi, Ctx& c);          // thunks.cpp
// Route an svc range [base, base+count) to a dispatcher (used by the JNI table).
void svc_register_range(u32 base, u32 count, void (*fn)(u32 slot, Ctx&));
void cpu_init();                        // cpu.cpp
int spawn_guest_thread(gaddr start_fn, gaddr arg, u32 stack_size, gaddr* out_handle);

}  // namespace wst
