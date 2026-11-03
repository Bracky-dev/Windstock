package com.windstock.translator64;

import android.view.Surface;

// Thin JNI surface to libwst64.so (the Dynarmic translator). All of the real
// work happens native-side on a dedicated translator thread.
public final class WstBridge {
    static { System.loadLibrary("wst64"); }

    // Hand the real on-screen Surface to the EGL bridge.
    public static native void nSetSurface(Surface surface);

    // Start the translator: load the guest libs from `dir`, with il2cpp data in
    // `dataDir`, Unity data in `apkPath`, driven against `activity`. Runs its own
    // thread; returns immediately.
    public static native void nStart(Object activity, String dir, String dataDir,
                                     String apkPath, boolean withIl2cpp);

    // Called from native once the translator is booted and the inverse host->guest
    // trampolines are registered on the real Unity classes. Hands off to the
    // Activity to instantiate the real UnityPlayer on the UI thread.
    public static void onTranslatorReady() {
        // The Windstock agent (Frida gadget, script mode): il2cpp is up, Unity has not run a
        // frame yet -- the same moment the native game loads it. Blocks until the script's
        // top level (config, hooks) has run.
        try {
            System.loadLibrary("frida-gadget");
            android.util.Log.i("wst64", "[agent] gadget loaded");
        } catch (Throwable t) {
            android.util.Log.i("wst64", "[agent] no gadget: " + t);
        }
        MainActivity a = MainActivity.instance;
        if (a != null) a.runOnUiThread(a::hostUnityPlayer);
    }
}
