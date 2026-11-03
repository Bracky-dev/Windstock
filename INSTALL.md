# Installing Windstock

This guide covers every way to run Windstock. Pick the path that matches your phone, then follow it top to bottom. If something goes wrong, jump to [Troubleshooting](#troubleshooting).

## Which path is for me?

| I have... | Use | Section |
|---|---|---|
| An iPhone or iPad | The iOS launcher (sideloaded) | [iOS](#ios) |
| An Android phone that still runs 32-bit apps | The Android launcher | [Android](#android) |
| A newer 64-bit-only Android phone | Windstock 64 | [Android, 64-bit](#android-64-bit-phones) |
| A PC and I want to host my own server | The Python server | [Self-hosting](#self-hosting-the-server) |
| I want to build everything from source | Per-branch build steps | [Building from source](#building-from-source) |

## Before you start

- **The game client is not included.** Windstock never ships Niantic's app. The launchers handle the game for you, but if you build from source you must supply your own legally obtained client.
- **You do not need a Niantic, Google or PTC account.** Log in with an email on the Windstock site or any username on a local server.
- **You do not type a server address.** The launchers have the public Windstock server built in. Local mode uses `127.0.0.1` automatically.
- **Back up first** if you already have a different Windstock install. Profiles live inside the app, and deleting the app deletes them.

## Where to get the files

| File | Where |
|---|---|
| iOS and Android launcher builds | The downloads page on [windstock.org](https://windstock.org) |
| Tweak (`windstock-v210.dylib`) | This repo's [Releases](../../releases) |
| Source | The branches of this repo |

---

## iOS

The iOS launcher is a normal app you sideload with a free Apple ID. No jailbreak, no TrollStore, and no Mac needs to stay on while you play.

**You need:** an iPhone or iPad, a computer with one of the sideloading tools below, and a free Apple ID.

### 1. Sideload the launcher

Use whichever tool you prefer.

- **SideStore** (no computer after setup): the project publishes a SideStore source on the website. Add it in SideStore, then install Windstock Launcher from it.
- **AltStore:** open AltServer on your computer, then in the AltStore app pick **My Apps > +** and choose `WindstockLauncher.ipa`.
- **Sideloadly:** drag `WindstockLauncher.ipa` into the window, sign in with your Apple ID, press **Start**.

Free Apple IDs expire apps after **7 days**. Re-sign (refresh) before then or the app stops opening. Your data stays.

### 2. Trust the developer

1. Open **Settings > General > VPN & Device Management**.
2. Tap your Apple ID under *Developer App*.
3. Tap **Trust**.

On iOS 16 and later you also need **Developer Mode**: **Settings > Privacy & Security > Developer Mode**, switch it on, and restart when asked.

### 3. First launch

1. Open **Windstock**. Allow notifications when asked (they warn you when a lure is about to end or an egg has hatched).
2. Pick or create a profile on the **Play** tab.
3. Choose where the server runs:
   - **On this phone** (default): the server starts inside the app. This works offline.
   - **Windstock Online**: joins the public server. Uses your Windstock account.
4. Press **Play**. After a two-second countdown the game opens.

### 4. Trust the certificate (local server only)

The game uses TLS, and your phone has never seen the server's certificate. This is only needed if you run the server on your own computer rather than the phone or the public server.

1. Install `server/certs/ca.crt` on the phone (AirDrop or email it, then open it).
2. **Settings > General > VPN & Device Management**, install the downloaded profile.
3. **Settings > General > About > Certificate Trust Settings**, turn the new certificate on.

### 5. Optional: the tweak

The tweak (`windstock-v210.dylib`) adds the mods the launcher menu controls: shinies, weather tint, night look, quick catch and more. Launcher builds that already embed a tweak do not need this step. To use a newer one, download it from [Releases](../../releases) and import it under **Settings > Custom dylibs** in the launcher.

> Importing a custom dylib needs the launcher's signing certificate: export your `.p12` from AltStore or SideStore and import it in **Settings** first. This path has not been tested on every device, so if the import fails, send the report from **Report a problem**.

---

## Android

**Requirements**

- Android **7.0 or newer**.
- A phone that can run **32-bit ARM apps**. Pokémon GO 0.35 is 32-bit only. If your phone dropped 32-bit support, use [Windstock 64](#android-64-bit-phones) instead. The launcher tells you when your phone is not compatible.
- About **1.5 GB** free (the launcher with world data is large).

### 1. Allow installs from your browser or file manager

**Settings > Apps > Special access > Install unknown apps**, then enable it for the app you downloaded the file with. The exact path varies by manufacturer.

### 2. Install the launcher

1. Download `WindstockLauncher.apk` from the website.
2. Open it and tap **Install**. If Play Protect warns you, choose **Install anyway**.
3. Open **Windstock**.

### 3. Install the game

The game is a separate app (`com.windstock.pokemongo`, named "Windstock GO"). It installs alongside the Play Store's Pokémon GO and does not replace it.

1. Go to the **Play** tab, then **Game**.
2. Tap **Install**. Android shows its normal install prompt. Accept it.

### 4. Play

1. Press **Play**. The server starts on the phone, then the game opens after a short countdown.
2. Sign in with your Windstock email, or pick a local profile.

You do not need to install any certificate when the server runs on the phone. The launcher hands its certificate to the game itself.

### Server on a PC instead

Run the server on your computer, then in the launcher open **Settings > Server certificate** and install that server's CA as a user CA. Android's own certificate screen will take you through it.

### Android 64-bit phones

Some newer phones cannot run 32-bit apps at all. **Windstock 64** is a separate build that runs the 32-bit game through a translator (Chucny's Translator, AGPL-3.0, used with permission).

1. Download the Windstock 64 APK from the website.
2. Install it the same way as the launcher above.
3. Open it. The launcher and the game are one app, so there is no separate game step.

Windstock 64 is newer and less tested. Expect rough edges, and report them from the app.

---

## Self-hosting the server

Use this if you want your own private world, or you want to host friends.

**You need:** Python 3.11 or newer on a PC, Mac or Linux box.

```bash
git clone https://github.com/Bracky-dev/Windstock.git
cd Windstock
git checkout server
python3 run.py
```

1. The launcher prints the IP the phone should use, for example `Point the phone's Wi-Fi DNS at: 192.168.1.20`.
2. Open the World Manager at `http://127.0.0.1:8080` to place PokéStops and gyms, download real points of interest, and run events.
3. Generate the certificates once with `python3 gen_certs.py`. The files land in `certs/`.
4. Install `certs/ca.crt` on each phone, as described in the [iOS](#4-trust-the-certificate-local-server-only) or [Android](#server-on-a-pc-instead) sections.

### Pointing a phone at your server (classic mode)

If you are using the stock patched client rather than the launcher:

1. **Wi-Fi > your network > Static IP**.
2. Set **DNS 1** to the IP the server printed.
3. Leave **DNS 2 empty**. A real second DNS server lets the phone bypass yours, and login fails.
4. Open the game and log in with any username.

### Playing away from home

Run the server on a host with a public IP, open **udp/53** and **tcp/443**, and point the phone's DNS there. A small VPN to the server is safer than exposing port 53, because a public DNS forwarder can be abused. See `VPN.md` on the `server` branch.

### Firewall on Windows

If the phone cannot reach the server, run these in an Administrator prompt:

```
netsh advfirewall firewall add rule name="pogo-dns"  dir=in action=allow protocol=UDP localport=53
netsh advfirewall firewall add rule name="pogo-https" dir=in action=allow protocol=TCP localport=443
```

---

## Building from source

| Build | Branch | Start with |
|---|---|---|
| Server | `server` | `python3 run.py` |
| iOS launcher | `ios-launcher` | `ios-launcher/README.md` |
| Android launcher | `android-launcher` | `android-launcher/README.md` |
| Windstock 64 | `translator64` + `android-launcher` | `make_w64_apk.sh` |
| 0.63 and 0.71 | `server-063`, `server-071` | each branch's README |

**iOS** needs Xcode, CPython 3.13 for iOS (`tools/fetch_python.sh`), and Theos for the tweak. Run `tools/make_ipa.sh` to get the IPA.

**Android** needs JDK 17, the Android SDK and Node. Run `tools/make_apk.sh`.

Keys, game binaries and assets are deliberately not in the repo, so you supply those yourself.

---

## Troubleshooting

**The app stops opening after a week (iOS).** Free Apple IDs expire apps every 7 days. Refresh it in AltStore or SideStore, or reinstall with Sideloadly.

**"Untrusted developer" (iOS).** Trust your Apple ID in **VPN & Device Management**, and turn on Developer Mode on iOS 16 and later.

**Login fails on a local server.** Check that DNS 2 is empty, the certificate is installed **and trusted**, and the phone can reach the server's IP and ports.

**The game says it cannot connect.** If you are on a local server, the server may not be running. If you are online, check [windstock.org/status](https://windstock.org/status).

**The map is empty or I do not move.** The old client only updates the map when you walk. Move a few steps. The launcher also keeps a heartbeat going while you stand still.

**"This phone cannot run 32-bit apps" (Android).** Use Windstock 64.

**Play Protect blocks the install (Android).** Choose **Install anyway**. The APK is signed by the project, not by the Play Store.

**Crashes or silent exits.** In the launcher, use **Report a problem**. It attaches the logs. Crashes sometimes leave no crash file, so the report is the best way to catch them.

Still stuck? Open an issue with your device model, OS version, launcher build number and what you tried.
