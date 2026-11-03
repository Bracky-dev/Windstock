package com.windstock.translator64;

import android.app.Activity;
import android.content.res.AssetManager;
import android.os.Bundle;
import android.util.Log;
import android.view.SurfaceHolder;
import android.view.SurfaceView;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.CountDownLatch;

// Our own minimal host Activity (modelled on Unity's UnityPlayerActivity flow,
// but all our code): a full-screen SurfaceView whose Surface we pass straight to
// the native EGL bridge, plus a one-time copy of the bundled guest libs + il2cpp
// data out of assets into filesDir so the translator can fopen() them.
public class MainActivity extends Activity implements SurfaceHolder.Callback {
    private static final String TAG = "wst64";
    static MainActivity instance;
    private Object unityPlayer;
    private final CountDownLatch copied = new CountDownLatch(1);
    private boolean started = false;
    private String filesPath, dataPath, apkPath;

    @Override protected void onCreate(Bundle b) {
        super.onCreate(b);
        instance = this;
        // The platform only creates the app's external dirs when asked; Unity
        // mkdir()s under them for persistentDataPath / il2cpp caches.
        try { getExternalFilesDir(null); getExternalCacheDir(); getObbDir(); } catch (Exception ignored) {}
        File guest = guestDir();
        guest.mkdirs();
        filesPath = guest.getAbsolutePath();
        dataPath = new File(guest, "Data/Managed").getAbsolutePath();
        apkPath = new File(guest, "game.apk").getAbsolutePath();

        SurfaceView sv = new SurfaceView(this);
        sv.getHolder().addCallback(this);
        setContentView(sv);

        new Thread(() -> {
            // before the translator starts (it waits for this thread): nothing routes yet
            try { configureNet(); } catch (Exception e) { Log.e(TAG, "[app] net config failed", e); }
            WsNet.init(guestDir());
            try { copyAssets(); Log.i(TAG, "[app] assets copied"); }
            catch (Exception e) { Log.e(TAG, "[app] asset copy failed", e); }
            copied.countDown();
        }, "wst-copy").start();
    }

    @Override public void surfaceCreated(SurfaceHolder h) {
        WstBridge.nSetSurface(h.getSurface());
        if (!started) {
            started = true;
            new Thread(() -> {
                try { copied.await(); } catch (InterruptedException ignored) {}
                Log.i(TAG, "[app] starting translator");
                WstBridge.nStart(MainActivity.this, filesPath, dataPath, apkPath, true);
            }, "wst-launch").start();
        }
    }

    @Override public void surfaceChanged(SurfaceHolder h, int f, int w, int ht) {
        WstBridge.nSetSurface(h.getSurface());
    }
    @Override public void surfaceDestroyed(SurfaceHolder h) {
        WstBridge.nSetSurface(null);
    }

    // Instantiate the real com.unity3d.player.UnityPlayer (from the bundled game
    // dex). Its constructor + lifecycle call the native methods, which dispatch
    // into the translated guest via the inverse trampoline. Reflection avoids a
    // compile-time dependency on the game classes.
    void hostUnityPlayer() {
        try {
            Class<?> cls = Class.forName("com.unity3d.player.UnityPlayer");
            try {
                unityPlayer = cls.getConstructor(android.content.Context.class).newInstance(this);
            } catch (NoSuchMethodException nsme) {
                unityPlayer = cls.getConstructor(android.content.ContextWrapper.class).newInstance(this);
            }
            Log.i(TAG, "[app] UnityPlayer instantiated: " + unityPlayer);
            if (unityPlayer instanceof android.view.View) {
                setContentView((android.view.View) unityPlayer);
            } else {
                try {
                    Object v = cls.getMethod("getView").invoke(unityPlayer);
                    if (v instanceof android.view.View) setContentView((android.view.View) v);
                } catch (Throwable ignore) {}
            }
            try { cls.getMethod("requestFocus").invoke(unityPlayer); } catch (Throwable ignore) {}
            try { cls.getMethod("resume").invoke(unityPlayer); } catch (Throwable ignore) {}
            try { cls.getMethod("windowFocusChanged", boolean.class).invoke(unityPlayer, true); } catch (Throwable ignore) {}
        } catch (Throwable t) {
            Log.e(TAG, "[app] hostUnityPlayer failed", t);
        }
    }

    private void up(String m) {
        if (unityPlayer == null) return;
        try { unityPlayer.getClass().getMethod(m).invoke(unityPlayer); } catch (Throwable ignore) {}
    }
    @Override protected void onResume() { super.onResume(); up("resume"); }
    @Override protected void onPause() { super.onPause(); up("pause"); }
    @Override public void onWindowFocusChanged(boolean f) {
        super.onWindowFocusChanged(f);
        if (unityPlayer != null) try {
            unityPlayer.getClass().getMethod("windowFocusChanged", boolean.class).invoke(unityPlayer, f);
        } catch (Throwable ignore) {}
    }

    // Where the guest libs + il2cpp data are copied to (and device.id lives). Windstock 64
    // (android-launcher, w64 flavour) hosts this Activity next to the launcher's own files.
    protected File guestDir() { return getFilesDir(); }

    // Windstock 64: point WsNet at the server the launcher chose (WsNet.configure).
    protected void configureNet() {}

    // ---- assets -> guestDir (idempotent: skip when size matches) ----
    private void copyAssets() throws Exception {
        AssetManager am = getAssets();
        // a new APK may carry same-sized libs: copy everything again once per install/update
        File stamp = new File(guestDir(), ".copied");
        String want = String.valueOf(getPackageManager().getPackageInfo(getPackageName(), 0).lastUpdateTime);
        String have = "";
        try (InputStream in = new java.io.FileInputStream(stamp)) {
            byte[] buf = new byte[64]; int n = in.read(buf); if (n > 0) have = new String(buf, 0, n, "US-ASCII");
        } catch (Exception ignored) {}
        forceCopy = !want.equals(have);
        copyTree(am, "guest", guestDir());
        try (OutputStream os = new FileOutputStream(stamp)) { os.write(want.getBytes("US-ASCII")); }
    }
    private boolean forceCopy;
    private void copyTree(AssetManager am, String path, File destDir) throws Exception {
        String[] kids = am.list(path);
        if (kids == null || kids.length == 0) { // it's a file
            File out = new File(destDir, new File(path).getName());
            copyFile(am, path, out);
            return;
        }
        File sub = path.equals("guest") ? destDir : new File(destDir, new File(path).getName());
        sub.mkdirs();
        for (String k : kids) copyTree(am, path + "/" + k, sub);
    }
    private void copyFile(AssetManager am, String assetPath, File out) throws Exception {
        try (InputStream in = am.open(assetPath)) {
            if (!forceCopy && out.exists() && out.length() == in.available()) return; // already copied
        } catch (Exception ignored) {}
        try (InputStream in = am.open(assetPath); OutputStream os = new FileOutputStream(out)) {
            byte[] buf = new byte[1 << 16]; int n;
            while ((n = in.read(buf)) > 0) os.write(buf, 0, n);
        }
    }
}
