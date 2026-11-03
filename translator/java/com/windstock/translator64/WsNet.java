package com.windstock.translator64;

import android.util.Log;

import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.security.KeyStore;
import java.security.SecureRandom;
import java.security.cert.CertificateFactory;
import java.util.Base64;

import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.HttpsURLConnection;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocketFactory;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;
import java.security.cert.X509Certificate;

// Points the game at the public Windstock server, from inside this app.
//
// The game's network layer (com.nianticlabs.nia.network.NiaNet) is Java running on
// the real ART, called by the translated engine through our JNI bridge. The bridge
// hands every NiaNet.request(...) to route() first: a request for one of Niantic's /
// Pokémon's hosts goes to the server's one public TLS port instead, with the original
// host in the Host header -- exactly what the launchers' tunnel (work/server/tunnel.py)
// does. setup() is called just before NiaNet's nativeSetupConnection and pins that
// connection to the server's own CA, verified as pgorelease.nianticlabs.com.
public final class WsNet {
    private static final String TAG = "wst64";
    // the public Windstock server, unless configure() names another (Windstock 64: the launcher's)
    static String SERVER = "10.0.2.2";   // 0.71 build: the Mac running the 0.63/0.71 fork server
    static int PORT = 8888;
    private static boolean enabled = true;
    static final String SERVER_NAME = "pgorelease.nianticlabs.com";
    static final String LAUNCHER_BUILD = "4";
    // The released game's RPC base was once baked to the public tunnel.
    private static final String[] BAKED = {"bracky.playit.plus"};
    private static final String[] HOSTS = {"nianticlabs.com", "pokemon.com", "zendesk.com"};
    // work/server/online_pins.py, "2.29.24.78:8888"
    private static String caPem;
    private static final String CA_PEM =
        "MIIDezCCAmOgAwIBAgIUFVD8OEPtm79uJ4YosMvySCvg2RcwDQYJKoZIhvcNAQELBQAwRTELMAkGA1UEBhMCVVMxHDAaBgNVBAoME1BvR08gUHJpdmF0ZSBTZXJ2ZXIxGDAWBgNVBAMMD1BvR08gUHJpdmF0ZSBDQTAeFw0yNjA2MTYxODE1MzJaFw0zNjA2MTMxODE1MzJaMEUxCzAJBgNVBAYTAlVTMRwwGgYDVQQKDBNQb0dPIFByaXZhdGUgU2VydmVyMRgwFgYDVQQDDA9Qb0dPIFByaXZhdGUgQ0EwggEiMA0GCSqGSIb3DQEBAQUAA4IBDwAwggEKAoIBAQCQPSFLpA3S609wm1zeiqzBSufPnIaXWNWNwXojUbPEG/Fp9vIZxyldYEmz2y3KfCbxhSJdJ1o6BnfOY1HCCmpGb7sBTGczAKApFXXMQHn4i6Z1h3aMwn6JLGVShOtOOekTC6M5IQCU4fYixOgDO//RCFznz7Z7pYXpDLLczJptZPX0csiInWcyPyNmljcLL53pii47omNaXxXX4A2Az4BYoBupPOMQFO8ASb9/SWrSnsLAZYGjZDEhLIi6AY/Fjr7l/AbMeXrBjsr6WOMT4y3JHNnMHYNmJZqUWKzMw9n2Ns2SxhVWilNoho1Fc9l5lUGC2e8D9Xj3y2T+9JT/RVi9AgMBAAGjYzBhMB0GA1UdDgQWBBS0ccgKmGap9saIsmLbzFkAE276/jAfBgNVHSMEGDAWgBS0ccgKmGap9saIsmLbzFkAE276/jAPBgNVHRMBAf8EBTADAQH/MA4GA1UdDwEB/wQEAwIBBjANBgkqhkiG9w0BAQsFAAOCAQEANY1KXOPhhxBq0k6N8SiTVUdXCfFgxVod9QpRvU1jqCx3ePN5SR7X6MD0qBXoY9X6GCuDeMCZeO6DiE+tMvtiseuHGcHO4nR+t8ATF7N9NRUTdY4KwFAYMpGP07YRoDIhUlcsgMUyjITQuAdz3D2sjIycM1gX6mr0mlsgSWMAvbREqCMZKOL+XZJu50MQCGaIkYooT4o0NGspiaTbkY500bMunb0qLLALGiYq4Kd/vfbjvnRGsY3nOKjS9+tfHZfWn3UVXTtan4h5iv/0SEI8Pp4mMB0Hp6F2CAtqXhTS1K/sVslJAPu+8GJKZcdC5vn8YJxU/Kz1LyqPJy+O6Dd/8A==";

