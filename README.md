# translator64 — Windstock's own 32-bit-on-64-bit ARM translator

Runs armeabi-v7a native libraries on 64-bit-only ARM Android by JIT-translating
the 32-bit code with [Dynarmic](https://github.com/merryhime/dynarmic) (0BSD).
Built from scratch for Windstock because Chucny's ZettaBridge fork is under a
copyright licence we can't use.

**Why:** new phones ship 64-bit-only, and 0.35 PoGO is 32-bit. This removes the
32-bit wall without his code. See memory `partner-064bit-029`, `android-launcher`.

## Phase 1 status — PoC PASSES (2026-10-15, arm64 emulator)

`libmain.so`'s `JNI_OnLoad` runs under Dynarmic and returns the genuine
`JNI_VERSION_1_6` (0x00010006). Observed guest sequence:

1. `JavaVM->GetEnv` → we hand back our synthetic `JNIEnv`
2. `JNIEnv->FindClass` (env slot 6)
3. `JNIEnv->RegisterNatives` (env slot 215, nMethods = 2)
4. returns `0x00010006`

`libil2cpp.so` (22 MB) also maps + relocates cleanly — 232,646 `R_ARM_RELATIVE`
plus 2,002 jump slots applied — proving the loader scales to the real image.

## Phase 2 status — il2cpp_init COMPLETES (2026-10-15)

`./wst64 . --il2cpp-init --data <dir>` loads `libil2cpp.so`, runs all 34
`init_array` constructors, sets the data dir, and calls `il2cpp_init`, which now
**returns a live `Il2CppDomain*`** (`PASS: il2cpp_init -> 0x3789120`). The full
il2cpp runtime stands up:

- **Boehm GC bring-up** (embedded in il2cpp): heap `mmap`, signal handlers
  (`sigaction`), `sem_init`, stack-bounds probing (`pthread_getattr_np` +
  `pthread_attr_getstack`), TLS keys, `setjmp`-based register flush, `memalign`
  allocations.
- **Metadata + type system**: `global-metadata.dat` loads, assemblies register,
  classes initialise, and the BCL static constructors run (`System.Threading`,
  `System.Globalization`, `System.Reflection`, … through `ClassInit` →
  `Class::GetCCtor` → the cctor's compiled method pointer).

Key fixes that got us here (all in `src/`):
- `wall_clock_cntpct = true` — guest timer-calibration loops that spin on the ARM
  generic counter now terminate.
- **Exclusive monitor + one processor id per guest thread** (`cpu.cpp`) — the
  arm64 backend routes `LDREX`/`STREX` through `global_monitor`, so the GC's
  test-and-set spinlocks work. (Our `MemoryWriteExclusive*` CAS is a fallback.)
- A broad libc surface (`sys.cpp`): stdio over host `FILE*`, raw file/`mmap`/dir
  syscalls, real `pthread` mutex/cond/sem/TLS/threads, host `libm`, a
  guest-varargs `printf`/`snprintf`/`vsnprintf` family, `setjmp`/`longjmp`.

### The metadata-matching gotcha (what the final crash actually was)

The last blocker was **not** a translator bug — it was a *data* mismatch. We were
feeding a `global-metadata.dat` from a *different build* than this `libil2cpp.so`.
il2cpp stores each method's compiled code in `Il2CppCodeRegistration.methodPointers[i]`
and the method's metadata (name, flags, class) in `methodDefinition[i]` — indexed
by the **same** `i`. The two tables are only aligned when the `.dat` and the `.so`
come from the *same* IL2CPP conversion run. With a mismatched `.dat`,
`System.Threading.Thread::.cctor` resolved its *name* correctly but its
*methodPointer* pointed at an unrelated instance setter (`+0xf03274`), which
dereferenced a null `this` and crashed deep inside the first `ClassInit`.

**Fix:** use the `global-metadata.dat` that ships *inside the same APK* as the
`libil2cpp.so` you load. For this image (md5 `396296d6…`) that is the 6,843,455-byte
(v21) metadata from `windstock-android-game.apk` /
`assets/bin/Data/Managed/Metadata/global-metadata.dat` — **not** the
`2017/extract` (v22) copy, which is a later game build. A SIGSEGV reporter
(`install_fault_reporter`) prints the faulting registers, a frame-pointer
backtrace, and any class/method names reachable from the registers, which is what
pinned the crash to `Thread::.cctor`.

## Phase 3 status — libunity bring-up + EGL/GLES bridge PASS (2026-10-15)

`./wst64 . --unity-init` loads `libmain.so`, then `libunity.so` (15 MB),
resolving libunity's **inter-module imports against libmain** (all 29 of them —
`_Unwind_*`, `__aeabi_*divmod/llsl/llsr`, `ANativeActivity_*`, `_MotionEvent_*`),
runs all **254 `init_array` constructors**, then runs libunity's own
**`JNI_OnLoad`, which returns `JNI_VERSION_1_6` (0x00010006)**. Observed:

- init_array executes real guest code — **1245 import calls** in the run: locale
  ctype setup (`btowc`/`wctob`/`wctype`), `pthread_mutex*`/`pthread_once` guards,
  158 `__cxa_atexit` registrations, `malloc`/`strcpy`/`strlen`, `__google_*`
  blocking-region markers.
- `JNI_OnLoad` does `FindClass` (env slot 6) + `RegisterNatives` (env slot 215)
  twice — registering the UnityPlayer natives (22 then 2 methods) — and returns
  `0x00010006`.

libunity imports **no `gl*` symbols directly**: it pulls every GLESv2 entrypoint
at runtime through `eglGetProcAddress`. So the bridge (`src/gfx.cpp`) is:

- **EGL** (18 funcs) as real host thunks returning plausible non-null handles and
  success — `eglGetDisplay/Initialize/ChooseConfig/GetConfigAttrib/CreateContext/
  CreateWindowSurface/MakeCurrent/QuerySurface/SwapBuffers/GetProcAddress/…`.
- **GLESv2**: a few getters with sane returns (`glGetString`, `glGetError`,
  `glGetIntegerv`), plus a generic per-name logging stub that every
  `eglGetProcAddress`-fetched entrypoint binds to (so the SVC trace names exactly
  which GL calls Unity makes).
- **libandroid.so** `ANativeWindow_*` (surface geometry = 1080×1920) and benign
  stubs for the input / sensor / looper API.

`gfx_selftest()` drives a representative headless bring-up through the registered
thunks — `eglGetDisplay → eglInitialize (EGL 1.4) → eglChooseConfig →
eglCreateContext → ANativeWindow_fromSurface → eglCreateWindowSurface →
eglMakeCurrent → eglQuerySurface (1080×1920) → eglGetProcAddress("glGetString") →
glGetString(GL_VERSION) = "OpenGL ES 2.0" → eglSwapBuffers` — each call going
guest-stub → SVC → host handler → guest, the exact path Unity's graphics code
takes. No `install_fault_reporter()` output was needed this phase (no crash).

**This is a HEADLESS bridge.** EGL/GLES calls return sane values so bring-up
*progresses*; nothing is drawn. Unity's real render loop only runs the GL calls
when the Java `UnityPlayer` drives registered natives (`nativeRender`, …) against
a real surface, which this headless harness does not stand up. Wiring the fake
`g_surf`/`g_dpy` through to the device's real `libEGL`/`libGLESv2` so frames
actually render is the next step; the seam is isolated to `src/gfx.cpp`.

## Phase 4 status — 64-bit host app + REAL frame on screen (2026-10-15)

The translator now ships as **`libwst64.so`** (arm64) inside our own minimal
Android app **`com.windstock.translator64`** (`android-app/`: a full-screen
`SurfaceView` Activity + `WstBridge` JNI, all ours — modelled on, not copied from,
Unity's `UnityPlayerActivity`). Built with `android-app/make_apk.sh` (javac → d8 →
aapt2 → zip → apksigner, reusing the launcher keystore). Verified on the arm64
`emulator-5554`:

- The whole translator runs **inside the app process**: `il2cpp_init` returns a
  live domain, `libunity` init + `JNI_OnLoad` → `0x00010006`, host ART bound
  (`vm`/`env` from the app).
- **Real host EGL/GLES bridge** (`src/gfx.cpp`, `g_real_egl` path): the guest's
  EGL/GLES calls forward to the device's `libEGL`/`libGLESv2` against the real
  `ANativeWindow` from the SurfaceView. Host handles (64-bit `EGLDisplay`/`Config`/
  `Context`/`Surface`) live in a token table; the guest only sees 32-bit tokens
  (`0xFE0000xx`). Guest pointers (attrib lists) translate via `g_base`.
- **First real frame:** driven entirely as guest calls through the bridge —
  `eglGetDisplay → eglInitialize (1.4) → eglChooseConfig → eglCreateContext →
  eglCreateWindowSurface (real, err EGL_SUCCESS) → eglMakeCurrent → glViewport →
  glClearColor(Windstock blue) → glClear → eglSwapBuffers` — paints the emulator
  screen. `glGetString(GL_VERSION)` = `OpenGL ES 3.1 (ANGLE)` (the real driver),
  `glGetError 0`. This is the translator running 32-bit guest code that drives the
  **real GPU** to a real on-screen frame.
- **Unity's native entry points captured** (our `RegisterNatives` handler logs
  them): `initJni(Context)`, `nativeFile(String)`,
  `nativeRecreateGfxState(int,Surface)`, `nativeResume()`, `nativeRender()`,
  `nativePause/Done/FocusChanged/...` (libunity) and `load/unload` (libmain).

