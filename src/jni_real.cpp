#include <atomic>
// Real guest<->host ART JNI bridge.
//
// The guest keeps calling our SYNTHETIC JNIEnv (the svc-stub table in jni.cpp);
// each slot handler here forwards to this process's real ART JNIEnv. Host refs
// (jobject/jclass/jmethodID/jfieldID/jstring/jarray) are 64-bit pointers that
// can't live in 32-bit guest space, so they're kept in a handle table and the
// guest only ever sees a 32-bit token (0xCA0000xx). Guest string/array pointers
// translate through g_base.
//
// Call<Type>Method needs the callee's JNI signature to read the guest's inline
// varargs and build a host jvalue[] — so GetMethodID/GetStaticMethodID record the
// signature keyed by the returned method-id token.
#include "cpu.h"
#include "guest.h"
#include "thunks_ctx.h"
#include "elf.h"

#include <jni.h>

#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace wst {

static JavaVM* g_vm = nullptr;
static bool g_real = false;
gaddr jni_javavm();   // synthetic guest JavaVM (jni.cpp)

// ---- handle table (host ref <-> 32-bit guest token) ----
// Tokens for local refs made while a host->guest native call is running are
// recycled when that call returns (the refs themselves die then too). Method/field
// IDs and global/weak refs get permanent tokens.
static std::mutex g_h_mu;
static std::vector<void*> g_htab;
static std::vector<u8> g_hkind;            // 0 free, 1 local, 2 permanent
static std::vector<u32> g_hfree;
static thread_local int t_depth = 0;
static thread_local std::vector<u32> t_frame;
static thread_local std::vector<size_t> t_marks;

static u32 tok_kind(void* h, u8 kind) {
    if (!h) return 0;
    u32 i;
    {
        std::lock_guard<std::mutex> lk(g_h_mu);
        if (!g_hfree.empty()) { i = g_hfree.back(); g_hfree.pop_back(); g_htab[i] = h; g_hkind[i] = kind; }
        else { g_htab.push_back(h); g_hkind.push_back(kind); i = u32(g_htab.size() - 1); }
    }
    if (kind == 1 && t_depth > 0) t_frame.push_back(i);
    return 0xCA000000u | i;
}
static u32 tok(void* h) { return tok_kind(h, 1); }
static u32 tok_perm(void* h) { return tok_kind(h, 2); }
// jmethodID/jfieldID tokens are canonical (one token per host ID): guest code
// compares IDs (e.g. Unity's proxy matches FromReflectedMethod against GetMethodID).
static std::unordered_map<void*, u32> g_idtok;
static u32 tok_id(void* h) {
    if (!h) return 0;
    {
        std::lock_guard<std::mutex> lk(g_h_mu);
        auto it = g_idtok.find(h);
        if (it != g_idtok.end()) return it->second;
    }
    u32 t = tok_kind(h, 2);
    std::lock_guard<std::mutex> lk(g_h_mu);
    auto ins = g_idtok.emplace(h, t);
    return ins.first->second;
}
static void* obj(u32 t) {
    if (t < 0xCA000000u) return nullptr;
    std::lock_guard<std::mutex> lk(g_h_mu);
    u32 i = t - 0xCA000000u;
    return i < g_htab.size() ? g_htab[i] : nullptr;
}
static void tok_release(u32 t, u8 kind) {
    if (t < 0xCA000000u) return;
    std::lock_guard<std::mutex> lk(g_h_mu);
    u32 i = t - 0xCA000000u;
    if (i < g_htab.size() && g_hkind[i] == kind) { g_htab[i] = nullptr; g_hkind[i] = 0; g_hfree.push_back(i); }
}
// Shadows for Java direct ByteBuffers that live outside guest space.
struct DBuf { gaddr g; u32 cap; };
static std::unordered_map<void*, DBuf> g_dbufs;
// Shadows to write back at frame leave, with the capacity the buffer had when it was
// handed out. The cache is keyed by address and keeps the biggest capacity seen; ART
// reuses a freed direct buffer's address for smaller ones, and writing the cached
// size back overran them ("Corrupt heap detected in: mspace_malloc").
static thread_local std::vector<std::pair<void*, u32>> t_dirty;
static gaddr dbuf_shadow(void* host, u32 cap) {
    DBuf d{};
    {
        std::lock_guard<std::mutex> lk(g_h_mu);
        auto it = g_dbufs.find(host);
        if (it == g_dbufs.end() || it->second.cap < cap) {
            if (it != g_dbufs.end()) gfree(it->second.g);
            DBuf n{gmalloc(cap ? cap : 4), cap};
            g_dbufs[host] = n;
            logf("[jni] direct buffer %p (%u bytes) shadowed at guest %08x", host, cap, n.g);
        }
        d = g_dbufs[host];
    }
    memcpy(H(d.g), host, cap);
    if (t_depth > 0) t_dirty.emplace_back(host, cap);
    return d.g;
}
static void dbuf_writeback() {
    for (auto& [host, cap] : t_dirty) {
        DBuf d{};
        { std::lock_guard<std::mutex> lk(g_h_mu); auto it = g_dbufs.find(host); if (it == g_dbufs.end()) continue; d = it->second; }
        memcpy(host, H(d.g), cap < d.cap ? cap : d.cap);
    }
    t_dirty.clear();
}

void jni_frame_enter() { ++t_depth; t_marks.push_back(t_frame.size()); }
void jni_frame_leave() {
    if (t_marks.empty()) return;
    size_t m = t_marks.back(); t_marks.pop_back(); --t_depth;
    if (t_depth == 0) dbuf_writeback();
    std::lock_guard<std::mutex> lk(g_h_mu);
    for (size_t k = m; k < t_frame.size(); ++k) {
        u32 i = t_frame[k];
        if (i < g_htab.size() && g_hkind[i] == 1) { g_htab[i] = nullptr; g_hkind[i] = 0; g_hfree.push_back(i); }
    }
    t_frame.resize(m);
}
size_t jni_token_count() { std::lock_guard<std::mutex> lk(g_h_mu); return g_htab.size() - g_hfree.size(); }

// ---- method/field signatures, keyed by their token ----
static std::mutex g_sig_mu;
static std::unordered_map<u32, std::string> g_sig;   // methodID token -> JNI sig
static void remember_sig(u32 midtok, const char* sig) {
    if (!midtok || !sig) return;
    std::lock_guard<std::mutex> lk(g_sig_mu);
    g_sig[midtok] = sig;
}
static std::string sig_for(u32 midtok) {
    std::lock_guard<std::mutex> lk(g_sig_mu);
    auto it = g_sig.find(midtok); return it == g_sig.end() ? std::string() : it->second;
}

