# bootComplete methods in il2cpp-dump-063/dump.cs

Gate to get past login to loading screen: `HoloBoot.RunBootSequence` runs its BootSteps; when all
report SUCCEEDED it fires `HoloBoot.BootComplete`, which `BootState.OnBootComplete` handles by setting
`BootState.bootComplete` (0x98); `CheckLoadingComplete` then advances to `loadingSceneName`.

| Class | Member | dump.cs line | RVA |
|---|---|---|---|
| BootState | bool bootComplete (field 0x98) | 249843 | - |
| BootState | EnterState() | ~249860 | 0x316F74 |
| BootState | IEnumerator RunLogin() (+ <RunLogin>c__Iterator0.MoveNext) | ~249863 | 0x31720C / 0x317558 |
| BootState | void OnBootComplete() | 249867 | 0x31743C |
| BootState | void CheckLoadingComplete() | 249870 | 0x317448 |
| BootState | ExitState() | ~249866 | 0x317284 |
| HoloBoot | Action BootComplete (field 0x20) | 249951 | - |
| HoloBoot | add_BootComplete / remove_BootComplete | 249977 / 249980 | 0x317110 / 0x317340 |
| HoloBoot | Start() | ~249994 | 0x317FA4 |
| HoloBoot | IEnumerator RunBootSequence(List<BootStep>) | 250000 | 0x318360 |
| HoloBoot | WaitForLogin(callback) <- login-screen gate | 250023 | 0x318704 |
| HoloBoot | RegisterSidechannels / RegisterRpcSideChannels | ~250005 | 0x31847C / 0x318500 |
| HoloBoot | InitializeRemoteConfigVersions | ~250010 | 0x318578 |
| HoloBoot | InitializeBundleDigest | ~250014 | 0x3185FC |
| HoloBoot | InitializeGameMasterTemplate | ~250018 | 0x318680 |
| HoloBoot | DownloadI18nBundles | ~250027 | 0x318788 |
| HoloBoot | InitializeUpsight / InitializeCrittercism | ~250031 | 0x31880C / 0x318890 |

Server must answer every step's RPC (remote config, asset digest, game master, i18n) with SUCCEEDED.
No Niantic request-signing symbol exists in this 0.63 managed dump; signing lives in native code.
