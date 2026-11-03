// A guest-visible JavaVM + JNIEnv. Every function slot is an ARM svc stub that
// traps to a host dispatcher. Slots are generic (log + return a fake handle)
// except the few JNI_OnLoad actually needs; the trace tells us which.
#include "cpu.h"
#include "thunks_ctx.h"
#include "guest.h"

#include "dynarmic/interface/A32/a32.h"

#include <string>
#include <vector>

namespace wst {

static constexpr u32 kEnvSlots = 232;
static constexpr u32 kVmSlots = 8;
static constexpr u32 kSvcEnvBase = 0x900000;   // env slot i -> svc (base+i)
static constexpr u32 kSvcVmBase = 0x980000;    // vm  slot i -> svc (base+i)

static gaddr g_env;      // JNIEnv* (points at g_env_tab)
static gaddr g_vm;       // JavaVM* (points at g_vm_tab)
static gaddr g_env_tab, g_vm_tab;

static constexpr u32 JNI_OK = 0;
static constexpr u32 JNI_VERSION_1_6 = 0x00010006;

// Known env slot numbers (jni.h order). Only the ones we special-case.
enum EnvSlot {
    kGetVersion = 4,
    kExceptionOccurred = 15,
    kExceptionClear = 17,
    kRegisterNatives = 215,
    kExceptionCheck = 228,
};

// Native methods Unity/libmain register, captured so the host app can drive them
// (nativeInit/nativeRender/...). name -> guest function pointer.
struct GuestNative { std::string cls, name, sig; gaddr fn; u32 clstok; };
static std::vector<GuestNative> g_natives;
const std::vector<GuestNative>& jni_registered_natives() { return g_natives; }
gaddr jni_find_native(const char* name) {
    for (auto& n : g_natives) if (n.name == name) return n.fn;
    return 0;
}
u32 jni_native_class(const char* name) {
    for (auto& n : g_natives) if (n.name == name) return n.clstok;
    return 0;
}
// Known invoke-table slots.
enum VmSlot { kGetEnv = 6, kAttachCurrentThread = 4 };

static gaddr emit_svc_stub_region(gaddr region, u32 slot, u32 svc_imm) {
    gaddr a = region + slot * 8;
    wr32(a, 0xEF000000u | (svc_imm & 0xFFFFFF));   // svc #imm (ARM)
    wr32(a + 4, 0xE12FFF1Eu);                       // bx lr
    return a;
}

bool jni_real_enabled();
bool jni_real_env(u32 slot, Ctx& c);
std::string jni_class_name(u32 tok);
void* jni_unwrap(u32 tok);
void jni_bind_guest_native(void* host_class, const char* cls, const char* name, const char* sig, gaddr fn);
bool jni_real_vm(u32 slot, Ctx& c);

static void env_dispatch(u32 slot, Ctx& c) {
    if (jni_real_enabled() && jni_real_env(slot, c)) return;
    switch (slot) {
        case kGetVersion:
            c.ret(JNI_VERSION_1_6);
            return;
        case kExceptionOccurred:
            c.ret(0);          // no pending exception
            return;
        case kExceptionCheck:
            c.ret(0);          // JNI_FALSE
            return;
        case kExceptionClear:
            c.ret(0);
            return;
        case kRegisterNatives: {
            gaddr methods = c.argp(2); u32 n = c.arg(3);
            std::string cls = jni_real_enabled() ? jni_class_name(c.arg(1)) : "";
            if (cls.empty() || cls == "?") { char b[32]; snprintf(b, sizeof b, "cls@%08x", c.arg(1)); cls = b; }
            for (u32 i = 0; i < n; ++i) {
                gaddr m = methods + i * 12;
                gaddr namep = rd32(m), sigp = rd32(m + 4), fn = rd32(m + 8);
                GuestNative gn{cls, namep ? HS(namep) : "", sigp ? HS(sigp) : "", fn, c.arg(1)};
                logf("[jni] RegisterNatives %s %s%s -> %s", cls.c_str(), gn.name.c_str(), gn.sig.c_str(),
                     describe_addr(fn & ~1u).c_str());
                if (jni_real_enabled())
                    jni_bind_guest_native(jni_unwrap(c.arg(1)), cls.c_str(), gn.name.c_str(), gn.sig.c_str(), fn);
                g_natives.push_back(std::move(gn));
            }
            c.ret(0);
            return;
        }
        default:
            VLOG("[jni] env slot %u (r1=%08x r2=%08x r3=%08x) -> fake %08x",
                 slot, c.arg(1), c.arg(2), c.arg(3), 0x7F000000u | slot);
            c.ret(0x7F000000u | slot);   // non-null fake handle (can't alias a version)
            return;
    }
}

static void vm_dispatch(u32 slot, Ctx& c) {
    if (jni_real_enabled() && jni_real_vm(slot, c)) return;
    switch (slot) {
        case kGetEnv: {
            gaddr penv = c.argp(1);   // JNIEnv** out
            if (penv) wr32(penv, g_env);
            c.ret(JNI_OK);
            return;
        }
        case kAttachCurrentThread: {
            gaddr penv = c.argp(1);
            if (penv) wr32(penv, g_env);
            c.ret(JNI_OK);
            return;
        }
        default:
            VLOG("[jni] vm slot %u -> JNI_OK", slot);
            c.ret(JNI_OK);
            return;
    }
}

// The two ranges share one registration point, so chain them.
static void range_dispatch(u32 off, Ctx& c) {
    if (off < (kSvcVmBase - kSvcEnvBase)) env_dispatch(off, c);
    else vm_dispatch(off - (kSvcVmBase - kSvcEnvBase), c);
}

gaddr jni_env();   // fwd
gaddr jni_javavm();

void jni_init() {
    // Stub regions for the two tables.
    gaddr env_stubs = va_alloc(kEnvSlots * 8);
    gaddr vm_stubs = va_alloc(kVmSlots * 8);

    g_env_tab = va_alloc(kEnvSlots * 4);
    g_vm_tab = va_alloc(kVmSlots * 4);
    for (u32 i = 0; i < kEnvSlots; ++i)
        wr32(g_env_tab + i * 4, emit_svc_stub_region(env_stubs, i, kSvcEnvBase + i));
    for (u32 i = 0; i < kVmSlots; ++i)
        wr32(g_vm_tab + i * 4, emit_svc_stub_region(vm_stubs, i, kSvcVmBase + i));

    // JNIEnv is a pointer to the table pointer; same for JavaVM.
    g_env = va_alloc(0x100);
    g_vm = va_alloc(0x100);
    wr32(g_env, g_env_tab);
    wr32(g_vm, g_vm_tab);

    // Register one contiguous svc range covering both tables.
    svc_register_range(kSvcEnvBase, (kSvcVmBase - kSvcEnvBase) + kVmSlots, range_dispatch);
}

gaddr jni_env() { return g_env; }
gaddr jni_javavm() { return g_vm; }

}  // namespace wst
