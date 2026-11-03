package com.windstock.boot;

import android.app.ActivityManager;
import android.app.ApplicationExitInfo;
import android.content.ContentProviderClient;
import android.content.Context;
import android.content.SharedPreferences;
import android.net.Uri;
import android.os.Build;
import android.os.Bundle;

import java.io.ByteArrayOutputStream;
import java.io.InputStream;
import java.io.PrintWriter;
import java.io.StringWriter;
import java.util.List;

/**
 * The game's first code: runs from UnityPlayerNativeActivity's static initializer,
 * before the frida gadget (and so before the agent) loads.
 *
 * Plain Java on purpose. When the game dies at start-up the agent never gets far
 * enough to say why, and a player's phone has no adb -- so this reports to the
 * launcher's log (ConfigProvider "log", the same channel the agent uses):
 *   * why the PREVIOUS game process ended (Android 11+ keeps the reason, and on 12+
 *     the native crash's tombstone), so the next "Report a problem" carries it;
 *   * Java exceptions that kill this process (default uncaught handler);
 *   * the gadget failing to load, which is caught: the game then runs without mods
 *     instead of dying in its static initializer.
 *
 * Built by tools/build_game_apk.sh into classes2.dex.
 */
public final class WSBoot {
    private static final String AUTHORITY = "content://com.windstock.launcher.config";
    private static ContentProviderClient client;

    private WSBoot() {}

    public static void boot() {
        try {
            Context app = (Context) Class.forName("android.app.ActivityThread")
                    .getMethod("currentApplication").invoke(null);
            if (app != null) {
                client = app.getContentResolver()
                        .acquireUnstableContentProviderClient(Uri.parse(AUTHORITY));
                if (client != null) {
                    reportLastExit(app);
                    catchCrashes();
                    log("game process " + android.os.Process.myPid() + " started on Android "
                            + Build.VERSION.RELEASE + " (API " + Build.VERSION.SDK_INT + ", "
                            + Build.MANUFACTURER + " " + Build.MODEL + ", "
                            + android.text.TextUtils.join("/", Build.SUPPORTED_ABIS) + ") -- loading the mods agent");
                }
            }
        } catch (Throwable t) {
            log("boot: " + t);
        }
        long t0 = System.currentTimeMillis();
        try {
            System.loadLibrary("frida-gadget");
            log("mods agent loaded in " + (System.currentTimeMillis() - t0) + " ms");
        } catch (Throwable t) {
            log("the mods agent did NOT load, running without mods: " + stack(t));
        }
    }

    static void log(String line) {
        ContentProviderClient c = client;
        if (c == null) return;
        try {
            c.call("log", "[boot] " + line, (Bundle) null);
        } catch (Throwable ignored) {
        }
    }

    private static void catchCrashes() {
        final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();
        Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
            @Override
            public void uncaughtException(Thread thread, Throwable e) {
                log("crash on thread \"" + thread.getName() + "\": " + stack(e));
                if (previous != null) previous.uncaughtException(thread, e);
            }
        });
    }

    /** Why the last game process(es) ended, each reported once. Android 11+. */
    private static void reportLastExit(Context app) {
        if (Build.VERSION.SDK_INT < 30) return;
        try {
            ActivityManager am = (ActivityManager) app.getSystemService(Context.ACTIVITY_SERVICE);
            List<ApplicationExitInfo> exits = am.getHistoricalProcessExitReasons(null, 0, 5);
            SharedPreferences prefs = app.getSharedPreferences("windstock-boot", Context.MODE_PRIVATE);
            long seen = prefs.getLong("lastExit", 0);
            long newest = seen;
            // Newest first; report oldest first so the log reads in order.
            for (int i = exits.size() - 1; i >= 0; i--) {
                ApplicationExitInfo e = exits.get(i);
                if (e.getTimestamp() <= seen) continue;
                newest = Math.max(newest, e.getTimestamp());
                log("last game exit: " + e);
                String trace = trace(e);
                if (trace != null) log("last game exit trace:\n" + trace);
            }
            if (newest != seen) prefs.edit().putLong("lastExit", newest).apply();
        } catch (Throwable t) {
            log("exit reasons: " + t);
        }
    }

    /** ANR traces are text; native crash tombstones (12+) are protobuf -- keep the readable runs. */
    private static String trace(ApplicationExitInfo e) {
        try (InputStream in = e.getTraceInputStream()) {
            if (in == null) return null;
            ByteArrayOutputStream buf = new ByteArrayOutputStream();
            byte[] b = new byte[16384];
            int n;
            while ((n = in.read(b)) > 0 && buf.size() < 512 * 1024) buf.write(b, 0, n);
            byte[] data = buf.toByteArray();
            if (e.getReason() == ApplicationExitInfo.REASON_ANR) {
                String s = new String(data, "UTF-8");
                return s.length() > 6000 ? s.substring(0, 6000) + "\n..." : s;
            }
            StringBuilder out = new StringBuilder();
            StringBuilder run = new StringBuilder();
            int lines = 0;
            for (int i = 0; i <= data.length && lines < 120; i++) {
                int c = i < data.length ? data[i] & 0xff : 0;
                if (c >= 0x20 && c < 0x7f) {
                    run.append((char) c);
                } else {
                    if (run.length() >= 6) {
                        out.append("  ").append(run).append('\n');
                        lines++;
                    }
                    run.setLength(0);
                }
            }
            return out.length() == 0 ? null : out.toString();
        } catch (Throwable t) {
            return "(trace unreadable: " + t + ")";
        }
    }

    private static String stack(Throwable t) {
        StringWriter w = new StringWriter();
        t.printStackTrace(new PrintWriter(w));
        String s = w.toString();
        return s.length() > 4000 ? s.substring(0, 4000) + "\n..." : s;
    }
}
