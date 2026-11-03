// Guest graphics + Android-native bridge for libunity.so.
//
// libunity imports NO gl* directly — it pulls every GLESv2 entrypoint at runtime
// through eglGetProcAddress(). So the bridge is: thunks for the EGL surface API,
// GL entrypoints, and the libandroid.so window/input/sensor API.
//
// Two modes:
//  * HEADLESS (g_real_egl=false): EGL returns plausible fake handles + success so
//    bring-up progresses with nothing drawn. Used by the CLI --unity-init.
//  * REAL (g_real_egl=true, set by the Android host app): the EGL/GL thunks
//    forward to the device's host libEGL/libGLESv2 against the real ANativeWindow
//    from the app's SurfaceView, so frames actually reach the screen. Host
//    handles (EGLDisplay/Config/Context/Surface — 64-bit pointers) can't live in
//    32-bit guest space, so they're kept in a token table and the guest only ever
//    sees a 32-bit token (0xFE0000xx).
#include "cpu.h"
#include "guest.h"
#include "thunks_ctx.h"

#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <EGL/egl.h>
#include <GLES2/gl2.h>

#include <unistd.h>
#include <string>
#include <vector>

#include "elf.h"

namespace wst {

// ---- real-mode state (wired by the Android host app) ----
static ANativeWindow* g_host_win = nullptr;
static bool g_real_egl = false;
void gfx_set_window(ANativeWindow* w) { g_host_win = w; }
void gfx_use_real_egl(bool on) { g_real_egl = on; }

// ---- host-handle token table (real mode) ----
static std::vector<void*> g_htab;
static u32 htok(void* h) {
    if (!h) return 0;
    for (size_t i = 0; i < g_htab.size(); ++i) if (g_htab[i] == h) return 0xFE000000u | u32(i);
    g_htab.push_back(h);
    return 0xFE000000u | u32(g_htab.size() - 1);
}
static void* hunh(u32 t) {
    if (t < 0xFE000000u) return nullptr;
    u32 i = t - 0xFE000000u;
    return i < g_htab.size() ? g_htab[i] : nullptr;
}

// ---- headless fake handles ----
static gaddr g_dpy, g_cfg, g_ctx, g_surf, g_win;
static u32 g_surf_w = 1080, g_surf_h = 1920;

#define GDEF(name) static void h_##name(Ctx& c)
static inline float ff(Ctx& c, int i) { u32 b = c.arg(i); float f; memcpy(&f, &b, 4); return f; }

// =====================================================================
// EGL
// =====================================================================
GDEF(eglGetDisplay) {
    if (g_real_egl) { c.retp(htok(eglGetDisplay(EGL_DEFAULT_DISPLAY))); return; }
    c.retp(g_dpy);
}
GDEF(eglInitialize) {
    if (g_real_egl) {
        EGLint maj = 0, min = 0;
        EGLBoolean r = eglInitialize((EGLDisplay)hunh(c.arg(0)), &maj, &min);
        if (c.argp(1)) wr32(c.argp(1), maj);
        if (c.argp(2)) wr32(c.argp(2), min);
        c.ret(r); return;
    }
    if (c.argp(1)) wr32(c.argp(1), 1);
    if (c.argp(2)) wr32(c.argp(2), 4);
    c.ret(1);
}
GDEF(eglTerminate) { c.ret(1); }
GDEF(eglGetError)  { c.ret(g_real_egl ? u32(eglGetError()) : 0x3000); }
GDEF(eglQueryString) {
    if (g_real_egl) {
        const char* s = eglQueryString((EGLDisplay)hunh(c.arg(0)), EGLint(c.arg(1)));
        c.retp(s ? gstrdup(s) : 0); return;
    }
    static gaddr s = 0; if (!s) s = gstrdup("Windstock translator64 EGL"); c.retp(s);
}
GDEF(eglChooseConfig) {
    if (g_real_egl) {
        EGLConfig tmp[64]; EGLint num = 0, want = EGLint(c.arg(3)); if (want > 64) want = 64;
        EGLBoolean r = eglChooseConfig((EGLDisplay)hunh(c.arg(0)),
                                       (const EGLint*)H(c.argp(1)), tmp, want, &num);
        gaddr out = c.argp(2);
        for (EGLint i = 0; i < num && out; ++i) wr32(out + i * 4, htok(tmp[i]));
        if (c.argp(4)) wr32(c.argp(4), num);
        c.ret(r); return;
    }
    if (c.argp(2) && c.arg(3) >= 1) wr32(c.argp(2), g_cfg);
    if (c.argp(4)) wr32(c.argp(4), 1);
    c.ret(1);
}
GDEF(eglGetConfigAttrib) {
    if (g_real_egl) {
        EGLint v = 0;
        EGLBoolean r = eglGetConfigAttrib((EGLDisplay)hunh(c.arg(0)), (EGLConfig)hunh(c.arg(1)),
                                          EGLint(c.arg(2)), &v);
        if (c.argp(3)) wr32(c.argp(3), v);
        c.ret(r); return;
    }
    if (c.argp(3)) wr32(c.argp(3), 8); c.ret(1);
}
GDEF(eglCreateContext) {
    if (g_real_egl) {
        EGLContext ctx = eglCreateContext((EGLDisplay)hunh(c.arg(0)), (EGLConfig)hunh(c.arg(1)),
                                          (EGLContext)hunh(c.arg(2)), (const EGLint*)H(c.argp(3)));
        c.retp(htok(ctx)); return;
    }
    c.retp(g_ctx);
}
GDEF(eglDestroyContext) {
    if (g_real_egl) { c.ret(eglDestroyContext((EGLDisplay)hunh(c.arg(0)), (EGLContext)hunh(c.arg(1)))); return; }
    c.ret(1);
}
static bool g_unlock_surface = false;
GDEF(eglCreateWindowSurface) {
    if (g_real_egl) {
        if (!g_host_win) { logf("[gfx] no host window for eglCreateWindowSurface"); c.retp(0); return; }
        EGLSurface s = eglCreateWindowSurface((EGLDisplay)hunh(c.arg(0)), (EGLConfig)hunh(c.arg(1)),
                                              g_host_win, (const EGLint*)H(c.argp(3)));
        logf("[gfx] real eglCreateWindowSurface -> %p (err 0x%x)", s, eglGetError());
        if (s && !getenv("WST_FPS")) g_unlock_surface = true;   // swap interval 0 once it is current
        c.retp(htok(s)); return;
    }
    c.retp(g_surf);
}
// A window holds one EGL surface at a time: Unity destroys the old one before making
// the next (e.g. a new size at the map), so this must really let it go.
GDEF(eglDestroySurface) {
    if (g_real_egl) {
        EGLBoolean r = eglDestroySurface((EGLDisplay)hunh(c.arg(0)), (EGLSurface)hunh(c.arg(1)));
        logf("[gfx] real eglDestroySurface(%p) -> %u", hunh(c.arg(1)), r);
        c.ret(r); return;
    }
    c.ret(1);
}
GDEF(eglMakeCurrent) {
    if (g_real_egl) {
        EGLBoolean r = eglMakeCurrent((EGLDisplay)hunh(c.arg(0)), (EGLSurface)hunh(c.arg(1)),
                                      (EGLSurface)hunh(c.arg(2)), (EGLContext)hunh(c.arg(3)));
        if (r && g_unlock_surface && c.arg(1)) { g_unlock_surface = false; eglSwapInterval((EGLDisplay)hunh(c.arg(0)), 0); }
        c.ret(r); return;
    }
    c.ret(1);
}
GDEF(eglGetCurrentContext) { c.retp(g_real_egl ? htok(eglGetCurrentContext()) : g_ctx); }
GDEF(eglGetCurrentSurface) { c.retp(g_real_egl ? htok(eglGetCurrentSurface(EGLint(c.arg(0)))) : g_surf); }
GDEF(eglQuerySurface) {
    if (g_real_egl) {
        EGLint v = 0;
        EGLBoolean r = eglQuerySurface((EGLDisplay)hunh(c.arg(0)), (EGLSurface)hunh(c.arg(1)),
                                       EGLint(c.arg(2)), &v);
        if (c.argp(3)) wr32(c.argp(3), v);
        c.ret(r); return;
    }
    u32 a = c.arg(2);
    u32 v = a == 0x3057 ? g_surf_w : a == 0x3056 ? g_surf_h : 0;
    if (c.argp(3)) wr32(c.argp(3), v); c.ret(1);
}
GDEF(eglSwapBuffers) {
    static int frames = 0; static timespec t0{};
    timespec now; clock_gettime(CLOCK_MONOTONIC, &now);
    if (!t0.tv_sec) t0 = now;
    ++frames;
    double dt = double(now.tv_sec - t0.tv_sec) + double(now.tv_nsec - t0.tv_nsec) / 1e9;
    if (dt >= 5.0) { logf("[fps] %.1f", frames / dt); frames = 0; t0 = now; }
    if (g_real_egl) { c.ret(eglSwapBuffers((EGLDisplay)hunh(c.arg(0)), (EGLSurface)hunh(c.arg(1)))); return; }
    c.ret(1);
}
GDEF(eglSwapInterval) {
    // Unlocked frame rate: never wait for vsync unless WST_FPS asks for a cap.
    if (g_real_egl) { EGLint iv = getenv("WST_FPS") ? EGLint(c.arg(1)) : 0;
                      c.ret(eglSwapInterval((EGLDisplay)hunh(c.arg(0)), iv)); return; }
    c.ret(1);
}

// =====================================================================
// GLESv2 — the subset needed to clear + present a frame, forwarding to the host
// driver in real mode. (The full per-signature GL forwarding table that Unity's
// GfxDeviceGLES2 needs is the next build-out; see unity_render_bringup.)
// =====================================================================
GDEF(gl_generic)    { c.ret(0); }
GDEF(glGetError)    { c.ret(g_real_egl ? u32(glGetError()) : 0); }
GDEF(glGetString)   {
    if (g_real_egl) { const GLubyte* s = glGetString(c.arg(0)); c.retp(s ? gstrdup((const char*)s) : gstrdup("")); return; }
    u32 n = c.arg(0);
    const char* s = n == 0x1F00 ? "Windstock" : n == 0x1F01 ? "translator64 GLES"
                  : n == 0x1F02 ? "OpenGL ES 2.0" : n == 0x8B8C ? "OpenGL ES GLSL ES 1.00" : "";
    c.retp(gstrdup(s));
}
GDEF(glGetIntegerv) {
    if (g_real_egl) { GLint v[4] = {0,0,0,0}; glGetIntegerv(c.arg(0), v); if (c.argp(1)) wr32(c.argp(1), u32(v[0])); c.ret(0); return; }
    if (c.argp(1)) wr32(c.argp(1), 0); c.ret(0);
}
GDEF(glGetFloatv)   { if (c.argp(1)) wr32(c.argp(1), 0); c.ret(0); }
GDEF(glViewport)    { if (g_real_egl) glViewport(c.arg(0), c.arg(1), c.arg(2), c.arg(3)); c.ret(0); }
GDEF(glClearColor)  { if (g_real_egl) glClearColor(ff(c,0), ff(c,1), ff(c,2), ff(c,3)); c.ret(0); }
GDEF(glClear)       { if (g_real_egl) glClear(c.arg(0)); c.ret(0); }
GDEF(glClearDepthf) { if (g_real_egl) glClearDepthf(ff(c,0)); c.ret(0); }
GDEF(glFinish)      { if (g_real_egl) glFinish(); c.ret(0); }
GDEF(glFlush)       { if (g_real_egl) glFlush(); c.ret(0); }
GDEF(glEnable)      { if (g_real_egl) glEnable(c.arg(0)); c.ret(0); }
GDEF(glDisable)     { if (g_real_egl) glDisable(c.arg(0)); c.ret(0); }
GDEF(glScissor)     { if (g_real_egl) glScissor(c.arg(0), c.arg(1), c.arg(2), c.arg(3)); c.ret(0); }

gaddr gl_fwd_proc(const char* name);   // gl_fwd.cpp

static void h_gl_unknown(Ctx& c) {
    static int n = 0;
    if (n++ < 50) logf("[gl] unknown proc '%s' called -> 0", thunk_cur_name());
    c.ret(0);
}

// Resolve a GL/EGL entrypoint for the guest (also used by dlsym on libGLESv2/libEGL).
gaddr gfx_proc_address(const char* nm) {
    if (!nm || !*nm) return 0;
    std::string name(nm);
    if (g_real_egl && !strncmp(nm, "gl", 2))
        if (gaddr t = gl_fwd_proc(nm)) return t;
    if (have_handler(name)) return thunk_for_import(name, false);
    return 0;
}

GDEF(eglGetProcAddress) {
    const char* nm = c.argp(0) ? HS(c.argp(0)) : nullptr;
    if (!nm || !*nm) { c.retp(0); return; }
    std::string name(nm);
    if (g_real_egl) {
        if (gaddr t = gl_fwd_proc(nm)) { c.retp(t); return; }
        if (have_handler(name)) { c.retp(thunk_for_import(name, false)); return; }
        logf("[gl] eglGetProcAddress('%s') not forwarded -> logging stub", nm);
        c.retp(make_thunk(name.c_str(), h_gl_unknown));
        return;
    }
    if (have_handler(name)) { c.retp(thunk_for_import(name, false)); return; }
    c.retp(make_thunk(name.c_str(), h_gl_generic));   // unknown GL: logging stub (returns 0)
}

// =====================================================================
// libandroid.so — ANativeWindow / input / sensor / looper
// =====================================================================
void* jni_unwrap(u32 tok);   // jni_real.cpp
void* jni_cur_env();
GDEF(ANativeWindow_fromSurface) {
    // (JNIEnv*, jobject surface): the surface is a guest JNI token for the real
    // host Surface (UnityPlayer's own SurfaceView) -> take ITS host window.
    if (g_real_egl) {
        jobject surf = (jobject)jni_unwrap(c.arg(1));
        JNIEnv* env = (JNIEnv*)jni_cur_env();
        if (surf && env) {
            ANativeWindow* w = ANativeWindow_fromSurface(env, surf);
            logf("[gfx] ANativeWindow_fromSurface(tok %08x) -> host %p (%dx%d)", c.arg(1), (void*)w,
                 w ? ANativeWindow_getWidth(w) : 0, w ? ANativeWindow_getHeight(w) : 0);
            if (w) g_host_win = w;
        } else {
            logf("[gfx] ANativeWindow_fromSurface(tok %08x): no host surface, keeping %p", c.arg(1), (void*)g_host_win);
        }
    }
    c.retp(g_win);   // guest never dereferences the window; one token is enough
}
GDEF(ANativeWindow_acquire)           { c.ret(0); }
GDEF(ANativeWindow_release)           { c.ret(0); }
GDEF(ANativeWindow_getWidth)          { c.ret(g_real_egl && g_host_win ? u32(ANativeWindow_getWidth(g_host_win)) : g_surf_w); }
GDEF(ANativeWindow_getHeight)         { c.ret(g_real_egl && g_host_win ? u32(ANativeWindow_getHeight(g_host_win)) : g_surf_h); }
GDEF(ANativeWindow_setBuffersGeometry){ if (c.arg(1)) g_surf_w = c.arg(1); if (c.arg(2)) g_surf_h = c.arg(2); c.ret(0); }
GDEF(ANativeWindow_lock)              { c.ret(0); }
GDEF(ANativeWindow_unlockAndPost)     { c.ret(0); }

GDEF(stub0) { c.ret(0); }
// ALooper_pollAll/pollOnce(timeoutMs, outFd*, outEvents*, outData**): no guest
// event sources are attached to a looper (input arrives via Java, sensors are
// stubbed), so always report ALOOPER_POLL_TIMEOUT after honouring the timeout.
GDEF(ALooper_poll) {
    int t = int(c.arg(0));
    if (t > 0) usleep(useconds_t(t > 100 ? 100 : t) * 1000);
    else if (t < 0) usleep(10 * 1000);
    c.ret(u32(-3));
}

void gfx_init() {
    g_dpy = va_alloc(0x100); g_cfg = va_alloc(0x100); g_ctx = va_alloc(0x100);
    g_surf = va_alloc(0x100); g_win = va_alloc(0x100);

#define REG(sym) register_handler(#sym, h_##sym)
    REG(eglGetDisplay); REG(eglInitialize); REG(eglTerminate); REG(eglGetError);
    REG(eglQueryString); REG(eglChooseConfig); REG(eglGetConfigAttrib);
    REG(eglCreateContext); REG(eglDestroyContext);
    REG(eglCreateWindowSurface); REG(eglDestroySurface);
    REG(eglMakeCurrent); REG(eglGetCurrentContext); REG(eglGetCurrentSurface);
    REG(eglQuerySurface); REG(eglSwapBuffers); REG(eglSwapInterval);
    REG(eglGetProcAddress);

    REG(glGetError); REG(glGetString); REG(glGetIntegerv); REG(glGetFloatv);
    REG(glViewport); REG(glClearColor); REG(glClear); REG(glClearDepthf);
    REG(glFinish); REG(glFlush); REG(glEnable); REG(glDisable); REG(glScissor);

    REG(ANativeWindow_fromSurface); REG(ANativeWindow_acquire); REG(ANativeWindow_release);
    REG(ANativeWindow_getWidth); REG(ANativeWindow_getHeight);
    REG(ANativeWindow_setBuffersGeometry); REG(ANativeWindow_lock); REG(ANativeWindow_unlockAndPost);
#undef REG

    static const char* kStubs[] = {
        "AInputEvent_getDeviceId", "AInputEvent_getSource", "AInputEvent_getType",
        "AInputQueue_attachLooper", "AInputQueue_finishEvent", "AInputQueue_getEvent",
        "AInputQueue_preDispatchEvent",
        "AKeyEvent_getAction", "AKeyEvent_getKeyCode", "AKeyEvent_getMetaState",
        "ALooper_forThread", "ALooper_prepare",
        "AMotionEvent_getAction", "AMotionEvent_getEventTime",
        "AMotionEvent_getHistoricalEventTime", "AMotionEvent_getHistoricalX",
        "AMotionEvent_getHistoricalY", "AMotionEvent_getHistorySize",
        "AMotionEvent_getPointerCount", "AMotionEvent_getPointerId",
        "AMotionEvent_getX", "AMotionEvent_getY",
        "ASensorEventQueue_disableSensor", "ASensorEventQueue_enableSensor",
        "ASensorEventQueue_getEvents", "ASensorEventQueue_hasEvents",
        "ASensorEventQueue_setEventRate",
        "ASensorManager_createEventQueue", "ASensorManager_destroyEventQueue",
        "ASensorManager_getDefaultSensor", "ASensorManager_getInstance",
        "ASensorManager_getSensorList",
        "ASensor_getMinDelay", "ASensor_getName", "ASensor_getResolution",
        "ASensor_getType", "ASensor_getVendor",
    };
    for (const char* n : kStubs) register_handler(n, h_stub0);
    register_handler("ALooper_pollAll", h_ALooper_poll);
    register_handler("ALooper_pollOnce", h_ALooper_poll);
}

// Call a registered thunk as guest code (guest-stub -> SVC -> host -> guest).
static u32 gcall(const char* name, std::initializer_list<u32> a) {
    return u32(call_guest(thunk_for_import(name, false), a));
}
static u32 gcallf(const char* name, std::initializer_list<float> fa) {
    std::vector<u32> a; for (float f : fa) { u32 b; memcpy(&b, &f, 4); a.push_back(b); }
    return u32(call_guest_v(thunk_for_import(name, false), a.data(), int(a.size())));
}

// Bring up a real EGL context on the host window and clear-present one frame,
// all driven as GUEST calls through the registered thunks — the exact path
// Unity's own graphics code takes. Proves the translator drives real GLES to the
// real on-screen surface. Returns the guest EGL display/context/surface tokens.
bool gfx_selftest() {
    gaddr scratch = va_alloc(0x1000);
    gaddr pmajor = scratch, pminor = scratch + 4, pcfg = scratch + 8, pnum = scratch + 12;
    gaddr pw = scratch + 16, ph = scratch + 20;

    // A standard GLES2 config attrib list, in guest memory.
    gaddr attribs = scratch + 64;
    u32 at[] = {0x3040,4 /*RENDERABLE_TYPE=OPENGL_ES2_BIT*/, 0x3024,8 /*RED*/, 0x3023,8 /*GREEN*/,
                0x3022,8 /*BLUE*/, 0x3021,8 /*ALPHA*/, 0x3025,16 /*DEPTH*/, 0x3038 /*NONE*/};
    for (size_t i = 0; i < sizeof(at)/4; ++i) wr32(attribs + u32(i) * 4, at[i]);
    gaddr ctxattr = scratch + 256;
    wr32(ctxattr, 0x3098); wr32(ctxattr + 4, 2); wr32(ctxattr + 8, 0x3038);  // CONTEXT_CLIENT_VERSION=2, NONE

    u32 dpy = gcall("eglGetDisplay", {0});
    u32 ini = gcall("eglInitialize", {dpy, pmajor, pminor});
    u32 cfgok = gcall("eglChooseConfig", {dpy, attribs, pcfg, 1, pnum});
    u32 cfg = rd32(pcfg);
    u32 ctx = gcall("eglCreateContext", {dpy, cfg, 0, ctxattr});
    u32 win = gcall("ANativeWindow_fromSurface", {0, 0});
    u32 surf = gcall("eglCreateWindowSurface", {dpy, cfg, win, 0});
    u32 cur = gcall("eglMakeCurrent", {dpy, surf, surf, ctx});
    gcall("eglQuerySurface", {dpy, surf, 0x3057, pw});
    gcall("eglQuerySurface", {dpy, surf, 0x3056, ph});
    u32 gs = gcall("eglGetProcAddress", {gstrdup("glGetString")});
    u32 ver = u32(call_guest(gs, {0x1F02}));
    logf("[gfx] EGL %u.%u init=%u choose=%u makeCurrent=%u surface=%ux%u GL_VERSION=\"%s\"",
         rd32(pmajor), rd32(pminor), ini, cfgok, cur, rd32(pw), rd32(ph), ver ? HS(ver) : "(null)");

    // Clear to Windstock blue and present — a real frame if g_real_egl.
    gcall("glViewport", {0, 0, rd32(pw), rd32(ph)});
    gcallf("glClearColor", {0.016f, 0.33f, 0.63f, 1.0f});
    gcall("glClear", {0x4000 /*GL_COLOR_BUFFER_BIT*/});
    gcall("glFinish", {});
    u32 sw = gcall("eglSwapBuffers", {dpy, surf});
    logf("[gfx] cleared + eglSwapBuffers -> %u (glGetError 0x%x)", sw, gcall("glGetError", {}));
    return dpy && cfgok && ctx && surf && cur;
}

void unity_render_bringup(Module* /*libunity*/) {
    logf("[gfx] render bring-up (real_egl=%d, host_win=%p)", g_real_egl, (void*)g_host_win);
    gfx_selftest();
}

}  // namespace wst