### What Unity's OWN first frame (splash/Niantic logo) still needs (Phase 4b)

Not done — the clear-frame above is *our* GL, not Unity's render yet. The path is
now precisely mapped; each piece is sizeable:

1. **Full ART-JNI bridge.** Replace the synthetic fake-handle JNIEnv (jni.cpp)
   with real routing to the host ART for the calls `initJni` makes — `FindClass`,
   `GetMethodID`, `Call*Method`, strings, arrays, `AssetManager`, `File`/display
   APIs — via a guest↔host handle table (host `jobject`/`jmethodID` are 64-bit, so
   they need tokens like the EGL handles). `RegisterNatives` capture is already in.
2. **Full GL forwarding table.** Unity fetches ~100 GL entrypoints via
   `eglGetProcAddress`; each needs a guest→host trampoline that marshals its exact
   signature (armeabi softfp: all args arrive as 32-bit words; host AAPCS64 needs
   floats in v-registers and pointers translated via `g_base`). Only the
   clear-frame subset is wired today.
3. **Unity's data.** Bundle `assets/bin/Data/**` from the game APK (we ship only
   `Metadata/global-metadata.dat` for il2cpp) and point `nativeFile` at it.
4. **Driving sequence** (our code, mirroring UnityPlayer.java): `initJni(activity)`
   → `nativeFile(apkPath)` → `nativeRecreateGfxState(0, surface)` →
   `nativeResume()` → a render thread calling `nativeRender()` each VSync.

