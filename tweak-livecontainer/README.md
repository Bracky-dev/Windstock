# WSTweak: LiveContainer tweaks for 0.67

> Only 0.67 is supported. 0.73 is not.

Tweak dylibs that let the stock 0.67 iOS client talk to a Windstock 0.71 server from inside [LiveContainer](https://github.com/khanhduytran0/LiveContainer), with no Windstock launcher, no jailbreak, and (for the no-JIT setup) no debugger.

| Dylib | What it does |
|---|---|
| `WSTweak.dylib` | Redirects Niantic, Pokémon and Zendesk hostnames to your server, and makes the client accept the server's private CA |
| `WSLog.dylib` | Logs what the client is doing, for debugging |
| `WSShop.dylib` | Shop experiments |

Prebuilt dylibs are on the repo's [Releases](../../../releases). Source is here; `build.sh` builds `WSTweak.dylib`, `build_shop.sh` and `build_log.sh` build the others (Xcode command line tools needed).

## Install

1. Get your own legally obtained 0.67 IPA and patch its login to plain HTTP (see `server-063` for the SSO patch script approach). The IPA is not provided.
2. Import the patched IPA into LiveContainer.
3. In LiveContainer, open the app's settings, choose **Tweaks**, and add `WSTweak.dylib`. Add **only** this one (no Frida files, so nothing asks for JIT).
4. Run the 0.71 server (`server-071` branch, `python3 run.py`) on a machine on the same network. It must be reachable on ports 443 and 80.
5. Open the game. In the server log you should see the SSO hop, then a TLS handshake, then RPCs. On the device, log lines are tagged `[WSTweak]`.

## Pointing it at your server

The prebuilt dylibs have `192.168.111.10` baked in, which is a LAN address from the author's setup. Override it without rebuilding:

- put a one-line IPv4 address in `ws_server.txt` inside the game's Documents folder, or
- set the `WS_SERVER` environment variable.

Or build your own: `./build.sh 192.168.1.50`.

You may also need to set the phone's Wi-Fi DNS to the server's address, because the app's network stack can use its own resolver. See `README-067-jitless.md`.

## Troubleshooting

- No `[WSTweak] installed` line: LiveContainer did not load the tweak. Check it is assigned to this app.
- `[WSTweak] resolve ...` but nothing reaches the server: wrong IP, firewall, or a different network.
- Clean handshake but the RPC is still refused: the client may pin a key outside the hook. This is the open problem; see the notes on this branch.

## Status

Experimental and not confirmed on every device. Not affiliated with LiveContainer.