// ---- app ClassLoader (so FindClass on our native thread resolves app/game
// classes, not just the bootstrap loader) ----
static jobject g_classloader = nullptr;   // global ref
static jmethodID g_loadClass = nullptr;

// ---- per-thread host env ----
static JNIEnv* cur_env() {
    if (!g_vm) return nullptr;
    JNIEnv* e = nullptr;
    if (g_vm->GetEnv((void**)&e, JNI_VERSION_1_6) == JNI_OK) return e;
    g_vm->AttachCurrentThread(&e, nullptr);
    return e;
}

void jni_bind_host(void* vm, void* /*env*/) {
    g_vm = reinterpret_cast<JavaVM*>(vm);
    g_real = true;
    logf("[jni] host ART bound (real bridge on): vm=%p", vm);
}
bool jni_real_enabled() { return g_real; }
static bool g_trace = false;
void jni_trace(bool on) { g_trace = on; }

// Wrap a host jobject as a guest token (so the driver can pass the Activity etc.
// into guest native methods).
u32 jni_wrap_host(void* jobj) { return tok(jobj); }
// Readable class name for a guest class token (logging).
std::string jni_class_name(u32 t) {
    JNIEnv* e = cur_env(); jclass k = (jclass)obj(t);
    if (!e || !k) return "?";
    jclass ck = e->GetObjectClass(k);
    jmethodID gn = e->GetMethodID(ck, "getName", "()Ljava/lang/String;");
    jstring nm = (jstring)e->CallObjectMethod(k, gn);
    std::string r = "?";
    if (nm) { const char* c = e->GetStringUTFChars(nm, nullptr); r = c; e->ReleaseStringUTFChars(nm, c); e->DeleteLocalRef(nm); }
    e->DeleteLocalRef(ck);
    if (e->ExceptionCheck()) e->ExceptionClear();
    return r;
}
void* jni_unwrap(u32 t) { return obj(t); }
void* jni_cur_env() { return cur_env(); }

// Cache the app's ClassLoader from the Activity so FindClass can resolve the
// bundled game classes (com.unity3d.player.*) even on our native thread.
void jni_set_classloader(void* activity_jobj) {
    JNIEnv* e = cur_env();
    if (!e || !activity_jobj) return;
    jobject act = (jobject)activity_jobj;
    jclass actCls = e->GetObjectClass(act);
    jmethodID getCL = e->GetMethodID(actCls, "getClassLoader", "()Ljava/lang/ClassLoader;");
    jobject cl = e->CallObjectMethod(act, getCL);
    if (e->ExceptionCheck()) { e->ExceptionClear(); return; }
    g_classloader = e->NewGlobalRef(cl);
    jclass clCls = e->GetObjectClass(cl);
    g_loadClass = e->GetMethodID(clCls, "loadClass", "(Ljava/lang/String;)Ljava/lang/Class;");
    logf("[jni] app ClassLoader cached (%p)", g_classloader);
}

// FindClass that prefers the app ClassLoader and never leaves a pending exception.
static jclass find_class(JNIEnv* e, const char* name) {
    if (g_classloader && g_loadClass) {
        std::string dotted(name);
        for (char& ch : dotted) if (ch == '/') ch = '.';
        jstring js = e->NewStringUTF(dotted.c_str());
        jclass k = (jclass)e->CallObjectMethod(g_classloader, g_loadClass, js);
        e->DeleteLocalRef(js);
        if (!e->ExceptionCheck() && k) return k;
        e->ExceptionClear();
    }
    jclass k = e->FindClass(name);
    if (e->ExceptionCheck()) { e->ExceptionClear(); logf("[jni] FindClass(%s) -> not found", name); return nullptr; }
    return k;
}

// Make a Java String on the host and hand back its guest token.
u32 jni_new_string(const char* s) {
    JNIEnv* e = cur_env();
    return e ? tok(e->NewStringUTF(s)) : 0;
}
// Check/clear a pending host exception; returns true if one was pending.
bool jni_check_exception(const char* where) {
    JNIEnv* e = cur_env();
    if (e && e->ExceptionCheck()) {
        logf("[jni] pending exception after %s:", where);
        e->ExceptionDescribe();
        e->ExceptionClear();
        return true;
    }
    return false;
}

// ---- method signatures/names for tracing ----
static std::unordered_map<u32, std::string> g_mname;   // methodID token -> name (trace only)

// ---- guest argument readers for Call<T>Method / V / A ----
// Plain '...' variants read the AAPCS slot stream (C varargs: float is promoted to
// double, 64-bit values take an aligned pair). V variants read an ARM va_list (a
// guest pointer to the same packed layout in memory). A variants read a guest
// jvalue[] (8 bytes per element).
struct ArgSrc {
    enum Kind { Slots, VaList, JArray } kind;
    Ctx* c; int idx;      // Slots
    gaddr q;              // VaList / JArray cursor
    u32 w() {
        if (kind == Slots) return c->arg(idx++);
        u32 v = rd32(q); q += 4; return v;
    }
    u64 w64() {
        if (kind == Slots) { idx = (idx + 1) & ~1; u64 v = u64(c->arg(idx)) | (u64(c->arg(idx + 1)) << 32); idx += 2; return v; }
        q = (q + 7) & ~7u; u64 v = rd64(q); q += 8; return v;
    }
};
static void build_args(ArgSrc src, const std::string& sig, std::vector<jvalue>& out) {
    size_t p = sig.find('(');
    if (p == std::string::npos) return;
    ++p;
    for (; p < sig.size() && sig[p] != ')'; ++p) {
        jvalue v; v.j = 0;
        char t = sig[p];
        if (src.kind == ArgSrc::JArray) {
            gaddr a = src.q; src.q += 8;   // one jvalue (8 bytes)
            switch (t) {
                case 'Z': v.z = jboolean(*(u8*)H(a)); break;
                case 'B': v.b = jbyte(*(u8*)H(a)); break;
                case 'C': v.c = jchar(rd16(a)); break;
                case 'S': v.s = jshort(rd16(a)); break;
                case 'I': v.i = jint(rd32(a)); break;
                case 'F': { u32 b = rd32(a); memcpy(&v.f, &b, 4); break; }
                case 'J': v.j = jlong(rd64(a)); break;
                case 'D': { u64 b = rd64(a); memcpy(&v.d, &b, 8); break; }
                case 'L': v.l = (jobject)obj(rd32(a)); while (p < sig.size() && sig[p] != ';') ++p; break;
                case '[': v.l = (jobject)obj(rd32(a));
                          while (p < sig.size() && sig[p] == '[') ++p;
                          if (p < sig.size() && sig[p] == 'L') while (p < sig.size() && sig[p] != ';') ++p;
                          break;
            }
        } else {
            switch (t) {
                case 'Z': v.z = jboolean(src.w()); break;
                case 'B': v.b = jbyte(src.w()); break;
                case 'C': v.c = jchar(src.w()); break;
                case 'S': v.s = jshort(src.w()); break;
                case 'I': v.i = jint(src.w()); break;
                case 'F': { u64 b = src.w64(); double d; memcpy(&d, &b, 8); v.f = float(d); break; }  // promoted
                case 'J': v.j = jlong(src.w64()); break;
                case 'D': { u64 b = src.w64(); memcpy(&v.d, &b, 8); break; }
                case 'L': v.l = (jobject)obj(src.w()); while (p < sig.size() && sig[p] != ';') ++p; break;
                case '[': v.l = (jobject)obj(src.w());
                          while (p < sig.size() && sig[p] == '[') ++p;
                          if (p < sig.size() && sig[p] == 'L') while (p < sig.size() && sig[p] != ';') ++p;
                          break;
            }
        }
        out.push_back(v);
    }
}

