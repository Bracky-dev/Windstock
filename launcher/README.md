# Windstock Launcher

An iOS app that runs the Pokémon GO 0.35 client inside itself, with the private
server embedded, a mods menu, and notifications. Sideloaded with a free Apple
ID — no jailbreak, no TrollStore, no LiveContainer, no Mac running in the
background while you play.

```
tap Windstock  ->  server starts on 127.0.0.1  ->  2s countdown  ->  the game
```

## What it actually does

**Container.** The game's Mach-O is converted to a dylib and loaded into the
launcher's own process — either imported at runtime (see below) or embedded at
build time. Before any of that, `main()` repoints
`HOME` / `CFFIXED_USER_HOME` / `TMPDIR` at `Documents/Containers/<profile>`, so
the game's saves, caches and preferences land in a container the launcher owns
and can wipe or switch per profile. `NSBundle.mainBundle` is swizzled onto the
guest's resource bundle, `UIApplicationMain` is intercepted in the guest image
only (it cannot be called twice in one process), and the guest's window is
adopted onto the launcher's scene.

**Server.** CPython 3.13 is linked in and runs `server.py` — the same server
the project maintains, not a port of it — on a background thread bound to
`127.0.0.1`. `ws_boot.py` bends the parts that assumed a desktop: the data
directory moves into the app container, and the `HTTPServer` main() builds
locally is captured so Start/Stop can work.

**Networking.** The client dials `https://pgorelease.nianticlabs.com:443`, which
on a phone with no DNS profile goes nowhere and which an unprivileged app cannot
bind anyway. `WSNetRedirect` rebinds `getaddrinfo`, `getaddrinfo_async_start`,
`DNSServiceGetAddrInfo` and `connect` process-wide: matching hostnames resolve
to loopback, and loopback connections to 443 are rewritten to the port the
server really has. Switch the server to "On my Mac" and every hook stands down,
so your existing DNS/Tailscale setup behaves exactly as before.

**Runtime import.** The launcher unpacks an IPA, converts its executable to a
loadable dylib and re-signs it on device, the way LiveContainer does. That last
step is the whole difficulty: iOS will not dlopen a Mach-O whose team differs
from the process loading it, so the guest has to be signed with the same
certificate as the launcher. Export that as a .p12 from AltStore or SideStore
and import it in Settings.

The signer is written against Security.framework rather than a vendored
OpenSSL: `SecPKCS12Import` reads the identity, `SecKeyCreateSignature` does the
RSA, and the PKCS#7 SignedData is built by hand in `Signing/` because
CMSEncoder is macOS-only and the OpenSSL inside CPython's `_ssl` is compiled
without CMS. The zip reader is hand-rolled for the same reason — iOS has no
unzip — on top of the Compression framework.

**Mods.** The menu writes `windstock-mods.json` into the guest container. The
tweak reads it once in its constructor and gates each feature on it. Features
that are `#define`d to 0 in the tweak are shown as compiled out rather than
given a switch that does nothing.

**Notifications.** Local, not push — a free provisioning profile has no
`aps-environment`, and none is needed when the server is in the same process.
The launcher watches the server's own `lures.json` and `save.json` and posts
when a lure is about to run out or an egg has finished its distance, plus the
server's own start/stop/failure.

## Building

```bash
tools/fetch_python.sh                    # CPython 3.13 for iOS, once
tools/stage_python.sh                    # stdlib + 53 extension frameworks
tools/stage_server.sh --with-world       # the server, assets_ios, seed data
# optional: bake a game in, instead of importing one on the phone
tools/embed_guest.sh ../RELEASE/pokemon-go-0.35-windstock.ipa \
                     ../work/mods/windstock-v86.dylib
tools/make_ipa.sh                        # -> build/WindstockLauncher.ipa
```

Then sideload `build/WindstockLauncher.ipa` with Sideloadly or AltStore.

Drop `--with-world` from `stage_server.sh` to leave out `osm_forts.json` and
`osm_biomes.json` (~200 MB). The server still runs; you place your own stops and
gyms in the World Manager instead of getting real ones.

`python3 tools/gen_xcodeproj.py` regenerates the project after adding a source
file. The project is generated rather than committed so it stays in step with
the staging scripts.

### Running it in the simulator

The launcher UI and the embedded server both work in the simulator. The game
does not — it is an arm64 iOS binary — and `stage_payload.sh` skips it for
simulator builds, so the Play button is disabled and everything else is live.

## After installing

Two things the app cannot do for itself:

1. **Trust the server's CA.** The client talks TLS to a certificate your phone
   has never seen. Install `server/certs/ca.crt` as a profile, then enable it in
   Settings › General › About › Certificate Trust Settings.
2. **Allow notifications** when the launcher asks.

## Layout

```
WindstockLauncher/
  Support/main.m            container bootstrap, before UIApplicationMain
  Container/                the loader: paths, hooks, guest handover, log
    WSContainer.{h,m}       HOME redirect; runs first, and has to
    WSPaths.{h,m}           the real sandbox home, remembered
    WSGuestLoader.{h,m}     dlopen the game, intercept UIApplicationMain
    WSNetRedirect.{h,m}     hostname + port redirect to the local server
    fishhook.{c,h}          symbol rebinding (BSD, Facebook)
  Server/
    WSPythonServer.{h,m}    embedded CPython lifecycle
    ws_boot.py              makes server.py work inside an app
  Signing/                  on-device re-signing, so IPAs can be imported
    DER.swift               minimal ASN.1 writer
    CMS.swift               the PKCS#7 in the signature's CMS slot
    MachOSigner.swift       CodeDirectory + SuperBlob + __LINKEDIT resize
    MachOPatcher.swift      thin to arm64, exec -> dylib
    CertificateInfo.swift   team ID and expiry, parsed from the certificate
    SigningIdentity.swift   .p12 import, kept in the keychain
    Zip.swift               IPA unpacking on the Compression framework
    AppLibrary.swift        import pipeline and the installed-games list
  App/                      SwiftUI: Play, Mods, Server, Settings
tools/                      fetch / stage / embed / package
Staging/                    build output, not source (gitignore it)
Vendor/Python.xcframework   downloaded by fetch_python.sh
```

The tweak itself stays where it lives: `work/mods/ios-tweak-035/`. The launcher
adds `WSConfig.inc.mm` there (the runtime mods config) and gates each feature on
it; `Tweak.mm.pre-launcher.bak` is the version from before that change.

## Things worth knowing

* **Free certificates expire after 7 days.** Re-sideloading replaces the app but
  keeps `Documents/`, so saves, settings and imported games survive. The games
  are still signed by the *old* certificate though: import the new .p12 and hit
  "Sign again" on each one.
* **Signing is verified, loading is not.** The signature the launcher produces
  is accepted by Apple's own `codesign` ("valid on disk", "satisfies its
  Designated Requirement") and tampering is detected — checked against a real
  IPA on the Mac. Whether iOS then dlopens the guest is a thing only a device
  can answer.
* **The IPA is ~270 MB** without the world data, ~470 MB with it.
* **Profiles switch on the next cold start**, not immediately — the container is
  chosen in `main()`, before the app's first line of Swift runs.
* **Safe mode:** create `Documents/Windstock/safe-mode` and the bootstrap leaves
  the environment alone, which is the way back in if a container redirect ever
  wedges the launcher.
