// Inverse host->guest JNI trampoline.
//
// When real Java code (UnityPlayer, JNIBridge proxies, WWW callbacks, ...) calls
// a native method the guest registered, the JVM dispatches to a host function we
// registered in its place. That host function converts the host args to guest
// form (jobjects -> guest tokens, primitives -> softfp words), call_guest()s the
// captured guest fnPtr with our synthetic JNIEnv, and converts the guest return
// back. So Unity's own Java side drives the translated engine.
//
// Generic: one pool of template trampolines, each bound to one guest native. A
// host JNI native is AAPCS64: (JNIEnv*, jobject/jclass, then ints/pointers in
// x2-x7 and floats/doubles in v0-v7 independently). Every trampoline takes all
// of those registers, and the native's JNI signature says which ones are live.
// Two families differ only in where the result goes (x0 vs v0).
// Registration happens the moment the guest calls RegisterNatives, so natives
// registered late (e.g. bitter.jnibridge.JNIBridge) are covered too.
#include "cpu.h"
#include "guest.h"

#include <jni.h>

#include <algorithm>
#include <cstdlib>
#include <mutex>
#include <string>
#include <vector>

namespace wst {

gaddr jni_env();                         // synthetic JNIEnv (guest-facing)
u32 jni_wrap_host(void* jobj);
void* jni_unwrap(u32 tok);
void* jni_cur_env();
void jni_trace(bool on);
void jni_frame_enter();                  // jni_real.cpp: local-token frames
void jni_frame_leave();

struct Bound { gaddr fn = 0; std::string cls, name, sig; char ret = 'V'; int calls = 0; };
static constexpr int kPool = 384;
static Bound g_bound[kPool];
static int g_nbound = 0;
static std::mutex g_bind_mu;

static char ret_of(const std::string& sig) {
    size_t p = sig.find(')');
    return (p == std::string::npos || p + 1 >= sig.size()) ? 'V' : sig[p + 1];
}

// The shared body: host args -> guest args, call, guest result -> 64-bit bits.
static u64 invoke(int I, jobject thiz, const u64* x, const double* d) {
    Bound& b = g_bound[I];
    jni_frame_enter();   // tokens made for this call (args + everything the guest gets) die with it
    std::vector<u32> a;
    a.push_back(jni_env());
    a.push_back(jni_wrap_host(thiz));
    int xi = 0, di = 0;
    const std::string& s = b.sig;
    auto pair = [&](u64 v) { if (a.size() & 1) a.push_back(0); a.push_back(u32(v)); a.push_back(u32(v >> 32)); };
    for (size_t p = s.find('(') + 1; p < s.size() && s[p] != ')'; ++p) {
        switch (s[p]) {
            case 'Z': case 'B': case 'C': case 'S': case 'I': a.push_back(u32(x[xi++])); break;
            case 'J': pair(x[xi++]); break;
            case 'F': { u64 bits; memcpy(&bits, &d[di++], 8); a.push_back(u32(bits)); break; }
            case 'D': { u64 bits; memcpy(&bits, &d[di++], 8); pair(bits); break; }
            case 'L': a.push_back(jni_wrap_host((void*)uintptr_t(x[xi++]))); while (p < s.size() && s[p] != ';') ++p; break;
            case '[': a.push_back(jni_wrap_host((void*)uintptr_t(x[xi++])));
                      while (p < s.size() && s[p] == '[') ++p;
                      if (p < s.size() && s[p] == 'L') while (p < s.size() && s[p] != ';') ++p;
                      break;
        }
        if (xi > 6 || di > 8) { logf("[inv] %s%s: too many register args for the generic trampoline", b.name.c_str(), b.sig.c_str()); jni_frame_leave(); return 0; }
    }
    bool trace = (b.name == "initJni" || b.name == "nativeRender") && b.calls < 2;
    if (b.calls < 2 || b.name != "nativeRender") {
        if (b.calls < 3) logf("[inv] -> %s.%s%s #%d", b.cls.c_str(), b.name.c_str(), b.sig.c_str(), b.calls);
    }
    b.calls++;
    if (trace) jni_trace(true);
    u64 r = call_guest_v(b.fn, a.data(), int(a.size()));
    if (trace) jni_trace(false);
    u64 out;
    switch (b.ret) {
        case 'Z': out = u8(r); break;
        case 'B': out = u64(s64(int8_t(u8(r)))); break;
        case 'C': out = u16(r); break;
        case 'S': out = u64(s64(int16_t(u16(r)))); break;
        case 'I': case 'F': out = u32(r); break;
        case 'J': case 'D': out = r; break;
        case 'L': case '[': {
            // The guest returns a token; hand Java a fresh local ref so it outlives our frame.
            void* o = jni_unwrap(u32(r));
            JNIEnv* e = (JNIEnv*)jni_cur_env();
            out = (o && e) ? u64(uintptr_t(e->NewLocalRef((jobject)o))) : 0;
            break;
        }
        default: out = 0; break;
    }
    if (b.name == "nativeSetupConnection" && xi >= 2) {   // NiaNet: after the game set its own trust manager, pin it to the Windstock server
        JNIEnv* e = (JNIEnv*)jni_cur_env();
        static jclass k = nullptr; static jmethodID m = nullptr;
        if (e && !k) {
            jclass lk = e->FindClass("com/windstock/translator64/WsNet");   // a host native frame: app loader
            if (e->ExceptionCheck()) { e->ExceptionClear(); lk = nullptr; }
            if (lk) { k = (jclass)e->NewGlobalRef(lk); m = e->GetStaticMethodID(k, "setup", "(Ljava/net/HttpURLConnection;)V"); }
        }
        if (e && m) {
            e->CallStaticVoidMethod(k, m, (jobject)uintptr_t(x[1]));
            if (e->ExceptionCheck()) { e->ExceptionDescribe(); e->ExceptionClear(); }
        }
    }
    jni_frame_leave();
    if (b.name == "fmodProcess" && (b.calls % 2000) == 1) {   // proof the PCM isn't silence
        JNIEnv* e = (JNIEnv*)jni_cur_env();
        const int16_t* p = e ? (const int16_t*)e->GetDirectBufferAddress((jobject)uintptr_t(x[0])) : nullptr;
        jlong n = e ? e->GetDirectBufferCapacity((jobject)uintptr_t(x[0])) / 2 : 0;
        int peak = 0;
        for (jlong i = 0; p && i < n; ++i) peak = std::max(peak, std::abs(int(p[i])));
        logf("[audio] fmodProcess #%d: %lld samples, peak %d", b.calls, (long long)n, peak);
    }
    if (trace) logf("[inv] <- %s returned %llx", b.name.c_str(), (unsigned long long)out);
    return out;
}

template <int I>
static u64 tramp_x(JNIEnv*, jobject thiz, u64 x2, u64 x3, u64 x4, u64 x5, u64 x6, u64 x7,
                   double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7) {
    const u64 x[6] = {x2, x3, x4, x5, x6, x7};
    const double d[8] = {d0, d1, d2, d3, d4, d5, d6, d7};
    return invoke(I, thiz, x, d);
}
template <int I>
static double tramp_v(JNIEnv*, jobject thiz, u64 x2, u64 x3, u64 x4, u64 x5, u64 x6, u64 x7,
                      double d0, double d1, double d2, double d3, double d4, double d5, double d6, double d7) {
    const u64 x[6] = {x2, x3, x4, x5, x6, x7};
    const double d[8] = {d0, d1, d2, d3, d4, d5, d6, d7};
    u64 bits = invoke(I, thiz, x, d);   // float: low 32 bits of v0 are s0
    double r; memcpy(&r, &bits, 8);
    return r;
}

template <int... Is> struct Seq {};
template <int N, int... Is> struct MakeSeq : MakeSeq<N - 1, N - 1, Is...> {};
template <int... Is> struct MakeSeq<0, Is...> { using type = Seq<Is...>; };
template <int... Is> static const void* const* tbl_x(Seq<Is...>) { static const void* t[] = {(const void*)&tramp_x<Is>...}; return t; }
template <int... Is> static const void* const* tbl_v(Seq<Is...>) { static const void* t[] = {(const void*)&tramp_v<Is>...}; return t; }

// Bind one guest native onto the real Java class (called from the RegisterNatives capture).
void jni_bind_guest_native(void* host_class, const char* cls, const char* name, const char* sig, gaddr fn) {
    JNIEnv* e = (JNIEnv*)jni_cur_env();
    if (!e || !host_class) return;
    int I;
    {
        std::lock_guard<std::mutex> lk(g_bind_mu);
        if (g_nbound >= kPool) { logf("[inv] trampoline pool exhausted (%s)", name); return; }
        I = g_nbound++;
        Bound& b = g_bound[I];
        b.fn = fn; b.cls = cls; b.name = name; b.sig = sig; b.ret = ret_of(b.sig);
    }
    static const void* const* tx = tbl_x(MakeSeq<kPool>::type{});
    static const void* const* tv = tbl_v(MakeSeq<kPool>::type{});
    char rc = g_bound[I].ret;
    JNINativeMethod m;
    m.name = g_bound[I].name.c_str();
    m.signature = g_bound[I].sig.c_str();
    m.fnPtr = const_cast<void*>((rc == 'F' || rc == 'D') ? tv[I] : tx[I]);
    jint r = e->RegisterNatives((jclass)host_class, &m, 1);
    if (e->ExceptionCheck()) {
        e->ExceptionDescribe(); e->ExceptionClear();
        logf("[inv] host RegisterNatives FAILED for %s.%s%s", cls, name, sig);
        return;
    }
    if (r != 0) logf("[inv] host RegisterNatives %s.%s -> %d", cls, name, r);
}

// Kept for the driver's call order; natives are now bound at capture time.
void jni_register_host_natives() {
    logf("[inv] inverse trampoline: %d guest natives bound to real Java classes", g_nbound);
}

}  // namespace wst