    private static SSLSocketFactory pinned;
    private static String device;
    private static int logged;

    /**
     * Windstock 64: the game goes where the launcher's config says (Launcher.gameConfig "net"):
     * its tunnel / embedded server on 127.0.0.1, or a server on the network -- TLS checked
     * against that server's CA (PEM, with or without the BEGIN/END lines). enabled=false leaves
     * every request alone. Call before init().
     */
    public static synchronized void configure(boolean on, String host, int port, String ca) {
        enabled = on;
        if (host != null && !host.isEmpty()) SERVER = host;
        if (port > 0) PORT = port;
        if (ca != null && !ca.isEmpty())
            caPem = ca.replaceAll("-----(BEGIN|END) CERTIFICATE-----", "").replaceAll("\\s", "");
    }

    static synchronized void init(File filesDir) {
        if (device != null) return;
        // 0.71: the Niantic plugin's native RPC socket (127.0.0.1:443) goes to this server (sys.cpp connect)
        if (enabled) try { android.system.Os.setenv("WST_RPC_HOST", SERVER, true); } catch (Exception ignored) {}
        File f = new File(filesDir, "device.id");
        try (FileInputStream in = new FileInputStream(f)) {
            byte[] b = new byte[128]; int n = in.read(b);
            String v = n > 0 ? new String(b, 0, n, "US-ASCII").trim() : "";
            if (v.length() >= 22 && v.length() <= 64) device = v;
        } catch (Exception ignored) {}
        if (device == null) {
            byte[] r = new byte[24]; new SecureRandom().nextBytes(r);
            device = Base64.getUrlEncoder().withoutPadding().encodeToString(r);
            try (FileOutputStream out = new FileOutputStream(f)) { out.write(device.getBytes("US-ASCII")); }
            catch (Exception e) { Log.w(TAG, "[net] could not save device.id: " + e); }
        }
        try {
            // certificate check removed: accept any server certificate
            SSLContext ctx = SSLContext.getInstance("TLS");
            ctx.init(null, new TrustManager[] { new X509TrustManager() {
                public void checkClientTrusted(X509Certificate[] chain, String authType) {}
                public void checkServerTrusted(X509Certificate[] chain, String authType) {}
                public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            } }, null);
            pinned = ctx.getSocketFactory();
        } catch (Exception e) {
            Log.e(TAG, "[net] TLS setup failed", e);
        }
        Log.i(TAG, "[net] Windstock server " + SERVER + ":" + PORT + " (no certificate check)"
            + (enabled ? "" : " -- routing OFF"));
        new Thread(WsNet::check, "wst-netcheck").start();
        new Thread(WsNet::relay, "wst-relay").start();
    }

    // ---- plain-HTTP relay for the guest's own sockets ----
    // The game's PTC sign-in is Mono's HttpWebRequest over plain HTTP to sso.pokemon.com:80.
    // The translator resolves that to 127.0.0.1 and turns port 80 into RELAY_PORT; each
    // connection here is one request, re-sent over the pinned TLS link with our headers.
    static final int RELAY_PORT = 18080;      // sys.cpp kRelayPort

    private static void relay() {
        try (java.net.ServerSocket ss = new java.net.ServerSocket(RELAY_PORT, 32, java.net.InetAddress.getByName("127.0.0.1"))) {
            Log.i(TAG, "[net] relay on 127.0.0.1:" + RELAY_PORT);
            while (true) {
                final java.net.Socket in = ss.accept();
                new Thread(() -> relayOne(in), "wst-relay-conn").start();
            }
        } catch (Exception e) {
            Log.e(TAG, "[net] relay stopped: " + e);
        }
    }

