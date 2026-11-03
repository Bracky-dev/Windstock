// Shared bring-up driver: load the guest libs under the translator, stand up
// il2cpp, run libunity, then drive Unity's native entry points. Used by both the
// CLI (--unity-init) and the Android host app (android_main.cpp).
#include <unistd.h>
#include "cpu.h"
#include "elf.h"
#include "guest.h"

#include <cstring>
#include <vector>

namespace wst {
gaddr jni_javavm();
gaddr jni_find_native(const char* name);
void jni_bind_exported_natives(Module* m);   // jni_real.cpp

// Load another guest .so on demand (System.loadLibrary / dlopen from the game):
// map + relocate, run its constructors and its JNI_OnLoad, like the platform would.
static std::string g_guest_dir;
Module* guest_load_library(const std::string& so) {
    if (Module* m = elf_find(so)) return m;
    if (so.find("frida") != std::string::npos) { logf("[drive] refusing to load %s (instrumentation agent)", so.c_str()); return nullptr; }
    std::string path = g_guest_dir + "/" + so;
    if (g_guest_dir.empty() || access(path.c_str(), R_OK) != 0) return nullptr;
    Module* m = elf_load(path.c_str(), so.c_str());
    if (!m) return nullptr;
    elf_run_init(m);
    if (gaddr onload = elf_resolve_entry(m, "JNI_OnLoad")) {
        u32 v = u32(call_guest(onload, {jni_javavm(), 0}));
        logf("[drive] %s JNI_OnLoad -> 0x%08x", so.c_str(), v);
    }
    jni_bind_exported_natives(m);
    logf("[drive] loaded guest library %s on demand", so.c_str());
    return m;
}
u32 jni_native_class(const char* name);
gaddr jni_env();
bool gfx_selftest();
void unity_render_bringup(Module* libunity);   // gfx.cpp — drives the first frame
gaddr jni_find_native(const char* name);

u32 jni_wrap_host(void* jobj);
u32 jni_new_string(const char* s);
bool jni_check_exception(const char* where);
void jni_set_classloader(void* activity_jobj);
void jni_trace(bool on);

static char g_path[1024];
static Module* load_so(const char* dir, const char* so) {
    snprintf(g_path, sizeof g_path, "%s/%s", dir, so);
    return elf_load(g_path, so);
}

gaddr jni_find_native(const char* name);

// Java-driven bring-up: load + relocate the guest libs, run their init_array
// constructors, and run their guest JNI_OnLoads so the native-method capture is
// populated — but DO NOT call il2cpp_init here; the Unity engine calls it itself
// during its own startup (driven by the real UnityPlayer.java through the inverse
// trampoline). data_dir still seeds il2cpp's data path for when it does.
void unity_drive(const char* dir, bool with_il2cpp, const char* data_dir) {
    g_guest_dir = dir;
    Module* main_mod = load_so(dir, "libmain.so");
    elf_run_init(main_mod);
    gaddr main_onload = elf_resolve_entry(main_mod, "JNI_OnLoad");
    if (main_onload) {
        u32 v = u32(call_guest(main_onload, {jni_javavm(), 0}));
        logf("[drive] libmain JNI_OnLoad -> 0x%08x", v);
    }

    if (with_il2cpp) {
        Module* il = load_so(dir, "libil2cpp.so");
        logf("[drive] libil2cpp init_array (%u entries)...", il->init_array_sz / 4);
        elf_run_init(il);
        call_guest(elf_resolve_entry(il, "il2cpp_set_data_dir"), {gstrdup(data_dir), 0});
        call_guest(elf_resolve_entry(il, "il2cpp_set_config_dir"), {gstrdup(data_dir), 0});
        logf("[drive] il2cpp mapped + data dir set (engine will init it)");
    }

    Module* uni = load_so(dir, "libunity.so");
    logf("[drive] libunity init_array (%u entries)...", uni->init_array_sz / 4);
    elf_run_init(uni);
    gaddr onload = elf_resolve_entry(uni, "JNI_OnLoad");
    u32 ver = u32(call_guest(onload, {jni_javavm(), 0}));
    logf("[drive] libunity JNI_OnLoad -> 0x%08x", ver);
}

// Drive Unity's own bring-up by calling its registered native entry points in the
// UnityPlayer order, routing every JNI callback to the host ART. activity and
// surface are host jobjects; apk is the data APK path for nativeFile.
void unity_start(void* activity, void* surface, const char* apk) {
    gaddr env = jni_env();
    u32 act = jni_wrap_host(activity);
    u32 surf = jni_wrap_host(surface);
    // JNI passes the method's class/this as the 2nd native arg; these engine
    // natives key off global state, so the class token works for all of them.
    auto call_native = [&](const char* name, std::initializer_list<u32> extra) {
        gaddr fn = jni_find_native(name);
        if (!fn) { logf("[drive] native %s NOT registered", name); return; }
        u32 cls = jni_native_class(name);
        std::vector<u32> a{env, cls};
        for (u32 x : extra) a.push_back(x);
        logf("[drive] -> %s", name);
        call_guest_v(fn, a.data(), int(a.size()));
        jni_check_exception(name);
        logf("[drive] <- %s ok", name);
    };

    logf("[drive] activity token=%08x surface token=%08x", act, surf);
    jni_trace(true);
    call_native("initJni", {act});
    jni_trace(false);
    call_native("nativeFile", {jni_new_string(apk)});
    call_native("nativeRecreateGfxState", {0, surf});
    call_native("nativeResume", {});

    gaddr render = jni_find_native("nativeRender");
    if (render) {
        u32 rcls = jni_native_class("nativeRender");
        logf("[drive] entering nativeRender loop (120 frames)...");
        for (int i = 0; i < 120; ++i) call_guest(render, {env, rcls});
        logf("[drive] nativeRender loop done");
    }
}

}  // namespace wst