// Call a method of any return type / dispatch kind and write the guest return.
// rt index (slot group order): 0 Object 1 Boolean 2 Byte 3 Char 4 Short 5 Int
// 6 Long 7 Float 8 Double 9 Void.   kind: 0 virtual, 1 nonvirtual, 2 static.
static void do_call(JNIEnv* e, Ctx& c, int kind, int rt, jobject o, jclass k, jmethodID m, const jvalue* a) {
    switch (rt) {
    case 0: { jobject r = kind == 0 ? e->CallObjectMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualObjectMethodA(o, k, m, a) : e->CallStaticObjectMethodA(k, m, a);
              c.retp(tok(r)); break; }
    case 1: c.ret(kind == 0 ? e->CallBooleanMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualBooleanMethodA(o, k, m, a) : e->CallStaticBooleanMethodA(k, m, a)); break;
    case 2: c.ret(u32(u8(kind == 0 ? e->CallByteMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualByteMethodA(o, k, m, a) : e->CallStaticByteMethodA(k, m, a)))); break;
    case 3: c.ret(kind == 0 ? e->CallCharMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualCharMethodA(o, k, m, a) : e->CallStaticCharMethodA(k, m, a)); break;
    case 4: c.ret(u32(s32(kind == 0 ? e->CallShortMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualShortMethodA(o, k, m, a) : e->CallStaticShortMethodA(k, m, a)))); break;
    case 5: c.ret(u32(kind == 0 ? e->CallIntMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualIntMethodA(o, k, m, a) : e->CallStaticIntMethodA(k, m, a))); break;
    case 6: c.ret64(u64(kind == 0 ? e->CallLongMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualLongMethodA(o, k, m, a) : e->CallStaticLongMethodA(k, m, a))); break;
    case 7: { float f = kind == 0 ? e->CallFloatMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualFloatMethodA(o, k, m, a) : e->CallStaticFloatMethodA(k, m, a);
              u32 b; memcpy(&b, &f, 4); c.ret(b); break; }
    case 8: { double d = kind == 0 ? e->CallDoubleMethodA(o, m, a) : kind == 1 ? e->CallNonvirtualDoubleMethodA(o, k, m, a) : e->CallStaticDoubleMethodA(k, m, a);
              u64 b; memcpy(&b, &d, 8); c.ret64(b); break; }
    default: if (kind == 0) e->CallVoidMethodA(o, m, a); else if (kind == 1) e->CallNonvirtualVoidMethodA(o, k, m, a); else e->CallStaticVoidMethodA(k, m, a);
             c.ret(0); break;
    }
}

// Get<T>Field / GetStatic<T>Field / Set... share the type order Object..Double.
static void get_field(JNIEnv* e, Ctx& c, bool st, int t, jobject o, jfieldID f) {
    jclass k = (jclass)o;
    switch (t) {
    case 0: c.retp(tok(st ? e->GetStaticObjectField(k, f) : e->GetObjectField(o, f))); break;
    case 1: c.ret(st ? e->GetStaticBooleanField(k, f) : e->GetBooleanField(o, f)); break;
    case 2: c.ret(u32(u8(st ? e->GetStaticByteField(k, f) : e->GetByteField(o, f)))); break;
    case 3: c.ret(st ? e->GetStaticCharField(k, f) : e->GetCharField(o, f)); break;
    case 4: c.ret(u32(s32(st ? e->GetStaticShortField(k, f) : e->GetShortField(o, f)))); break;
    case 5: c.ret(u32(st ? e->GetStaticIntField(k, f) : e->GetIntField(o, f))); break;
    case 6: c.ret64(u64(st ? e->GetStaticLongField(k, f) : e->GetLongField(o, f))); break;
    case 7: { float v = st ? e->GetStaticFloatField(k, f) : e->GetFloatField(o, f); u32 b; memcpy(&b, &v, 4); c.ret(b); break; }
    case 8: { double v = st ? e->GetStaticDoubleField(k, f) : e->GetDoubleField(o, f); u64 b; memcpy(&b, &v, 8); c.ret64(b); break; }
    }
}
static void set_field(JNIEnv* e, Ctx& c, bool st, int t, jobject o, jfieldID f) {
    jclass k = (jclass)o;
    switch (t) {
    case 0: { jobject v = (jobject)obj(c.arg(3)); if (st) e->SetStaticObjectField(k, f, v); else e->SetObjectField(o, f, v); break; }
    case 1: { jboolean v = jboolean(c.arg(3)); if (st) e->SetStaticBooleanField(k, f, v); else e->SetBooleanField(o, f, v); break; }
    case 2: { jbyte v = jbyte(c.arg(3)); if (st) e->SetStaticByteField(k, f, v); else e->SetByteField(o, f, v); break; }
    case 3: { jchar v = jchar(c.arg(3)); if (st) e->SetStaticCharField(k, f, v); else e->SetCharField(o, f, v); break; }
    case 4: { jshort v = jshort(c.arg(3)); if (st) e->SetStaticShortField(k, f, v); else e->SetShortField(o, f, v); break; }
    case 5: { jint v = jint(c.arg(3)); if (st) e->SetStaticIntField(k, f, v); else e->SetIntField(o, f, v); break; }
    case 6: { jlong v = jlong(c.arg64(3)); if (st) e->SetStaticLongField(k, f, v); else e->SetLongField(o, f, v); break; }
    case 7: { u32 b = c.arg(3); float v; memcpy(&v, &b, 4); if (st) e->SetStaticFloatField(k, f, v); else e->SetFloatField(o, f, v); break; }
    case 8: { u64 b = c.arg64(3); double v; memcpy(&v, &b, 8); if (st) e->SetStaticDoubleField(k, f, v); else e->SetDoubleField(o, f, v); break; }
    }
    c.ret(0);
}