    private static void relayOne(java.net.Socket in) {
        javax.net.ssl.SSLSocket up = null;
        try {
            in.setSoTimeout(60000);
            java.io.InputStream ci = in.getInputStream();
            // the request head, up to the blank line
            java.io.ByteArrayOutputStream head = new java.io.ByteArrayOutputStream();
            int m = 0, b;
            while (m < 4 && (b = ci.read()) >= 0) {
                head.write(b);
                m = (b == (m % 2 == 0 ? '\r' : '\n')) ? m + 1 : (b == '\r' ? 1 : 0);
                if (head.size() > 65536) throw new java.io.IOException("request head too large");
            }
            String[] lines = head.toString("ISO-8859-1").split("\r\n");
            StringBuilder out = new StringBuilder(lines[0]).append("\r\n");
            for (int i = 1; i < lines.length; i++) {
                String l = lines[i]; if (l.isEmpty()) continue;
                String k = l.substring(0, Math.max(0, l.indexOf(':'))).trim().toLowerCase();
                if (k.equals("connection") || k.equals("proxy-connection") || k.startsWith("x-ws-")) continue;
                if (k.equals("host") && l.contains("127.0.0.1")) l = "Host: " + SERVER_NAME;   // a relayed Unity download
                out.append(l).append("\r\n");
            }
            out.append("Connection: close\r\nX-WS-Device: ").append(device)
               .append("\r\nX-WS-Launcher: ").append(LAUNCHER_BUILD).append("\r\n\r\n");
            if (logged++ < 8) Log.i(TAG, "[net] relay: " + lines[0]);

            up = (javax.net.ssl.SSLSocket) pinned.createSocket(SERVER, PORT);
            up.setSoTimeout(60000);
            up.startHandshake();
            final java.io.OutputStream uo = up.getOutputStream();
            uo.write(out.toString().getBytes("ISO-8859-1"));
            uo.flush();
            final javax.net.ssl.SSLSocket upf = up;
            Thread body = new Thread(() -> {       // request body (if any) -> server
                try { pump(ci, uo); } catch (Exception ignored) {}
            }, "wst-relay-body");
            body.start();
            pump(up.getInputStream(), in.getOutputStream());   // response -> game
        } catch (Exception e) {
            Log.e(TAG, "[net] relay: " + e);
        } finally {
            try { in.close(); } catch (Exception ignored) {}
            try { if (up != null) up.close(); } catch (Exception ignored) {}
        }
    }

    private static void pump(java.io.InputStream i, java.io.OutputStream o) throws java.io.IOException {
        byte[] buf = new byte[16384]; int n;
        while ((n = i.read(buf)) > 0) { o.write(buf, 0, n); o.flush(); }
    }

    // One status request at start, so the log shows the server is reachable and trusted.
    private static void check() {
        try {
            HttpURLConnection c = (HttpURLConnection) new URL("https://" + SERVER + ":" + PORT + "/windstock/online").openConnection();
            setup(c);
            c.setRequestProperty("Host", SERVER_NAME);
            c.setConnectTimeout(10000); c.setReadTimeout(10000);
            int code = c.getResponseCode();
            byte[] b = new byte[200]; int n = 0;
            try (java.io.InputStream in = code < 400 ? c.getInputStream() : c.getErrorStream()) { if (in != null) n = Math.max(0, in.read(b)); }
            Log.i(TAG, "[net] server check: HTTP " + code + " " + new String(b, 0, n, "UTF-8").replace('\n', ' '));
        } catch (Exception e) {
            Log.e(TAG, "[net] server check FAILED: " + e);
        }
    }

    private static boolean ours(String host) {
        host = host.toLowerCase();
        for (String b : BAKED) if (host.equals(b)) return true;
        for (String h : HOSTS) if (host.equals(h) || host.endsWith("." + h)) return true;
        return false;
    }

    // {url, headers} to use instead, or null to leave the request alone.
    public static String[] route(String url, String headers) {
        try {
            URL u = new URL(url);
            String host = u.getHost();
            if (!enabled || !ours(host)) return null;
            for (String b : BAKED) if (host.equalsIgnoreCase(b)) host = SERVER_NAME;
            String file = u.getFile().isEmpty() ? "/" : u.getFile();
            String to = "https://" + SERVER + ":" + PORT + file;
            String h = "Host:" + host + "\nX-WS-Device:" + device + "\nX-WS-Launcher:" + LAUNCHER_BUILD + "\n"
                     + (headers == null ? "" : headers);
            if (logged++ < 8) Log.i(TAG, "[net] " + url + " -> " + to + " (Host " + host + ")");
            return new String[]{to, h};
        } catch (Exception e) {
            return null;
        }
    }

    // Unity's own downloads (com.unity3d.player.WWW / UnityWebRequest -- the Pokémon models
    // from /asset/...) can't be pinned from here, so they go through the local relay instead.
    public static String localUrl(String url) {
        try {
            URL u = new URL(url);
            if (!enabled || !ours(u.getHost())) return null;
            String to = "http://127.0.0.1:" + RELAY_PORT + (u.getFile().isEmpty() ? "/" : u.getFile());
            if (logged++ < 16) Log.i(TAG, "[net] www " + url + " -> relay");
            return to;
        } catch (Exception e) {
            return null;
        }
    }

    // Before NiaNet's nativeSetupConnection: pin connections to the server.
    public static void setup(HttpURLConnection c) {
        if (!(c instanceof HttpsURLConnection) || pinned == null) return;
        URL u = c.getURL();
        if (!SERVER.equals(u.getHost()) || u.getPort() != PORT) return;
        HttpsURLConnection s = (HttpsURLConnection) c;
        s.setSSLSocketFactory(pinned);
        s.setHostnameVerifier((name, session) -> true);   // no hostname check
    }
}
