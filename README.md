# Windstock: 0.63

Early work on getting the Pokémon GO **0.63.4** client (Unity 5.5.1, il2cpp metadata v22, still the old gyms, Gen 2 era) talking to a Windstock server.

This is a fork of the main server, so the layout matches the [`server`](../../tree/server) branch.

## What's here

- `server/`: the server, forked from the 0.29/0.35 one, with the 0.71 gym and game-master work pulled in.
- `build_063_http.py`, `patch_sso_http.py`: patch the client's six SSO URLs so it logs in over plain HTTP against a Windstock server.
- `launcher/`: the iOS launcher fork for 0.63.
- `translator/`: the Android translator scripts (agent, APK build, login helper).
- `research/`: my notes on boot, RPC stalls and the translator heap fix.

## Status

Experimental. Login patching works. Importing the patched app through the launcher was rejected by on-device signing, and the protocol port from 0.29 is not finished. Treat it as a working notebook, not a release.

## Not included

The client itself, decoded dumps, assets, game-master data, certificates, and keys. Bring your own legally obtained client.

## License

Copyright (C) 2026 Bracky!. Licensed under the [GNU AGPL-3.0](LICENSE). Original Windstock code only, not Niantic material or Pokémon trademarks.