// ---- primitive arrays: element size by type (Boolean..Double) ----
static const u32 kElemSize[8] = {1, 1, 2, 2, 4, 8, 4, 8};   // Z B C S I J F D
struct ArrPin { jarray arr; u32 bytes; };
static std::mutex g_pin_mu;
static std::unordered_map<gaddr, ArrPin> g_pins;   // guest copy -> host array

static gaddr pin_array(JNIEnv* e, jarray arr, u32 esz) {
    if (!arr) return 0;
    jsize n = e->GetArrayLength(arr);
    u32 bytes = u32(n) * esz;
    gaddr g = gmalloc(bytes ? bytes : 4);
    void* h = e->GetPrimitiveArrayCritical(arr, nullptr);
    if (h) { memcpy(H(g), h, bytes); e->ReleasePrimitiveArrayCritical(arr, h, JNI_ABORT); }
    std::lock_guard<std::mutex> lk(g_pin_mu);
    g_pins[g] = {arr, bytes};
    return g;
}
static void unpin_array(JNIEnv* e, gaddr g, jint mode) {
    ArrPin pin{};
    {
        std::lock_guard<std::mutex> lk(g_pin_mu);
        auto it = g_pins.find(g);
        if (it == g_pins.end()) return;
        pin = it->second;
        if (mode != 1 /*JNI_COMMIT keeps the copy*/) g_pins.erase(it);
    }
    if (mode != 2 /*JNI_ABORT*/) {
        void* h = e->GetPrimitiveArrayCritical(pin.arr, nullptr);
        if (h) { memcpy(h, H(g), pin.bytes); e->ReleasePrimitiveArrayCritical(pin.arr, h, 0); }
    }
    if (mode != 1) gfree(g);
}
static void array_region(JNIEnv* e, jarray arr, u32 esz, jsize start, jsize len, gaddr buf, bool set) {
    if (!arr || !buf || len <= 0) return;
    // Real JNI throws ArrayIndexOutOfBoundsException here; a raw memcpy past the end
    // overwrote ART's heap ("Corrupt heap detected in: mspace_malloc").
    jsize n = e->GetArrayLength(arr);
    if (start < 0 || start > n || len > n - start) {
        logf("[jni] %sArrayRegion out of bounds: start %d len %d, array length %d -- clamped",
             set ? "Set" : "Get", int(start), int(len), int(n));
        if (start < 0 || start >= n) return;
        len = n - start;
    }
    void* h = e->GetPrimitiveArrayCritical(arr, nullptr);
    if (!h) return;
    u8* p = (u8*)h + size_t(start) * esz;
    if (set) memcpy(p, H(buf), size_t(len) * esz); else memcpy(H(buf), p, size_t(len) * esz);
    e->ReleasePrimitiveArrayCritical(arr, h, set ? 0 : JNI_ABORT);
}

// JNI descriptor of a java.lang.Class ("I", "[I", "Ljava/lang/String;").
static std::string class_desc(JNIEnv* e, jclass k) {
    static jmethodID getName = nullptr, isPrim = nullptr;
    jclass cc = e->FindClass("java/lang/Class");
    if (!getName) { getName = e->GetMethodID(cc, "getName", "()Ljava/lang/String;"); isPrim = e->GetMethodID(cc, "isPrimitive", "()Z"); }
    e->DeleteLocalRef(cc);
    jstring js = (jstring)e->CallObjectMethod(k, getName);
    const char* cs = e->GetStringUTFChars(js, nullptr);
    std::string n = cs; e->ReleaseStringUTFChars(js, cs); e->DeleteLocalRef(js);
    for (char& ch : n) if (ch == '.') ch = '/';
    if (e->CallBooleanMethod(k, isPrim)) {
        static const char* kP[][2] = {{"int","I"},{"boolean","Z"},{"byte","B"},{"char","C"},{"short","S"},{"long","J"},{"float","F"},{"double","D"},{"void","V"}};
        for (auto& p : kP) if (n == p[0]) return p[1];
        return "V";
    }
    if (n[0] == '[') return n;
    return "L" + n + ";";
}
// JNI signature of a reflected java.lang.reflect.Method / Constructor.
static std::string reflected_sig(JNIEnv* e, jobject rm, std::string* name) {
    jclass mk = e->GetObjectClass(rm);
    jmethodID gp = e->GetMethodID(mk, "getParameterTypes", "()[Ljava/lang/Class;");
    jmethodID gr = e->GetMethodID(mk, "getReturnType", "()Ljava/lang/Class;");
    if (e->ExceptionCheck()) { e->ExceptionClear(); gr = nullptr; }   // Constructor: no return type
    jmethodID gn = e->GetMethodID(mk, "getName", "()Ljava/lang/String;");
    std::string sig = "(";
    jobjectArray ps = gp ? (jobjectArray)e->CallObjectMethod(rm, gp) : nullptr;
    if (ps) {
        jsize n = e->GetArrayLength(ps);
        for (jsize i = 0; i < n; ++i) { jclass pk = (jclass)e->GetObjectArrayElement(ps, i); sig += class_desc(e, pk); e->DeleteLocalRef(pk); }
        e->DeleteLocalRef(ps);
    }
    sig += ")";
    if (gr) { jclass rk = (jclass)e->CallObjectMethod(rm, gr); sig += rk ? class_desc(e, rk) : "V"; if (rk) e->DeleteLocalRef(rk); }
    else sig += "V";
    if (name && gn) {
        jstring js = (jstring)e->CallObjectMethod(rm, gn);
        if (js) { const char* cs = e->GetStringUTFChars(js, nullptr); *name = cs; e->ReleaseStringUTFChars(js, cs); e->DeleteLocalRef(js); }
    }
    e->DeleteLocalRef(mk);
    if (e->ExceptionCheck()) e->ExceptionClear();
    return sig;
}

