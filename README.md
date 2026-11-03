# Windstock Launcher for Android

The Android port of `ios-launcher/`: one app that runs the Windstock server on the
phone, installs and starts Pokémon GO 0.35, and carries the mods menu, the
server-settings editor, the Game Editor, World Data and notifications.

```
tap Windstock  ->  server starts on 127.0.0.1  ->  2 s countdown  ->  the game
```

## How it maps onto the iOS app

| iOS launcher | Android launcher |
|---|---|
| Game loaded **into** the launcher's process (exec→dylib, re-signing) | Game is its own app: a patched 0.35 APK shipped in the launcher's assets and installed through `PackageInstaller` (Play tab › Game) |
| `WSNetRedirect` + `WSURLProtocol` hook DNS/connect in-process | The same idea inside the game: `work/mods/android-035/lib/redirect.js` hooks bionic's resolvers and `connect()` (443→8443, 80→8080), loaded by a Frida gadget in the game APK |
| Tweak reads `windstock-mods.json` from the guest container | Agent asks `ConfigProvider` (`content://com.windstock.launcher.config`) as the game loads — mods, server address, ports |
| CPython 3.13 linked in, `WSPythonServer.m` | CPython 3.11 via Chaquopy, `PythonServer.kt`; the **same** `ws_boot.py` |
| Server runs from the read-only bundle | Unpacked once per install from assets (`ServerAssets.kt`, `MANIFEST.txt`) |
| iOS reclaims listening sockets → `revive()` | Kept: `revive()` on resume; plus a foreground service so Android doesn't kill the server while the game has the screen |
| Share the CA, trust it in Settings | Save it to Downloads, install as a CA in Settings — and the app **checks** the user CA store (`CertHelper.kt`) |
| SwiftUI tabs: Play, Mods, Server, Tutorial, Settings | Compose, same tabs, same sections |
| OSMImport.swift (PBF → pack on the phone) | `world/OSMImport.kt`, output verified row-for-row identical to the Swift converter on the Luxembourg extract (15,219 forts) |

Dropped because they only exist on iOS: signing certificates / IPA import,
per-profile containers, the GPS joystick dylib, "Back to Launcher" (on Android you
just switch apps). Mods the Android agent doesn't implement yet (sound packs, night
music, mass transfer, appraisal IVs) are left out of the Mods tab rather than shown
as dead switches.

The game opened straight from the home screen still works: the agent's config
request starts the launcher process and the server (measured: 1.3 s cold).

## Building

Toolchain (once): JDK 17 + Android SDK in `~/android-toolchain` (`source
~/android-toolchain/env.sh`), node for the agent.

```bash
tools/make_apk.sh            # agent + game APK + server (with world data) + launcher
```

or step by step:

```bash
(cd ../work/mods/android-035 && npm test && npm run build)
tools/build_game_apk.sh      # RELEASE/pokemon-go-0.35-windstock.apk + gadget + agent
tools/stage_server.sh --with-world
./gradlew assembleRelease
```

Output: `build/WindstockLauncher.apk` (~420 MB with the world data; `--no-world`
leaves out the US pack). Signed with `tools/windstock-launcher.jks` so every build
installs over the last; the game APK is signed with `work/tools/pogo.keystore`, the
key the released Windstock APKs carry, so it updates an existing install.

## Requirements on the phone

* Android 7.0+ for the launcher (32-bit ARM, arm64; x86_64 for emulators). CPython is
  3.11 on Android because Chaquopy has no 32-bit build of anything newer.
* **32-bit ARM support for the game.** Pokémon GO 0.35 is armeabi-v7a only. Phones
  that dropped 32-bit apps (and every emulator on Apple Silicon) cannot install it;
  the launcher says so instead of failing silently.
* Nothing for the certificate when the server runs on the phone: the launcher hands its CA
  to the agent (`net.ca`), and `lib/trust.js` adds it to the game's own trust managers.
  For a server on a PC, install that server's CA as a user CA (Settings › Server certificate).
* The game installs as `com.windstock.pokemongo` ("Windstock GO"), next to the Play Store's
  Pokémon GO. frida-gadget is **16.7.19**: 17.x crashes at startup on a Galaxy S9 (Android 10).

## Verified so far (Android 11 arm64 emulator)

Launcher UI on every tab; server unpack (769 files, 293 MB, ~3 s) and start
(~0.5 s); TLS 8443 / plain 8080 / editor 8081 listening; the Game Editor web view;
the config handshake, including waking a force-stopped launcher; the login test
(`work/server/test_login.py`) and signed boot batch (`2017/test_boot_071.py`) passing
against the phone's server over `adb forward`; the install flow up to the system
prompt and its 32-bit error. **Not verified:** the game itself with the agent on a
real 32-bit-capable phone — the emulator here cannot run ARM32 code.