## Phase 4b status — guest→host ART-JNI bridge; Unity init driven deep (2026-10-15)

Built the real guest↔host **ART JNI bridge** (`src/jni_real.cpp`): the guest keeps
calling our synthetic JNIEnv (svc stubs), each slot forwards to this process's real
ART via a **handle table** (host `jobject`/`jclass`/`jmethodID` are 64-bit → guest
sees a 32-bit token `0xCA0000xx`). `Get*MethodID`/`Get*FieldID` record the JNI
signature so `Call*Method` reads the guest's inline varargs and builds a host
`jvalue[]`. `FindClass` routes through the **app ClassLoader** (so Unity's own Java
classes resolve on our native thread) and is exception-safe.

The app now bundles the game's **`classes.dex`** (so `com.unity3d.player.*` exist)
and captures Unity's native entry points via `RegisterNatives`. Driving the real
sequence (`android-app` → `unity_drive` → `unity_start`):

- `il2cpp_init` OK; libmain + libunity `JNI_OnLoad` → `0x00010006`, all through the
  real bridge.
- **`initJni` executes and makes hundreds of real JNI calls** into ART:
  `GetJavaVM`, `NewGlobalRef(UnityPlayer class)`, then dozens of `GetMethodID`
  (`showSoftInput`, `Location_*`, `executeGLThreadJobs`, `getSplashMode`,
  `loadLibrary`, `installPresentationDisplay`, …).

### The architecture finding (why manual C++ driving stops here)

Those `GetMethodID`s resolve on the **context's class**, and they're all methods of
`com.unity3d.player.UnityPlayer` — because real Unity's `initJni(this)` is passed a
**UnityPlayer instance** as the context, not an Activity. We passed our minimal
`MainActivity`, so the methods are missing, a method result is null, and
`GetObjectClass(null)` trips CheckJNI.

