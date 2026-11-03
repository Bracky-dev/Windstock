# Windstock: 0.71

Work on the Pokémon GO **0.71** client (il2cpp metadata v22) against a Windstock server, mainly the newer gym system.

Forked from the main server, so the layout matches the [`server`](../../tree/server) branch.

## What's here

- `server/`: the server with the 0.71 gym code (`gym071.py`, `gm071.py`, `extras071.py`), plus 0.67 raid experiments (`raid067.py`, `raid071.py`).
- `translator/`: the Android translator scripts (agent, APK build, login helper).
- `phone/`: the iOS agent used to poke at the client on a phone.

## Status

Experimental. Raids were scrapped, so the raid files are history only. The 0.71 gym system was tested in the server's own tests but not on a real device.

## Not included

The client, decrypted IPAs, decoding and decryption tools, assets, game-master data, certificates, and keys. Bring your own legally obtained client.

## License

Copyright (C) 2026 Bracky!. Licensed under the [GNU AGPL-3.0](LICENSE). Original Windstock code only, not Niantic material or Pokémon trademarks.
