# Windstock

Windstock is a Pokémon GO private server and a set of launchers that let you play the game the way it was in 2016. No Niantic account, no ban risk, no internet requirement beyond reaching the server. You log in, you get a live map at your real location, and you catch, spin stops, hatch eggs, and fight at gyms.

I built this by reverse-engineering the old client (0.29 and 0.35, with work on 0.63, 0.67 and 0.71) and writing the server from scratch. It's a hobby project that got bigger than planned, and it now has an online server, a website, iOS and Android launchers, and a few mods on top.

> **All source code in this repo is original Windstock code.** The one thing it doesn't cover is the prebuilt **Windstock 64** APK on [Releases](../../releases), which bundles [Chucny's Translator](https://github.com/Chucny/translator) (AGPL-3.0, used with his permission) as a separate component. The credit and our patch to it are on the [`translator64`](../../tree/translator64) branch.

> **This repo contains none of Niantic's code, assets, or data.** You bring your own legally obtained client. Windstock is not affiliated with or endorsed by Niantic, Nintendo, or The Pokémon Company.

## How the repo is laid out

Each build lives on its own branch, and each branch is self-contained with its own README. `main` is just this overview, the [install guide](INSTALL.md), and the license. Prebuilt launchers and tweaks are on [Releases](../../releases).

| Branch | What's in it | Status |
|---|---|---|
| [`server`](../../tree/server) | The Python game server (protocol, catching, stops, gyms, trading, friends, events, anti-cheat, World Manager) | Running live |
| [`ios-launcher`](../../tree/ios-launcher) | The iOS app (container + embedded Python server) and the 0.35 tweak (Theos). Launcher builds are on Releases | Working, ongoing |
| [`android-launcher`](../../tree/android-launcher) | The Android port of the launcher, including the 64-bit "Windstock 64" flavour | Working, ongoing |
| [`translator64`](../../tree/translator64) | Our 32-bit to 64-bit ARM translator work for modern Android phones | Experimental |
| [`server-063`](../../tree/server-063) | The 0.63 server fork, login patch scripts, iOS launcher fork, Android translator scripts and research notes | Early, experimental |
| [`server-071`](../../tree/server-071) | The 0.71 server with the newer gym system, Android translator scripts, phone agent, and the WSTweak LiveContainer tweak source (0.67) | Early, experimental |
| [`website`](../../tree/website) | The windstock.org site: profiles, leaderboard, events, map | Running live |

## What you get

- **Offline or online.** Run the server on your own machine, or join the public one from the launcher.
- **The real 2016 feel.** Catching, throw scoring, PokéStops, eggs and incubators, evolve and power up, medals, gyms with type-matchup damage.
- **Extras I added.** Shinies, Halloween events, weather tinting, friends and Pokémon trading, nests built from real park outlines, leaderboards, and an anti-cheat speed lock.
- **Real maps.** World data is built from OpenStreetMap, so stops and gyms sit where they should.

## Getting started

**Just want to play?** Follow [INSTALL.md](INSTALL.md) for iOS, Android and self-hosting. The rest of this section is for building from source.

Pick the branch for what you want to build or run, and follow its README.

```bash
git clone https://github.com/Bracky-dev/Windstock.git
cd Windstock
git checkout server   # or ios-launcher, android-launcher, ...
```

Heads up on a few things I'd rather be upfront about:

- Some features are untested on a physical phone. Where that's the case, the branch README says so.
- The branches hold source only. Game binaries, certificates and signing keys are deliberately **not** in the repo. Prebuilt launchers and tweaks live on [Releases](../../releases).
- The prebuilt Windstock 64 APK bundles Chucny's Translator (AGPL-3.0), used with permission. His name and credits stay on every copy. The source in this repo is original. See the `translator64` branch.

## Contributing

Bug reports and pull requests are welcome. Open an issue first if it's a big change, so we don't end up building the same thing twice.

## Legal

This is an independent, educational interoperability project for personal use with a client you already own. Don't redistribute Niantic's app or assets. "Pokémon" and "Pokémon GO" are trademarks of their respective owners.

## Credits

- [AeonLucid/POGOProtos](https://github.com/AeonLucid/POGOProtos) for protocol definitions
- [rastapasta/pokemon-go-mitm](https://github.com/rastapasta/pokemon-go-mitm) for map-object layout reference
- [Chucny](https://github.com/Chucny/translator), author of the Translator that makes Windstock 64 possible (AGPL-3.0), and ZailoxTT, whose runtime it builds on
- Android Open Source Project (guest sysroot, Apache-2.0) and the Dynarmic contributors (0BSD)
- OpenStreetMap contributors for the map data

## License

Copyright (C) 2026 Bracky!. Licensed under the [GNU AGPL-3.0](LICENSE). This covers original Windstock code only, not Niantic material or Pokémon trademarks.