So the correct architecture for the splash is **Java-driven, not C++-driven**: the
real `UnityPlayer.java` must run (its constructor calls `initJni(this)` and spins up
the GLSurfaceView + render thread), with the guest natives exposed to real Java by
an **inverse host→guest JNI trampoline** — register real JNI natives on the
UnityPlayer class that marshal host args → guest and `call_guest` the captured guest
fnPtr. Our `RegisterNatives` capture already has `(name, sig, guestFn, classTok)`
for exactly this.

### Remaining to the splash (Phase 4c)

1. **Inverse host→guest JNI bridge**: register real natives on the Java UnityPlayer
   class (from the capture) that marshal host→guest and dispatch into the translator.
2. **Run the real `UnityPlayer.java`**: an Activity that `new`s `UnityPlayer(this)`
   with `System.loadLibrary` redirected to the translator, so Unity's own Java lifecycle
   drives `initJni`/`nativeRecreateGfxState`/`nativeRender`.
3. **Full GL forwarding table** (nativeRecreateGfxState/nativeRender fetch ~100 GL
   entrypoints via `eglGetProcAddress`; each needs per-signature marshalling).
4. **Bundle Unity's `assets/bin/Data/**`** (the matched `windstock-android-game.apk`)
   and point `nativeFile` at it.

## Phase 4c status — Java-driven Unity runs under the translator; reaches nativeRender (2026-10-15)

