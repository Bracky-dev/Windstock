# 0.67 jitless — WSTweak only (no JIT, no frida, no tunnel)

This is the complete non-JIT setup. It works every cold launch with no debugger,
no tunnel, no `grant_jit.sh`. WSTweak does redirect + trust + pin-override purely
with fishhook and ObjC `class_replaceMethod` — none of which needs RWX/JIT.

Why this works (verified statically 2026-10-31 against the 0.67 arm64 binary):
- 0.67's RPC TLS trust decision is `NIATrustedCertificatesAuthenticator
  URLSession:didReceiveChallenge:completionHandler:` (IMP 0x1021cf1c4). Its ENTIRE
  cert-pinning routine is inside that one method (SecTrustGetCertificateCount,
  SecTrustEvaluate, SecCertificateCopyData, SecTrustGetCertificateAtIndex).
- WSTweak REPLACES that whole method with "accept the server trust", so all pinning
  is bypassed. (PGPTrustedCertificatesAuthenticator, same selector, also replaced.)
- Server cipher fix (netbase.py) lets the handshake complete; SSO is already plain http.

## Install in LiveContainer (0.67 guest)
1. Import the http-patched IPA: `ipa067/pogo-0.67.2-http.ipa`.
2. App settings -> Tweaks: add **WSTweak.dylib** (this folder). That is the ONLY tweak.
3. **Remove** any frida files from this app's Tweaks if present
   (`FridaGadget.dylib`, `FridaGadget.config`, `agent.compiled.js`) — they would make
   the guest want JIT. Jitless = WSTweak alone.

## Network
- `192.168.111.10` up, 0.71 server running (binds 443/80/53).
- Phone on the same LAN. Point the phone's Wi-Fi DNS at **192.168.111.10** (the server
  answers :53). NSURLSession uses its own resolver, so manual DNS is the reliable
  redirect for the RPC; WSTweak's getaddrinfo hooks cover the rest.

## Expect
- server .10 log: SSO hop -> TLS `ECDHE-RSA-AES128-GCM-SHA256` -> RPCs -> map loads.
- device console: `[WSTweak] installed ...`, then `[WSTweak] pin: ... accepting <host>`.

## If RPC still refused after a clean handshake
Narrow remaining suspects (all checkable on-device):
- No `[WSTweak] pin: ... accepting` line = the override didn't land / class not found.
- Handshake ok but connection resets right after = something other than this authenticator
  is validating. Re-dump delegates; the only RPC trust class found was NIATrusted...
- Last resort (needs on-device testing, do NOT ship blind): static pin-patch of IMP
  0x1021cf1c4 — force its completionHandler to UseCredential. Offsets recorded in
  ios073/RESUME.md.