// ---- implicit JNI binding: exported Java_<class>_<method>[__<sig>] symbols ----
void jni_bind_guest_native(void* host_class, const char* cls, const char* name, const char* sig, gaddr fn);  // jni_invoke.cpp
static std::string jni_unmangle(const std::string& m) {
    std::string out;
    for (size_t i = 0; i < m.size(); ++i) {
        if (m[i] != '_') { out += m[i]; continue; }
        if (i + 1 < m.size() && m[i + 1] == '1') { out += '_'; ++i; }
        else if (i + 1 < m.size() && m[i + 1] == '2') { out += ';'; ++i; }
        else if (i + 1 < m.size() && m[i + 1] == '3') { out += '['; ++i; }
        else if (i + 5 < m.size() && m[i + 1] == '0') { out += char(strtol(m.substr(i + 2, 4).c_str(), nullptr, 16)); i += 5; }
        else out += '/';
    }
    return out;
}
void jni_bind_exported_natives(Module* m) {
    JNIEnv* e = cur_env();
    if (!e || !m) return;
    int bound = 0;
    for (u32 i = 0; i < m->nsyms; ++i) {
        gaddr se = m->symtab + i * m->syment;
        u32 nameoff = rd32(se), value = rd32(se + 4);
        u16 shndx = rd16(se + 14);
        if (!shndx || !value) continue;
        std::string sym = m->str(nameoff);
        if (sym.compare(0, 5, "Java_") != 0) continue;
        std::string body = sym.substr(5), sigpart;
        size_t dd = body.find("__");
        if (dd != std::string::npos) { sigpart = body.substr(dd + 2); body = body.substr(0, dd); }
        // last unescaped '_' separates class and method (an escaped one is "_1")
        size_t cut = std::string::npos;
        for (size_t k = body.size(); k-- > 0;)
            if (body[k] == '_' && !(k + 1 < body.size() && (body[k + 1] >= '0' && body[k + 1] <= '3'))) { cut = k; break; }
        if (cut == std::string::npos) continue;
        std::string cls = jni_unmangle(body.substr(0, cut)), meth = jni_unmangle(body.substr(cut + 1));
        jclass k = find_class(e, cls.c_str());
        if (!k) { logf("[jni] export %s: class %s not found", sym.c_str(), cls.c_str()); continue; }
        // find the declared native method by name (and arg descriptor when overloaded)
        jclass ck = e->GetObjectClass(k);
        jmethodID gdm = e->GetMethodID(ck, "getDeclaredMethods", "()[Ljava/lang/reflect/Method;");
        jobjectArray ms = (jobjectArray)e->CallObjectMethod(k, gdm);
        if (e->ExceptionCheck()) { e->ExceptionClear(); ms = nullptr; }
        std::string sig;
        std::string want = sigpart.empty() ? "" : "(" + jni_unmangle(sigpart) + ")";
        for (char& ch : want) if (ch == '/' ) {}   // descriptors keep '/'
        if (ms) {
            jsize n = e->GetArrayLength(ms);
            for (jsize j = 0; j < n && sig.empty(); ++j) {
                jobject rm = e->GetObjectArrayElement(ms, j);
                std::string nm, sg = reflected_sig(e, rm, &nm);
                if (nm == meth && (want.empty() || sg.compare(0, want.size(), want) == 0)) sig = sg;
                e->DeleteLocalRef(rm);
            }
            e->DeleteLocalRef(ms);
        }
        e->DeleteLocalRef(ck);
        if (sig.empty()) { logf("[jni] export %s: method %s not found on %s", sym.c_str(), meth.c_str(), cls.c_str()); continue; }
        jni_bind_guest_native(k, cls.c_str(), meth.c_str(), sig.c_str(), m->base + value);
        ++bound;
    }
    logf("[jni] %s: bound %d exported Java_* natives", m->name.c_str(), bound);
}

// The guest libs live in guest space, not in the app's lib dir: Java can't find or
// load them. Unity asks Java to findLibrary/loadLibrary("il2cpp") before dlopen'ing
// it, so answer those for our guest modules ourselves.
static std::string method_name(u32 midtok) {
    std::lock_guard<std::mutex> lk(g_sig_mu);
    auto it = g_mname.find(midtok); return it == g_mname.end() ? std::string() : it->second;
}
Module* guest_load_library(const std::string& so);   // driver.cpp
// NiaNet.request(J, I, String url, I, String headers, ByteBuffer, I, I): the game's login
// and every RPC. WsNet.route() (our Java) sends Niantic's hosts to the Windstock server.
static void route_nianet(JNIEnv* e, std::vector<jvalue>& a) {
    if (a.size() != 8 || !a[2].l) return;
    static jclass k = nullptr; static jmethodID m = nullptr;
    if (!k) {
        jclass lk = find_class(e, "com/windstock/translator64/WsNet");
        if (!lk) return;
        k = (jclass)e->NewGlobalRef(lk);
        m = e->GetStaticMethodID(k, "route", "(Ljava/lang/String;Ljava/lang/String;)[Ljava/lang/String;");
        if (e->ExceptionCheck()) { e->ExceptionClear(); m = nullptr; }
    }
    if (!m) return;
    jobjectArray r = (jobjectArray)e->CallStaticObjectMethod(k, m, a[2].l, a[4].l);
    if (e->ExceptionCheck()) { e->ExceptionDescribe(); e->ExceptionClear(); return; }
    if (!r) return;
    a[2].l = e->GetObjectArrayElement(r, 0);
    a[4].l = e->GetObjectArrayElement(r, 1);
}

static bool intercept_call(JNIEnv* e, Ctx& c, u32 midtok, std::vector<jvalue>& a) {
    std::string n = method_name(midtok);
    if (n == "request" || n == "doSyncRequest") { route_nianet(e, a); return false; }
    if ((n != "loadLibrary" && n != "findLibrary" && n != "load") || a.size() != 1 || !a[0].l) return false;
    const char* cs = e->GetStringUTFChars((jstring)a[0].l, nullptr);
    std::string lib = cs ? cs : ""; if (cs) e->ReleaseStringUTFChars((jstring)a[0].l, cs);
    std::string so = "lib" + lib + ".so";
    if (n != "load" && !elf_find(so) && guest_load_library(so)) {}   // the game's own native plugins
    if (n == "load") {   // System.load(path): a full path to one of our guest modules -> no-op
        size_t sl = lib.rfind('/'); so = sl == std::string::npos ? lib : lib.substr(sl + 1);
        if (!elf_find(so)) return false;
        logf("[jni] System.load(%s) -> guest module (no-op)", lib.c_str());
        c.ret(0); return true;
    }
    if (!elf_find(so)) return false;
    logf("[jni] %s(\"%s\") -> guest module %s", n.c_str(), lib.c_str(), so.c_str());
    if (n == "loadLibrary") c.ret(1);
    else c.retp(tok(e->NewStringUTF(("/wst-guest/" + so).c_str())));
    return true;
}