The real `com.unity3d.player.UnityPlayer` now drives the translated engine. Built
the **inverse host→guest JNI trampoline** (`src/jni_invoke.cpp`): host C stubs
(matching each Unity native's JNI signature) are registered on the real Java
classes via `RegisterNatives` (using the `(name, sig, guestFn, classTok)` capture);
each stub wraps host args → guest (jobjects → tokens) and `call_guest`es the
captured guest fnPtr with our synthetic JNIEnv. So Unity's own Java lifecycle
dispatches straight into the translated native code.

Flow (`android-app` Activity hosts UnityPlayer by reflection; a dummy arm64
`libmain.so` lets `System.loadLibrary("main")` succeed; the game's `classes.dex`
is bundled so `com.unity3d.player.*` resolve; `assets/bin/Data/**` from
`windstock-android-game.apk` is bundled uncompressed so Unity finds its data):

1. Translator boots, guest `JNI_OnLoad`s populate the native capture, inverse
   trampolines registered (**14 host natives** on the real classes).
2. `new UnityPlayer(activity)` → real Java → `NativeLoader.load`, **`initJni`**
   (hundreds of JNI calls into host ART, all resolving now that the context is a
   real UnityPlayer), then the constructor's `nativeInitWWW` etc.
3. Activity lifecycle (`resume`/`windowFocusChanged`) → **`nativeRecreateGfxState(surface)`**
   (real surface) → the engine's **`nativeRender`** loop starts on the **UnityMain**
   thread.

### Blocker (Phase 4d): the GL forwarding table

`nativeRender` #0 aborts with a guest `UndefinedInstruction` — a hardcoded `bl` to
a `udf` trap (an "unreachable" error path) inside the engine's GLES device init.
Cause: Unity fetches ~100 GL entrypoints via `eglGetProcAddress`; only the ~13 we
registered return real values, the rest bind to a stub returning 0, so the engine
can't determine GL capabilities and takes its fatal path. The fix is the full GL
forwarding table: a host trampoline per GL entrypoint that calls the real host
`libGLESv2` with correct per-signature marshalling (armeabi softfp args are 32-bit
words; host AAPCS64 needs floats in v-registers; pointer args translate via
`g_base`). `ExceptionRaised` now dumps the guest regs + fp-chain backtrace, and
`__android_log_print` expands varargs, so engine errors are legible.

## Phase 4d status — THE GAME RUNS on the arm64 emulator (2026-10-15)

32-bit Pokémon GO 0.35 (Windstock build) runs under our translator inside the
64-bit app on emulator-5554: Unity splash → C# startup → **login age gate →
"Sign up with GOOGLE / WINDSTOCK"**, all rendered by real GLES; touch input works
(tapped the year picker and SUBMIT). Screenshots: `shots/p4d-1.png` (splash),
`shots/p4d-login.png` (age gate), `shots/p4d-tap2.png` (sign-up screen).

What it took (all ours):
- `src/gl_fwd.cpp` — full GLES 2.0/3.0 (+ common ext) forwarding table: one
  signature-driven forwarder (softfp words → AAPCS64 x/v regs; pointer vs.
  buffer-offset args; GLsync tokens; shadowed buffer mappings; string arrays).
  Reached via `eglGetProcAddress` and `dlsym(libGLESv2)`.
- JNI: all Call*Method/V/A (+nonvirtual/static), fields, primitive arrays, critical
  regions, direct buffers (shadowed + written back), canonical method/field-ID
  tokens (Unity compares them), signatures learnt from reflection, recycled local
  tokens per native frame, `loadLibrary/findLibrary/System.load` answered for guest
  modules.
- Generic host→guest trampolines (template pool, x/v register families) bound the
  moment the guest calls RegisterNatives, plus implicit binding of exported
  `Java_*` symbols (libNianticLabsPlugin).
- Real `dlopen/dlsym` over our loader; on-demand guest `.so` loading (+ init,
  JNI_OnLoad); ARM kuser-helper page at 0xffff0000.
- libc fixes: lseek/fseek sign-extension (APK zip parsing), real file mmap,
  bionic `_ctype_` pointer variables, `uname` struct size (stack smash), ARM32→arm64
  `open()` flags, owner-tracked recursive mutexes + correct cond timedwait, futex
  `syscall`, ALooper poll timeout, va_list `__android_log_vprint`, thread names,
  stdout/stderr → logcat, atomic CAS for STREX.
- App: game manifest entries (permissions, Play-services/Upsight metadata,
  activities/services), the game's `resources.arsc` + `res/`, external dirs.
- Diagnostics: `[prof]` per-import call profile + per-thread "blocked in" dump with
  guest stack scans (`src/thunks.cpp`).

Known gaps / next:
- **GC disabled** (`GC_DONT_GC=1`, `android_main.cpp`): Boehm's stop-the-world
  needs guest signal delivery (pthread_kill → guest handler + sigsuspend), not yet
  implemented. Memory grows with play time.
- libfrida-gadget (the Windstock Android agent) is deliberately NOT loaded, so its
  game mods (plain login age-gate skip, research, shinies UI, ...) are absent.

### Windstock server, audio, speed (2026-10-15, later)
- **Server**: `android-app/java/.../WsNet.java` + the JNI bridge. Every guest call to
  `NiaNet.request(...)` (login + all RPCs) goes through `WsNet.route()` first:
  `*.nianticlabs.com`, `*.pokemon.com`, `*.zendesk.com` and the baked
  `bracky.playit.plus` go to `https://2.29.24.78:8888` with `Host:<original>`,
  `X-WS-Device` (random id in filesDir/device.id) and `X-WS-Launcher: 4` -- what
  `work/server/tunnel.py` does. Just before the guest's `nativeSetupConnection`,
  `WsNet.setup()` pins the connection to the server's CA (online_pins.py), verified as
  pgorelease.nianticlabs.com. Start-up self-check logs `[net] server check: HTTP 200`.
  Verified to the server; an actual sign-in not yet done (needs a player's login).
- **Audio** works: FMOD uses Java `org.fmod.FMODAudioDevice` (AudioTrack) and fills
  its direct ByteBuffer through `fmodProcess`; `[audio]` logs a non-zero peak. The old
  silence was the emulator's `-no-audio`.
- **Speed**: `-gpu host` (Mac GPU via gfxstream) = steady **30 fps** (the game's own
  cap) vs 15 fps on `swiftshader_indirect`. `[fps]` logged every 5 s from eglSwapBuffers.
  Visible emulator: `$ANDROID_HOME/emulator/emulator -avd windstock30 -gpu host -no-snapshot-save`.

### Playable on the map (2026-10-15, late)
Signed in to the public Windstock server and spun a PokéStop in the windowed emulator.
- **Guest sockets** are real now (`src/sys.cpp`): socket/connect/send/recv/poll/select,
  getaddrinfo/gethostbyname with ARM32 struct conversion. Niantic/Pokémon hosts resolve
  to 127.0.0.1 and plain-HTTP port 80 goes to WsNet's relay (127.0.0.1:18080, Java),
  which re-sends each request over the pinned TLS link with X-WS-Device/X-WS-Launcher.
  That is the PTC sign-in (Mono HttpWebRequest, `http://pgorelease.nianticlabs.com/sso/...`).
- NiaNet: `WsNet.setup()` now runs AFTER the guest's `nativeSetupConnection` (the game
  installs NianticTrustManager there and used to override our pin).
- EGL: real `eglDestroySurface`/`eglDestroyContext` (BootState→map recreates the surface;
  the old no-op gave EGL_BAD_ALLOC and "device lost").
- **Guest signals** (`src/signals.cpp`): sigaction/tkill/raise/sigsuspend/pthread_sigmask.
  A per-thread RunLock is held while executing guest code (released in every SVC);
  running threads are halted with HR_SIGNAL and run the handler themselves, threads in
  host code get a stand-in host thread that runs the handler with their identity on
  their guest stack. Fixes the map freeze: il2cpp Liveness (UnloadUnusedAssets) calls
  Boehm `GC_stop_world` (SIGPWR 30 suspend / SIGXCPU 24 restart) even with GC off.
  GC itself is still disabled (`GC_DONT_GC=1`) -- re-enabling it is the next test.
- libc: lround, remainder, strtoll, fgetc, rewind, lseek64, flock, fchmod,
  pthread_cond_timedwait_monotonic_np, ...
- Diagnostics: `[gl] COMPILE FAILED` (host verdict), `[web]` Java URLs, `[net]`, `[sig]`, `[fps]`.
- Known: the emulator's ES2 compiler rejects `GL_EXT_shadow_samplers` shaders (12, shadows);
  hiding it from GL_EXTENSIONS didn't change Unity's choice. Map tiles: none (as on phones,
  `/glm/mmap` is served empty). Location = the emulator's Extended controls → Location.

### Pokémon on the map, 60 fps request (2026-10-15, night)
- **Spawns**: the server was always sending them (24 Pokémon/GET_MAP_OBJECTS); the models
  (`/asset/...`) download through Unity's Java `com.unity3d.player.WWW`, which went to the
  real Niantic ("Broken asset, wrong CRC"). NewObject of WWW/UnityWebRequest with a
  Niantic-host URL now gets `WsNet.localUrl()` -> `http://127.0.0.1:18080/...` (relay sets
  Host: pgorelease.nianticlabs.com). Manifest: `usesCleartextTraffic` (our res can't carry a
  network-security-config: the game's resources.arsc replaces ours).
- **pthread_exit** really ends the thread now (halt_return at depth 1). It used to return, and
  Unity tail-calls it at the end of its thread wrapper -> ran the next function -> SEGV at
  libunity+0x43a4e0 as soon as asset-loading threads finished.
- **60 fps**: `il2cpp_add_internal_call` handed out by our dlsym is a wrapper that swaps
  `Application::set_targetFrameRate` (forced to WST_FPS, default 60) and
  `QualitySettings::set_vSyncCount` (0). Works ("game asked 30 -> 60") but measured 20-29 fps:
  now CPU/GPU-bound (render thread ~67% of a core, 4-vCPU emulator, gfxstream round trips).
  Next: emulator `-cores`, profile the render thread.
- **GC**: stop-the-world verified working with collection ON (many SIGPWR/SIGXCPU rounds),
  but kept OFF by default until a longer play test -- the crash first blamed on GC was the
  pthread_exit bug above, so GC on is worth retrying (remove the setenv in android_main.cpp).

### GC on, shadows, freeze + crash fixes (2026-10-16)
- **GC collects again** (no GC_DONT_GC). Needed two more fixes:
  - ExclusiveMonitor processor ids are now one per LIVE thread (bitmap, recycled at thread
    exit, 256 slots); stand-ins borrow their target's id. Before, ids came from a counter
    mod 64 and every signal stand-in took one, so after ~20 GC rounds two live threads
    shared an id and their LDREX/STREX loops livelocked (render + worker at 100% = "froze").
  - guest `mmap` honours MAP_FIXED (in-place zero pages / claim the range). Boehm returns
    heap pages with mmap(addr, PROT_NONE, MAP_FIXED) and aborted ("mmap(PROT_NONE) failed")
    when we returned another address -- the crash on opening the Pokédex.
- **Shadows**: shaders the host refuses for GL_EXT_shadow_samplers are rewritten to GLSL ES
  3.00 (whole program, at link) -- `[gl] ... -> GLSL ES 3.00 OK`. The GL_EXTENSIONS hiding
  attempt was removed.
- **SVC fast path**: short non-blocking thunks (mem*/str*, TLS, malloc, forwarded GL except
  waits) keep the run lock; RunLock is a CAS fast path. Blocking thunks still release it.
- Emulator: `-gpu host -cores 6`. fps 20-30 at a 60 target; the render thread is the limit.

### fps work (2026-10-16, later)
- **fastmem** on (`fastmem_pointer = g_base`): ordinary loads/stores no longer go through
  the C++ callbacks.
- **Lock-free exclusives**: local patch to Dynarmic's monitor header,
  `patches/dynarmic-valuebased-monitor.patch` (third-party, 0BSD; rebuild build/dynarmic
  after applying). STREX succeeds iff the reservation matches and the CAS against the
  LDREX value succeeds -- dynarmic's own x64-fastmem semantics, no global spinlock/scan.
  Before: ~45-55% of the render thread in ExclusiveMonitor + its spinlock.
- **Guest-PC sampler** (`[samp]`, on by default, WST_SAMPLE=0 off): halts running threads
  every 5 ms, prints the hottest 64-byte guest code buckets per thread every 5 s.
- Result: steady ~24 fps on the map (was 20-30, varying). Where the time goes now:
  a Unity worker spends 95% in `libunity+0x7fff40` = NEON CPU skinning (vmla.f32 by
  scalar); the render thread mostly waits for it. gpuSkinning is ON in PlayerSettings but
  Unity 5.3.5 has no GPU skinning on Android GLES3 (came in 5.4). Next lever: Dynarmic's
  arm64 code for A32 NEON VMLA-by-scalar (or FPCR switching between VFP/ASIMD ops).

### State at wrap-up (2026-10-16)
- **FPSCR = FZ|DN at every JIT** (`cpu.cpp` JitSlot): with the guest's default mode Dynarmic's
  arm64 backend wrapped EVERY NEON float op in two `MSR FPCR` (serialising) to switch to the
  ASIMD standard FPSCR -- ~40 per vertex in Unity's skinning loop. Built and ran; its fps
  effect was not measured cleanly before the session ended.
- **Frame rate unlocked** by default: targetFrameRate -> 1000, eglSwapInterval forced 0
  (also once the window surface is first made current). `WST_FPS=60` restores a cap.
- **OPEN: intermittent freeze** (seen with the fastmem build and again later): UnityMain sits
  in Boehm `GC_stop_world` (libil2cpp+0x1151300) in sem_wait on the ack semaphore with one
  ack missing (sems `020ce84c: p76/w77`), no signal pending, no stand-in alive. Signal log
  cap is now 100000 lines to catch which thread loses its ack. Suspects: Boehm's duplicate-
  signal path (handler returns without ack when last_stop_count already matches) racing our
  delayed stand-in delivery, or a thread exiting while registered. Workaround if needed:
  `WST_GUEST_ENV=GC_DONT_GC=1`.
- Emulator was closed (not by us) at the end; start it with
  `$ANDROID_HOME/emulator/emulator -avd windstock30 -gpu host -cores 6 -no-snapshot-save`.

### 60 fps + GC freeze fix (2026-10-16, later)
- **Freeze fixed (root cause):** a thread halted in guest code for a signal ran the handler
  via `call_guest`, which re-acquired the thread's own (non-recursive) RunLock -> deadlock;
  Boehm then waited forever for that thread's ack. `GuestThread::run_mine` now marks "this
  host thread holds its run lock" and nested `call_guest` skips the acquire. Also: delivery
  from thunks (`raise`, `sigprocmask`, `sigsuspend`) takes the run lock first
  (`deliver_as_self`), so the real thread and a stand-in can't run handlers on the same
  guest stack at once, and `sig_deliver_now` claims each pending bit via the `fetch_and`
  result (no double delivery). Soak: 11 min of encounters/menus, 234 handler rounds, no hang.
- **60 fps:** targetFrameRate 1000 measured a flat 30.0 (Unity 5.3 falls back to its mobile
  default above the display rate), and the quality level's own vSyncCount (never set through
  the setter) paced every other vblank. Now targetFrameRate -> 60 and `set_vSyncCount(0)` is
  called right after it. Measured on the map and in encounters: 54-60 fps (was ~24).
- Android Back on the map = the game's own "quit" (nativeDone -> finish). Teardown then
  SEGVs at libunity+0x9a906c (guest null read in shutdown) -- harmless, not fixed.

## Windstock tweaks in the translator app (2026-10-16)
The Android agent (`work/mods/android-035`) now runs inside `com.windstock.translator64`,
loaded by an **arm64 frida-gadget 16.7.19** (script mode, `lib/arm64-v8a/libfrida-gadget*.so`,
loaded from `WstBridge.onTranslatorReady` before UnityPlayer starts). Build: `cd work/mods/android-035
&& npm run build:t64` (-> `work/mods/windstock-t64.js`), then `android-app/make_apk.sh`
(`WST_AGENT=0` leaves it out). Verified on emulator-5554: every module arms and logs `ready`;
plain login, colored names, 60 fps, quick catch (Run pinned), shiny, research, map heartbeat,
friends, XP bonus, weather (leaves in encounters), look/music, sound packs, mass transfer,
appraisal, keep ball, settings rows, GPS panel. Map ~49 fps, encounter 52-56 fps with it on.

How (all ours):
- **`src/hooks.cpp`** -- guest hooks + the C surface the shim calls: `wst_gbase/gcall/gsym/
  gmodule/galloc/gfree/ghook/ghook_orig/gunhook`. A hook writes an 8-byte jump at the function
  entry to an SVC stub; the host callback returns 0 (run original via a trampoline of the
  relocated entry -- ARM/Thumb, PC-relative loads/ADR/ADD-PC fixed up), 1 (return now with
  r0/r1) or 2 (run original, call back on return via a leave stub). Calls made from inside a
  hook's own callback on that thread go to the original (Frida's replace semantics).
  `guest_code_changed` makes every JIT drop stale translations (`HR_INVAL`, applied before
  each `Run`). The CPU loop now tolerates any mix of halt reasons.
