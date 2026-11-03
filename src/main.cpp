// PoC driver: bring up the guest space, load the 0.35 native libs, and run
// libmain.so's JNI_OnLoad through Dynarmic.
#include "cpu.h"
#include "elf.h"
#include "guest.h"
#include "thunks_ctx.h"

#include <cstdio>
#include <cstring>

namespace wst { void jni_init(); gaddr jni_javavm(); void thunks_init(); void sys_init(); void install_fault_reporter();
                void gfx_init(); bool gfx_selftest(); }

using namespace wst;

static char g_path[1024];
static Module* load_so(const char* dir, const char* so) {
    snprintf(g_path, sizeof g_path, "%s/%s", dir, so);
    return elf_load(g_path, so);
}

static int run_jni(const char* dir, bool want_il2cpp) {
    Module* main_mod = load_so(dir, "libmain.so");
    if (want_il2cpp) load_so(dir, "libil2cpp.so");
    elf_run_init(main_mod);
    gaddr onload = elf_resolve_entry(main_mod, "JNI_OnLoad");
    logf("[run] JNI_OnLoad at %s (thumb=%d)", describe_addr(onload & ~1u).c_str(), onload & 1);
    u32 ver = u32(call_guest(onload, {jni_javavm(), 0}));
    logf("[run] JNI_OnLoad returned 0x%08x", ver);
    bool ok = (ver == 0x00010006 || ver == 0x00010004 || ver == 0x00010002);
    printf("\n==== %s: JNI_OnLoad -> 0x%08x ====\n", ok ? "PASS" : "FAIL", ver);
    return ok ? 0 : 2;
}

static int run_il2cpp_init(const char* dir, const char* data_dir) {
    Module* m = load_so(dir, "libil2cpp.so");
    logf("[run] running libil2cpp init_array (%u entries)...", m->init_array_sz / 4);
    elf_run_init(m);
    logf("[run] init_array done");

    gaddr set_dir = elf_resolve_entry(m, "il2cpp_set_data_dir");
    gaddr set_cfg = elf_resolve_entry(m, "il2cpp_set_config_dir");
    call_guest(set_dir, {gstrdup(data_dir), 0});
    call_guest(set_cfg, {gstrdup(data_dir), 0});
    logf("[run] data dir set to %s", data_dir);

    gaddr init = elf_resolve_entry(m, "il2cpp_init");
    logf("[run] calling il2cpp_init ...");
    u32 r = u32(call_guest(init, {gstrdup("IL2CPP Root Domain"), 0}));
    logf("[run] il2cpp_init returned %u", r);
    printf("\n==== %s: il2cpp_init -> %u ====\n", r ? "PASS" : "FAIL", r);
    return r ? 0 : 2;
}

// Phase 3: bring up libunity.so. libunity NEEDs libmain (all 29 inter-module
// symbols it imports are libmain exports), so load libmain first, then libunity,
// exercising the loader's inter-module resolution. Run all of libunity's
// init_array constructors, then its JNI_OnLoad (which registers the UnityPlayer
// natives), then drive a representative headless EGL/GLES bring-up through the
// bridge to prove it dispatches.
static int run_unity_init(const char* dir, bool also_il2cpp) {
    Module* main_mod = load_so(dir, "libmain.so");
    if (also_il2cpp) load_so(dir, "libil2cpp.so");
    elf_run_init(main_mod);
    Module* uni = load_so(dir, "libunity.so");
    logf("[run] running libunity init_array (%u entries)...", uni->init_array_sz / 4);
    elf_run_init(uni);
    logf("[run] libunity init_array done");

    gaddr onload = elf_resolve_entry(uni, "JNI_OnLoad");
    logf("[run] libunity JNI_OnLoad at %s (thumb=%d)", describe_addr(onload & ~1u).c_str(), onload & 1);
    u32 ver = u32(call_guest(onload, {jni_javavm(), 0}));
    logf("[run] libunity JNI_OnLoad returned 0x%08x", ver);
    bool jni_ok = (ver == 0x00010006 || ver == 0x00010004 || ver == 0x00010002);

    logf("[run] driving headless EGL/GLES bring-up through the bridge...");
    bool gfx_ok = gfx_selftest();

    bool ok = jni_ok && gfx_ok;
    printf("\n==== %s: libunity JNI_OnLoad -> 0x%08x, EGL/GLES bridge %s ====\n",
           ok ? "PASS" : "FAIL", ver, gfx_ok ? "ok" : "FAILED");
    return ok ? 0 : 2;
}

int main(int argc, char** argv) {
    const char* dir = ".";
    const char* data_dir = "./Data/Managed";
    bool want_il2cpp = false, il2cpp_init_mode = false, unity_init_mode = false;
    for (int i = 1; i < argc; ++i) {
        if (!strcmp(argv[i], "-v")) g_verbose = 1;
        else if (!strcmp(argv[i], "--il2cpp")) want_il2cpp = true;
        else if (!strcmp(argv[i], "--il2cpp-init")) il2cpp_init_mode = true;
        else if (!strcmp(argv[i], "--unity-init")) unity_init_mode = true;
        else if (!strcmp(argv[i], "--data") && i + 1 < argc) data_dir = argv[++i];
        else if (argv[i][0] != '-') dir = argv[i];
    }

    if (!mem_init()) { fprintf(stderr, "mem_init failed\n"); return 1; }
    cpu_init();
    thunks_init();
    sys_init();
    gfx_init();
    jni_init();

    install_fault_reporter();
    if (unity_init_mode) return run_unity_init(dir, want_il2cpp);
    return il2cpp_init_mode ? run_il2cpp_init(dir, data_dir) : run_jni(dir, want_il2cpp);
}