static std::atomic<int> g_burst{0};   // trace every JNI call for a while after the RPC URI appears
static void trace_call(const char* what, u32 midtok) {
    std::string n;
    { std::lock_guard<std::mutex> lk(g_sig_mu); auto it = g_mname.find(midtok); if (it != g_mname.end()) n = it->second; }
    if (!g_trace) {   // networking calls are always worth a line
        static int left = 80;
        static const char* kNet[] = {"createSocket", "connect", "openConnection", "getInputStream", "getOutputStream",
                                     "startHandshake", "select", "setRequestMethod", "getResponseCode", "write", "read",
                                     "checkServerTrusted", "getByName", "getAllByName", "setRequestProperty"};
        bool hit = false; for (const char* k : kNet) if (n == k) { hit = true; break; }
        if (g_burst.load() > 0) { --g_burst; hit = true; left = std::max(left, 1); }
        if (!hit || left <= 0) return;
        --left;
    }
    logf("[jni] %s %s%s", what, n.c_str(), sig_for(midtok).c_str());
}

// =====================================================================
// Env slot dispatch. Returns true if handled (real mode).
// =====================================================================
bool jni_real_env(u32 slot, Ctx& c) {
    if (!g_real) return false;
    JNIEnv* e = cur_env();
    if (!e) return false;

    // ---- Call<Type>Method{,V,A}: instance 34..63, nonvirtual 64..93, static 114..143 ----
    if ((slot >= 34 && slot <= 93) || (slot >= 114 && slot <= 143)) {
        int kind = slot >= 114 ? 2 : slot >= 64 ? 1 : 0;
        u32 base = kind == 2 ? 114 : kind == 1 ? 64 : 34;
        int rt = int(slot - base) / 3, var = int(slot - base) % 3;   // var: 0 '...', 1 V, 2 A
        jobject o = nullptr; jclass k = nullptr; u32 midtok; int first;
        if (kind == 1) { o = (jobject)obj(c.arg(1)); k = (jclass)obj(c.arg(2)); midtok = c.arg(3); first = 4; }
        else { midtok = c.arg(2); first = 3; if (kind == 2) k = (jclass)obj(c.arg(1)); else o = (jobject)obj(c.arg(1)); }
        jmethodID m = (jmethodID)obj(midtok);
        if (!m) { logf("[jni] call slot %u with null method id", slot); c.ret64(0); return true; }
        ArgSrc src{};
        src.c = &c;
        if (var == 0) { src.kind = ArgSrc::Slots; src.idx = first; }
        else { src.kind = var == 1 ? ArgSrc::VaList : ArgSrc::JArray; src.q = c.argp(first); }
        std::vector<jvalue> a; a.reserve(8); build_args(src, sig_for(midtok), a);
        if (sig_for(midtok).empty()) logf("[jni] WARNING: call through method id %08x with unknown signature", midtok);
        trace_call(kind == 2 ? "CallStatic" : "Call", midtok);
        if (intercept_call(e, c, midtok, a)) return true;
        do_call(e, c, kind, rt, o, k, m, a.data());
        if (g_trace && e->ExceptionCheck()) { logf("[jni]   -> Java exception:"); e->ExceptionDescribe(); }
        return true;
    }
    // ---- NewObject{,V,A} 28..30 ----
    if (slot >= 28 && slot <= 30) {
        jclass k = (jclass)obj(c.arg(1)); u32 midtok = c.arg(2); jmethodID m = (jmethodID)obj(midtok);
        ArgSrc src{}; src.c = &c;
        if (slot == 28) { src.kind = ArgSrc::Slots; src.idx = 3; }
        else { src.kind = slot == 29 ? ArgSrc::VaList : ArgSrc::JArray; src.q = c.argp(3); }
        std::vector<jvalue> a; build_args(src, sig_for(midtok), a);
        trace_call("NewObject", midtok);
        {   // web requests the engine makes through Java (WWW, UnityWebRequest): log their URLs
            static int n = 0;
            const std::string sg = sig_for(midtok);
            size_t ai = 0;
            for (size_t p = sg.find('(') + 1; p < sg.size() && sg[p] != ')' && ai < a.size(); ++p, ++ai) {
                bool str = sg.compare(p, 18, "Ljava/lang/String;") == 0;
                if (sg[p] == 'L') p = sg.find(';', p);
                else if (sg[p] == '[') { while (sg[p] == '[') ++p; if (sg[p] == 'L') p = sg.find(';', p); }
                if (!str || !a[ai].l) continue;
                const char* cs = e->GetStringUTFChars((jstring)a[ai].l, nullptr);
                bool url = cs && (!strncmp(cs, "http://", 7) || !strncmp(cs, "https://", 8));
                if (url && n < 40) { logf("[web] %s %.300s", jni_class_name(c.arg(1)).c_str(), cs); ++n; }
                if (url && strstr(cs, "/plfe/rpc")) g_burst = 300;
                if (cs) e->ReleaseStringUTFChars((jstring)a[ai].l, cs);
                std::string kn = url ? jni_class_name(c.arg(1)) : std::string();
                if (url && (kn.find("unity3d/player/WWW") != std::string::npos || kn.find("unity3d.player.WWW") != std::string::npos ||
                            kn.find("UnityWebRequest") != std::string::npos)) {   // Windstock: Unity's downloads go through WsNet's relay
                    static jclass wk = nullptr; static jmethodID wm = nullptr;
                    if (!wk) { jclass lk = find_class(e, "com/windstock/translator64/WsNet");
                               if (lk) { wk = (jclass)e->NewGlobalRef(lk); wm = e->GetStaticMethodID(wk, "localUrl", "(Ljava/lang/String;)Ljava/lang/String;"); }
                               if (e->ExceptionCheck()) { e->ExceptionClear(); wm = nullptr; } }
                    if (wm) {
                        jobject to = e->CallStaticObjectMethod(wk, wm, a[ai].l);
                        if (e->ExceptionCheck()) { e->ExceptionClear(); to = nullptr; }
                        if (to) a[ai].l = to;
                    }
                }
            }
        }
        c.retp(k && m ? tok(e->NewObjectA(k, m, a.data())) : 0);
        return true;
    }
    // ---- fields ----
    if (slot >= 95 && slot <= 103)  { get_field(e, c, false, int(slot - 95),  (jobject)obj(c.arg(1)), (jfieldID)obj(c.arg(2))); return true; }
    if (slot >= 104 && slot <= 112) { set_field(e, c, false, int(slot - 104), (jobject)obj(c.arg(1)), (jfieldID)obj(c.arg(2))); return true; }
    if (slot >= 145 && slot <= 153) { get_field(e, c, true,  int(slot - 145), (jobject)obj(c.arg(1)), (jfieldID)obj(c.arg(2))); return true; }
    if (slot >= 154 && slot <= 162) { set_field(e, c, true,  int(slot - 154), (jobject)obj(c.arg(1)), (jfieldID)obj(c.arg(2))); return true; }
    // ---- primitive arrays ----
    if (slot >= 175 && slot <= 182) {   // New<T>Array
        jsize n = jsize(c.arg(1)); jarray r = nullptr;
        switch (slot) {
            case 175: r = e->NewBooleanArray(n); break; case 176: r = e->NewByteArray(n); break;
            case 177: r = e->NewCharArray(n); break;    case 178: r = e->NewShortArray(n); break;
            case 179: r = e->NewIntArray(n); break;     case 180: r = e->NewLongArray(n); break;
            case 181: r = e->NewFloatArray(n); break;   case 182: r = e->NewDoubleArray(n); break;
        }
        c.retp(tok(r)); return true;
    }
    if (slot >= 183 && slot <= 190) {   // Get<T>ArrayElements(arr, isCopy*)
        if (c.argp(2)) *(u8*)H(c.argp(2)) = 1;
        c.retp(pin_array(e, (jarray)obj(c.arg(1)), kElemSize[slot - 183])); return true;
    }
    if (slot >= 191 && slot <= 198) { unpin_array(e, c.argp(2), jint(c.arg(3))); c.ret(0); return true; }
    if (slot >= 199 && slot <= 206) { array_region(e, (jarray)obj(c.arg(1)), kElemSize[slot - 199], jsize(c.arg(2)), jsize(c.arg(3)), c.argp(4), false); c.ret(0); return true; }
    if (slot >= 207 && slot <= 214) { array_region(e, (jarray)obj(c.arg(1)), kElemSize[slot - 207], jsize(c.arg(2)), jsize(c.arg(3)), c.argp(4), true); c.ret(0); return true; }

    switch (slot) {
    case 4: c.ret(e->GetVersion()); return true;                    // GetVersion
    case 6: { // FindClass(name) — via app ClassLoader, exception-safe
        c.retp(tok(find_class(e, HS(c.argp(1))))); return true;
    }
    case 7: { jobject rm = (jobject)obj(c.arg(1));
        jmethodID m = e->FromReflectedMethod(rm);
        u32 t = tok_id((void*)m);
        if (t && sig_for(t).empty()) {   // learn name + JNI signature of an ID first seen via reflection
            std::string nm, sg = reflected_sig(e, rm, &nm);
            remember_sig(t, sg.c_str());
            { std::lock_guard<std::mutex> lk(g_sig_mu); g_mname[t] = nm; }
            if (g_trace) logf("[jni] FromReflectedMethod %s%s", nm.c_str(), sg.c_str());
        }
        c.retp(t); return true; }
    case 8: c.retp(tok_id((void*)e->FromReflectedField((jobject)obj(c.arg(1))))); return true;
    case 9: c.retp(tok(e->ToReflectedMethod((jclass)obj(c.arg(1)), (jmethodID)obj(c.arg(2)), jboolean(c.arg(3))))); return true;
    case 10: c.retp(tok(e->GetSuperclass((jclass)obj(c.arg(1))))); return true;
    case 11: c.ret(e->IsAssignableFrom((jclass)obj(c.arg(1)), (jclass)obj(c.arg(2)))); return true;
    case 12: c.retp(tok(e->ToReflectedField((jclass)obj(c.arg(1)), (jfieldID)obj(c.arg(2)), jboolean(c.arg(3))))); return true;
    case 13: c.ret(u32(e->Throw((jthrowable)obj(c.arg(1))))); return true;
    case 14: c.ret(u32(e->ThrowNew((jclass)obj(c.arg(1)), HS(c.argp(2))))); return true;
    case 15: c.retp(tok(e->ExceptionOccurred())); return true;
    case 16: e->ExceptionDescribe(); c.ret(0); return true;
    case 17: e->ExceptionClear(); c.ret(0); return true;
    case 18: logf("[jni] guest FatalError: %s", HS(c.argp(1))); fatal("guest JNI FatalError: %s", HS(c.argp(1)));
    case 21: c.retp(tok_perm(e->NewGlobalRef((jobject)obj(c.arg(1))))); return true;
    case 22: e->DeleteGlobalRef((jobject)obj(c.arg(1))); tok_release(c.arg(1), 2); c.ret(0); return true;
    case 23: e->DeleteLocalRef((jobject)obj(c.arg(1))); c.ret(0); return true;
    case 24: c.ret(e->IsSameObject((jobject)obj(c.arg(1)), (jobject)obj(c.arg(2)))); return true;
    case 25: c.retp(tok(e->NewLocalRef((jobject)obj(c.arg(1))))); return true;
    case 26: c.ret(e->EnsureLocalCapacity(jint(c.arg(1)))); return true;
    case 19: c.ret(e->PushLocalFrame(jint(c.arg(1)))); return true;
    case 20: c.retp(tok(e->PopLocalFrame((jobject)obj(c.arg(1))))); return true;
    case 27: c.retp(tok(e->AllocObject((jclass)obj(c.arg(1))))); return true;
    case 31: { void* o = obj(c.arg(1));                 // GetObjectClass
        if (!o) { logf("[jni] GetObjectClass(null) -> null"); c.retp(0); return true; }
        c.retp(tok(e->GetObjectClass((jobject)o))); return true; }
    case 32: c.ret(e->IsInstanceOf((jobject)obj(c.arg(1)), (jclass)obj(c.arg(2)))); return true;
    case 33: case 113: { // Get(Static)MethodID(clazz, name, sig)
        jclass k = (jclass)obj(c.arg(1));
        const char* nm = HS(c.argp(2)); const char* sg = HS(c.argp(3));
        jmethodID m = k ? (slot == 33 ? e->GetMethodID(k, nm, sg) : e->GetStaticMethodID(k, nm, sg)) : nullptr;
        if (e->ExceptionCheck()) { e->ExceptionClear(); m = nullptr; }
        if (!m) logf("[jni] Get%sMethodID(%s%s) missing", slot == 33 ? "" : "Static", nm, sg);
        u32 t = tok_id((void*)m); remember_sig(t, sg);
        if (t) { std::lock_guard<std::mutex> lk(g_sig_mu); g_mname[t] = nm; }
        c.retp(t); return true;
    }
    case 94: case 144: { jclass k = (jclass)obj(c.arg(1));
        const char* nm = HS(c.argp(2)); const char* sg = HS(c.argp(3));
        jfieldID f = k ? (slot == 94 ? e->GetFieldID(k, nm, sg) : e->GetStaticFieldID(k, nm, sg)) : nullptr;
        if (e->ExceptionCheck()) { e->ExceptionClear(); f = nullptr; }
        if (!f) logf("[jni] Get%sFieldID(%s %s) missing", slot == 94 ? "" : "Static", nm, sg);
        c.retp(tok_id((void*)f)); return true; }

    // ---- strings ----
    case 163: { // NewString(unicode, len) — guest 16-bit chars
        jint len = jint(c.arg(2));
        c.retp(tok(e->NewString((const jchar*)H(c.argp(1)), len))); return true;
    }
    case 164: c.ret(u32(e->GetStringLength((jstring)obj(c.arg(1))))); return true;
    case 167: c.retp(tok(e->NewStringUTF(c.argp(1) ? HS(c.argp(1)) : nullptr))); return true;
    case 168: c.ret(u32(e->GetStringUTFLength((jstring)obj(c.arg(1))))); return true;
    case 169: { // GetStringUTFChars(str, isCopy*) -> copy into guest heap
        jstring js = (jstring)obj(c.arg(1));
        const char* s = js ? e->GetStringUTFChars(js, nullptr) : nullptr;
        gaddr g = s ? gstrdup(s) : 0;
        if (s) e->ReleaseStringUTFChars(js, s);
        if (c.argp(2)) *(u8*)H(c.argp(2)) = 1;   // isCopy = JNI_TRUE (jboolean is 1 byte)
        c.retp(g); return true;
    }
    case 170: if (c.argp(2)) gfree(c.argp(2)); c.ret(0); return true;   // ReleaseStringUTFChars
    case 165: case 224: { // GetStringChars / GetStringCritical -> copy 16-bit into guest heap
        jstring js = (jstring)obj(c.arg(1));
        if (!js) { c.retp(0); return true; }
        const jchar* s = e->GetStringChars(js, nullptr);
        jsize n = e->GetStringLength(js);
        gaddr g = gmalloc(u32(n + 1) * 2);
        if (s) memcpy(H(g), s, size_t(n) * 2);
        u16 zero = 0; memcpy(H(g + u32(n) * 2), &zero, 2);
        if (s) e->ReleaseStringChars(js, s);
        if (c.argp(2)) *(u8*)H(c.argp(2)) = 1;
        c.retp(g); return true;
    }
    case 166: case 225: if (c.argp(2)) gfree(c.argp(2)); c.ret(0); return true;   // Release{StringChars,StringCritical}
    case 220: { // GetStringRegion(str, start, len, jchar* buf)
        e->GetStringRegion((jstring)obj(c.arg(1)), jsize(c.arg(2)), jsize(c.arg(3)), (jchar*)H(c.argp(4)));
        c.ret(0); return true; }
    case 221: { // GetStringUTFRegion(str, start, len, char* buf)
        e->GetStringUTFRegion((jstring)obj(c.arg(1)), jsize(c.arg(2)), jsize(c.arg(3)), (char*)H(c.argp(4)));
        c.ret(0); return true; }

    // ---- object arrays / critical ----
    case 171: c.ret(u32(e->GetArrayLength((jarray)obj(c.arg(1))))); return true;
    case 172: c.retp(tok(e->NewObjectArray(jsize(c.arg(1)), (jclass)obj(c.arg(2)), (jobject)obj(c.arg(3))))); return true;
    case 173: c.retp(tok(e->GetObjectArrayElement((jobjectArray)obj(c.arg(1)), jsize(c.arg(2))))); return true;
    case 174: e->SetObjectArrayElement((jobjectArray)obj(c.arg(1)), jsize(c.arg(2)), (jobject)obj(c.arg(3))); c.ret(0); return true;
    case 222: { // GetPrimitiveArrayCritical -> pinned guest copy (element size from the array class)
        jarray arr = (jarray)obj(c.arg(1));
        u32 esz = 1;
        if (arr) {
            jclass ak = e->GetObjectClass(arr);
            jclass ck = e->GetObjectClass(ak);
            jmethodID gn = e->GetMethodID(ck, "getName", "()Ljava/lang/String;");
            jstring nm = (jstring)e->CallObjectMethod(ak, gn);
            const char* s = e->GetStringUTFChars(nm, nullptr);
            switch (s && s[0] == '[' ? s[1] : 'B') { case 'C': case 'S': esz = 2; break; case 'I': case 'F': esz = 4; break; case 'J': case 'D': esz = 8; break; default: esz = 1; }
            e->ReleaseStringUTFChars(nm, s);
            e->DeleteLocalRef(nm); e->DeleteLocalRef(ck); e->DeleteLocalRef(ak);
        }
        if (c.argp(2)) *(u8*)H(c.argp(2)) = 1;
        c.retp(pin_array(e, arr, esz)); return true;
    }
    case 223: unpin_array(e, c.argp(2), jint(c.arg(3))); c.ret(0); return true;

    case 215: return false;   // RegisterNatives: capture in jni.cpp (guest fns stay guest)
    case 216: c.ret(0); return true;   // UnregisterNatives
    case 217: c.ret(u32(e->MonitorEnter((jobject)obj(c.arg(1))))); return true;
    case 218: c.ret(u32(e->MonitorExit((jobject)obj(c.arg(1))))); return true;
    case 219: if (c.argp(1)) wr32(c.argp(1), jni_javavm()); c.ret(0); return true;   // GetJavaVM -> synthetic guest VM
    case 226: c.retp(tok_perm(e->NewWeakGlobalRef((jobject)obj(c.arg(1))))); return true;
    case 227: e->DeleteWeakGlobalRef((jweak)obj(c.arg(1))); tok_release(c.arg(1), 2); c.ret(0); return true;
    case 228: c.ret(e->ExceptionCheck()); return true;
    case 229: c.retp(tok(e->NewDirectByteBuffer(H(c.argp(1)), jlong(c.arg64(2))))); return true;
    case 230: { // GetDirectBufferAddress
        void* p = e->GetDirectBufferAddress((jobject)obj(c.arg(1)));
        if (!p) { c.retp(0); return true; }
        if (in_guest(p)) { c.retp(G(p)); return true; }
        // Java-allocated buffer outside guest space: a cached guest shadow, refreshed
        // now and written back when the current host->guest native call returns.
        jlong cap = e->GetDirectBufferCapacity((jobject)obj(c.arg(1)));
        c.retp(dbuf_shadow(p, u32(cap > 0 ? cap : 0))); return true;
    }
    case 231: c.ret64(u64(e->GetDirectBufferCapacity((jobject)obj(c.arg(1))))); return true;
    case 232: c.ret(e->GetObjectRefType((jobject)obj(c.arg(1)))); return true;
    default: {
        static bool seen[240];
        if (slot < 240 && !seen[slot]) { seen[slot] = true; logf("[jni] UNIMPLEMENTED env slot %u", slot); }
        return false;   // jni.cpp logs a fake handle
    }
    }
}

bool jni_real_vm(u32 /*slot*/, Ctx& /*c*/) { return false; }  // VM table handled in jni.cpp

}  // namespace wst
