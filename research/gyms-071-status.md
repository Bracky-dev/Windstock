# 0.71 gyms + models: status (2026-10-19, overnight)

## Working
- 0.71 gym RPCs on the server (`server/gym071.py`): GYM_GET_INFO 156, GYM_DEPLOY 155,
  GYM_START_SESSION 157, GYM_BATTLE_ATTACK 158, GYM_FEED_POKEMON 164. Gym screen shows the
  0.71 defender view (motivation heart, CP now, trainer, time defended, berries).
- Models: `GlobalSettings.max_pokemon_types` (DOWNLOAD_SETTINGS field 10) was unset, so
  `PokemonAssetManager.IsValidPokemonId` (`1 <= id <= MaxPokemonTypes`, libil2cpp 0x138BCE8)
  rejected every species and no bundle was ever requested. Now 151: 0.71 requests the 2016
  `pm####` bundles through GET_DOWNLOAD_URLS, downloads, decrypts and loads them.
- One full gym battle ran (Lapras vs Zubat, START_SESSION + ATTACKs answered).

## Not working yet
1. ~~Magenta models~~ FIXED 2026-10-20: `server/port_bundles071.py` swaps each bundle's
   embedded Unity 5.3 shaders for the same-named 5.5 shaders in 0.71's sharedassets0 and
   writes `server/assets071/` (own keys + asset_digest); 0.70+ clients get that set. Pack
   with the original compression: the LZ4 repack crashed 0.71 (null thread entry,
   libunity+0x38dbd8) on two launches.
2. **Native crashes with the old bundles.** SIGSEGV in `libunity.so+0xb1c92c` (null read)
   when opening Pokémon detail screens, and once a bad delegate target in
   `AssetBundleHandle.<Initialize>m__0` after a bundle request completed.
3. **Later battles don't start.** After the first battle, GO BATTLE runs the intro
   (`GymBattleIntroState.RunIntro`) and ~8 s later `GymBattleState.ExitState` with no
   START_SESSION sent. Party models that are not cached are requested but no download starts
   during the intro. Not confirmed which promise fails: hooking `Niantic.Promise.Error`
   (even read-only) hangs boot - the function is too small for the translator's hook patch.
4. **No icons.** 0.71 wants `pokemon_icon_NNN` bundles; none exist (blank portraits).
5. The old 0.63 battle engine ends a battle after very few actions ("defender beaten" after
   1 action) - needs a look with LOG_VERBOSE=1.

## Next steps
- Port bundles to Unity 5.5: export with AssetStudio/UnityPy, rebuild in a Unity 5.5.x editor
  (needs the editor installed), re-encrypt like the originals (decrypt_bundle.py has the
  scheme), update the digest. Same pipeline can build `pokemon_icon_NNN` from PNGs
  (ZeChrales/PogoAssets has 2D icons).
- Alternatively replace the shader at runtime (agent: swap materials' shader for a 0.71
  shader found with Shader.Find) to fix magenta without rebuilding.
- Find what 0.71's battle intro waits on (hook a larger function than Promise.Error, e.g.
  the `<RunIntro>c__AnonStorey0` lambdas or `GymState.FailedToStartBattle` callers).

## Test setup left in place
- testtrainer: level 5, team Mystic, 6 level-20 Pokémon, 10 Razz (backup of the old save:
  /private/tmp/claude-501/testtrainer.backup.json).
- Server restarted with LOG_VERBOSE=1, log /private/tmp/claude-501/server071v.log.