- **`work/mods/android-035/t64/guest.js`** -- game pointers are HOST form (window base +
  guest address): ordinary reads/writes just work; `readPointer/writePointer` are 32-bit
  inside the window; `NativeFunction` on a window address calls the game; `Hook.attach/
  replace` (util.js; Frida's own are non-configurable) patch game code, many listeners per
  address. Raw "below 4 GB = game" does NOT work: ART's Java heap lives there too.
- **`t64/il2cpp.js`** -- the frida-il2cpp-bridge API the agent uses, rebuilt on the game's
  `il2cpp_*` exports; `invoke` goes through `il2cpp_runtime_invoke` (no per-method ABI);
  `implementation =` decodes softfp args (sret, 64-bit alignment). `Il2Cpp.perform` waits for
  `il2cpp_init` (the agent loads before Unity starts il2cpp).
- Agent changes (native agent unaffected; `npm test` passes): `PS` (game pointer size),
  `Hook`, `gmem/gstr` in util.js; CModule filters fall back to their JS listeners; under t64
  the agent skips redirect/trust (WsNet does it) and talks to the server via the relay
  127.0.0.1:18080.

Gaps closed (2026-10-16, later; verified on emulator-5554):
- **Launcher config** -- `AndroidManifest.xml` has `<queries><provider
  android:authorities="com.windstock.launcher.config"/></queries>` (API 30 package visibility),
  and the launcher's `ConfigProvider` allows `GameInstaller.TRANSLATOR_PACKAGE`
  (`com.windstock.translator64`) besides the game -- needs launcher 1.5 built after this change.
  Log: `launcher 1.5 (...): server running, mods on` and the mod toggles apply (launcher row
  on). The agent still overrides `LAUNCHER.net` with the 127.0.0.1:18080 relay under
  `WST_T64`, so the launcher's `redirect 127.0.0.1:8443` in that line is ignored.
- **Unity data** -- `make_apk.sh` bundles `assets/bin/Data/**` from the patch_badges base,
  the same cached file the launcher uses (`android-launcher/tools/cache/base-badges.apk`,
  rebuilt from `RELEASE/` when RELEASE or the patcher/art is newer), plus `--shakes-only`;
  extracted once into `android-app/cache/unity-data`. It stops if that base's
  global-metadata.dat differs from `assets/guest/` (all builds share metadata 3f6c7d9a / so
  84234999). Log: `research: Unity buttons found on Nearby`; W + binoculars on the map.
- **Assets** -- `assets/windstock/` (night/Halloween music, `sky_night.png`, `sfx_*`,
  `music_*`, 22 files from `work/mods/ios-tweak-035/{night,sounds}`) via a second aapt2 `-A`.

Still open: objects held only by JS aren't GC roots (same as the native bridge -- the agent pins
what it keeps). Night music/sky only show at night (not exercised in the 14:00 test).
Emulator gotcha: a launcher upgraded in place from the 1.0 (Python 3.13) build exits(1) on
Python start (any config call -> DeadObjectException in the agent); `pm clear
com.windstock.launcher` fixed it.
