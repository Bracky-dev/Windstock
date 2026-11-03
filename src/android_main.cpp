// JNI entry points for the Windstock translator64 Android host app.
//
// The app (com.windstock.translator64) is our own minimal Activity + SurfaceView
// that loads THIS library (libwst64.so, arm64) and hands us the real Surface +
// Activity. We load the 32-bit guest libs (libmain/libil2cpp/libunity) under the
// Dynarmic translator, give the EGL bridge the real ANativeWindow, bridge guest
// JNI to the host ART, and drive Unity's native entry points.
#include <jni.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>

#include <android/log.h>
#include <pthread.h>
#include <stdio.h>
#include <unistd.h>
#include <string>

#include "cpu.h"
#include "elf.h"
#include "guest.h"

namespace wst {
void cpu_init();
void thunks_init(); void sys_init(); void gfx_init(); void jni_init();
void install_fault_reporter();
void profile_start();
void gfx_set_window(ANativeWindow* win);
void gfx_use_real_egl(bool on);
void jni_bind_host(void* vm, void* env);
void jni_set_classloader(void* activity_jobj);
void jni_register_host_natives();
void unity_drive(const char* dir, bool with_il2cpp, const char* data_dir);
void unity_start(void* activity, void* surface, const char* apk);
}  // namespace wst

using namespace wst;

static JavaVM* g_vm = nullptr;
static ANativeWindow* g_win = nullptr;
static jobject g_activity = nullptr;   // global ref
static jobject g_surface = nullptr;    // global ref
static jclass g_bridge_cls = nullptr;  // global ref to WstBridge
static std::string g_dir, g_data, g_apk;
static bool g_with_il2cpp = true;

static void* driver_thread(void*) {
    JNIEnv* env = nullptr;
    g_vm->AttachCurrentThread(&env, nullptr);

    // Boehm GC collects normally; its stop-the-world uses guest signals (signals.cpp).
    // Diagnosis: set WST_GUEST_ENV=GC_DONT_GC=1 to turn collection off.
    logf("[app] translator thread up; dir=%s apk=%s", g_dir.c_str(), g_apk.c_str());
    mem_init();
    cpu_init();
    thunks_init();
    sys_init();
    gfx_init();
    jni_init();
    install_fault_reporter();
    sampler_start();
    profile_start();

    jni_bind_host(g_vm, env);
    jni_set_classloader(g_activity);   // before init_array (Unity FindClass's its Java classes)
    gfx_set_window(g_win);
    gfx_use_real_egl(true);

    unity_drive(g_dir.c_str(), g_with_il2cpp, g_data.c_str());

    // Register our inverse host->guest trampolines on the real Unity Java classes,
    // then ask Java (UI thread) to host the real UnityPlayer, which will drive the
    // engine through those trampolines.
    jni_register_host_natives();
    jclass bc = g_bridge_cls ? g_bridge_cls : env->FindClass("com/windstock/translator64/WstBridge");
    if (bc) {
        jmethodID onReady = env->GetStaticMethodID(bc, "onTranslatorReady", "()V");
        if (onReady) { logf("[app] translator ready -> hosting UnityPlayer"); env->CallStaticVoidMethod(bc, onReady); }
        else logf("[app] onTranslatorReady not found");
        if (env->ExceptionCheck()) env->ExceptionClear();
    }
    logf("[app] driver thread idle");
    return nullptr;
}

// App processes send stdout/stderr to /dev/null; the guest's libstdc++ writes its
// terminate()/what() diagnostics there, so pipe both fds into logcat.
static void* stdio_pump(void* arg) {
    int fd = int(reinterpret_cast<intptr_t>(arg));
    char buf[1024]; std::string line;
    for (;;) {
        ssize_t n = read(fd, buf, sizeof buf);
        if (n <= 0) break;
        for (ssize_t i = 0; i < n; ++i) {
            if (buf[i] == '\n') { __android_log_write(ANDROID_LOG_WARN, "wst64-stdio", line.c_str()); line.clear(); }
            else line += buf[i];
        }
    }
    return nullptr;
}
namespace wst { extern bool g_stderr_is_logcat; }
static void redirect_stdio() {
    int p[2];
    if (pipe(p) != 0) return;
    setvbuf(stdout, nullptr, _IONBF, 0);
    setvbuf(stderr, nullptr, _IONBF, 0);
    dup2(p[1], 1); dup2(p[1], 2);
    wst::g_stderr_is_logcat = true;
    pthread_t t;
    pthread_create(&t, nullptr, stdio_pump, reinterpret_cast<void*>(intptr_t(p[0])));
    pthread_detach(t);
}

extern "C" JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void*) {
    g_vm = vm;
    redirect_stdio();
    return JNI_VERSION_1_6;
}

extern "C" JNIEXPORT void JNICALL
Java_com_windstock_translator64_WstBridge_nSetSurface(JNIEnv* env, jclass, jobject surface) {
    if (g_win) { ANativeWindow_release(g_win); g_win = nullptr; }
    if (g_surface) { env->DeleteGlobalRef(g_surface); g_surface = nullptr; }
    if (surface) {
        g_surface = env->NewGlobalRef(surface);
        g_win = ANativeWindow_fromSurface(env, surface);
        logf("[app] host window %p (%dx%d)", g_win,
             g_win ? ANativeWindow_getWidth(g_win) : 0,
             g_win ? ANativeWindow_getHeight(g_win) : 0);
        if (g_win) gfx_set_window(g_win);
    }
}

extern "C" JNIEXPORT void JNICALL
Java_com_windstock_translator64_WstBridge_nStart(JNIEnv* env, jclass bridge, jobject activity,
        jstring dir, jstring data, jstring apk, jboolean il2cpp) {
    g_bridge_cls = (jclass)env->NewGlobalRef(bridge);
    g_activity = env->NewGlobalRef(activity);
    const char* d = env->GetStringUTFChars(dir, nullptr);
    const char* da = env->GetStringUTFChars(data, nullptr);
    const char* ap = env->GetStringUTFChars(apk, nullptr);
    g_dir = d; g_data = da; g_apk = ap; g_with_il2cpp = il2cpp;
    env->ReleaseStringUTFChars(dir, d);
    env->ReleaseStringUTFChars(data, da);
    env->ReleaseStringUTFChars(apk, ap);

    pthread_t t;
    pthread_create(&t, nullptr, driver_thread, nullptr);
    pthread_detach(t);
}
