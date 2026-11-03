// Windstock NIGHT MUSIC -- LiveContainer tweak (arm64), 0.35 + 0.29 iOS clients.
//
// Between NIGHT_START_HOUR and NIGHT_END_HOUR (device local time) the overworld map
// theme ("walk") is replaced by a night track played through AVAudioPlayer. Every other
// piece of music (encounter, evolution, title, ...) stays stock: when one starts, the
// night track fades out, and it fades back in when the map theme returns.
//
// NO-JIT DESIGN -- this tweak never writes to code. Inline hooks (MSHookFunction) rewrite
// signed __TEXT pages; without JIT iOS kills the app the moment such a page runs
// (measured on device, v5-v7). Instead we redirect IL2CPP's METHOD POINTER TABLE, which
// lives in __DATA,__const: il2cpp copies each method's code address from that table into
// its runtime MethodInfo when a class is first set up, and MusicService's methods are only
// ever reached through MethodInfo (interface dispatch -- zero direct b/bl callers in the
// 0.35 binary, verified). Our constructor runs before il2cpp initialises, so swapping the
// table entry for our function is enough. The "original" is the untouched real function.
//
// Addresses: RVAs from masked byte-signature matching against the 0.29 dump
// (work/il2cpp/ios/out/dump.cs). Table slots are NOT hard-coded: we scan the guest's
// __DATA for the 8-byte pointer (base + RVA), so both client versions work.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <SafariServices/SafariServices.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach/mach.h>
#include <dlfcn.h>
#include <signal.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <sys/ucontext.h>
#include <stdint.h>
#include <string.h>

// ----------------------------------------------------------------- RVAs (0.29 + 0.35 iOS)
struct Rvas { const char *version; uintptr_t play, stopall, pause, unpause, get_name; };
static const Rvas kTables[] = {
    // PlayMusic StopAll   Pause     Unpause   Object.get_name
    { "0.35", 0x206F44, 0x207328, 0x207550, 0x207688, 0x8ABA50 },
    { "0.29", 0x1F0C34, 0x1F1018, 0x1F1240, 0x1F1378, 0x88A280 },
};
// first instruction of each function (identical in both builds; verified by disassembly)
static const uint32_t kPrologue[5] = { 0x6dbb23e9, 0xa9bd57f6, 0xa9be4ff4, 0xa9be4ff4, 0xa9be4ff4 };

// Music : MonoBehaviour field offsets (same in both builds)
#define OFF_MUSIC_CLIP   0x20   // AudioClip
#define OFF_MUSIC_VOLUME 0x28   // float

// ----------------------------------------------------------------- config
#define NIGHT_START_HOUR 19     // 7:00 PM
#define NIGHT_END_HOUR   6      // 6:00 AM
#define MAP_CLIP_NAME    "walk" // the overworld theme's AudioClip name (sharedassets0)
#define FADE_SECONDS     2.0
#define NIGHT_VOLUME     0.8f

// ----------------------------------------------------------------- log file
// NSLog is hard to reach under LiveContainer, so everything goes to windstock_log.txt in
// BOTH the game's Documents and the tweak's own folder -- readable from the Files app.
static void wlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSDateFormatter *df; static dispatch_once_t once;
    dispatch_once(&once, ^{ df = [NSDateFormatter new]; df.dateFormat = @"HH:mm:ss"; });
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [df stringFromDate:[NSDate date]], msg];
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    Dl_info info; NSString *tweakDir = nil;
    if (dladdr((void *)&wlog, &info) && info.dli_fname)
        tweakDir = [@(info.dli_fname) stringByDeletingLastPathComponent];
    @synchronized ([NSFileManager class]) {
        for (NSString *dir in @[docs ?: @"", tweakDir ?: @""]) {
            if (!dir.length) continue;
            NSString *path = [dir stringByAppendingPathComponent:@"windstock_log.txt"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            if (!fh) { [line writeToFile:path atomically:NO encoding:NSUTF8StringEncoding error:nil]; }
            else { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        }
    }
    NSLog(@"%@", msg);
}
#define WLOG(...) wlog(__VA_ARGS__)

#include "Compat.inc.h"
#include "WSConfig.inc.mm"

// ----------------------------------------------------------------- crash reporter
// Catches crashes from ANY code in the process (the game, KantoIOS.dylib, us) and writes
// them into windstock_log.txt: signal, fault address, pc/lr and a frame-pointer backtrace,
// each resolved to "image+offset". SIGKILL (e.g. a code-signing kill after something
// patched __TEXT without JIT) can't be caught -- then the log simply stops after the last
// heartbeat, which is itself the tell.
static int g_crash_fds[2] = { -1, -1 };

static void crash_write(const char *s) {
    size_t n = strlen(s);
    for (int i = 0; i < 2; i++) if (g_crash_fds[i] >= 0) write(g_crash_fds[i], s, n);
}

static void crash_addr(const char *label, uintptr_t a) {
    char buf[512];
    Dl_info info;
    if (a && dladdr((void *)a, &info) && info.dli_fname) {
        const char *img = strrchr(info.dli_fname, '/'); img = img ? img + 1 : info.dli_fname;
        uintptr_t base = 0;
        for (uint32_t i = 0; i < _dyld_image_count(); i++)
            if (_dyld_get_image_name(i) && strcmp(_dyld_get_image_name(i), info.dli_fname) == 0) {
                base = (uintptr_t)_dyld_get_image_header(i); break;
            }
        snprintf(buf, sizeof buf, "  %-6s %p  %s+0x%lx  (%s)\n", label, (void *)a, img,
                 (unsigned long)(a - base), info.dli_sname ? info.dli_sname : "?");
    } else {
        snprintf(buf, sizeof buf, "  %-6s %p  (unknown image)\n", label, (void *)a);
    }
    crash_write(buf);
}

static void crash_handler(int sig, siginfo_t *si, void *ctx) {
    char buf[256];
    time_t now = time(NULL); struct tm tmv; localtime_r(&now, &tmv);
    snprintf(buf, sizeof buf, "%02d:%02d:%02d !!!! CRASH signal %d (%s) fault addr %p\n",
             tmv.tm_hour, tmv.tm_min, tmv.tm_sec, sig,
             sig == SIGSEGV ? "SIGSEGV" : sig == SIGBUS ? "SIGBUS" : sig == SIGILL ? "SIGILL" :
             sig == SIGABRT ? "SIGABRT" : sig == SIGTRAP ? "SIGTRAP" : sig == SIGFPE ? "SIGFPE" : "?",
             si ? si->si_addr : NULL);
    crash_write(buf);
    ucontext_t *uc = (ucontext_t *)ctx;
    if (uc && uc->uc_mcontext) {
        __darwin_arm_thread_state64 *ss = &uc->uc_mcontext->__ss;
        uintptr_t pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(*ss);
        uintptr_t lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(*ss);
        uintptr_t fp = (uintptr_t)__darwin_arm_thread_state64_get_fp(*ss);
        crash_addr("pc", pc);
        crash_addr("lr", lr);
        snprintf(buf, sizeof buf, "  x0=%p x1=%p x2=%p x8=%p\n", (void *)ss->__x[0], (void *)ss->__x[1],
                 (void *)ss->__x[2], (void *)ss->__x[8]);
        crash_write(buf);
        for (int i = 0; i < 16 && fp && (fp & 7) == 0 && fp > 0x100000000ULL; i++) {
            uintptr_t ret = *(uintptr_t *)(fp + 8);
            char label[8]; snprintf(label, sizeof label, "#%d", i);
            crash_addr(label, ret);
            uintptr_t next = *(uintptr_t *)fp;
            if (next <= fp) break;
            fp = next;
        }
    }
    crash_write("---- end crash ----\n");
    signal(sig, SIG_DFL);   // let the process die normally
    raise(sig);
}

static void uncaught_exception(NSException *e) {
    WLOG(@"!!!! UNCAUGHT EXCEPTION %@: %@\n%@", e.name, e.reason,
         [e.callStackSymbols componentsJoinedByString:@"\n"]);
}

static void install_crash_reporter(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    Dl_info info; NSString *tweakDir = nil;
    if (dladdr((void *)&install_crash_reporter, &info) && info.dli_fname)
        tweakDir = [@(info.dli_fname) stringByDeletingLastPathComponent];
    NSArray *dirs = @[docs ?: @"", tweakDir ?: @""];
    for (int i = 0; i < 2; i++) {
        if (![dirs[i] length]) continue;
        NSString *p = [dirs[i] stringByAppendingPathComponent:@"windstock_log.txt"];
        g_crash_fds[i] = open(p.fileSystemRepresentation, O_WRONLY | O_CREAT | O_APPEND, 0644);
    }
    // Route stderr into the log too: KantoIOS.dylib's _KantoLog (and NSLog output that
    // reaches stderr) prints there, so Kanto's own messages land next to ours.
    int stderr_target = g_crash_fds[1] >= 0 ? g_crash_fds[1] : g_crash_fds[0];
    if (stderr_target >= 0) {
        dprintf(stderr_target, "---- stderr now mirrored here (KantoLog / NSLog) ----\n");
        dup2(stderr_target, STDERR_FILENO);
        setvbuf(stderr, NULL, _IONBF, 0);
    }
    static char altstack[64 * 1024];
    stack_t ss = { .ss_sp = altstack, .ss_size = sizeof altstack, .ss_flags = 0 };
    sigaltstack(&ss, NULL);
    struct sigaction sa; memset(&sa, 0, sizeof sa);
    sa.sa_sigaction = crash_handler;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    for (int sig : { SIGSEGV, SIGBUS, SIGILL, SIGABRT, SIGFPE, SIGTRAP }) sigaction(sig, &sa, NULL);
    NSSetUncaughtExceptionHandler(&uncaught_exception);

    // loaded non-system images: shows whether KantoIOS.dylib (and a 2nd windstock) are in
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        if (n && !strstr(n, "/System/") && strncmp(n, "/usr/lib/", 9) != 0)
            WLOG(@"  image: %s @ %p", n, (void *)_dyld_get_image_header(i));
    }
    WLOG(@"crash reporter armed");
}

// ----------------------------------------------------------------- guest image
// The game's MAIN executable only: path must END in "/pokemongo".
static const struct mach_header_64 *guest_header(void) {
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *n = _dyld_get_image_name(i);
        size_t l = n ? strlen(n) : 0;
        if (l >= 10 && strcmp(n + l - 10, "/pokemongo") == 0) {
            WLOG(@"guest image: %s", n);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

// __DATA segment of the guest, in runtime addresses (slide applied)
static bool guest_data_range(const struct mach_header_64 *mh, uintptr_t *start, size_t *size) {
    const struct load_command *lc = (const struct load_command *)(mh + 1);
    intptr_t slide = 0; bool have_text = false;
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__TEXT") == 0) { slide = (intptr_t)mh - (intptr_t)seg->vmaddr; have_text = true; }
    }
    if (!have_text) return false;
    lc = (const struct load_command *)(mh + 1);
    for (uint32_t i = 0; i < mh->ncmds; i++, lc = (const struct load_command *)((char *)lc + lc->cmdsize)) {
        if (lc->cmd != LC_SEGMENT_64) continue;
        const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
        if (strcmp(seg->segname, "__DATA") == 0) {
            *start = (uintptr_t)(seg->vmaddr + slide); *size = (size_t)seg->vmsize;
            return true;
        }
    }
    return false;
}

// Replace the single method-pointer table entry holding `target` with `replacement`.
// Only DATA is written. Returns false (and changes nothing) unless exactly one entry exists.
static bool redirect_method_pointer(uintptr_t dstart, size_t dsize, uintptr_t target,
                                    uintptr_t replacement, const char *label) {
    uintptr_t *hit = NULL; int count = 0;
    for (uintptr_t *p = (uintptr_t *)dstart; (uintptr_t)(p + 1) <= dstart + dsize; p++) {
        if (*p == target) { if (!hit) hit = p; count++; }
    }
    if (count != 1) {
        WLOG(@"  %s: found %d table entries for %p -- NOT redirected", label, count, (void *)target);
        return false;
    }
    vm_address_t page = (vm_address_t)hit & ~(vm_address_t)vm_page_mask;
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        WLOG(@"  %s: vm_protect failed (%d) -- NOT redirected", label, kr);
        return false;
    }
    *hit = replacement;
    WLOG(@"  %s: table entry %p redirected (%p -> %p)", label, hit, (void *)target, (void *)replacement);
    return true;
}

// ----------------------------------------------------------------- il2cpp bits
static inline bool looks_like_ptr(void *p) {
    return p && ((uintptr_t)p & 7) == 0 && (uintptr_t)p > 0x100000000ULL;
}

static void *(*g_get_name)(void *obj, void *method) = NULL;

// System.String: [header 0x10][int32 length @0x10][char16 chars @0x14]
static bool il2cpp_string_equals(void *s, const char *ascii) {
    if (!looks_like_ptr(s)) return false;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len != (int32_t)strlen(ascii)) return false;
    uint16_t *c = (uint16_t *)((uint8_t *)s + 0x14);
    for (int32_t i = 0; i < len; i++)
        if (c[i] != (uint16_t)ascii[i]) return false;
    return true;
}

static bool is_map_music(void *music) {
    if (!looks_like_ptr(music) || !g_get_name) return false;
    void *clip = *(void **)((uint8_t *)music + OFF_MUSIC_CLIP);
    if (!looks_like_ptr(clip)) { WLOG(@"PlayMusic: clip is null"); return false; }
    void *name = g_get_name(clip, NULL);
    if (looks_like_ptr(name)) {
        int32_t len = *(int32_t *)((uint8_t *)name + 0x10);
        if (len > 0 && len < 128)
            WLOG(@"PlayMusic: clip '%@'", [NSString stringWithCharacters:(unichar *)((uint8_t *)name + 0x14) length:len]);
    }
    return il2cpp_string_equals(name, MAP_CLIP_NAME);
}

// ----------------------------------------------------------------- night state
static bool g_halloween = false;           // v146: the running event's theme is "halloween" (/shiny/state)
// v157: the Halloween LOOK, switched on and tuned by the server ("look" in /shiny/state,
// settings "halloween"): night all day -- the game's own night map and our night music --
// orange fog, and a tint on the map's night light. All zero = no look.
// v160: sky = the fog climbs past the horizon and fades out sh degrees up -- see sky_fog_band.
#define WS_TWEAK_BUILD 207                  // = WS_TWEAK_VERSION, for code above its definition
struct HwLook { int night, fog, tint; float fr, fg, fb, fs, fe, tr, tg, tb, ta; int sky; float sh; };
static char g_sky_state[24] = "-";         // v160: what became of the sky fog, for the server's log
static HwLook g_look = {};
static int g_look_gen = 0;                 // bumped on every change (main thread only)
static bool is_night_now(void) {
    if (!ws_mod(@"night_music", true)) return false;
    if (g_look.night) return true;
    NSInteger h = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
    NSInteger start = (NSInteger)ws_value(@"night_start_hour", NIGHT_START_HOUR);
    NSInteger end   = (NSInteger)ws_value(@"night_end_hour", NIGHT_END_HOUR);
    return start > end ? (h >= start || h < end) : (h >= start && h < end);
}

// The game's own Settings toggles (Niantic.Holoholo.PersistentData.Preferences). They go through
// PlayerPrefs.GetBool/SetBool, which Unity's iOS player keeps in NSUserDefaults as ints under
// these GUID keys. Missing key = enabled (the game's default). Our AVAudioPlayers bypass Unity's
// audio, so they have to honour these themselves.
#define PREF_MUSIC_ENABLED @"5a4d0a56-e3e1-4e72-b1fd-8dd550a1cb03"
#define PREF_SFX_ENABLED   @"09929d1d-4109-4e04-8929-6e368e8ebf9d"
static bool game_pref_enabled(NSString *key) {
    id v = [[NSUserDefaults standardUserDefaults] objectForKey:key];
    return v ? [v intValue] != 0 : true;
}

static AVAudioPlayer *g_player = nil;    // replacement music now playing (night track or pack music)
static NSURL *g_player_url = nil;
static void *g_cur_music = NULL;         // the Music object last handed to PlayMusic
static NSString *g_cur_name = nil;       // its clip name
static bool  g_music_active = false;     // that music is the current music
// Which gym screen the MUSIC says is open: 0 none, 1 gym approach ('before_the_fight'),
// 2 gym battle ('battle'). Measured on device: these play reliably, unlike the v30 object lookup.
static int   g_gym_music = 0;
static bool  g_map_active = false;       // ...and it is the map theme
// v119: the Windstock Launcher can park the game behind its own UI (the home button on the
// map). Unity pauses its own audio then; our AVAudioPlayers don't, so they check this.
static bool  g_in_launcher = false;
static bool  g_paused = false;           // MusicService paused (app backgrounded, etc.)
// v155: the app is not frontmost (app switcher, Control Center, notification shade). The game
// still gets a frame or two and re-sends PlayMusic('walk'), which used to start the music again.
static bool  g_inactive = false;

static NSURL *pack_clip_url(const char *clipName);   // sound packs, below

// AudioClips that belong to music (seen in PlayMusic). The SFX hooks leave these alone, so a
// pack's walk.mp3 is handled here as looping music rather than as a one-shot sound effect.
static void *g_music_clips[64]; static int g_music_clip_count = 0;
static void remember_music_clip(void *clip) {
    if (!looks_like_ptr(clip)) return;
    @synchronized ([NSObject class]) {
        for (int i = 0; i < g_music_clip_count; i++) if (g_music_clips[i] == clip) return;
        if (g_music_clip_count < 64) g_music_clips[g_music_clip_count++] = clip;
    }
}
static bool is_music_clip(void *clip) {
    @synchronized ([NSObject class]) {
        for (int i = 0; i < g_music_clip_count; i++) if (g_music_clips[i] == clip) return true;
    }
    return false;
}

static NSURL *night_track_url(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *exts = @[@"m4a", @"mp3", @"caf", @"wav", @"aac"];
    // 1) user override: <app Documents>/night_music.<ext>
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    for (NSString *e in exts) {
        NSString *p = [docs stringByAppendingPathComponent:[@"night_music" stringByAppendingPathExtension:e]];
        if ([fm fileExistsAtPath:p]) return [NSURL fileURLWithPath:p];
    }
    // 2) shipped in the IPA: pokemongo.app/windstock_night.<ext>
    for (NSString *e in exts) {
        NSString *p = [[NSBundle mainBundle] pathForResource:@"windstock_night" ofType:e];
        if (p) return [NSURL fileURLWithPath:p];
    }
    return nil;
}

// v117: night versions of other clips shipped in the IPA: pokemongo.app/windstock_<clip>_night.<ext>
// (embed_guest.sh copies them in -- 102_encounter_night is the night catch theme).
static NSURL *bundled_night_url(NSString *clip) {
    NSString *res = [NSString stringWithFormat:@"windstock_%@_night", clip.lowercaseString];
    for (NSString *e in @[@"m4a", @"mp3", @"caf", @"wav", @"aac"]) {
        NSString *p = [[NSBundle mainBundle] pathForResource:res ofType:e];
        if (p) return [NSURL fileURLWithPath:p];
    }
    return nil;
}

// Which file replaces the current music? nil = the game's own track plays.
//   map theme at night: pack "walk_night" > Documents/night_music > IPA windstock_night > pack "walk"
//   anything else:      at night the pack's "<clip>_night" (102_encounter_night, battle_night, ...),
//                       then the IPA's windstock_<clip>_night,
//                       else the pack file named after the clip (walk, 102_encounter, 200_ME_gotcha, ...)
// v146: Halloween nights (event theme "halloween") come first: the pack's "<clip>_halloween"
// (walk_halloween = the map), then the IPA's windstock_<clip>_halloween, then the usual night music.
static NSURL *halloween_url(NSString *clip) {
    if (!g_halloween || !is_night_now()) return nil;
    NSURL *u = pack_clip_url([clip stringByAppendingString:@"_halloween"].UTF8String);
    if (u) return u;
    NSString *res = [NSString stringWithFormat:@"windstock_%@_halloween", clip.lowercaseString];
    for (NSString *e in @[@"m4a", @"mp3", @"caf", @"wav", @"aac"]) {
        NSString *p = [[NSBundle mainBundle] pathForResource:res ofType:e];
        if (p) return [NSURL fileURLWithPath:p];
    }
    return nil;
}

static NSURL *music_override_url(void) {
    if (!g_music_active || !g_cur_name.length) return nil;
    if (!game_pref_enabled(PREF_MUSIC_ENABLED)) return nil;   // Settings > Music off: stay silent like the game
    NSURL *hw = halloween_url(g_map_active ? @MAP_CLIP_NAME : g_cur_name);
    if (hw) return hw;
    if (g_map_active && is_night_now()) {
        NSURL *u = pack_clip_url(MAP_CLIP_NAME "_night");
        if (!u) u = night_track_url();
        if (u) return u;
    }
    if (is_night_now()) {                                     // v115: any music clip can have a
        NSString *n = [g_cur_name stringByAppendingString:@"_night"];   // night version in the pack,
        NSURL *u = pack_clip_url(n.UTF8String);               // e.g. 102_encounter_night
        if (!u) u = bundled_night_url(g_cur_name);
        if (u) return u;
    }
    return pack_clip_url(g_cur_name.UTF8String);
}

// "ME" clips (200_ME_gotcha, 302_ME_levelup) are one-shot jingles; everything else loops.
static bool music_loops(NSString *name) { return ![name.lowercaseString containsString:@"_me_"]; }

static void player_fade_out(void) {
    if (!g_player) return;
    AVAudioPlayer *p = g_player;
    g_player = nil; g_player_url = nil;
    ws_fade(p, 0, FADE_SECONDS);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((FADE_SECONDS + 0.1) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ [p stop]; });
}

// Play url as the current music (no restart if it is already the one playing). Returns false
// if the file can't be played, in which case the game's own track must stay audible.
static bool player_play(NSURL *url, bool loop) {
    if (g_player && [g_player_url isEqual:url]) {
        if (!g_player.playing && g_player.numberOfLoops < 0) [g_player play];   // resume a loop, never replay a finished jingle
        if (g_player.numberOfLoops < 0) ws_fade(g_player, NIGHT_VOLUME, FADE_SECONDS);
        return true;
    }
    player_fade_out();
    static bool session = false;
    if (!session) {
        session = true;   // Ambient mixes with Unity's own audio session and respects the silent switch
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryAmbient
                                         withOptions:AVAudioSessionCategoryOptionMixWithOthers error:nil];
    }
    NSError *err = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!p) {
        static int warned = 0;
        if (warned++ < 5) WLOG(@"music: %@ failed to load: %@", url.lastPathComponent, err);
        return false;
    }
    p.numberOfLoops = loop ? -1 : 0;
    [p prepareToPlay];
    if (loop) { p.volume = 0; [p play]; ws_fade(p, NIGHT_VOLUME, FADE_SECONDS); }
    else      { p.volume = NIGHT_VOLUME; [p play]; }
    g_player = p; g_player_url = url;
    WLOG(@"music: playing %@ for '%@' (%.1fs, %@)", url.lastPathComponent, g_cur_name,
         p.duration, loop ? @"loop" : @"once");
    return true;
}

// Silence the game's map theme WITHOUT touching code. Writing Music.Volume does nothing:
// MusicPlayInstance.Update calls AudioSource.set_volume(1.0f) every frame once no fade is
// running (measured in the 0.35 disassembly), and AudioSource.set_mute is stripped from
// this Unity build. But the same Update does `if (instance.Paused) set_volume(source, 0)`
// every frame -- so we set that flag (MusicPlayInstance+0x31) on the map theme's live
// instances. The clip keeps playing silently and is instantly back at full volume when
// the flag is cleared. Instances are found in MusicService.activeMusic.
//   MusicService:      activeMusic List<MusicPlayInstance> @0x20
//   List<T>:           _items T[] @0x10, _size int @0x18
//   T[] (Il2CppArray): elements @0x20
//   MusicPlayInstance: Source @0x20, Music @0x28, PlayComplete @0x30, Paused @0x31
#define OFF_SERVICE_ACTIVE   0x20
#define OFF_LIST_ITEMS       0x10
#define OFF_LIST_SIZE        0x18
#define OFF_ARRAY_DATA       0x20
#define OFF_INST_MUSIC       0x28
#define OFF_INST_PAUSED      0x31

static void *g_service = NULL;        // the MusicService instance (PlayMusic's `this`)
static void *g_silenced = NULL;       // Music whose instances WE paused (so only we clear it)

static int set_music_paused(void *music, bool want) {
    if (!looks_like_ptr(g_service) || !looks_like_ptr(music)) return 0;
    void *list = *(void **)((uint8_t *)g_service + OFF_SERVICE_ACTIVE);
    if (!looks_like_ptr(list)) return 0;
    void *items = *(void **)((uint8_t *)list + OFF_LIST_ITEMS);
    int32_t size = *(int32_t *)((uint8_t *)list + OFF_LIST_SIZE);
    if (!looks_like_ptr(items) || size < 0 || size > 64) return 0;
    int touched = 0;
    for (int32_t i = 0; i < size; i++) {
        void *inst = *(void **)((uint8_t *)items + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(inst)) continue;
        if (*(void **)((uint8_t *)inst + OFF_INST_MUSIC) != music) continue;
        uint8_t *paused = (uint8_t *)inst + OFF_INST_PAUSED;
        if (*paused != (uint8_t)want) { *paused = want; touched++; }
    }
    return touched;
}

// Silence the current music's game instances while a replacement plays; give back any we
// silenced before (never un-pause what the game itself paused).
static void apply_mute(bool replaced) {
    void *target = replaced ? g_cur_music : NULL;
    if (g_silenced && g_silenced != target) {
        int n = set_music_paused(g_silenced, false);
        if (n) WLOG(@"music: game track restored (%d instance%@)", n, n == 1 ? @"" : @"s");
        g_silenced = NULL;
    }
    if (target) {
        int n = set_music_paused(target, true);
        if (n) WLOG(@"music: game track '%@' silenced (%d instance%@)", g_cur_name, n, n == 1 ? @"" : @"s");
        g_silenced = target;
    }
}

// v194: a screen of ours can ask for its own music over whatever the game plays (Friends: the
// modern game's trade-room theme 124_trade_standby, then 125_trade for the swap). A sound pack's
// file of that name wins, else the app's windstock_music_<name>.m4a/.mp3 (embed_guest.sh).
static NSString *g_extra_music = nil;
static bool g_extra_loop = true;
static NSURL *extra_music_url(void) {
    if (!g_extra_music.length || !game_pref_enabled(PREF_MUSIC_ENABLED)) return nil;
    NSURL *u = pack_clip_url(g_extra_music.UTF8String);
    if (u) return u;
    NSString *res = [@"windstock_music_" stringByAppendingString:g_extra_music];
    for (NSString *e in @[@"m4a", @"mp3", @"wav"]) {
        NSString *p = [[NSBundle mainBundle] pathForResource:res ofType:e];
        if (p) return [NSURL fileURLWithPath:p];
    }
    static int missing = 0;
    if (missing++ < 3) WLOG(@"music: %@ not in the app", res);
    return nil;
}
static void refresh(void);
static void ws_extra_music(NSString *name, bool loop) {
    if ((name == g_extra_music || [name isEqualToString:g_extra_music]) && loop == g_extra_loop) return;
    g_extra_music = name;
    g_extra_loop = loop;
    refresh();
}

// Called on every relevant change: music started/stopped, pause, pack picked, or the hour ticking over.
static void refresh(void) {
    if (g_paused || g_in_launcher || g_inactive) { [g_player pause]; return; }   // while the service is paused the game owns the flags
    NSURL *url = extra_music_url();
    bool loop = g_extra_loop;
    if (!url) { url = music_override_url(); loop = music_loops(g_cur_name); }
    bool on = url && player_play(url, loop);
    if (!url) player_fade_out();
    static NSString *last = nil;
    NSString *state = [NSString stringWithFormat:@"'%@' -> %@", g_music_active ? g_cur_name : @"(none)",
                       on ? url.lastPathComponent : @"stock"];
    if (![state isEqualToString:last]) {
        last = state;
        WLOG(@"music: %@ (map=%d night=%d)", state, g_map_active, is_night_now());
    }
    apply_mute(on);
}

// ----------------------------------------------------------------- replacements
// Each "original" is the game's real, untouched function (never a trampoline).
// il2cpp calling convention: (this, args..., MethodInfo*).
static void (*o_play)(void *, void *, void *);
static bool g_game_live = false;         // the game has started playing music = safe to look things up
static void rs_music_changed(NSString *name, bool map);   // Research.inc.mm: toast timing
static void hk_play(void *self, void *music, void *m) {
    static bool first = true;
    if (first) { first = false; g_game_live = true; WLOG(@"PlayMusic redirect is live"); }
    if (looks_like_ptr(self)) g_service = self;
    bool map = is_map_music(music);
    void *clip = looks_like_ptr(music) ? *(void **)((uint8_t *)music + OFF_MUSIC_CLIP) : NULL;
    NSString *name = nil;
    if (looks_like_ptr(clip) && g_get_name) {
        void *s = g_get_name(clip, NULL);
        int32_t len = looks_like_ptr(s) ? *(int32_t *)((uint8_t *)s + 0x10) : 0;
        if (len > 0 && len < 128) name = [NSString stringWithCharacters:(unichar *)((uint8_t *)s + 0x14) length:len];
    }
    remember_music_clip(clip);
    static int calls = 0;
    bool trace = calls++ < 6;     // step-trace the first few starts (where the kills happen)
    if (trace) WLOG(@"  [play %d] -> game PlayMusic (map=%d)", calls, map);
    o_play(self, music, m);       // creates the MusicPlayInstance and adds it to activeMusic
    if (trace) WLOG(@"  [play %d] <- game PlayMusic returned; refresh", calls);
    // Set music state AFTER the game's PlayMusic: it calls StopAll internally (interface slot 5),
    // which reaches hk_stopall and would otherwise clear it straight away.
    if (looks_like_ptr(music)) {
        // finished jingle: allow a replay (a loop that isn't playing is only paused -- keep it)
        if (g_player && !g_player.playing && g_player.numberOfLoops >= 0 && !g_paused) { g_player = nil; g_player_url = nil; }
        g_cur_music = music;
        g_cur_name = name;
        g_gym_music = [name isEqualToString:@"before_the_fight"] ? 1 : [name isEqualToString:@"battle"] ? 2 : 0;
        g_music_active = true;
        g_map_active = map;
        rs_music_changed(name, map);
    }
    refresh();                    // ...so the new instance can be silenced right away
    if (trace) WLOG(@"  [play %d] refresh done", calls);
}

static void (*o_stopall)(void *, void *);
static void hk_stopall(void *self, void *m) {
    o_stopall(self, m);
    g_music_active = false; g_map_active = false;
    // Inside PlayMusic the new track is set (and refreshed) right after, so don't fade out a
    // replacement that is about to continue -- PlayMusic re-sends 'walk' every ~1.5 s.
    dispatch_async(dispatch_get_main_queue(), ^{ if (!g_music_active) refresh(); });
}

static void (*o_pause)(void *, void *);
static void hk_pause(void *self, void *m) { g_paused = true; g_silenced = NULL; refresh(); o_pause(self, m); }

static void (*o_unpause)(void *, void *);
// Unpause clears every instance's Paused flag, so re-apply our silence right after it.
static void hk_unpause(void *self, void *m) { o_unpause(self, m); g_paused = false; refresh(); }

// ----------------------------------------------------------------- 60 fps (no-JIT)
// Unity's iOS player paces rendering with a CADisplayLink: targetFrameRate 30 becomes
// frameInterval = 2 (or preferredFramesPerSecond = 30). Swapping those two ObjC setters
// with method_setImplementation is plain runtime metadata -- no code pages are written,
// so it works without JIT. Same approach Kanto uses (_KantoInstallDisplayLinkHook).
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import <objc/message.h>
#define TARGET_FPS 60

static IMP g_orig_setFrameInterval = NULL;
static IMP g_orig_setPreferredFPS = NULL;
static bool g_fps_logged = false;

static void ws_setFrameInterval(id self, SEL _cmd, NSInteger interval) {
    if (!g_fps_logged) { g_fps_logged = true; WLOG(@"60fps: game asked frameInterval=%ld -> 1", (long)interval); }
    ((void (*)(id, SEL, NSInteger))g_orig_setFrameInterval)(self, _cmd, 1);
}

static void ws_setPreferredFramesPerSecond(id self, SEL _cmd, NSInteger fps) {
    if (!g_fps_logged) { g_fps_logged = true; WLOG(@"60fps: game asked preferredFramesPerSecond=%ld -> %d", (long)fps, TARGET_FPS); }
    ((void (*)(id, SEL, NSInteger))g_orig_setPreferredFPS)(self, _cmd, TARGET_FPS);
}

static void install_60fps(void) {
    Class cls = [CADisplayLink class];
    Method m1 = class_getInstanceMethod(cls, @selector(setFrameInterval:));
    if (m1) g_orig_setFrameInterval = method_setImplementation(m1, (IMP)ws_setFrameInterval);
    Method m2 = class_getInstanceMethod(cls, @selector(setPreferredFramesPerSecond:));
    if (m2) g_orig_setPreferredFPS = method_setImplementation(m2, (IMP)ws_setPreferredFramesPerSecond);
    WLOG(@"60fps: CADisplayLink setters swapped (frameInterval=%d preferredFPS=%d)", m1 != NULL, m2 != NULL);
}

// ----------------------------------------------------------------- web links, in the game
// v104: Settings -> Help Center / Report an Issue (and any other web link the game opens)
// used to leave for Safari. The Help Center now lives on the launcher's own server
// (http://127.0.0.1:8080/hc -- the link is set in the game's text table by
// tools/patch_badges.py), and once the launcher is in the background iOS pauses it, server
// and all. So web links open in an in-app browser over the game instead: the server keeps
// running, and Done goes straight back to the map. Swapping UIApplication's openURL
// methods is runtime metadata only -- safe without JIT, like the 60 fps swap above.
static IMP g_orig_openURL1 = NULL, g_orig_openURL3 = NULL;
static UIView *mt_unity_view(void);

static bool ws_open_in_app(NSURL *url) {
    url = ws_web_rebase(url);                   // v152: Windstock Online -> the server's IP
    NSString *scheme = url.scheme.lowercaseString;
    if (![scheme isEqualToString:@"http"] && ![scheme isEqualToString:@"https"]) return false;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIViewController *top = mt_unity_view().window.rootViewController;
        while (top.presentedViewController) top = top.presentedViewController;
        if (!top) { WLOG(@"web: no view controller to show %@ -- Safari instead", url); 
                    ((BOOL (*)(id, SEL, NSURL *))g_orig_openURL1)(UIApplication.sharedApplication,
                                                                   @selector(openURL:), url);
                    return; }
        SFSafariViewController *vc = [[SFSafariViewController alloc] initWithURL:url];
        vc.modalPresentationStyle = UIModalPresentationPageSheet;
        [top presentViewController:vc animated:YES completion:nil];
        WLOG(@"web: %@ opened in the game", url.absoluteString);
    });
    return true;
}

static BOOL ws_openURL1(id self, SEL _cmd, NSURL *url) {
    if (ws_open_in_app(url)) return YES;
    return ((BOOL (*)(id, SEL, NSURL *))g_orig_openURL1)(self, _cmd, url);
}

static void ws_openURL3(id self, SEL _cmd, NSURL *url, NSDictionary *opts, void (^done)(BOOL)) {
    if (ws_open_in_app(url)) { if (done) done(YES); return; }
    ((void (*)(id, SEL, NSURL *, NSDictionary *, void (^)(BOOL)))g_orig_openURL3)(self, _cmd, url, opts, done);
}

static void install_in_app_links(void) {
    Class cls = [UIApplication class];
    Method m1 = class_getInstanceMethod(cls, @selector(openURL:));
    if (m1) g_orig_openURL1 = method_setImplementation(m1, (IMP)ws_openURL1);
    Method m3 = class_getInstanceMethod(cls, @selector(openURL:options:completionHandler:));
    if (m3) g_orig_openURL3 = method_setImplementation(m3, (IMP)ws_openURL3);
    WLOG(@"web: links open in the game (openURL: %d, openURL:options: %d)", m1 != NULL, m3 != NULL);
}

// ----------------------------------------------------------------- quick catch (no-JIT, 0.35)
// Keeps a Run button on screen through the whole throw/capture. The game hides the
// encounter's UIRoot while the ball is in flight; we clone its "UIRoot/RunAway" button and
// parent the clone to the EncounterUIController itself (outside UIRoot), so it stays
// visible. The clone keeps the original button's click handler, so tapping it runs away.
// No hooks: every step is a plain call into existing game/Unity code (safe without JIT).
// Recipe and addresses from KantoIOS _KantoRestoreQuickCatchRun; every name confirmed via
// icall strings or 0.29 signature match, and every call is guarded by its first instruction.
// Calling convention in this build (as Kanto calls them): static methods take an unused
// first argument (x0 = 0), then the real argument(s), then MethodInfo* = NULL.
#define QUICK_CATCH 1

struct QcFn { const char *name; uintptr_t rva; uint32_t first; };
static const QcFn kQc[] = {
    { "Marshal.PtrToStringAnsi",    0x9B86E4, 0xaa0103e0 },
    { "Type.GetType",               0xA66F7C, 0xa9be4ff4 },
    { "Object.FindObjectOfType",    0x8BA038, 0xa9bf7bfd },
    { "Component.get_transform",    0x891F54, 0xa9be4ff4 },
    { "Transform.Find",             0x8D6950, 0xa9bd57f6 },
    { "Component.get_gameObject",   0x892004, 0xa9be4ff4 },
    { "Object.Instantiate",         0x8B9FE0, 0xa9be4ff4 },
    { "GameObject.get_transform",   0x89B714, 0xa9be4ff4 },
    { "Transform.SetParent",        0x8D5DBC, 0xa9bd57f6 },
    { "Transform.SetAsLastSibling", 0x8D68EC, 0xa9be4ff4 },
    { "GameObject.SetActive",       0x89B850, 0xa9bd57f6 },
};
enum { QC_STR, QC_GETTYPE, QC_FINDOBJ, QC_COMP_TR, QC_FIND, QC_COMP_GO, QC_INSTANTIATE,
       QC_GO_TR, QC_SETPARENT, QC_LASTSIB, QC_SETACTIVE, QC_COUNT };
static void *g_qc[QC_COUNT];

typedef void *(*qc_static1)(void *unused, void *arg, void *mi);
typedef void *(*qc_inst0)(void *self, void *mi);
typedef void *(*qc_inst1)(void *self, void *arg, void *mi);

static void *g_qc_controller = NULL;   // EncounterUIController we last cloned for
static void *g_qc_clone = NULL;        // our Run button clone (GameObject)

static bool install_quick_catch(uintptr_t base, const char *version) {
    if (strcmp(version, "0.35") != 0) { WLOG(@"quick catch: 0.35 only -- off on %s", version); return false; }
    for (int i = 0; i < QC_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kQc[i].rva);
        if (w != kQc[i].first) {
            WLOG(@"quick catch: %s @0x%lx first word %08x != %08x -- OFF", kQc[i].name,
                 (unsigned long)kQc[i].rva, w, kQc[i].first);
            return false;
        }
        g_qc[i] = (void *)(base + kQc[i].rva);
    }
    WLOG(@"quick catch: %d game functions verified", QC_COUNT);
    return true;
}

// v199: locked until trainer level 2. In the tutorial the pinned Run button let a catch be
// "run" from mid-throw: the server had already caught the starter, the game hadn't, so the
// tutorial offered the starters again -- 4 starters in the bag. Level from /shiny/state
// ("level"); polled here only while still locked, since the shiny poll can be switched off.
#define QC_UNLOCK_LEVEL 2
#define QC_STATE_URL @"https://pgorelease.nianticlabs.com/shiny/state"
static int g_qc_level = 0;          // 0 = not known yet (locked); an older server without "level" -> unlocked
static bool g_qc_asking = false;
static void qc_level_from(NSDictionary *j) {
    if (![j isKindOfClass:[NSDictionary class]]) return;
    id lv = j[@"level"];
    int n = [lv isKindOfClass:[NSNumber class]] ? [lv intValue] : (j[@"species"] ? 99 : 0);
    if (n <= 0 || n == g_qc_level) return;              // 0: not signed in yet
    g_qc_level = n;
    WLOG(@"quick catch: trainer level %d -> %s", n, n >= QC_UNLOCK_LEVEL ? "on" : "locked (need 2)");
}
static void qc_level_poll(void) {
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (g_qc_asking || now - last < 10) return;
    g_qc_asking = true;
    last = now;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:QC_STATE_URL]];
    rq.timeoutInterval = 5;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ g_qc_asking = false; qc_level_from(j); });
    }] resume];
}

static void *mt_type(const char *name);
// v209 probe: why does the encounter intro never finish for species above 151? While an
// encounter is open, dump the raw fields of EncounterPokemon and EncounterIntroState at 1.5 s,
// 4 s and 8 s. The same dump from a normal Pokemon (intro finishes) shows which field differs.
static void enc_probe_dump(const char *tname, void *obj) {
    uint8_t *b = (uint8_t *)obj;
    for (int off = 0; off < 0x120; off += 0x20) {
        NSMutableString *h = [NSMutableString string];
        for (int i = 0; i < 0x20; i += 8) {
            uint64_t w = *(uint64_t *)(b + off + i);
            [h appendFormat:@"%016llx ", (unsigned long long)w];
        }
        WLOG(@"probe %s +%03x: %@", tname, off, h);
    }
}
static void enc_probe_tick(void) {
    static void *t_ep = NULL, *t_intro = NULL, *t_ui = NULL;
    static double t0 = 0; static int stage = 0;
    if (!g_qc[QC_FINDOBJ] || !g_qc[QC_STR] || !g_qc[QC_GETTYPE]) return;
    if (!t_ui) t_ui = mt_type("Niantic.Holoholo.Encounter.EncounterUIController, Assembly-CSharp");
    if (!t_ep) t_ep = mt_type("Niantic.Holoholo.Encounter.EncounterPokemon, Assembly-CSharp");
    if (!t_intro) t_intro = mt_type("Niantic.Holoholo.Encounter.EncounterIntroState, Assembly-CSharp");
    if (!looks_like_ptr(t_ui) || !looks_like_ptr(t_ep)) return;
    void *ui = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_ui, NULL);
    double now = CFAbsoluteTimeGetCurrent();
    if (!looks_like_ptr(ui)) { stage = 0; t0 = 0; return; }
    if (stage == 0 && t0 == 0) t0 = now;
    double dt = now - t0;
    double at[3] = { 1.5, 4.0, 8.0 };
    if (stage >= 3 || dt < at[stage]) return;
    WLOG(@"probe: encounter open %.1f s (stage %d)", dt, stage);
    void *ep = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_ep, NULL);
    WLOG(@"probe: EncounterPokemon=%p IntroState=%p", ep, looks_like_ptr(t_intro) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_intro, NULL) : NULL);
    if (looks_like_ptr(ep)) enc_probe_dump("EncounterPokemon", ep);
    if (looks_like_ptr(t_intro)) {
        void *is = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_intro, NULL);
        if (looks_like_ptr(is)) enc_probe_dump("IntroState", is);
    }
    stage++;
}

static void quick_catch_tick(void) {
    if (!g_game_live) return;
    enc_probe_tick();
    if (g_qc_level < QC_UNLOCK_LEVEL) { qc_level_poll(); return; }
    static void *type = NULL;
    if (!type) {
        void *name = ((qc_static1)g_qc[QC_STR])(NULL,
            (void *)"Niantic.Holoholo.Encounter.EncounterUIController, Assembly-CSharp", NULL);
        if (looks_like_ptr(name)) type = ((qc_static1)g_qc[QC_GETTYPE])(NULL, name, NULL);
        if (!looks_like_ptr(type)) { type = NULL; return; }
        WLOG(@"quick catch: EncounterUIController type resolved");
    }
    void *controller = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, type, NULL);
    if (!looks_like_ptr(controller)) { g_qc_controller = NULL; g_qc_clone = NULL; return; }
    if (controller == g_qc_controller && g_qc_clone) return;      // already done for this encounter

    void *ctrl_tr = ((qc_inst0)g_qc[QC_COMP_TR])(controller, NULL);
    if (!looks_like_ptr(ctrl_tr)) return;
    void *path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"UIRoot/RunAway", NULL);
    if (!looks_like_ptr(path)) return;
    void *run_tr = ((qc_inst1)g_qc[QC_FIND])(ctrl_tr, path, NULL);
    if (!looks_like_ptr(run_tr)) { WLOG(@"quick catch: UIRoot/RunAway not found yet"); return; }
    void *run_go = ((qc_inst0)g_qc[QC_COMP_GO])(run_tr, NULL);
    if (!looks_like_ptr(run_go)) return;
    void *clone = ((qc_static1)g_qc[QC_INSTANTIATE])(NULL, run_go, NULL);
    if (!looks_like_ptr(clone)) { WLOG(@"quick catch: Instantiate failed"); return; }
    void *clone_tr = ((qc_inst0)g_qc[QC_GO_TR])(clone, NULL);
    if (!looks_like_ptr(clone_tr)) return;
    ((void (*)(void *, void *, bool, void *))g_qc[QC_SETPARENT])(clone_tr, ctrl_tr, false, NULL);
    ((void (*)(void *, void *))g_qc[QC_LASTSIB])(clone_tr, NULL);
    ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(clone, true, NULL);
    g_qc_controller = controller;
    g_qc_clone = clone;
    WLOG(@"quick catch: Run button pinned for encounter %p", controller);
}

// ----------------------------------------------------------------- mass transfer (no-JIT, 0.35)
// Kanto-style: in Pokemon storage, LONG-PRESS to enter select mode, TAP rows to select,
// LONG-PRESS again for a confirmation, then each Pokemon is released through the game's
// own PokemonBagImpl.ReleasePokemon (same path as a normal transfer, so the bag and candy
// update normally). Row taps are intercepted by redirecting PokemonInventoryList.
// PokemonElementSelected in the method-pointer table (1 entry, 0 direct callers -- it's
// reached through a delegate). Everything else is plain calls, like quick catch.
#define MASS_TRANSFER 1
#include <algorithm>
#include <unordered_set>
#include <string>
#include <unordered_map>
#include <vector>

struct UColor { float r, g, b, a; };

static const QcFn kMt[] = {
    { "PokemonInventoryList.PokemonElementSelected", 0xE7D3C,  0xa9bd57f6 },
    { "PlayerService.get_Instance",                  0xA86B0,  0xa9be4ff4 },
    { "PlayerService.get_PokemonBag",                0xAA010,  0xf9405800 },
    { "PokemonBagImpl.GetPokemon",                   0x26DA50, 0xa9be4ff4 },
    { "PokemonBagImpl.ReleasePokemon",               0x26DCA0, 0xa9bc5ff8 },
    { "Resources.FindObjectsOfTypeAll",              0x8C21F0, 0xa9be4ff4 },
    { "GameObject.GetComponent",                     0x89B13C, 0xa9bd57f6 },
    { "GameObject.get_activeInHierarchy",            0x89B928, 0xa9be4ff4 },
    { "Graphic.get_color",                           0x857A10, 0x2d450400 },
    { "Graphic.set_color",                           0x8562A4, 0xa9be4ff4 },
};
enum { MT_ELEM_SELECTED, MT_PS_INSTANCE, MT_PS_BAG, MT_BAG_GET, MT_BAG_RELEASE, MT_FIND_ALL,
       MT_GETCOMPONENT, MT_ACTIVE, MT_GET_COLOR, MT_SET_COLOR, MT_COUNT };
static void *g_mt[MT_COUNT];

// PokemonProto (0.35, same as 0.29): id_ @0x10, deployedFortId_ (string) @0x30, isEgg_ @0x40, favorite_ @0xA0
// PokemonInventoryList: pokemonData List<DataSetOf<PokemonProto>> @0x50 ; DataSetOf<T>: item @0x28
// RecyclerViewPrototype: BoundIndex @0x30
#define OFF_PROTO_ID       0x10
#define OFF_PROTO_FORT     0x30
#define OFF_PROTO_EGG      0x40
#define OFF_PROTO_FAV      0xA0
#define OFF_INVLIST_DATA   0x50
#define OFF_DATASET_ITEM   0x28
#define OFF_ROW_BOUNDINDEX 0x30

static bool g_mt_ready = false;
static bool g_mt_mode = false;
static std::unordered_set<uint64_t> g_mt_selected;
static std::vector<uint64_t> g_mt_queue;
static size_t g_mt_queue_total = 0;
static std::unordered_map<void *, UColor> g_mt_tinted;       // Image -> original color
static void *g_mt_type_list = NULL, *g_mt_type_gui = NULL, *g_mt_type_row = NULL, *g_mt_type_image = NULL;

static void *mt_type(const char *name) {
    if (!g_qc[QC_STR]) return NULL;
    void *s = ((qc_static1)g_qc[QC_STR])(NULL, (void *)name, NULL);
    return looks_like_ptr(s) ? ((qc_static1)g_qc[QC_GETTYPE])(NULL, s, NULL) : NULL;
}

static bool mt_resolve_types(void) {
    if (!g_mt_type_list)  g_mt_type_list  = mt_type("Niantic.Holoholo.UI.PokemonInventoryList, Assembly-CSharp");
    if (!g_mt_type_gui)   g_mt_type_gui   = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInventoryGuiController, Assembly-CSharp");
    if (!g_mt_type_row)   g_mt_type_row   = mt_type("Niantic.Holoholo.Widget.RecyclerViewPrototype, Assembly-CSharp");
    if (!g_mt_type_image) g_mt_type_image = mt_type("UnityEngine.UI.Image, UnityEngine.UI");
    return looks_like_ptr(g_mt_type_list) && looks_like_ptr(g_mt_type_gui) &&
           looks_like_ptr(g_mt_type_row) && looks_like_ptr(g_mt_type_image);
}

static bool mt_storage_open(void) {
    if (!g_game_live || !mt_resolve_types()) return false;
    return looks_like_ptr(((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_mt_type_gui, NULL));
}

static void *mt_proto_at(void *list, int32_t index) {
    if (!looks_like_ptr(list) || index < 0) return NULL;
    void *data = *(void **)((uint8_t *)list + OFF_INVLIST_DATA);
    if (!looks_like_ptr(data)) return NULL;
    void *items = *(void **)((uint8_t *)data + OFF_LIST_ITEMS);
    int32_t size = *(int32_t *)((uint8_t *)data + OFF_LIST_SIZE);
    if (!looks_like_ptr(items) || index >= size) return NULL;
    void *ds = *(void **)((uint8_t *)items + OFF_ARRAY_DATA + index * 8);
    if (!looks_like_ptr(ds)) return NULL;
    void *proto = *(void **)((uint8_t *)ds + OFF_DATASET_ITEM);
    return looks_like_ptr(proto) ? proto : NULL;
}

// NULL if transferable, else the reason it isn't
static const char *mt_block_reason(void *proto) {
    if (!looks_like_ptr(proto)) return "no pokemon";
    if (*(uint8_t *)((uint8_t *)proto + OFF_PROTO_EGG)) return "egg";
    if (*(uint8_t *)((uint8_t *)proto + OFF_PROTO_FAV)) return "favorite";
    void *fort = *(void **)((uint8_t *)proto + OFF_PROTO_FORT);
    if (looks_like_ptr(fort) && *(int32_t *)((uint8_t *)fort + 0x10) > 0) return "in a gym";
    return NULL;
}

// v84: the tint map is a lookup table only -- the original colour, keyed by Image. It is
// never used as a call target: an il2cpp object held from one frame to the next can be gone
// by the time we touch it (the list is rebuilt whenever the bag changes), which is what made
// the confirm dialog take the game down. Every set_color below is on an Image that the
// current pass just enumerated and found alive.
static void mt_refresh_rows(void);

static void mt_exit_mode(const char *why) {
    if (!g_mt_mode && g_mt_selected.empty() && g_mt_tinted.empty()) return;
    g_mt_selected.clear();
    g_mt_mode = false;
    mt_refresh_rows();                    // restores the live rows, then:
    g_mt_tinted.clear();                  // whatever is left belongs to rows that are gone
    WLOG(@"mass transfer: select mode off (%s)", why);
}

// Tint every visible row whose Pokemon is selected; restore rows that no longer are.
static void mt_refresh_rows(void) {
    if (!mt_storage_open()) {
        if (g_mt_mode || !g_mt_selected.empty() || !g_mt_tinted.empty()) {
            g_mt_tinted.clear();                       // storage closed: those objects are gone
            g_mt_selected.clear();
            g_mt_mode = false;
            WLOG(@"mass transfer: storage closed, selection cleared");
        }
        return;
    }
    if (!g_mt_mode && g_mt_tinted.empty()) return;
    void *list = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_mt_type_list, NULL);
    void *rows = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_mt_type_row, NULL);
    if (!looks_like_ptr(list) || !looks_like_ptr(rows)) return;
    int64_t n = *(int64_t *)((uint8_t *)rows + 0x18);            // Il2CppArray max_length
    if (n < 0 || n > 512) return;
    static void *bg_path = NULL;
    if (!bg_path) bg_path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"HP/Background", NULL);
    int live = 0, with_img = 0, sel_rows = 0;
    for (int64_t i = 0; i < n; i++) {
        void *row = *(void **)((uint8_t *)rows + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(row)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(row, NULL);
        if (!looks_like_ptr(go)) continue;
        if (!((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        live++;
        // v84: tint the row's own card Image (PokemonListPrototype root: RectTransform,
        // CanvasRenderer, CanvasGroup, Image, Button, RecyclerViewPrototype...). The old
        // "HP/Background" target is the stamina slider's backing strip -- it sits under a
        // Mask and is covered by the Fill, so the green was never actually on screen.
        void *img = ((qc_inst1)g_mt[MT_GETCOMPONENT])(go, g_mt_type_image, NULL);
        if (!looks_like_ptr(img)) {                            // fall back to the old target
            void *row_tr = ((qc_inst0)g_qc[QC_COMP_TR])(row, NULL);
            void *bg_tr = (looks_like_ptr(row_tr) && looks_like_ptr(bg_path)) ?
                          ((qc_inst1)g_qc[QC_FIND])(row_tr, bg_path, NULL) : NULL;
            if (looks_like_ptr(bg_tr)) {
                void *bg_go = ((qc_inst0)g_qc[QC_COMP_GO])(bg_tr, NULL);
                if (looks_like_ptr(bg_go)) img = ((qc_inst1)g_mt[MT_GETCOMPONENT])(bg_go, g_mt_type_image, NULL);
            }
        }
        if (!looks_like_ptr(img)) continue;
        with_img++;
        void *proto = mt_proto_at(list, *(int32_t *)((uint8_t *)row + OFF_ROW_BOUNDINDEX));
        bool selected = proto && g_mt_selected.count(*(uint64_t *)((uint8_t *)proto + OFF_PROTO_ID));
        auto it = g_mt_tinted.find(img);
        if (selected) {
            sel_rows++;
            if (it == g_mt_tinted.end()) {
                g_mt_tinted[img] = ((UColor (*)(void *, void *))g_mt[MT_GET_COLOR])(img, NULL);
                it = g_mt_tinted.find(img);
            }
            // re-assert every pass: the list repaints rows itself (disabledColor on rebind)
            // and the Button's tint transition runs over the top, so tinting once didn't hold.
            UColor now = ((UColor (*)(void *, void *))g_mt[MT_GET_COLOR])(img, NULL);
            UColor tint = { 0.35f, 0.95f, 0.45f, it->second.a > 0.05f ? it->second.a : 1.0f };
            if (now.r != tint.r || now.g != tint.g || now.b != tint.b)
                ((void (*)(void *, UColor, void *))g_mt[MT_SET_COLOR])(img, tint, NULL);
        } else if (it != g_mt_tinted.end()) {
            ((void (*)(void *, UColor, void *))g_mt[MT_SET_COLOR])(img, it->second, NULL);
            g_mt_tinted.erase(it);
        }
    }
    static int last_live = -1, last_img = -1, last_sel = -1;
    if (live != last_live || with_img != last_img || sel_rows != last_sel) {
        last_live = live; last_img = with_img; last_sel = sel_rows;
        WLOG(@"mass transfer: rows live=%d with_image=%d selected_visible=%d (selected total=%zu)",
             live, with_img, sel_rows, g_mt_selected.size());
    }
}

// Replacement for PokemonInventoryList.PokemonElementSelected(RecyclerViewPrototype view, int index)
static void (*o_elem_selected)(void *, void *, int32_t, void *);
static void hk_elem_selected(void *self, void *view, int32_t index, void *m) {
    if (!g_mt_mode) { o_elem_selected(self, view, index, m); return; }
    void *proto = mt_proto_at(self, index);
    const char *why = mt_block_reason(proto);
    if (why) {
        ws_haptic_error();
        WLOG(@"mass transfer: row %d not selectable (%s)", index, why);
        return;
    }
    uint64_t uid = *(uint64_t *)((uint8_t *)proto + OFF_PROTO_ID);
    bool now = !g_mt_selected.count(uid);
    if (now) g_mt_selected.insert(uid); else g_mt_selected.erase(uid);
    WLOG(@"mass transfer: row %d %@ %llx (species %d) -> %zu selected", index, now ? @"+" : @"-",
         (unsigned long long)uid, *(int32_t *)((uint8_t *)proto + 0x18), g_mt_selected.size());
    ws_haptic_select();
    mt_refresh_rows();
}

static void mt_release_next(void) {
    if (g_mt_queue.empty()) return;
    if (!g_mt_ready || !g_game_live) return;               // nothing safe to call into yet
    if (!mt_storage_open()) {                             // left storage: drop the rest
        WLOG(@"mass transfer: storage closed with %zu left -- stopping", g_mt_queue.size());
        g_mt_queue.clear();
        g_mt_queue_total = 0;
        return;
    }
    uint64_t uid = g_mt_queue.back();
    g_mt_queue.pop_back();
    size_t done = g_mt_queue_total - g_mt_queue.size();
    void *ps = ((qc_inst0)g_mt[MT_PS_INSTANCE])(NULL, NULL);
    void *bag = looks_like_ptr(ps) ? ((qc_inst0)g_mt[MT_PS_BAG])(ps, NULL) : NULL;
    void *proto = looks_like_ptr(bag) ? ((void *(*)(void *, uint64_t, void *))g_mt[MT_BAG_GET])(bag, uid, NULL) : NULL;
    const char *why = mt_block_reason(proto);
    // the bag looks it up in a Dictionary: make sure we really got the one we asked for
    if (!why && *(uint64_t *)((uint8_t *)proto + OFF_PROTO_ID) != uid) why = "id mismatch";
    if (why) {
        WLOG(@"mass transfer: %zu/%zu skipped %llx (%s)", done, g_mt_queue_total, (unsigned long long)uid, why);
    } else {
        ((qc_inst1)g_mt[MT_BAG_RELEASE])(bag, proto, NULL);
        WLOG(@"mass transfer: %zu/%zu released %llx", done, g_mt_queue_total, (unsigned long long)uid);
    }
    if (g_mt_queue.empty()) {
        WLOG(@"mass transfer: finished (%zu)", g_mt_queue_total);
        g_mt_queue_total = 0;
    }
}

// Unity's own view / controller. Under LiveContainer the key window's rootViewController is
// LiveContainer's launcher UI (a UILayoutContainerView) -- attaching or presenting there is
// wrong (measured v16: alert dismissal killed the game). Ask UnityAppController instead.
static UIView *mt_unity_view(void) {
    id d = [UIApplication sharedApplication].delegate;
    if ([d respondsToSelector:@selector(unityView)]) {
        UIView *v = ((UIView *(*)(id, SEL))objc_msgSend)(d, @selector(unityView));
        if (v) return v;
    }
    // (UIApplication.windows is deprecated on the iOS 15 SDK, but this app is one plain
    // UIKit window and the scene walk buys us nothing -- keep it, quietly.)
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *win in [UIApplication sharedApplication].windows) {
        NSMutableArray *stack = [NSMutableArray arrayWithObject:win];
        while (stack.count) {
            UIView *v = stack.lastObject; [stack removeLastObject];
            if ([NSStringFromClass([v class]) containsString:@"Unity"]) return v;
            [stack addObjectsFromArray:v.subviews];
        }
    }
#pragma clang diagnostic pop
    return nil;
}

static UIViewController *mt_top_controller(void) {
    UIViewController *vc = nil;
    id d = [UIApplication sharedApplication].delegate;
    if ([d respondsToSelector:@selector(rootViewController)])
        vc = ((UIViewController *(*)(id, SEL))objc_msgSend)(d, @selector(rootViewController));
    if (!vc) {
        UIView *uv = mt_unity_view();
        for (UIResponder *r = uv; r; r = r.nextResponder)
            if ([r isKindOfClass:[UIViewController class]]) { vc = (UIViewController *)r; break; }
    }
    while (vc.presentedViewController) vc = vc.presentedViewController;
    return vc;
}

static void mt_present_confirm(void) {
    size_t n = g_mt_selected.size();
    UIAlertController *a = [UIAlertController
        alertControllerWithTitle:n ? [NSString stringWithFormat:@"Transfer %zu Pokémon?", n] : @"No Pokémon selected"
                         message:n ? @"They will be sent to the Professor. You can't undo this." :
                                     @"Tap Pokémon to select them, then long-press again."
                  preferredStyle:UIAlertControllerStyleAlert];
    if (n) {
        [a addAction:[UIAlertAction actionWithTitle:[NSString stringWithFormat:@"Transfer %zu", n]
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction *x) {
            g_mt_queue.assign(g_mt_selected.begin(), g_mt_selected.end());
            g_mt_queue_total = g_mt_queue.size();
            WLOG(@"mass transfer: starting %zu", g_mt_queue_total);
            mt_exit_mode("transfer started");
        }]];
    }
    [a addAction:[UIAlertAction actionWithTitle:@"Clear selection" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) {
        WLOG(@"mass transfer: 'Clear selection' tapped");
        mt_exit_mode("cleared");
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Keep selecting" style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction *x) { WLOG(@"mass transfer: 'Keep selecting' tapped"); }]];
    UIViewController *host = mt_top_controller();
    WLOG(@"mass transfer: confirm dialog on %@ (%zu selected)", NSStringFromClass([host class]), n);
    [host presentViewController:a animated:YES completion:nil];
}

@interface WSMassTransferGesture : NSObject <UIGestureRecognizerDelegate>
- (void)longPress:(UILongPressGestureRecognizer *)g;
@end
@implementation WSMassTransferGesture
- (void)longPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan || !g_mt_ready || !g_mt_queue.empty()) return;
    if (!mt_storage_open()) return;
    if (!g_mt_mode) {
        g_mt_mode = true;
        ws_haptic_impact();
        WLOG(@"mass transfer: select mode ON");
        static bool hinted = false;
        if (!hinted) {
            hinted = true;
            UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Select mode"
                message:@"Tap Pokémon to select them. Long-press again to transfer or clear."
                preferredStyle:UIAlertControllerStyleAlert];
            [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
            [mt_top_controller() presentViewController:a animated:YES completion:nil];
        }
        return;
    }
    mt_present_confirm();
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b {
    return YES;
}
@end

static WSMassTransferGesture *g_mt_gesture_target = nil;

static void mt_install_gesture(void) {
    UIView *v = mt_unity_view();
    if (!v) return;
    for (UIGestureRecognizer *g in v.gestureRecognizers)
        if (g.delegate == g_mt_gesture_target && g_mt_gesture_target) return;      // already on this view
    if (!g_mt_gesture_target) g_mt_gesture_target = [WSMassTransferGesture new];
    UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
        initWithTarget:g_mt_gesture_target action:@selector(longPress:)];
    lp.minimumPressDuration = 0.6;
    lp.cancelsTouchesInView = NO;
    lp.delegate = g_mt_gesture_target;
    [v addGestureRecognizer:lp];
    WLOG(@"mass transfer: long-press installed on %@", NSStringFromClass([v class]));
}

// ----------------------------------------------------------------- IV display (no-JIT, 0.35)
// Appends the IV percentage to each storage row's name, e.g. "Pidgey 91%". The name label
// is the row's "Name" child (PokemonListPrototype prefab, read from the 0.35 assets). The
// game re-binds names when rows are recycled on scroll, so this re-applies on the same
// 0.25 s refresh as the selection tint, and only calls set_text when the label differs.
// UnityEngine.UI.Text: m_Text (string) @0xC0 (0.29 get_text = ldr x0,[x0,#0xc0]; 0.35
// set_text reads the same field). set_text @0x87F9D8. PokemonProto IVs @0x64/0x68/0x6C.
#define IV_DISPLAY 0   // storage-name IV % -- turned off at the user's request (IVs live in Appraise now)
#define OFF_TEXT_STRING  0xC0
#define OFF_PROTO_IV_ATK 0x64
#define OFF_PROTO_IV_DEF 0x68
#define OFF_PROTO_IV_STA 0x6C
static const QcFn kIvSetText = { "Text.set_text", 0x87F9D8, 0xa9bd57f6 };
static void *g_iv_set_text = NULL;
static void *g_iv_type_text = NULL;
static const unichar kIvMarker = 0x2009;   // THIN SPACE: separates the game's name from our " 91%"

static NSString *il2cpp_to_ns(void *s) {
    if (!looks_like_ptr(s)) return nil;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len < 0 || len > 256) return nil;
    return [NSString stringWithCharacters:(const unichar *)((uint8_t *)s + 0x14) length:len];
}

static void iv_apply_row(void *row, void *proto) {
    static void *name_path = NULL;
    if (!name_path) name_path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"Name", NULL);
    if (!looks_like_ptr(name_path) || !looks_like_ptr(g_iv_type_text)) return;
    void *row_tr = ((qc_inst0)g_qc[QC_COMP_TR])(row, NULL);
    void *name_tr = looks_like_ptr(row_tr) ? ((qc_inst1)g_qc[QC_FIND])(row_tr, name_path, NULL) : NULL;
    if (!looks_like_ptr(name_tr)) return;
    void *name_go = ((qc_inst0)g_qc[QC_COMP_GO])(name_tr, NULL);
    void *text = looks_like_ptr(name_go) ? ((qc_inst1)g_mt[MT_GETCOMPONENT])(name_go, g_iv_type_text, NULL) : NULL;
    if (!looks_like_ptr(text)) return;

    NSString *cur = il2cpp_to_ns(*(void **)((uint8_t *)text + OFF_TEXT_STRING));
    if (!cur) return;
    NSRange mark = [cur rangeOfString:[NSString stringWithCharacters:&kIvMarker length:1]];
    NSString *base = mark.location == NSNotFound ? cur : [cur substringToIndex:mark.location];
    NSString *want = base;
    if (looks_like_ptr(proto) && !*(uint8_t *)((uint8_t *)proto + OFF_PROTO_EGG)) {
        int32_t a = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_ATK);
        int32_t d = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_DEF);
        int32_t s = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_STA);
        if (a >= 0 && a <= 15 && d >= 0 && d <= 15 && s >= 0 && s <= 15) {
            int pct = (int)lround((a + d + s) * 100.0 / 45.0);
            want = [NSString stringWithFormat:@"%@%C%d%%", base, kIvMarker, pct];
        }
    }
    if ([want isEqualToString:cur]) return;
    void *ms = ((qc_static1)g_qc[QC_STR])(NULL, (void *)want.UTF8String, NULL);
    if (looks_like_ptr(ms)) ((qc_inst1)g_iv_set_text)(text, ms, NULL);
    // diagnostics: did the label actually take our text? (scroll bug hunt)
    static int samples = 0;
    NSString *after = il2cpp_to_ns(*(void **)((uint8_t *)text + OFF_TEXT_STRING));
    if (samples < 40) {
        samples++;
        WLOG(@"iv display: text %p '%@' -> '%@' (now '%@')", text, cur, want, after);
    }
}

// Walk the visible storage rows once and label each with its IV %.
__attribute__((unused)) static void iv_refresh_rows(void) {
    if (!g_iv_set_text || !mt_storage_open()) return;
    if (!g_iv_type_text) g_iv_type_text = mt_type("UnityEngine.UI.Text, UnityEngine.UI");
    void *list = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_mt_type_list, NULL);
    void *rows = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_mt_type_row, NULL);
    if (!looks_like_ptr(list) || !looks_like_ptr(rows)) return;
    int64_t n = *(int64_t *)((uint8_t *)rows + 0x18);
    if (n < 0 || n > 512) return;
    int labeled = 0;
    for (int64_t i = 0; i < n; i++) {
        void *row = *(void **)((uint8_t *)rows + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(row)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(row, NULL);
        if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        iv_apply_row(row, mt_proto_at(list, *(int32_t *)((uint8_t *)row + OFF_ROW_BOUNDINDEX)));
        labeled++;
    }
    static int last = -1;
    if (labeled != last) { last = labeled; WLOG(@"iv display: %d visible rows labeled", labeled); }
}

__attribute__((unused)) static bool install_iv_display(uintptr_t base) {
    uint32_t w = *(uint32_t *)(base + kIvSetText.rva);
    if (w != kIvSetText.first) {
        WLOG(@"iv display: %s first word %08x != %08x -- OFF", kIvSetText.name, w, kIvSetText.first);
        return false;
    }
    g_iv_set_text = (void *)(base + kIvSetText.rva);
    WLOG(@"iv display: Text.set_text verified");
    return true;
}

// ----------------------------------------------------------------- IVs in the appraisal (no-JIT, 0.35)
// Appraising builds a List<ConversationData> (intro, overall, best stat, size, outro) and hands
// it to IConversationService.PresentConversations(list, bool, team) -- interface slot 3, i.e.
// ConversationService::PresentConversations(3 params) @0xCAB08 (1 table entry, 0 direct
// callers). We redirect it: when the lines are an appraisal (ConvoKey starts "appraise_"),
// append one more line with the exact IVs, then present as normal.
// Addresses come from 0.35's OWN metadata: method-pointer table @file 0x1C58E28,
// Il2CppMethodDefinition.methodIndex @+24 (see memory pogo-windstock-mods).
//   ConversationData: ConvoKey @0x10, Texture @0x18, Args @0x20; .ctor(this,key,texture,args) @0xC91DC
//   PokemonInfoPanel.get_PokemonProto = ldr x0,[x0,#0x2F0]
#define APPRAISAL_IVS 1
#define WS_KEY_PREFIX "ws:"   // i18n keys starting with this are rendered as literal text (see below)
#define OFF_CONVO_KEY     0x10
#define OFF_CONVO_TEXTURE 0x18
#define OFF_CONVO_ARGS    0x20
#define OFF_INFOPANEL_PROTO 0x2F0
#define OFF_LIST_VERSION  0x1C

static const QcFn kAp[] = {
    { "ConversationService.PresentConversations(3)", 0xCAB08, 0xa9bb67fa },
    { "ConversationData.ctor",                       0xC91DC, 0xa9bd57f6 },
    { "FormatterServices.GetUninitializedObject",    0x9E64F0, 0xa9be4ff4 },
    { "PokemonInfoPanel.get_PokemonProto",           0xDA214, 0xf9417800 },
};
enum { AP_PRESENT3, AP_CONVO_CTOR, AP_UNINIT, AP_PANEL_PROTO, AP_COUNT };
static void *g_ap[AP_COUNT];
static void *g_ap_type_convo = NULL, *g_ap_type_panel = NULL;

static bool il2cpp_string_has_prefix(void *s, const char *prefix) {
    if (!looks_like_ptr(s)) return false;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    int32_t n = (int32_t)strlen(prefix);
    if (len < n) return false;
    uint16_t *c = (uint16_t *)((uint8_t *)s + 0x14);
    for (int32_t i = 0; i < n; i++) if (c[i] != (uint16_t)prefix[i]) return false;
    return true;
}

static void (*o_present3)(void *, void *, bool, int32_t, void *);
static void hk_present3(void *self, void *list, bool flag, int32_t team, void *m) {
    @try {
        void *items = looks_like_ptr(list) ? *(void **)((uint8_t *)list + OFF_LIST_ITEMS) : NULL;
        int32_t size = looks_like_ptr(list) ? *(int32_t *)((uint8_t *)list + OFF_LIST_SIZE) : 0;
        void *first = (looks_like_ptr(items) && size > 0) ? *(void **)((uint8_t *)items + OFF_ARRAY_DATA) : NULL;
        if (looks_like_ptr(first) && il2cpp_string_has_prefix(*(void **)((uint8_t *)first + OFF_CONVO_KEY), "appraise_")) {
            if (!g_ap_type_convo) g_ap_type_convo = mt_type("Niantic.Holoholo.UI.Conversations.ConversationData, Assembly-CSharp");
            if (!g_ap_type_panel) g_ap_type_panel = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInfoPanel, Assembly-CSharp");
            void *panel = looks_like_ptr(g_ap_type_panel) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_ap_type_panel, NULL) : NULL;
            void *proto = looks_like_ptr(panel) ? ((qc_inst0)g_ap[AP_PANEL_PROTO])(panel, NULL) : NULL;
            if (looks_like_ptr(proto)) {
                int32_t a = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_ATK);
                int32_t d = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_DEF);
                int32_t s = *(int32_t *)((uint8_t *)proto + OFF_PROTO_IV_STA);
                int pct = (int)lround((a + d + s) * 100.0 / 45.0);
                char line[128];
                snprintf(line, sizeof line, WS_KEY_PREFIX "Attack %d / Defense %d / Stamina %d (%d percent)", a, d, s, pct);
                void *key = ((qc_static1)g_qc[QC_STR])(NULL, (void *)line, NULL);
                void *last = *(void **)((uint8_t *)items + OFF_ARRAY_DATA + (size - 1) * 8);
                int64_t cap = *(int64_t *)((uint8_t *)items + 0x18);
                void *obj = NULL;                  // no new line object needed any more
                // v49: the appraisal shows ONLY the IVs -- the team leader's comments are
                // dropped. Reuse the first line (its portrait/args are valid), give it the
                // IV text, and cut the list down to that one line.
                (void)obj; (void)last; (void)cap;
                void *first = *(void **)((uint8_t *)items + OFF_ARRAY_DATA);
                if (looks_like_ptr(first) && looks_like_ptr(key)) {
                    *(void **)((uint8_t *)first + OFF_CONVO_KEY) = key;
                    *(int32_t *)((uint8_t *)list + OFF_LIST_SIZE) = 1;
                    *(int32_t *)((uint8_t *)list + OFF_LIST_VERSION) += 1;
                    WLOG(@"appraisal: IVs only -- %d/%d/%d (%d%%), %d leader line(s) dropped",
                         a, d, s, pct, size);
                }
            } else {
                WLOG(@"appraisal: PokemonInfoPanel/proto not found -- lines unchanged");
            }
        }
    } @catch (NSException *e) {
        WLOG(@"appraisal: exception %@ -- lines unchanged", e);
    }
    WLOG(@"appraisal: -> game PresentConversations (list %p size %d)", list,
         looks_like_ptr(list) ? *(int32_t *)((uint8_t *)list + OFF_LIST_SIZE) : -1);
    o_present3(self, list, flag, team, m);
    WLOG(@"appraisal: <- game PresentConversations returned");
}

// ---- i18n passthrough for our own lines ----
// ConversationGuiController.ShowConversation asks II18n.HasText(key) (slot 3) before each page
// and SKIPS the page when the key is unknown (measured v19: our appended line never rendered),
// then renders II18n.TextFormat(key, args) (slot 2). Redirect I18n's Text / TextFormat /
// HasText (each 1 table entry, 0 direct callers): a key starting "ws:" is literal text.
static const QcFn kI18n[] = {
    { "I18n.Text",       0x2711B8, 0xa9bd57f6 },
    { "I18n.TextFormat", 0x2712CC, 0xa9bd57f6 },
    { "I18n.HasText",    0x2714DC, 0xa9bd57f6 },
};
static void *(*o_i18n_text)(void *, void *, void *);
static void *(*o_i18n_textformat)(void *, void *, void *, void *);
static bool  (*o_i18n_hastext)(void *, void *, void *);

// Conversation lines are multi-page: the GUI asks HasText("key|1"), "key|2", ... and keeps
// adding pages while the answer is true (measured v21: answering true for every "ws:" key
// built pages forever and froze the game). So a "ws:" line is exactly ONE page.
//   ws_page("ws:foo|3") -> 3 ; ws_page("ws:foo") -> 0 (no page suffix)
static int ws_page(NSString *k) {
    NSRange bar = [k rangeOfString:@"|" options:NSBackwardsSearch];
    if (bar.location == NSNotFound) return 0;
    NSString *tail = [k substringFromIndex:bar.location + 1];
    return tail.length && [tail rangeOfCharacterFromSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]].location == NSNotFound
           ? tail.intValue : 0;
}

// managed "ws:<text>[|N]" -> managed "<text>"
static void *ws_literal(void *key) {
    NSString *k = il2cpp_to_ns(key);
    if (!k || ![k hasPrefix:@WS_KEY_PREFIX]) return NULL;
    NSString *body = [k substringFromIndex:strlen(WS_KEY_PREFIX)];
    if (ws_page(k) > 0) body = [body substringToIndex:[body rangeOfString:@"|" options:NSBackwardsSearch].location];
    return ((qc_static1)g_qc[QC_STR])(NULL, (void *)body.UTF8String, NULL);
}
static int g_ws_log = 0;   // cap diagnostic lines for ws: keys
static void *hk_i18n_text(void *self, void *key, void *m) {
    if (il2cpp_string_has_prefix(key, WS_KEY_PREFIX)) {
        void *s = ws_literal(key);
        if (g_ws_log++ < 30) WLOG(@"i18n: Text(%@) -> %p", il2cpp_to_ns(key), s);
        if (s) return s;
    }
    return o_i18n_text(self, key, m);
}
static void *hk_i18n_textformat(void *self, void *key, void *args, void *m) {
    if (il2cpp_string_has_prefix(key, WS_KEY_PREFIX)) {
        void *s = ws_literal(key);
        if (g_ws_log++ < 30) WLOG(@"i18n: TextFormat(%@, args %p) -> %p '%@'", il2cpp_to_ns(key), args, s, il2cpp_to_ns(s));
        if (s) return s;
    }
    return o_i18n_textformat(self, key, args, m);
}
static bool hk_i18n_hastext(void *self, void *key, void *m) {
    if (il2cpp_string_has_prefix(key, WS_KEY_PREFIX)) {
        int page = ws_page(il2cpp_to_ns(key));
        bool has = page <= 1;               // bare key or page 1 only
        if (g_ws_log++ < 30) WLOG(@"i18n: HasText(%@) -> %d", il2cpp_to_ns(key), has);
        return has;
    }
    return o_i18n_hastext(self, key, m);
}

static bool install_i18n_passthrough(uintptr_t base, uintptr_t dstart, size_t dsize) {
    for (const QcFn &f : kI18n) {
        uint32_t w = *(uint32_t *)(base + f.rva);
        if (w != f.first) { WLOG(@"i18n: %s first word %08x != %08x -- OFF", f.name, w, f.first); return false; }
    }
    o_i18n_text       = (void *(*)(void *, void *, void *))(base + kI18n[0].rva);
    o_i18n_textformat = (void *(*)(void *, void *, void *, void *))(base + kI18n[1].rva);
    o_i18n_hastext    = (bool (*)(void *, void *, void *))(base + kI18n[2].rva);
    bool ok = redirect_method_pointer(dstart, dsize, base + kI18n[0].rva, (uintptr_t)&hk_i18n_text, "I18n.Text");
    ok &= redirect_method_pointer(dstart, dsize, base + kI18n[1].rva, (uintptr_t)&hk_i18n_textformat, "I18n.TextFormat");
    ok &= redirect_method_pointer(dstart, dsize, base + kI18n[2].rva, (uintptr_t)&hk_i18n_hastext, "I18n.HasText");
    WLOG(@"i18n: ws: literal keys %@", ok ? @"armed" : @"PARTIAL");
    return ok;
}

static bool install_appraisal_ivs(uintptr_t base, uintptr_t dstart, size_t dsize) {
    if (!install_i18n_passthrough(base, dstart, dsize)) return false;
    for (int i = 0; i < AP_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kAp[i].rva);
        if (w != kAp[i].first) {
            WLOG(@"appraisal: %s first word %08x != %08x -- OFF", kAp[i].name, w, kAp[i].first);
            return false;
        }
        g_ap[i] = (void *)(base + kAp[i].rva);
    }
    o_present3 = (void (*)(void *, void *, bool, int32_t, void *))g_ap[AP_PRESENT3];
    if (!redirect_method_pointer(dstart, dsize, base + kAp[AP_PRESENT3].rva,
                                 (uintptr_t)&hk_present3, "PresentConversations(3)")) return false;
    WLOG(@"appraisal: IV line armed");
    return true;
}


static bool install_mass_transfer(uintptr_t base, const char *version, bool qc_ok,
                                  uintptr_t dstart, size_t dsize) {
    if (!qc_ok) { WLOG(@"mass transfer: needs the quick-catch call table -- off"); return false; }
    if (strcmp(version, "0.35") != 0) { WLOG(@"mass transfer: 0.35 only -- off on %s", version); return false; }
    for (int i = 0; i < MT_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kMt[i].rva);
        if (w != kMt[i].first) {
            WLOG(@"mass transfer: %s @0x%lx first word %08x != %08x -- OFF", kMt[i].name,
                 (unsigned long)kMt[i].rva, w, kMt[i].first);
            return false;
        }
        g_mt[i] = (void *)(base + kMt[i].rva);
    }
    o_elem_selected = (void (*)(void *, void *, int32_t, void *))g_mt[MT_ELEM_SELECTED];
    if (!redirect_method_pointer(dstart, dsize, base + kMt[MT_ELEM_SELECTED].rva,
                                 (uintptr_t)&hk_elem_selected, "PokemonElementSelected")) return false;
    WLOG(@"mass transfer: %d game functions verified", MT_COUNT);
    return true;
}

// ----------------------------------------------------------------- custom sound packs (no-JIT, 0.35)
// A pack is a folder Documents/SoundPacks/<name>/ holding <clipname>.<mp3|m4a|wav|caf|aac>.
// When a sound effect plays, if the active pack has a file matching the clip's name, we play
// that file (AVAudioPlayer) and skip the game's sound. The game reaches every SFX through two
// Unity engine functions -- AudioSource.Play and AudioSource.PlayOneShot -- via il2cpp
// "internal call" thunks that cache the resolved native pointer in a writable __DATA slot on
// first use. We wait for those slots to fill, keep the real pointer, and drop our own
// function into the slot -- DATA write only (no-JIT safe), like the method-pointer redirects.
//   Play(UInt64)              cache slot RVA 0x1F24158   native (self, ulong delay)
//   PlayOneShot(clip,float)   cache slot RVA 0x1F24178   native (self, clip, float vol)
//   set_clip(clip)            cache slot RVA 0x1F24150   native (self, clip)  -- tracks source->clip
// The AudioSourceExt.PlaySFX/PlayUISFX helpers have dozens of direct callers, so they can't be
// method-table redirected -- hence going one level down to these icall slots.
#define SOUND_PACKS 1
#define RVA_SLOT_SETCLIP     0x1F24150
#define RVA_SLOT_PLAY        0x1F24158
#define RVA_SLOT_PLAYONESHOT 0x1F24178

static NSString *g_pack = nil;                            // active pack folder, nil = default (stock)
static std::unordered_map<void *, void *> g_src_clip;    // AudioSource -> its last-set AudioClip
static NSMutableArray<AVAudioPlayer *> *g_sfx_pool = nil;

// The SoundPacks folder in Documents. Tolerant of spelling/case/spacing so a folder named
// "SoundPacks", "soundspacks", "Sound Packs", etc. all work; falls back to "SoundPacks".
static NSString *sound_packs_dir(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *n in [fm contentsOfDirectoryAtPath:docs error:nil] ?: @[]) {
        NSString *norm = [[n lowercaseString] stringByReplacingOccurrencesOfString:@" " withString:@""];
        if ([norm isEqualToString:@"soundpacks"] || [norm isEqualToString:@"soundspacks"]) {
            BOOL dir = NO;
            NSString *p = [docs stringByAppendingPathComponent:n];
            if ([fm fileExistsAtPath:p isDirectory:&dir] && dir) return p;
        }
    }
    return [docs stringByAppendingPathComponent:@"SoundPacks"];
}
static NSArray<NSString *> *list_sound_packs(void) {
    NSFileManager *fm = [NSFileManager defaultManager];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *n in [fm contentsOfDirectoryAtPath:sound_packs_dir() error:nil] ?: @[]) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:[sound_packs_dir() stringByAppendingPathComponent:n] isDirectory:&dir] && dir)
            [out addObject:n];
    }
    return [out sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)];
}
static NSString *pack_pref_path(void) {
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    return [docs stringByAppendingPathComponent:@"windstock_pack.txt"];
}
static void load_pack_pref(void) {
    NSString *p = [NSString stringWithContentsOfFile:pack_pref_path() encoding:NSUTF8StringEncoding error:nil];
    p = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    g_pack = (p.length && [list_sound_packs() containsObject:p]) ? p : nil;
}

// URL of the pack file overriding a given clip name, or nil
// v27: forgiving match -- index every audio file anywhere under the pack folder (subfolders
// too) by its lowercased name with ALL audio extensions stripped, so "SE_GO_MAIN_BALL.MP3",
// "se_go_main_ball.mp3.mp3" or "sfx/se_go_main_ball.wav" all match clip se_go_main_ball.
// The index is rebuilt when the pack changes and logged once so a naming mistake is visible.
static NSString *audio_stem(NSString *file) {
    NSSet *exts = [NSSet setWithArray:@[@"mp3", @"m4a", @"wav", @"caf", @"aac", @"aif", @"aiff"]];
    NSString *s = file.lastPathComponent.lowercaseString;
    while ([exts containsObject:s.pathExtension]) s = s.stringByDeletingPathExtension;
    return [s stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
}
static int g_pack_gen = 0;      // bumped when packs are downloaded, so the file index reloads
static NSURL *pack_clip_url(const char *clipName) {
    if (!g_pack || !clipName || !*clipName) return nil;
    static NSString *indexed = nil; static NSDictionary<NSString *, NSString *> *index = nil;
    static int indexed_gen = -1;
    @synchronized ([NSFileManager class]) {
        if (![indexed isEqualToString:g_pack] || indexed_gen != g_pack_gen) {
            indexed_gen = g_pack_gen;
            NSString *root = [sound_packs_dir() stringByAppendingPathComponent:g_pack];
            NSMutableDictionary *m = [NSMutableDictionary dictionary];
            NSMutableArray *skipped = [NSMutableArray array];
            NSDirectoryEnumerator *en = [[NSFileManager defaultManager] enumeratorAtPath:root];
            for (NSString *rel in en) {
                if ([en.fileAttributes[NSFileType] isEqualToString:NSFileTypeDirectory]) continue;
                NSString *stem = audio_stem(rel);
                if ([stem isEqualToString:rel.lastPathComponent.lowercaseString]) { [skipped addObject:rel]; continue; }
                m[stem] = [root stringByAppendingPathComponent:rel];
            }
            index = m; indexed = g_pack;
            WLOG(@"sound packs: pack '%@' at %@ -> %lu audio file(s): %@", g_pack, root,
                 (unsigned long)m.count, [m.allKeys sortedArrayUsingSelector:@selector(compare:)]);
            if (skipped.count) WLOG(@"sound packs: ignored (not an audio file name): %@", skipped);
        }
        NSString *p = index[[@(clipName) lowercaseString]];
        return p ? [NSURL fileURLWithPath:p] : nil;
    }
}
static const char *clip_name_c(void *clip) {
    if (!looks_like_ptr(clip) || !g_get_name) return NULL;
    void *s = g_get_name(clip, NULL);
    if (!looks_like_ptr(s)) return NULL;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len <= 0 || len > 96) return NULL;
    static char buf[128];
    uint16_t *c = (uint16_t *)((uint8_t *)s + 0x14);
    for (int32_t i = 0; i < len; i++) buf[i] = (char)c[i];
    buf[len] = 0;
    return buf;
}
// play a pack file for this clip; returns true if we handled it (game should stay silent)
// v26 diagnostics: log each distinct clip the game plays once (name, via which call, and
// whether the active pack has a file for it) -- shows whether the hooks fire at all and
// which names a pack must use.
static void sfx_note(const char *via, void *clip, const char *nm, NSURL *url) {
    static NSMutableSet<NSString *> *seen; static int unnamed = 0;
    NSString *key = [NSString stringWithFormat:@"%s|%s|%@", via, nm ?: "?", g_pack ?: @""];
    @synchronized ([NSFileManager class]) {
        if (!seen) seen = [NSMutableSet set];
        if ([seen containsObject:key]) return;
        if (!nm && ++unnamed > 5) return;
        [seen addObject:key];
    }
    WLOG(@"sound packs: %s clip=%p name=%s pack=%@ -> %@", via, clip, nm ?: "(none)",
         g_pack ?: @"default", url ? url.lastPathComponent : @"no file");
}
static bool sfx_override(void *clip, const char *via) {
    if (!clip || is_music_clip(clip)) return false;   // music is replaced by refresh(), not here
    if (!game_pref_enabled(PREF_SFX_ENABLED)) return false;   // Settings > Sound Effects off: the game mutes its own
    const char *nm = clip_name_c(clip);
    NSURL *url = nm ? pack_clip_url(nm) : nil;
    sfx_note(via, clip, nm, url);
    if (!url) return false;
    NSError *err = nil;
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
    if (!p) { WLOG(@"sound packs: %@ failed to load: %@", url.lastPathComponent, err); return false; }
    if (!g_sfx_pool) g_sfx_pool = [NSMutableArray array];
    [g_sfx_pool addObject:p];
    while (g_sfx_pool.count > 8) [g_sfx_pool removeObjectAtIndex:0];   // keep recent players alive
    [p play];
    return true;
}

static void (*o_as_setclip)(void *, void *);
static void hk_as_setclip(void *self, void *clip) {
    if (looks_like_ptr(self)) g_src_clip[self] = clip;
    o_as_setclip(self, clip);
}
static void (*o_as_play)(void *, uint64_t);
static void hk_as_play(void *self, uint64_t delay) {
    void *clip = (looks_like_ptr(self) && g_src_clip.count(self)) ? g_src_clip[self] : NULL;
    if (sfx_override(clip, "Play")) return;      // pack sound played; skip the game's
    o_as_play(self, delay);
}
static void (*o_as_playoneshot)(void *, void *, float);
static void hk_as_playoneshot(void *self, void *clip, float vol) {
    // v208: a Gen 2 cry (pv152+) has no clip in the 0.35 resources, so the game passes NULL. The
    // engine call throws on that, which killed EncounterIntroState (camera stuck at ground level).
    if (!clip) {
        static int nulls = 0;
        if (nulls++ < 5) WLOG(@"sound: PlayOneShot with a NULL clip skipped (%d)", nulls);
        return;
    }
    if (sfx_override(clip, "PlayOneShot")) return;
    o_as_playoneshot(self, clip, vol);
}

// swap one icall cache slot once it has been resolved (non-zero). Returns true when done.
static bool swap_icall_slot(uintptr_t base, uintptr_t rva, void *replacement, void **orig, const char *label) {
    if (*orig) return true;                       // already swapped
    uintptr_t *slot = (uintptr_t *)(base + rva);
    if (*slot == 0) return false;                 // not resolved yet
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)vm_page_mask;
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) {
        static int warned = 0;
        if (warned++ < 3) WLOG(@"sound packs: %s slot %p vm_protect failed (%d) -- not swapped", label, slot, kr);
        return false;
    }
    *orig = (void *)*slot;
    *slot = (uintptr_t)replacement;
    WLOG(@"sound packs: %s icall slot swapped (orig %p)", label, *orig);
    return true;
}
static void sound_packs_tick(uintptr_t base) {
    static bool a = false, b = false, c = false;
    if (!a) a = swap_icall_slot(base, RVA_SLOT_SETCLIP,     (void *)hk_as_setclip,     (void **)&o_as_setclip,     "set_clip");
    if (!b) b = swap_icall_slot(base, RVA_SLOT_PLAY,        (void *)hk_as_play,        (void **)&o_as_play,        "Play");
    if (!c) c = swap_icall_slot(base, RVA_SLOT_PLAYONESHOT, (void *)hk_as_playoneshot, (void **)&o_as_playoneshot, "PlayOneShot");
}

// Settings picker: redirect SettingsGuiController.ClickAbout (1 table entry, 0 direct callers)
// to an action sheet listing Default + packs (+ the real About page).
static const QcFn kClickAbout = { "SettingsGuiController.ClickAbout", 0xECF94, 0xa9be4ff4 };
static void (*o_click_about)(void *, void *);
// v50: pull packs built in the World Manager (work/server/soundpacks.py) into
// Documents/SoundPacks. A pack folder we created carries a ".from_server" marker, so a
// re-download also removes sounds deleted on the server -- packs you copied in yourself
// are never touched.
#define SOUNDPACK_URL @"https://pgorelease.nianticlabs.com/soundpacks/"
static void sp_present(NSString *title, NSString *msg) {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:title message:msg
                                                        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [mt_top_controller() presentViewController:a animated:YES completion:nil];
}
static NSString *sp_url_part(NSString *s) {
    return [s stringByAddingPercentEncodingWithAllowedCharacters:NSCharacterSet.URLPathAllowedCharacterSet];
}
static void sp_download_all(void) {
    NSURL *idx = [NSURL URLWithString:[SOUNDPACK_URL stringByAppendingString:@"index.json"]];
    WLOG(@"sound packs: downloading pack list from %@", idx);
    [[[NSURLSession sharedSession] dataTaskWithURL:idx
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        NSDictionary *j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        NSArray *packs = [j isKindOfClass:[NSDictionary class]] ? j[@"packs"] : nil;
        if (![packs isKindOfClass:[NSArray class]]) {
            WLOG(@"sound packs: pack list failed: %@", e.localizedDescription ?: @"bad reply");
            dispatch_async(dispatch_get_main_queue(), ^{
                sp_present(@"Couldn't reach the server",
                           e.localizedDescription ?: @"The server didn't send a pack list.");
            });
            return;
        }
        NSFileManager *fm = [NSFileManager defaultManager];
        NSString *root = sound_packs_dir();
        [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:nil];
        dispatch_group_t group = dispatch_group_create();
        __block int got = 0, kept = 0, failed = 0, removed = 0;
        NSObject *tally = [NSObject new];
        for (NSDictionary *pk in packs) {
            NSString *name = [pk isKindOfClass:[NSDictionary class]] ? pk[@"name"] : nil;
            NSArray *files = [pk isKindOfClass:[NSDictionary class]] ? pk[@"files"] : nil;
            if (![name isKindOfClass:[NSString class]] || !name.length || [name containsString:@"/"]) continue;
            NSString *dir = [root stringByAppendingPathComponent:name];
            [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
            [@"" writeToFile:[dir stringByAppendingPathComponent:@".from_server"] atomically:YES
                    encoding:NSUTF8StringEncoding error:nil];
            NSMutableSet *want = [NSMutableSet setWithObject:@".from_server"];
            for (NSDictionary *f in ([files isKindOfClass:[NSArray class]] ? files : @[])) {
                NSString *file = f[@"file"];
                if (![file isKindOfClass:[NSString class]] || [file containsString:@"/"]) continue;
                [want addObject:file];
                NSString *dst = [dir stringByAppendingPathComponent:file];
                long long size = [f[@"size"] longLongValue];
                NSNumber *have = [fm attributesOfItemAtPath:dst error:nil][NSFileSize];
                if (have && have.longLongValue == size) { @synchronized (tally) { kept++; } continue; }
                NSURL *u = [NSURL URLWithString:[NSString stringWithFormat:@"%@file/%@/%@", SOUNDPACK_URL,
                                                 sp_url_part(name), sp_url_part(file)]];
                dispatch_group_enter(group);
                [[[NSURLSession sharedSession] downloadTaskWithURL:u
                    completionHandler:^(NSURL *tmp, NSURLResponse *resp, NSError *err) {
                    NSInteger code = [resp isKindOfClass:[NSHTTPURLResponse class]] ?
                                     ((NSHTTPURLResponse *)resp).statusCode : 0;
                    BOOL ok = tmp && !err && code == 200;
                    if (ok) {
                        [fm removeItemAtPath:dst error:nil];
                        ok = [fm moveItemAtURL:tmp toURL:[NSURL fileURLWithPath:dst] error:nil];
                    }
                    @synchronized (tally) { if (ok) got++; else failed++; }
                    dispatch_group_leave(group);
                }] resume];
            }
            // sounds removed on the server go away here too (server-made packs only)
            for (NSString *old in [fm contentsOfDirectoryAtPath:dir error:nil] ?: @[]) {
                if (![want containsObject:old]) {
                    [fm removeItemAtPath:[dir stringByAppendingPathComponent:old] error:nil];
                    removed++;
                }
            }
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{
            g_pack_gen++;
            refresh();
            WLOG(@"sound packs: download done -- %d new, %d unchanged, %d removed, %d failed (%lu pack(s))",
                 got, kept, removed, failed, (unsigned long)packs.count);
            sp_present(failed ? @"Some sounds didn't download" : @"Sound packs updated",
                       [NSString stringWithFormat:@"%lu pack(s) from the server.\n%d sound(s) downloaded, %d already up to date%@%@.\nOpen About again to pick one.",
                        (unsigned long)packs.count, got, kept,
                        removed ? [NSString stringWithFormat:@", %d removed", removed] : @"",
                        failed ? [NSString stringWithFormat:@", %d failed", failed] : @""]);
        });
    }] resume];
}

static bool g_sp_on = false;     // sound pack picker on About
static void *ls_row_clicked(void);
static void *ls_launcher_button(void), *ls_keep_ball_button(void);
static void ls_return_to_launcher(void);
static void kb_toggle(void);

static void hk_click_about(void *self, void *m) {
    // v123: the "Back to Launcher" row is a copy of About, so it lands here too
    // v166: and so is the "Keep Ball" row
    void *row = ls_row_clicked();
    if (row && row == ls_launcher_button()) { ls_return_to_launcher(); return; }
    if (row && row == ls_keep_ball_button()) { kb_toggle(); return; }
    if (!g_sp_on) { o_click_about(self, m); return; }
    // log what we can actually see, so a wrong folder name is obvious
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    WLOG(@"sound packs: Documents = %@", [[NSFileManager defaultManager] contentsOfDirectoryAtPath:docs error:nil]);
    WLOG(@"sound packs: dir = %@ -> packs %@", sound_packs_dir(), list_sound_packs());
    void (^pick)(NSString *) = ^(NSString *name) {
        g_pack = name;
        [(name ?: @"") writeToFile:pack_pref_path() atomically:YES encoding:NSUTF8StringEncoding error:nil];
        WLOG(@"sound packs: active pack -> %@", name ?: @"(default)");
        refresh();   // swap the music that is playing right now
    };
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Windstock Sound Pack"
                              message:@"Choose which sounds the game uses."
                       preferredStyle:UIAlertControllerStyleActionSheet];
    [a addAction:[UIAlertAction actionWithTitle:(g_pack ? @"Default sounds" : @"Default sounds  ✓")
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { pick(nil); }]];
    for (NSString *name in list_sound_packs()) {
        NSString *title = [g_pack isEqualToString:name] ? [name stringByAppendingString:@"  ✓"] : name;
        [a addAction:[UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction *x) { pick(name); }]];
    }
    if (list_sound_packs().count == 0)
        [a addAction:[UIAlertAction actionWithTitle:@"(no packs yet -- download them below)"
                                              style:UIAlertActionStyleDefault handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"Download packs from server" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { sp_download_all(); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Open About page" style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction *x) { o_click_about(self, m); }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    UIViewController *host = mt_top_controller();
    if (a.popoverPresentationController && host.view) {   // iPad: anchor the sheet
        a.popoverPresentationController.sourceView = host.view;
        a.popoverPresentationController.sourceRect =
            CGRectMake(host.view.bounds.size.width / 2, host.view.bounds.size.height / 2, 1, 1);
    }
    [host presentViewController:a animated:YES completion:nil];
}

// ClickAbout is redirected once, for whichever of the sound pack picker and the launcher
// row wants it; hk_click_about sorts out which one a tap was for.
static bool install_click_about(uintptr_t base, uintptr_t dstart, size_t dsize) {
    static int done = -1;
    if (done >= 0) return done;
    uint32_t w = *(uint32_t *)(base + kClickAbout.rva);
    if (w != kClickAbout.first) { WLOG(@"settings: ClickAbout %08x != %08x -- not hooked", w, kClickAbout.first); return done = 0; }
    o_click_about = (void (*)(void *, void *))(base + kClickAbout.rva);
    redirect_method_pointer(dstart, dsize, base + kClickAbout.rva, (uintptr_t)&hk_click_about, "ClickAbout");
    return done = 1;
}

static bool install_sound_packs(uintptr_t base, uintptr_t dstart, size_t dsize) {
    load_pack_pref();
    if (!install_click_about(base, dstart, dsize)) { WLOG(@"sound packs: picker OFF"); return false; }
    g_sp_on = true;
    WLOG(@"sound packs: picker armed (active: %@); %lu pack(s)", g_pack ?: @"default", (unsigned long)list_sound_packs().count);
    return true;
}

// ----------------------------------------------------------------- v123: Back to Launcher
// A row at the bottom of Settings that pauses the game and shows the Windstock Launcher
// (only when the launcher is the host; it posts the swap -- WSGuestLoader). The Settings list
// (SettingsGui/Content/ScrollPanel/Viewport/Content) is a VerticalLayoutGroup, so a copy of
// its About row parented to it and made the last sibling becomes a real row at the bottom,
// same look, same press animation. The copy keeps About's click (ClickAbout), so the About
// hook tells the two apart by what Unity's EventSystem just selected: a Button selects
// itself on pointer-down (EventSystem.m_CurrentSelected @0x40).
static const QcFn kSetText = { "Text.set_text", 0x87F9D8, 0xa9bd57f6 };
#define OFF_EVENTSYSTEM_SELECTED 0x40
static bool g_ls_on = false;          // Back to Launcher row wanted (launcher is the host)
static bool g_kb_row_on = false;      // v166: Keep Ball row wanted
static void *g_ls_ctrl = NULL;        // SettingsGuiController the rows were added to
static void *g_ls_button = NULL;      // the copy's Button GameObject (what gets selected)
static void *g_ls_text = NULL;        // the copy's Text component
static void *g_kb_button = NULL;      // v166: same for the Keep Ball row
static void *g_kb_text = NULL;
static int g_ls_relabel = 0;          // ticks left to keep the labels (Auto_Translate re-applies)
static void *g_ls_set_text = NULL;
static void *g_ls_type_ctrl = NULL, *g_ls_type_text = NULL, *g_ls_type_es = NULL;
static bool kb_enabled(void);
static void *ls_launcher_button(void) { return g_ls_button; }
static void *ls_keep_ball_button(void) { return g_kb_button; }

// the row Button the EventSystem just selected (a Button selects itself on pointer-down)
static void *ls_row_clicked(void) {
    if (!g_ls_button && !g_kb_button) return NULL;
    if (!g_ls_type_es) g_ls_type_es = mt_type("UnityEngine.EventSystems.EventSystem, UnityEngine.UI");
    void *es = looks_like_ptr(g_ls_type_es) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_ls_type_es, NULL) : NULL;
    void *sel = looks_like_ptr(es) ? *(void **)((uint8_t *)es + OFF_EVENTSYSTEM_SELECTED) : NULL;
    WLOG(@"settings rows: About/row tap -- selected %p, launcher %p, keep ball %p", sel, g_ls_button, g_kb_button);
    return sel;
}

static void ls_return_to_launcher(void) {
    WLOG(@"launcher row: Back to Launcher");
    [[NSNotificationCenter defaultCenter] postNotificationName:@"WSReturnToLauncher" object:nil];
}

static void ls_text(void *text, const char *label) {
    void *str = ((qc_static1)g_qc[QC_STR])(NULL, (void *)label, NULL);
    if (looks_like_ptr(str) && looks_like_ptr(text))
        ((void (*)(void *, void *, void *))g_ls_set_text)(text, str, NULL);
}

static void ls_set_label(void) {
    if (g_ls_text) ls_text(g_ls_text, "Back to Launcher");
    if (g_kb_text) ls_text(g_kb_text, kb_enabled() ? "Keep Ball: ON" : "Keep Ball: OFF");
}

// A copy of the About row, made the last row of the list. Returns its Button GameObject
// and (via text) its label's Text component.
static void *ls_add_row(void *list_tr, void *about_go, void **text) {
    *text = NULL;
    void *clone = ((qc_static1)g_qc[QC_INSTANTIATE])(NULL, about_go, NULL);
    void *clone_tr = looks_like_ptr(clone) ? ((qc_inst0)g_qc[QC_GO_TR])(clone, NULL) : NULL;
    if (!looks_like_ptr(clone_tr)) return NULL;
    ((void (*)(void *, void *, bool, void *))g_qc[QC_SETPARENT])(clone_tr, list_tr, false, NULL);
    ((void (*)(void *, void *))g_qc[QC_LASTSIB])(clone_tr, NULL);
    ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(clone, true, NULL);
    void *bpath = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"Button", NULL);
    void *btn_tr = looks_like_ptr(bpath) ? ((qc_inst1)g_qc[QC_FIND])(clone_tr, bpath, NULL) : NULL;
    void *tpath = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"Button/Text", NULL);
    void *text_tr = looks_like_ptr(tpath) ? ((qc_inst1)g_qc[QC_FIND])(clone_tr, tpath, NULL) : NULL;
    void *text_go = looks_like_ptr(text_tr) ? ((qc_inst0)g_qc[QC_COMP_GO])(text_tr, NULL) : NULL;
    *text = looks_like_ptr(text_go) ? ((qc_inst1)g_mt[MT_GETCOMPONENT])(text_go, g_ls_type_text, NULL) : NULL;
    return looks_like_ptr(btn_tr) ? ((qc_inst0)g_qc[QC_COMP_GO])(btn_tr, NULL) : NULL;
}

static void ls_tick(void) {
    if (!g_game_live) return;
    if (!g_ls_type_ctrl) g_ls_type_ctrl = mt_type("Niantic.Holoholo.UI.SettingsGuiController, Assembly-CSharp");
    if (!g_ls_type_text) g_ls_type_text = mt_type("UnityEngine.UI.Text, UnityEngine.UI");
    if (!looks_like_ptr(g_ls_type_ctrl) || !looks_like_ptr(g_ls_type_text)) return;
    void *ctrl = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_ls_type_ctrl, NULL);
    if (!looks_like_ptr(ctrl)) {                             // Settings not open
        // v170: forget the rows. A Settings screen opened later can be a NEW controller at the
        // old address; relabelling the old rows' Text pointers then crashed (SIGSEGV in
        // Text.set_text). Rows are rebuilt for every Settings screen instead.
        g_ls_ctrl = NULL;
        g_ls_relabel = 0;
        g_ls_button = g_ls_text = g_kb_button = g_kb_text = NULL;
        return;
    }
    if (ctrl == g_ls_ctrl) {                                 // already has the rows
        if (g_ls_relabel > 0) { g_ls_relabel--; ls_set_label(); }
        return;
    }
    g_ls_button = g_ls_text = g_kb_button = g_kb_text = NULL;
    g_ls_ctrl = ctrl;
    void *ctrl_tr = ((qc_inst0)g_qc[QC_COMP_TR])(ctrl, NULL);
    void *list_path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"Content/ScrollPanel/Viewport/Content", NULL);
    void *list_tr = looks_like_ptr(ctrl_tr) && looks_like_ptr(list_path)
        ? ((qc_inst1)g_qc[QC_FIND])(ctrl_tr, list_path, NULL) : NULL;
    void *about_path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"About", NULL);
    void *about_tr = looks_like_ptr(list_tr) && looks_like_ptr(about_path)
        ? ((qc_inst1)g_qc[QC_FIND])(list_tr, about_path, NULL) : NULL;
    if (!looks_like_ptr(about_tr)) { WLOG(@"settings rows: Settings list/About not found"); return; }
    void *about_go = ((qc_inst0)g_qc[QC_COMP_GO])(about_tr, NULL);
    if (!looks_like_ptr(about_go)) return;
    // Keep Ball first, so Back to Launcher stays the very last row
    if (g_kb_row_on) {
        g_kb_button = ls_add_row(list_tr, about_go, &g_kb_text);
        WLOG(@"keep ball: row added to Settings (button %p, text %p)", g_kb_button, g_kb_text);
    }
    if (g_ls_on) {
        g_ls_button = ls_add_row(list_tr, about_go, &g_ls_text);
        WLOG(@"launcher row: added to Settings (button %p, text %p)", g_ls_button, g_ls_text);
    }
    g_ls_relabel = 12;                                       // ~3 s: past Auto_Translate's Start
    ls_set_label();
}

static bool install_settings_text(uintptr_t base) {
    if (*(uint32_t *)(base + kSetText.rva) != kSetText.first) { WLOG(@"settings rows: Text.set_text mismatch -- off"); return false; }
    g_ls_set_text = (void *)(base + kSetText.rva);
    return true;
}

static bool install_launcher_row(uintptr_t base, uintptr_t dstart, size_t dsize) {
    if (!NSClassFromString(@"WSGuestLoader")) { WLOG(@"launcher row: not in the Windstock Launcher -- off"); return false; }
    if (!install_settings_text(base)) return false;
    if (!install_click_about(base, dstart, dsize)) return false;
    g_ls_on = true;
    WLOG(@"launcher row: armed");
    return true;
}

// ----------------------------------------------------------------- v166: Keep Ball
// Settings > "Keep Ball: ON" -- the ball you were throwing (say an Ultra Ball) is still the
// selected ball in the next encounter, instead of the game going back to a Poke Ball.
// The game keeps the selected ball in PlayerService.currentPokeball (an Item id: 1 Poke,
// 2 Great, 3 Ultra, 4 Master); the item bag's ball pick only writes that field
// (SetCurrentPokeball), and the Pokeball's own state machine re-reads it and swaps the model.
// EncounterInteractionState.EnterState resets it to 1 with a direct call, so there's nothing
// to redirect -- instead, every 0.1 s: while an encounter is on, remember the field; when a
// new encounter's interaction state goes active, put the remembered ball back. If you have
// none of that ball left, get_CurrentPokeball falls back to the lowest ball you do have.
// 0.35 (port from 0.29 EnterState / HandleItemBagDismissed, both callers of the same setter):
//   PlayerService.SetCurrentPokeball @0xA9D04 = "str w1, [x0, #0x64]; ret".
static const QcFn kSetCurrentBall = { "PlayerService.SetCurrentPokeball", 0xA9D04, 0xb9006401 };
#define OFF_PS_CURRENT_BALL   0x64   // PlayerService.currentPokeball (int Item)
#define OFF_KB_STATE_ACTIVE   0x38   // GameState.<IsActiveState>k__BackingField
#define KB_PREF_ON            @"WSKeepBall"
#define KB_PREF_ITEM          @"WSKeepBallItem"
static bool g_kb_ready = false;
static void *g_kb_type_state = NULL;
static void *g_kb_state = NULL;       // EncounterInteractionState we already restored for
static int32_t g_kb_item = 0;         // the ball to carry over (0 = none yet)

static bool kb_enabled(void) { return [[NSUserDefaults standardUserDefaults] boolForKey:KB_PREF_ON]; }

static void kb_toggle(void) {
    bool on = !kb_enabled();
    [[NSUserDefaults standardUserDefaults] setBool:on forKey:KB_PREF_ON];
    ws_haptic_select();
    ls_set_label();
    WLOG(@"keep ball: %s (remembered ball %d)", on ? "ON" : "OFF", g_kb_item);
}

static void kb_tick(void) {
    if (!g_game_live || !g_kb_ready) return;
    if (!g_kb_type_state) g_kb_type_state = mt_type("Niantic.Holoholo.Encounter.EncounterInteractionState, Assembly-CSharp");
    if (!looks_like_ptr(g_kb_type_state)) { g_kb_type_state = NULL; return; }
    void *st = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_kb_type_state, NULL);
    if (!looks_like_ptr(st) || !*(uint8_t *)((uint8_t *)st + OFF_KB_STATE_ACTIVE)) {
        g_kb_state = NULL;                                   // no encounter going on
        return;
    }
    void *ps = ((qc_inst0)g_mt[MT_PS_INSTANCE])(NULL, NULL);
    if (!looks_like_ptr(ps)) return;
    int32_t *cur = (int32_t *)((uint8_t *)ps + OFF_PS_CURRENT_BALL);
    if (st != g_kb_state) {                                  // EnterState just ran: ball is back to 1
        g_kb_state = st;
        if (kb_enabled() && g_kb_item >= 1 && g_kb_item <= 4 && *cur != g_kb_item) {
            WLOG(@"keep ball: new encounter -- ball %d -> %d", *cur, g_kb_item);
            *cur = g_kb_item;
        }
        return;
    }
    // during the encounter: follow whatever ball is in use (bag pick, or the game's fallback)
    int32_t now = *cur;
    if (now >= 1 && now <= 4 && now != g_kb_item) {
        g_kb_item = now;
        [[NSUserDefaults standardUserDefaults] setInteger:now forKey:KB_PREF_ITEM];
        WLOG(@"keep ball: ball in use -> %d", now);
    }
}

static bool install_keep_ball(uintptr_t base, uintptr_t dstart, size_t dsize) {
    uint32_t w = *(uint32_t *)(base + kSetCurrentBall.rva);
    if (w != kSetCurrentBall.first) {
        WLOG(@"keep ball: %s %08x != %08x -- off", kSetCurrentBall.name, w, kSetCurrentBall.first);
        return false;
    }
    if (!install_settings_text(base) || !install_click_about(base, dstart, dsize)) return false;
    g_kb_item = (int32_t)[[NSUserDefaults standardUserDefaults] integerForKey:KB_PREF_ITEM];
    g_kb_row_on = g_kb_ready = true;
    WLOG(@"keep ball: armed (%s, remembered ball %d)", kb_enabled() ? "ON" : "OFF", g_kb_item);
    return true;
}


// ----------------------------------------------------------------- il2cpp helpers (raids, map, weather)
static NSString *il2cpp_ns(void *s) {
    if (!looks_like_ptr(s)) return nil;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len <= 0 || len > 256) return nil;
    return [NSString stringWithCharacters:(unichar *)((uint8_t *)s + 0x14) length:len];
}
static void *raid_type(const char *name) {
    if (!g_qc[QC_STR]) return NULL;
    void *s = ((qc_static1)g_qc[QC_STR])(NULL, (void *)name, NULL);
    return looks_like_ptr(s) ? ((qc_static1)g_qc[QC_GETTYPE])(NULL, s, NULL) : NULL;
}
static id rj(id obj, NSString *key) {            // JSON field, nil for missing/null
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id v = obj[key];
    return (v == [NSNull null]) ? nil : v;
}
// ----------------------------------------------------------------- raids: 0.71 port (RAIDS=1 builds)
// These three live in work/port071/tweak (found via -I in the Makefile).
#include "Raids071.inc.mm"
#include "Gyms071.inc.mm"     // gym v2 screen (server gyms.v2), raids builds
#include "GymScreen071.inc.mm" // 0.71's own gym screen (transplanted prefab), raids builds

// ----------------------------------------------------------------- weather (map effects + icon)
// Real weather comes from the server (work/server/weather.py -> Open-Meteo). The client has
// no weather, so the tweak draws it: rain/snow/wind particles and a tint over the map, plus
// a pill with the condition and which types it boosts. Pure UIKit/Core Animation on top of
// Unity's view -- no game code is touched, and it never takes touches. Shown only while the
// map theme is playing (g_map_active), so encounters, gyms and menus stay clean.
#import <QuartzCore/QuartzCore.h>
#define WEATHER 1   // v136: back on for the 3D test -- scene fog + mesh rain, no 2D overlay
// v150: weather SHELVED again (code kept): the tweak never asks the server for the weather, so
// no rain / snow / wind, weather fog, shade, weather icon or mist. 1 = weather back on.
#define WEATHER_FX 0
// v202: the 3D rain / snow / wind particles are back on their own (user, 2026-10-25), from the
// weather tint's copy of /weather; weather fog, shade, icon and catch mist stay shelved.
#define WEATHER_PARTICLES 1
// v207: weather sleeps only while the app is in the background (or in the launcher). It used
// g_paused (MusicService paused), but the game also pauses its music for the ball shakes in a
// catch -- which switched the particles off for the whole ball animation.
#define WX_HOLD (g_inactive || g_in_launcher)
#define WX_OVERLAY 0 // the v32-v48 UIKit drops/tint over the map. Off: weather lives in the scene now
#define WEATHER_URL @"https://pgorelease.nianticlabs.com/weather"

static NSDictionary *g_wx = nil;          // last /weather reply
static NSDictionary *g_wx_tint = nil;     // v200: the same reply for the weather tint (even with WEATHER_FX 0)
static bool g_tint_ok = false;            // v200: weather tint functions verified + mod on
static int g_wx_fx = 0;                   // v143: 0 none, 1 rain, 2 snow, 3 wind (weather_tick)
static float g_wx_shade = 0;              // v148: daytime shade, 0..1 (weather_tick)
static float g_wx_mist = 0;               // v145: catch-screen fog sheets, 0..1 (weather_tick)
static NSString *g_wx_drawn = nil;        // condition the effects are built for
static CGSize g_wx_size;                  // view size they were laid out for
static UIView *W_layer = nil, *W_tint = nil;
static CAEmitterLayer *W_emitter = nil, *W_splash = nil;
static CAShapeLayer *W_fx_far = nil, *W_fx_near = nil;

#define WX_MAX_DROPS 260
typedef struct { CGFloat x, y, vx, vy, len; int near; } WxDrop;
static WxDrop g_drops[WX_MAX_DROPS];
static int g_drop_count = 0;
static NSString *g_drop_kind = nil;      // rainy / snow / windy, or nil for none

__attribute__((unused))
static void wx_seed_drops(NSString *cond, CGSize sz) {
    g_drop_kind = cond;
    g_drop_count = 0;
    if (sz.width < 2 || sz.height < 2) return;
    int want = 0;
    if ([cond isEqualToString:@"rainy"]) want = 150;
    else if ([cond isEqualToString:@"snow"]) want = 90;
    else if ([cond isEqualToString:@"windy"]) want = 40;
    if (!want) return;
    for (int i = 0; i < want && i < WX_MAX_DROPS; i++) {
        WxDrop *d = &g_drops[g_drop_count++];
        d->near = (i % 3 == 0);
        d->x = ((CGFloat)arc4random_uniform(10000) / 10000.0) * (sz.width + 80) - 40;
        d->y = ((CGFloat)arc4random_uniform(10000) / 10000.0) * sz.height;
        if ([cond isEqualToString:@"rainy"]) {
            d->vy = d->near ? 1500 : 950;  d->vx = 150;  d->len = d->near ? 42 : 26;
        } else if ([cond isEqualToString:@"snow"]) {
            d->vy = d->near ? 150 : 90;    d->vx = 30;   d->len = d->near ? 5 : 3.2;
        } else {                             // windy: sideways streaks
            d->vy = 20;                    d->vx = d->near ? 1500 : 1000; d->len = d->near ? 46 : 30;
        }
    }
}

// One frame of weather. dt in seconds.
__attribute__((unused))
static void wx_step_drops(CGSize sz, CGFloat dt) {
    if (!g_drop_count || sz.width < 2) return;
    BOOL snow = [g_drop_kind isEqualToString:@"snow"];
    BOOL wind = [g_drop_kind isEqualToString:@"windy"];
    UIBezierPath *pfar = [UIBezierPath bezierPath], *pnear = [UIBezierPath bezierPath];
    CFTimeInterval t = CACurrentMediaTime();
    for (int i = 0; i < g_drop_count; i++) {
        WxDrop *d = &g_drops[i];
        CGFloat drift = snow ? sin(t * 1.3 + i) * 26 : 0;
        d->y += d->vy * dt;
        d->x += (d->vx + drift) * dt;
        if (d->y > sz.height + d->len || d->x > sz.width + 60 || d->x < -80) {
            d->y = wind ? ((CGFloat)arc4random_uniform((uint32_t)MAX(1, sz.height))) : -d->len - 10;
            d->x = wind ? -60 : ((CGFloat)arc4random_uniform((uint32_t)(sz.width + 80))) - 40;
        }
        UIBezierPath *p = d->near ? pnear : pfar;
        if (snow) {
            [p appendPath:[UIBezierPath bezierPathWithOvalInRect:
                CGRectMake(d->x, d->y, d->len, d->len)]];
        } else if (wind) {
            [p moveToPoint:CGPointMake(d->x, d->y)];
            [p addLineToPoint:CGPointMake(d->x - d->len, d->y + 2)];
        } else {
            [p moveToPoint:CGPointMake(d->x, d->y)];
            [p addLineToPoint:CGPointMake(d->x - d->vx * 0.012, d->y - d->len)];
        }
    }
    W_fx_far.path = pfar.CGPath;
    W_fx_near.path = pnear.CGPath;
    W_fx_far.fillColor = W_fx_near.fillColor = snow ? [UIColor colorWithWhite:1 alpha:0.85].CGColor
                                                    : UIColor.clearColor.CGColor;
}
static UIView *W_chip = nil;              // the game-style weather chip
static UIImageView *W_icon = nil;         // our hand-drawn weather glyph
static UILabel *W_pill = nil;             // temperature under the glyph

// The real game's weather glyphs are Niantic artwork and are not in the 0.35 client
// (weather arrived in 2017), so these are drawn here in the same visual language:
// white line art, round caps, on a dark translucent rounded chip.
__attribute__((unused))
static UIImage *wx_icon_image(NSString *cond, CGFloat size) {
    return ws_draw_image(CGSizeMake(size, size), ^(CGContextRef cg) {
        CGFloat u = size / 24.0;                       // drawn on a 24x24 grid
        UIColor *ink = UIColor.whiteColor;
        [ink setStroke];
        [ink setFill];
        CGFloat lw = 1.9 * u;
        BOOL sun    = [cond isEqualToString:@"sunny"];
        BOOL moon   = [cond isEqualToString:@"clear"];
        BOOL partly = [cond isEqualToString:@"partly_cloudy"];
        BOOL rain   = [cond isEqualToString:@"rainy"];
        BOOL snow   = [cond isEqualToString:@"snow"];
        BOOL fog    = [cond isEqualToString:@"fog"];
        BOOL windy  = [cond isEqualToString:@"windy"];
        BOOL cloud  = partly || rain || snow || fog || [cond isEqualToString:@"cloudy"];

        if (sun || partly) {                            // sun disc (+ rays when alone)
            CGPoint c = partly ? CGPointMake(9 * u, 9 * u) : CGPointMake(12 * u, 12 * u);
            CGFloat rad = partly ? 3.4 * u : 4.6 * u;
            UIBezierPath *disc = [UIBezierPath bezierPathWithArcCenter:c radius:rad
                                                            startAngle:0 endAngle:2 * M_PI clockwise:YES];
            disc.lineWidth = lw;
            [disc stroke];
            if (!partly) {
                UIBezierPath *rays = [UIBezierPath bezierPath];
                for (int i = 0; i < 8; i++) {
                    CGFloat a = i * M_PI / 4;
                    [rays moveToPoint:CGPointMake(c.x + cos(a) * rad * 1.55, c.y + sin(a) * rad * 1.55)];
                    [rays addLineToPoint:CGPointMake(c.x + cos(a) * rad * 2.05, c.y + sin(a) * rad * 2.05)];
                }
                rays.lineWidth = lw;
                rays.lineCapStyle = kCGLineCapRound;
                [rays stroke];
            }
        }
        if (moon) {                                     // crescent: disc minus offset disc
            UIBezierPath *m = [UIBezierPath bezierPathWithArcCenter:CGPointMake(13 * u, 12 * u)
                                                             radius:6.5 * u startAngle:0 endAngle:2 * M_PI clockwise:YES];
            [m appendPath:[UIBezierPath bezierPathWithArcCenter:CGPointMake(9.5 * u, 9.5 * u)
                                                         radius:6.0 * u startAngle:0 endAngle:2 * M_PI clockwise:YES]];
            m.usesEvenOddFillRule = YES;
            [m fill];
        }
        if (cloud) {                                    // rounded cloud, game-style
            CGFloat cy = (rain || snow || fog) ? 11.5 * u : 13.0 * u;
            UIBezierPath *c = [UIBezierPath bezierPath];
            [c addArcWithCenter:CGPointMake(10 * u, cy) radius:4.2 * u
                     startAngle:M_PI endAngle:0 clockwise:YES];
            [c addArcWithCenter:CGPointMake(15.2 * u, cy + 1.2 * u) radius:3.2 * u
                     startAngle:-M_PI_2 endAngle:M_PI_2 clockwise:YES];
            [c addLineToPoint:CGPointMake(7.5 * u, cy + 4.4 * u)];
            [c addArcWithCenter:CGPointMake(7.5 * u, cy + 2.2 * u) radius:2.2 * u
                     startAngle:M_PI_2 endAngle:M_PI clockwise:YES];
            [c closePath];
            [c fill];
        }
        UIBezierPath *below = [UIBezierPath bezierPath];
        below.lineWidth = lw;
        below.lineCapStyle = kCGLineCapRound;
        if (rain) {
            for (int i = 0; i < 3; i++) {
                CGFloat x = (8.0 + i * 3.2) * u;
                [below moveToPoint:CGPointMake(x, 17.5 * u)];
                [below addLineToPoint:CGPointMake(x - 1.2 * u, 20.8 * u)];
            }
        } else if (snow) {
            for (int i = 0; i < 3; i++) {
                CGFloat x = (8.0 + i * 3.2) * u, y = 19.2 * u, a = 1.5 * u;
                [below moveToPoint:CGPointMake(x - a, y)];  [below addLineToPoint:CGPointMake(x + a, y)];
                [below moveToPoint:CGPointMake(x, y - a)];  [below addLineToPoint:CGPointMake(x, y + a)];
            }
        } else if (fog) {
            for (int i = 0; i < 3; i++) {
                CGFloat y = (17.6 + i * 2.4) * u;
                [below moveToPoint:CGPointMake((6.0 + (i == 1 ? 1.5 : 0)) * u, y)];
                [below addLineToPoint:CGPointMake((18.0 - (i == 2 ? 2.5 : 0)) * u, y)];
            }
        } else if (windy) {
            CGFloat ys[3] = {8.5 * u, 12.5 * u, 16.5 * u};
            CGFloat ends[3] = {15.5 * u, 18.0 * u, 14.0 * u};
            for (int i = 0; i < 3; i++) {
                [below moveToPoint:CGPointMake(4.0 * u, ys[i])];
                [below addLineToPoint:CGPointMake(ends[i], ys[i])];
                [below addArcWithCenter:CGPointMake(ends[i], ys[i] - 1.8 * u) radius:1.8 * u
                             startAngle:M_PI_2 endAngle:-M_PI_2 clockwise:YES];
            }
        }
        [below stroke];
    });
}

// v45: weather in the actual 3D scene, not only as an overlay. Unity's RenderSettings
// fog + ambient light colour the map geometry itself (distance haze, dimmer light), which
// is what the engine gives us without building particle systems inside the game. Plain
// static calls, like quick catch -- nothing is hooked. 0.35 RVAs via tools/port_rva.py.
static const QcFn kWx[] = {
    { "RenderSettings.set_fog",                0x8C0FEC, 0xa9be4ff4 },
    { "RenderSettings.set_fogColor",           0x8C1134, 0xa9bf7bfd },
    { "RenderSettings.set_fogStartDistance",   0x8C126C, 0x6dbd23e9 },
    { "RenderSettings.set_fogEndDistance",     0x8C132C, 0x6dbd23e9 },
    { "RenderSettings.set_ambientSkyColor",    0x8C1394, 0xa9bf7bfd },
    { "RenderSettings.set_ambientGroundColor", 0x8C141C, 0xa9bf7bfd },
};
enum { WX_FOG, WX_FOGCOLOR, WX_FOGSTART, WX_FOGEND, WX_AMBSKY, WX_AMBGROUND, WX_COUNT };
static void *g_wxfn[WX_COUNT];
static bool g_wx_scene_ok = false;

typedef void (*wx_set_bool)(bool, void *);
typedef void (*wx_set_float)(float, void *);
typedef void (*wx_set_color)(float, float, float, float, void *);   // Color = 4 floats (HFA)

__attribute__((unused))
static bool install_weather_scene(uintptr_t base, const char *version) {
    if (strcmp(version, "0.35") != 0) return false;
    for (int i = 0; i < WX_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kWx[i].rva);
        if (w != kWx[i].first) {
            WLOG(@"weather: %s first word %08x != %08x -- scene weather OFF",
                 kWx[i].name, w, kWx[i].first);
            return false;
        }
        g_wxfn[i] = (void *)(base + kWx[i].rva);
    }
    WLOG(@"weather: scene fog/light ready (%d functions verified)", WX_COUNT);
    return true;
}

// Push the current condition into the scene. v144: on the map AND in catches. The fog
// distances were map units (tuned with the camera ~49 from the avatar); they're now that
// many shares of D, the camera's distance to the anchor (rain3d), so the catch camera ~3
// away gets the same haze instead of none. D 0 = unknown: the old map numbers. Re-applied
// every few seconds too, because Unity resets RenderSettings when a scene loads.
#define WX_FOG_REF_D 49.0f
static float g_wx_fogcol[3] = { 0.84f, 0.87f, 0.90f };   // v145: the catch screen's fog sheets use it
// v149: SMOOTH FOG. weather_scene_apply only sets a target; fog_smooth_frame (60 fps) eases
// colour and distances toward it, so the haze rolls in and out and never steps when the camera
// distance is re-measured (the visible jumps in shade). Writing it every frame also puts it
// straight back after Unity resets RenderSettings on a scene load.
struct FogState { bool on; float r, g, b, s, e; };
static FogState g_fog_t = { false, 0, 0, 0, 0, 0 }, g_fog_c = { false, 0, 0, 0, 0, 0 };
static bool g_fog_have = false, g_fog_snap = false, g_fog_live = false;
static const char *g_fog_scene = NULL;
#define FOG_FAR 4000.0f                        // "no fog": pushed out past everything
#define FOG_EASE_S 0.8f                        // time constant of the easing, seconds
__attribute__((unused))
static void weather_scene_apply(NSString *cond, bool active, float D, const char *scene) {
    if (!g_wx_scene_ok) return;
    static NSString *applied = nil;
    static bool applied_active = false;
    static float applied_D = 0;
    static const char *applied_scene = NULL;
    static CFTimeInterval applied_at = 0;
    static int applied_look = -1;
    CFTimeInterval now = CACurrentMediaTime();
    bool same_d = (D <= 0 && applied_D <= 0) ||
                  (D > 0 && applied_D > 0 && fabsf(D - applied_D) < applied_D * 0.15f);
    if (applied_active == active && [applied isEqualToString:cond] && same_d &&
        applied_scene == scene && applied_look == g_look_gen && now - applied_at < 5.0) return;
    bool changed = !(applied_active == active && [applied isEqualToString:cond] && same_d &&
                     applied_scene == scene && applied_look == g_look_gen);
    applied_look = g_look_gen;
    applied = cond;
    applied_active = active;
    applied_D = D;
    applied_scene = scene;
    applied_at = now;
    g_fog_live = active;
    if (!active) return;                       // nothing to fog (menus, loading): leave the scene alone
    float fr = 0, fg = 0, fb = 0, start = 150, end = 900;
    bool fog = true;
    if ([cond isEqualToString:@"rainy"]) {
        // v148: rain, snow and cloud were 90-800 away -- past most of what the map draws,
        // so the haze vanished the moment the weather turned. Now it closes in like fog does.
        fr = 0.30f; fg = 0.36f; fb = 0.45f; start = 30;  end = 330;
    } else if ([cond isEqualToString:@"fog"]) {
        fr = 0.84f; fg = 0.87f; fb = 0.90f; start = 15;  end = 210;   // fog is meant to be thick
    } else if ([cond isEqualToString:@"snow"]) {
        fr = 0.80f; fg = 0.85f; fb = 0.91f; start = 30;  end = 320;
    } else if ([cond isEqualToString:@"cloudy"]) {
        fr = 0.50f; fg = 0.54f; fb = 0.60f; start = 60;  end = 480;
    } else if ([cond isEqualToString:@"clear"]) {
        fr = 0.12f; fg = 0.16f; fb = 0.32f; start = 120; end = 800;
    } else {                                   // sunny, partly cloudy, windy: leave the map alone
        fog = false;
    }
    // v151: the v146 Halloween violet night haze was removed (user asked); fog is weather-only again.
    // v157: the server's Halloween look colours whatever haze there is, and brings its own
    // when the weather has none or a thinner one.
    if (g_look.fog) {
        if (!fog || g_look.fe < end) { start = g_look.fs; end = g_look.fe; }
        fog = true;
        fr = g_look.fr; fg = g_look.fg; fb = g_look.fb;
    }
    if (fog) { g_wx_fogcol[0] = fr; g_wx_fogcol[1] = fg; g_wx_fogcol[2] = fb; }
    if (D > 0) { start *= D / WX_FOG_REF_D; end *= D / WX_FOG_REF_D; }
    {   // v148: weather.rainfx.fog_distance scales every weather's fog (0.5 = twice as close)
        id v = rj(rj(g_wx, @"rainfx"), @"fog_distance");
        float k = [v isKindOfClass:[NSNumber class]] ? MAX(0.1f, MIN(4.0f, [v floatValue])) : 1.0f;
        start *= k; end *= k;
    }
    // v149: no longer written here -- fog_smooth_frame eases the scene toward it every frame
    g_fog_t.on = fog;
    if (fog) { g_fog_t.r = fr; g_fog_t.g = fg; g_fog_t.b = fb; g_fog_t.s = start; g_fog_t.e = end; }
    if (changed && applied_scene != g_fog_scene) g_fog_snap = true;   // map <-> catch: jump, don't glide
    g_fog_scene = applied_scene;
    g_fog_have = true;
    // NOTE: ambient light is deliberately NOT touched -- v45 did and the map went flat.
    if (changed)
        WLOG(@"weather: scene [%s] set for %@ (fog %d, %.2f-%.2f, D %.2f)", scene ?: "?", cond, fog, start, end, D);
}

// v136: RAIN IN THE 3D SCENE (test). The game's ParticleSystem is stripped to almost nothing
// in 0.35 (no speed / lifetime / emission setters survive), so the rain is a MESH instead:
// hundreds of thin vertical quads with a vertex-colour fade, drawn by a stock transparent
// shader, in a box in front of the map camera. The whole box slides down and wraps (the
// mesh repeats every `height` units), and it turns with the camera's yaw so the streaks
// always face it. Everything is made through surviving managed calls -- Activator /
// Array.CreateInstance allocate, the Mesh / Renderer / Transform wrappers do the rest --
// since the build exports no il2cpp_* API. Tunables come from the server's /weather reply
// ("rain3d": {...}) so it can be tuned without a rebuild. 0.35 RVAs via tools/port_rva.py.
struct V3 { float x, y, z; };
static const QcFn kR3[] = {
    { "Array.CreateInstance(Type,int)",        0x90E4F4, 0xa9bd57f6 },
    { "Activator.CreateInstance(Type)",        0x909FCC, 0x52800002 },
    { "Activator.CreateInstance(Type,obj[])",  0x90A26C, 0xa9bd57f6 },
    { "GameObject.AddComponent(Type)",         0x89B0D4, 0x140002c1 },
    { "GameObject.get_layer",                  0x89B778, 0xa9be4ff4 },
    { "GameObject.set_layer",                  0x89B7DC, 0xa9bd57f6 },
    { "Mesh.set_vertices",                     0x8B7364, 0xa9bd57f6 },
    { "Mesh.set_colors32",                     0x8B7B1C, 0xa9bd57f6 },
    { "Mesh.set_triangles",                    0x8B7D98, 0xa9bd57f6 },
    { "Mesh.RecalculateBounds",                0x8B7C08, 0xa9be4ff4 },
    { "MeshFilter.set_mesh",                   0x8B822C, 0xa9bd57f6 },
    { "Renderer.set_material",                 0x8C0AA4, 0xa9bd57f6 },
    { "Shader.Find",                           0x8C4C30, 0xa9be4ff4 },
    { "Camera.get_main",                       0x88FB5C, 0xa9be4ff4 },
    { "Camera.get_cullingMask",                0x88ED88, 0xa9be4ff4 },
    { "Transform.get_position",                0x8D531C, 0xa9bf7bfd },
    { "Transform.set_position",                0x8D53C0, 0xa9bf7bfd },
    { "Transform.get_eulerAngles",             0x8D5594, 0xa9bf7bfd },
    { "Transform.set_eulerAngles",             0x8D55FC, 0xa9be4ff4 },
    { "Transform.get_forward",                 0x8D5840, 0xa9bf7bfd },
    { "Object.get_name",                       0x8ABA50, 0xa9be4ff4 },
    { "Object.Destroy",                        0x8B98B0, 0x4f00e400 },
    { "GCHandle.Alloc(object)",                0x9B8148, 0xa9bf7bfd },
    { "Renderer.get_bounds",                   0x8C0CB8, 0xa9be4ff4 },
    { "Camera.get_fieldOfView",                0x88EA48, 0xa9be4ff4 },
};
enum { R3_ARRAY, R3_NEW, R3_NEW_ARGS, R3_ADDCOMP, R3_GETLAYER, R3_SETLAYER, R3_VERTS, R3_COLORS,
       R3_TRIS, R3_BOUNDS, R3_SETMESH, R3_SETMAT, R3_FINDSHADER, R3_CAMMAIN, R3_CULLMASK,
       R3_GETPOS, R3_SETPOS, R3_GETEULER, R3_SETEULER, R3_FORWARD, R3_NAME, R3_DESTROY, R3_GCALLOC,
       R3_RBOUNDS, R3_FOV, R3_COUNT };
static void *g_r3[R3_COUNT];
static bool g_r3_ok = false;
#define OFF_UOBJ_CACHED 0x18      // UnityEngine.Object.m_CachedPtr: 0 once the native object is gone
#define OFF_ARRAY_LEN   0x18      // Il2CppArray.max_length
#define OFF_ARRAY_DATA  0x20

typedef V3 (*r3_getv3)(void *self, void *mi);
typedef void (*r3_setv3)(void *self, V3 v, void *mi);
typedef void *(*r3_static2)(void *unused, void *a, void *b, void *mi);
typedef void *(*r3_array_new)(void *unused, void *type, int32_t n, void *mi);

__attribute__((unused))
static bool install_rain3d(uintptr_t base, const char *version) {
    if (strcmp(version, "0.35") != 0) return false;
    for (int i = 0; i < R3_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kR3[i].rva);
        if (w != kR3[i].first) {
            WLOG(@"rain3d: %s first word %08x != %08x -- 3D rain OFF", kR3[i].name, w, kR3[i].first);
            return false;
        }
        g_r3[i] = (void *)(base + kR3[i].rva);
    }
    WLOG(@"rain3d: %d functions verified", R3_COUNT);
    return true;
}

// A Unity object we can still call into: a managed wrapper whose native side is alive.
static bool r3_alive(void *o) {
    return looks_like_ptr(o) && *(void **)((uint8_t *)o + OFF_UOBJ_CACHED) != NULL;
}

static void *r3_array(const char *elem_type, int32_t n) {
    void *t = mt_type(elem_type);
    if (!looks_like_ptr(t)) { WLOG(@"rain3d: no type %s", elem_type); return NULL; }
    void *a = ((r3_array_new)g_r3[R3_ARRAY])(NULL, t, n, NULL);
    if (!looks_like_ptr(a)) return NULL;
    uint32_t len = *(uint32_t *)((uint8_t *)a + OFF_ARRAY_LEN);
    if ((int32_t)len != n) {           // layout isn't what we think: don't write into it
        WLOG(@"rain3d: %s[%d] length reads %u -- array layout mismatch, 3D rain OFF", elem_type, n, len);
        g_r3_ok = false;
        return NULL;
    }
    return a;
}

static NSDictionary *g_r3_cfg = nil;         // "rain3d" from /weather, read each build
static float r3f(NSString *k, float dflt) {
    id v = rj(g_r3_cfg, k);
    return [v isKindOfClass:[NSNumber class]] ? [v floatValue] : dflt;
}

// v139: every drop is its own falling streak in WORLD space. It falls from `fall` above the
// ground, drifts with the wind, is drawn along its own velocity (so angles differ with the
// gusts and with each drop's speed), and when it reaches the ground it stops there and
// leaves a ripple at that exact spot -- v136-v138 slid one rigid box of streaks through the
// ground, so drops missed the ripples and all leaned the same way. Drops closer to the
// camera than `near` x (its distance to the spot it looks at) are hidden -- they were the
// big pale bars. Two meshes, rewritten in place every frame: no allocations after the build.
// v140: sizes are plain scene units again (the v138 ones, which looked right on the map AND
// the catch screen). v139 scaled them by the camera's height, and the map camera is so high
// that every streak became a screen-sized white slab. Hard caps below keep any setting from
// doing that again.
#define R3_RING_SEGS 12
#define R3_MAX_DROPS 1500
#define R3_MAX_RIPPLES 200
typedef struct { float x, y, z, vy, len, drift, a, age, life; } R3Drop;
static R3Drop R3_d[R3_MAX_DROPS];
static int R3_n = 0;
static void *R3_go = NULL, *R3_mesh = NULL, *R3_verts = NULL, *R3_cols = NULL;
static void *R3_rgo = NULL, *R3_rmesh = NULL, *R3_rverts = NULL, *R3_rcols = NULL;
// v145: fog sheets for the catch screen -- see r3_draw_mist
#define R3_FOG_SHEETS 6
static void *R3_fgo = NULL, *R3_fmesh = NULL, *R3_fverts = NULL, *R3_fcols = NULL;
// v148: the daytime shade -- see r3_draw_shade
static void *R3_sgo = NULL, *R3_smesh = NULL, *R3_sverts = NULL, *R3_scols = NULL;
static int R3_rn = 0, R3_rnext = 0;
static float R3_rx[R3_MAX_RIPPLES], R3_rz[R3_MAX_RIPPLES], R3_rs[R3_MAX_RIPPLES];
static double R3_rstart[R3_MAX_RIPPLES];
static NSString *R3_built_for = nil;         // JSON of the tunables it was built with
static int R3_builds = 0;
static CFTimeInterval R3_last_try = 0;
static uint8_t R3_cr = 205, R3_cg = 220, R3_cb = 255;
// tunables: v141 -- shares of D, the camera's distance to the anchor (wind/gust/alpha/life
// excepted). Chosen so a map camera ~50 away gets v138's look (3-unit streaks, 0.05 wide).
static float R3_area = 1.2f, R3_fall = 1.0f, R3_len = 0.06f, R3_wid = 0.001f, R3_speed = 0.9f,
             R3_near = 0.25f, R3_wind = 0.18f, R3_gust = 0.12f, R3_alpha = 0.45f, R3_ground = 0,
             R3_ground_off = 0, R3_ahead = 0.3f,
             R3_rsize = 0.018f, R3_rlife = 0.7f, R3_ralpha = 0.5f, R3_rwidth = 0.001f, R3_splash = 0.35f;

static void rain3d_destroy_ref(void) {
    if (r3_alive(R3_go)) ((qc_static1)g_r3[R3_DESTROY])(NULL, R3_go, NULL);
    if (r3_alive(R3_rgo)) ((qc_static1)g_r3[R3_DESTROY])(NULL, R3_rgo, NULL);
    if (r3_alive(R3_fgo)) ((qc_static1)g_r3[R3_DESTROY])(NULL, R3_fgo, NULL);
    if (r3_alive(R3_sgo)) ((qc_static1)g_r3[R3_DESTROY])(NULL, R3_sgo, NULL);
    R3_fgo = R3_fmesh = R3_fverts = R3_fcols = NULL;
    R3_sgo = R3_smesh = R3_sverts = R3_scols = NULL;
    R3_go = R3_mesh = R3_verts = R3_cols = NULL;
    R3_rgo = R3_rmesh = R3_rverts = R3_rcols = NULL;
    R3_n = R3_rn = 0;
}

// v137: a managed wrapper the GC can't see us holding may be collected and its memory
// reused. A Normal GC handle keeps our objects and arrays alive while the rain exists.
static void r3_pin(void *o) {
    if (looks_like_ptr(o)) ((qc_static1)g_r3[R3_GCALLOC])(NULL, o, NULL);
}

static float r3_rand(void) { return (float)arc4random_uniform(100000) / 100000.0f; }

// One mesh of `quads` quads on its own GameObject, arrays pinned for per-frame rewriting.
static bool r3_make_mesh(int quads, void *mat, int layer, void **go_out, void **mesh_out,
                         void **verts_out, void **cols_out) {
    void *t_go = mt_type("UnityEngine.GameObject, UnityEngine");
    void *t_mesh = mt_type("UnityEngine.Mesh, UnityEngine");
    void *t_mf = mt_type("UnityEngine.MeshFilter, UnityEngine");
    void *t_mr = mt_type("UnityEngine.MeshRenderer, UnityEngine");
    if (!looks_like_ptr(t_go) || !looks_like_ptr(t_mesh) || !looks_like_ptr(t_mf) || !looks_like_ptr(t_mr))
        return false;
    void *verts = r3_array("UnityEngine.Vector3, UnityEngine", quads * 4);
    void *cols  = r3_array("UnityEngine.Color32, UnityEngine", quads * 4);
    void *tris  = r3_array("System.Int32", quads * 6);
    if (!verts || !cols || !tris) return false;
    memset((uint8_t *)verts + OFF_ARRAY_DATA, 0, quads * 4 * sizeof(V3));   // collapsed, invisible
    memset((uint8_t *)cols + OFF_ARRAY_DATA, 0, quads * 4 * 4);
    int32_t *t = (int32_t *)((uint8_t *)tris + OFF_ARRAY_DATA);
    for (int q = 0; q < quads; q++) {
        int b = q * 4;
        t[q * 6 + 0] = b; t[q * 6 + 1] = b + 2; t[q * 6 + 2] = b + 1;
        t[q * 6 + 3] = b; t[q * 6 + 4] = b + 3; t[q * 6 + 5] = b + 2;
    }
    void *mesh = ((qc_static1)g_r3[R3_NEW])(NULL, t_mesh, NULL);
    void *go = ((qc_static1)g_r3[R3_NEW])(NULL, t_go, NULL);
    if (!r3_alive(mesh) || !r3_alive(go)) return false;
    ((qc_inst1)g_r3[R3_VERTS])(mesh, verts, NULL);
    ((qc_inst1)g_r3[R3_COLORS])(mesh, cols, NULL);
    ((qc_inst1)g_r3[R3_TRIS])(mesh, tris, NULL);
    void *mf = ((qc_inst1)g_r3[R3_ADDCOMP])(go, t_mf, NULL);
    void *mr = ((qc_inst1)g_r3[R3_ADDCOMP])(go, t_mr, NULL);
    if (!r3_alive(mf) || !r3_alive(mr)) { ((qc_static1)g_r3[R3_DESTROY])(NULL, go, NULL); return false; }
    ((qc_inst1)g_r3[R3_SETMESH])(mf, mesh, NULL);
    ((qc_inst1)g_r3[R3_SETMAT])(mr, mat, NULL);
    ((void (*)(void *, int, void *))g_r3[R3_SETLAYER])(go, layer, NULL);
    r3_pin(go); r3_pin(mesh); r3_pin(verts); r3_pin(cols);
    *go_out = go; *mesh_out = mesh; *verts_out = verts; *cols_out = cols;
    return true;
}

// Build (or rebuild, when the tunables changed) the rain. At most once every 5 s, 8 in all.
static bool rain3d_build(void) {
    static NSDictionary *sig_of = nil;
    static NSString *sig = @"{}";
    if (g_r3_cfg != sig_of) {
        sig_of = g_r3_cfg;
        NSData *j = [NSJSONSerialization dataWithJSONObject:(g_r3_cfg ?: @{}) options:ws_json_sorted() error:nil];
        sig = j ? [[NSString alloc] initWithData:j encoding:NSUTF8StringEncoding] : @"{}";
    }
    if (r3_alive(R3_go) && [sig isEqualToString:R3_built_for]) return true;
    static NSString *failed_for = nil;
    if ([sig isEqualToString:failed_for]) return false;
    CFTimeInterval now = CACurrentMediaTime();
    if (now - R3_last_try < 5.0) return false;
    R3_last_try = now;
    if (R3_builds >= 8) {
        WLOG(@"rain3d: built %d times already -- something keeps killing it, 3D rain OFF", R3_builds);
        g_r3_ok = false;
        return false;
    }
    R3_builds++;
    rain3d_destroy_ref();
    failed_for = sig;

    int n = (int)MAX(10, MIN(R3_MAX_DROPS, r3f(@"count", 500)));
    // hard caps: nothing a setting says can make a drop a slab again
    R3_area = MAX(0.2f, MIN(3, r3f(@"area", 1.2)));      R3_fall = MAX(0.1f, MIN(3, r3f(@"fall", 1.0)));
    R3_len = MAX(0.005f, MIN(0.2f, r3f(@"length", 0.06))); R3_wid = MAX(0.0001f, MIN(0.005f, r3f(@"width", 0.001)));
    R3_speed = MAX(0.1f, MIN(4, r3f(@"speed", 0.9)));     R3_near = MAX(0, MIN(0.9f, r3f(@"near", 0.25)));
    R3_ahead = MAX(-1, MIN(1, r3f(@"ahead", 0.3)));      R3_ground_off = r3f(@"ground_offset", 0);
    R3_wind = r3f(@"wind", 0.18);     R3_gust = r3f(@"gust", 0.12);
    R3_alpha = MAX(0, MIN(1, r3f(@"alpha", 0.45)));
    R3_rsize = MAX(0.002f, MIN(0.08f, r3f(@"ripple_size", 0.018)));   R3_rlife = MAX(0.1f, r3f(@"ripple_life", 0.7));
    R3_ralpha = MAX(0, MIN(1, r3f(@"ripple_alpha", 0.5)));
    R3_rwidth = MAX(0.0001f, MIN(0.006f, r3f(@"ripple_width", 0.001)));
    R3_splash = MAX(0, MIN(1, r3f(@"ripple_chance", 0.35)));   // share of landings that ripple
    R3_cr = (uint8_t)r3f(@"r", 205); R3_cg = (uint8_t)r3f(@"g", 220); R3_cb = (uint8_t)r3f(@"b", 255);
    int rn = (int)MAX(0, MIN(R3_MAX_RIPPLES, r3f(@"ripples", 80)));

    void *t_mat = mt_type("UnityEngine.Material, UnityEngine");
    if (!looks_like_ptr(t_mat)) { WLOG(@"rain3d: Unity types missing"); return false; }
    // a stock shader that blends by vertex colour; first one the build still contains wins
    NSString *want = rj(g_r3_cfg, @"shader");
    NSMutableArray *names = [NSMutableArray array];
    if ([want isKindOfClass:[NSString class]] && want.length) [names addObject:want];
    [names addObjectsFromArray:@[@"Sprites/Default", @"UI/Default", @"Particles/Alpha Blended",
                                 @"Legacy Shaders/Particles/Alpha Blended", @"Mobile/Particles/Alpha Blended"]];
    void *shader = NULL;
    NSString *shader_name = nil;
    for (NSString *nm in names) {
        void *s = ((qc_static1)g_qc[QC_STR])(NULL, (void *)nm.UTF8String, NULL);
        void *sh = looks_like_ptr(s) ? ((qc_static1)g_r3[R3_FINDSHADER])(NULL, s, NULL) : NULL;
        if (r3_alive(sh)) { shader = sh; shader_name = nm; break; }
        WLOG(@"rain3d: shader %@ not in this build", nm);
    }
    if (!shader) { WLOG(@"rain3d: no usable shader -- 3D rain OFF"); return false; }
    void *args = r3_array("System.Object", 1);
    if (!args) return false;
    *(void **)((uint8_t *)args + OFF_ARRAY_DATA) = shader;
    void *mat = ((r3_static2)g_r3[R3_NEW_ARGS])(NULL, t_mat, args, NULL);
    if (!r3_alive(mat)) { WLOG(@"rain3d: new Material failed"); return false; }
    r3_pin(mat);

    // a layer the camera actually draws
    void *cam = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
    int layer = 0;
    if (r3_alive(cam)) {
        int mask = (int)(intptr_t)((qc_inst0)g_r3[R3_CULLMASK])(cam, NULL);
        if (!(mask & 1) && mask) layer = __builtin_ctz((unsigned)mask);
        void *cgo = ((qc_inst0)g_qc[QC_COMP_GO])(cam, NULL);
        WLOG(@"rain3d: camera '%@' mask %08x -> layer %d", r3_alive(cgo) ?
             il2cpp_to_ns(((qc_inst0)g_r3[R3_NAME])(cgo, NULL)) : @"?", mask, layer);
    }
    if (!r3_make_mesh(n, mat, layer, &R3_go, &R3_mesh, &R3_verts, &R3_cols)) {
        WLOG(@"rain3d: rain mesh could not be built");
        R3_go = R3_mesh = R3_verts = R3_cols = NULL;
        return false;
    }
    R3_n = n;
    for (int i = 0; i < n; i++) R3_d[i].vy = 0;          // 0 = spawn on the first frame
    if (rn > 0 && r3_make_mesh(rn * R3_RING_SEGS, mat, layer, &R3_rgo, &R3_rmesh, &R3_rverts, &R3_rcols)) {
        R3_rn = rn;
        for (int i = 0; i < rn; i++) R3_rstart[i] = 0;
    } else if (rn > 0) {
        WLOG(@"rain3d: ripples could not be built -- rain only");
        R3_rgo = R3_rmesh = R3_rverts = R3_rcols = NULL;
    }
    if (!r3_make_mesh(R3_FOG_SHEETS, mat, layer, &R3_fgo, &R3_fmesh, &R3_fverts, &R3_fcols)) {
        WLOG(@"rain3d: fog sheets could not be built");
        R3_fgo = R3_fmesh = R3_fverts = R3_fcols = NULL;
    }
    if (!r3_make_mesh(1, mat, layer, &R3_sgo, &R3_smesh, &R3_sverts, &R3_scols)) {
        WLOG(@"rain3d: shade could not be built");
        R3_sgo = R3_smesh = R3_sverts = R3_scols = NULL;
    }

    R3_built_for = sig;
    failed_for = nil;
    WLOG(@"rain3d: build #%d: %d drops, %d ripples, shader %@", R3_builds, n, R3_rn, shader_name);
    return true;
}

// A drop lands at (x, z): take the next free ripple slot (a ring still spreading is left alone).
static void r3_ripple_at(float x, float z, float size, double now) {
    for (int tries = 0; tries < 4 && R3_rn; tries++) {
        int i = R3_rnext;
        R3_rnext = (R3_rnext + 1) % R3_rn;
        if (R3_rstart[i] && now - R3_rstart[i] < R3_rlife) continue;
        R3_rx[i] = x; R3_rz[i] = z; R3_rs[i] = size * (0.7f + 0.6f * r3_rand());
        R3_rstart[i] = now;
        return;
    }
}

static void r3_draw_ripples(double now, float D) {
    if (!R3_rn || !r3_alive(R3_rmesh)) return;
    V3 *v = (V3 *)((uint8_t *)R3_rverts + OFF_ARRAY_DATA);
    uint8_t *c = (uint8_t *)R3_rcols + OFF_ARRAY_DATA;
    float y = R3_ground + 0.0015f * D;                          // just above the ground
    for (int i = 0; i < R3_rn; i++) {
        double age = now - R3_rstart[i];
        bool live = R3_rstart[i] && age < R3_rlife;
        float t = live ? (float)(age / R3_rlife) : 1.0f;
        float r = R3_rs[i] * (1.0f - (1.0f - t) * (1.0f - t));   // fast out, slowing as it spreads
        float w = R3_rwidth * D * (1.0f - 0.5f * t);
        uint8_t a = live ? (uint8_t)(R3_ralpha * 255 * (1.0f - t) * (1.0f - t)) : 0;
        float r0 = MAX(0, r - w), r1 = r + w;
        for (int k = 0; k < R3_RING_SEGS; k++) {
            float a0 = (float)k / R3_RING_SEGS * 6.2831853f, a1 = (float)(k + 1) / R3_RING_SEGS * 6.2831853f;
            float c0 = cosf(a0), s0 = sinf(a0), c1 = cosf(a1), s1 = sinf(a1);
            int b = (i * R3_RING_SEGS + k) * 4;
            v[b + 0] = (V3){ R3_rx[i] + c0 * r0, y, R3_rz[i] + s0 * r0 };
            v[b + 1] = (V3){ R3_rx[i] + c1 * r0, y, R3_rz[i] + s1 * r0 };
            v[b + 2] = (V3){ R3_rx[i] + c1 * r1, y, R3_rz[i] + s1 * r1 };
            v[b + 3] = (V3){ R3_rx[i] + c0 * r1, y, R3_rz[i] + s0 * r1 };
            for (int j = 0; j < 4; j++) {
                uint8_t *p = c + (b + j) * 4;
                p[0] = R3_cr; p[1] = R3_cg; p[2] = R3_cb; p[3] = a;
            }
        }
    }
    ((qc_inst1)g_r3[R3_VERTS])(R3_rmesh, R3_rverts, NULL);
    ((qc_inst1)g_r3[R3_COLORS])(R3_rmesh, R3_rcols, NULL);
    ((qc_inst0)g_r3[R3_BOUNDS])(R3_rmesh, NULL);
}

// v141: WHERE it rains. The rain is anchored to the thing the camera is about -- the
// Pokemon in a catch (EncounterPokemon; the ground is the bottom of its model's bounds, so
// a hovering flyer doesn't lift the floor) or you on the map (MapAvatar, which stands on
// the ground). Every size is a share of the camera's distance to that anchor, so the huge
// catch arena and the map get the same look. No anchor = no rain.
struct UBounds { V3 c, e; };
typedef UBounds (*r3_getbounds)(void *self, void *mi);
static void *R3_anchor = NULL;       // anchor Transform (pinned)
static const char *R3_anchor_kind = "none";
static float R3_anchor_ground = 0, R3_anchor_h = 0;
static UILabel *R3_dbg = nil;

static void r3_find_anchor(void) {
    static void *t_ep = NULL, *t_av = NULL;
    if (!t_ep) t_ep = mt_type("Niantic.Holoholo.Encounter.EncounterPokemon, Assembly-CSharp");
    if (!t_av) t_av = mt_type("Niantic.Holoholo.Avatar.MapAvatar, Assembly-CSharp");
    void *ep = looks_like_ptr(t_ep) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_ep, NULL) : NULL;
    void *obj = r3_alive(ep) ? ep : NULL;
    const char *kind = "pokemon";
    // v206: once the Pokemon is in the ball the game switches it off and FindObjectOfType stops
    // seeing it, so the rain stopped for the whole ball animation. While its Transform still
    // exists and the catch camera is still on that spot, keep raining there.
    static void *last_ep_tr = NULL;
    if (obj) {
        void *t = ((qc_inst0)g_qc[QC_COMP_TR])(obj, NULL);
        if (r3_alive(t) && t != last_ep_tr) { r3_pin(t); last_ep_tr = t; }
    } else if (r3_alive(last_ep_tr)) {
        void *cam = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
        void *ctr = r3_alive(cam) ? ((qc_inst0)g_qc[QC_COMP_TR])(cam, NULL) : NULL;
        if (r3_alive(ctr)) {
            V3 c = ((r3_getv3)g_r3[R3_GETPOS])(ctr, NULL), a = ((r3_getv3)g_r3[R3_GETPOS])(last_ep_tr, NULL);
            float dx = c.x - a.x, dy = c.y - a.y, dz = c.z - a.z;
            if (dx * dx + dy * dy + dz * dz < 15.0f * 15.0f) {
                if (R3_anchor != last_ep_tr) WLOG(@"rain3d: Pokemon in the ball -- still raining on its spot");
                R3_anchor = last_ep_tr;
                R3_anchor_kind = "pokemon";
                R3_anchor_ground = a.y;
                R3_anchor_h = 0;
                return;
            }
        }
    }
    if (!obj) {
        void *av = looks_like_ptr(t_av) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_av, NULL) : NULL;
        obj = r3_alive(av) ? av : NULL;
        kind = "map";
    }
    void *tr = obj ? ((qc_inst0)g_qc[QC_COMP_TR])(obj, NULL) : NULL;
    if (!r3_alive(tr)) { R3_anchor = NULL; R3_anchor_kind = "none"; return; }
    if (tr != R3_anchor) {
        r3_pin(tr);
        WLOG(@"rain3d: anchored to the %s", kind);
    }
    R3_anchor = tr;
    R3_anchor_kind = kind;
    V3 a = ((r3_getv3)g_r3[R3_GETPOS])(tr, NULL);
    R3_anchor_ground = a.y;
    R3_anchor_h = 0;
    // v142: the floor is the anchor's own height (the Pokemon's root sits on the ground).
    // v141 also read the model's bounds through EncounterPokemon.renderers at the 0.29
    // offset (0x80), unverified on 0.35 -- a likely second crash, so it's gone.
}

// On-screen numbers while tuning (weather.rain.debug): where the camera and anchor are.
static void r3_debug(bool on, NSString *text) {
    UIView *parent = mt_unity_view();
    if (!on || !parent) { R3_dbg.hidden = YES; return; }
    if (!R3_dbg || R3_dbg.superview != parent) {
        [R3_dbg removeFromSuperview];
        R3_dbg = [UILabel new];
        R3_dbg.numberOfLines = 0;
        R3_dbg.font = ws_mono(10, UIFontWeightSemibold);
        R3_dbg.textColor = UIColor.whiteColor;
        R3_dbg.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        R3_dbg.userInteractionEnabled = NO;
        [parent addSubview:R3_dbg];
    }
    R3_dbg.hidden = NO;
    R3_dbg.text = text;
    CGSize sz = [R3_dbg sizeThatFits:CGSizeMake(parent.bounds.size.width - 16, 400)];
    R3_dbg.frame = CGRectMake(8, ws_safe_insets(parent).top + 44, sz.width + 8, sz.height + 6);
    [parent bringSubviewToFront:R3_dbg];
}

// v145: FOG SHEETS on the catch screen. Scene fog alone can't be trusted to hide the
// backdrop (its shader may ignore fog, or it may be drawn apart), so in fog the catch gets
// a few big camera-facing sheets in the fog colour BEHIND the Pokemon, each further one
// thicker, the last one solid -- the trees fade into grey and then are gone. Rain and snow
// get a thinner version (a misty distance). The Pokemon stands in front of all of them
// (opaque, drawn first), the rain in front of them too. mist 0 = sheets hidden.
static void r3_draw_mist(float mist, V3 p, V3 f, float D, bool night) {
    if (!r3_alive(R3_fgo) || !r3_alive(R3_fmesh)) return;
    ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_fgo, mist > 0, NULL);
    if (mist <= 0) return;
    static const float dist[R3_FOG_SHEETS]  = { 12.0f, 7.0f, 4.6f, 3.2f, 2.3f, 1.6f };   // far first
    static const float alpha[R3_FOG_SHEETS] = { 1.00f, 0.75f, 0.55f, 0.42f, 0.32f, 0.22f };
    float hl = sqrtf(f.x * f.x + f.z * f.z);
    float hx = hl > 1e-3f ? f.x / hl : 0, hz = hl > 1e-3f ? f.z / hl : 1;   // camera's flat forward
    float rx = hz, rz = -hx;                                              // ...and flat right
    float k = night ? 0.4f : 1.0f;                                        // no glowing grey walls at night
    uint8_t cr = (uint8_t)(g_wx_fogcol[0] * k * 255), cg = (uint8_t)(g_wx_fogcol[1] * k * 255),
            cb = (uint8_t)(g_wx_fogcol[2] * k * 255);
    V3 *v = (V3 *)((uint8_t *)R3_fverts + OFF_ARRAY_DATA);
    uint8_t *c = (uint8_t *)R3_fcols + OFF_ARRAY_DATA;
    for (int i = 0; i < R3_FOG_SHEETS; i++) {
        float di = dist[i] * D;
        float cx = p.x + hx * di, cz = p.z + hz * di;
        float half = di * 2.2f, lo = R3_ground - 0.1f * D, hi = R3_ground + di * 1.6f;
        int b = i * 4;
        v[b + 0] = (V3){ cx - rx * half, lo, cz - rz * half };
        v[b + 1] = (V3){ cx + rx * half, lo, cz + rz * half };
        v[b + 2] = (V3){ cx + rx * half, hi, cz + rz * half };
        v[b + 3] = (V3){ cx - rx * half, hi, cz - rz * half };
        float a = MIN(1.0f, alpha[i] * mist);
        uint8_t abot = (uint8_t)(a * 255), atop = (uint8_t)(a * (i == 0 ? 1.0f : 0.8f) * 255);
        for (int j = 0; j < 4; j++) {
            uint8_t *q = c + (b + j) * 4;
            q[0] = cr; q[1] = cg; q[2] = cb; q[3] = j < 2 ? abot : atop;
        }
    }
    ((qc_inst1)g_r3[R3_VERTS])(R3_fmesh, R3_fverts, NULL);
    ((qc_inst1)g_r3[R3_COLORS])(R3_fmesh, R3_fcols, NULL);
    ((qc_inst0)g_r3[R3_BOUNDS])(R3_fmesh, NULL);
}

// v148: THE DAYTIME SHADE. Bad weather at noon still looked like a sunny map, just with
// drops on it. One big see-through sheet straight in front of the camera, between it and
// everything it looks at, dims the whole 3D scene -- the map and the catch -- but not the
// HUD, which Unity draws afterwards. How dark comes from weather_tick (weather.rainfx.shade_*).
static void r3_draw_shade(float shade, V3 p, V3 f, float D, NSString *cond) {
    if (!r3_alive(R3_sgo) || !r3_alive(R3_smesh)) return;
    ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_sgo, shade > 0, NULL);
    if (shade <= 0) return;
    float fl = sqrtf(f.x * f.x + f.y * f.y + f.z * f.z);
    if (fl < 1e-4f) return;
    V3 F = { f.x / fl, f.y / fl, f.z / fl };
    float hl = sqrtf(F.x * F.x + F.z * F.z);
    V3 R = hl > 1e-3f ? (V3){ F.z / hl, 0, -F.x / hl } : (V3){ 1, 0, 0 };   // camera's right
    V3 Up = { R.y * F.z - R.z * F.y, R.z * F.x - R.x * F.z, R.x * F.y - R.y * F.x };
    float dist = MAX(0.02f, MIN(0.9f, r3f(@"shade_distance", 0.3f))) * D;  // in front of the anchor
    float half = dist * 3.0f;                                                // well past the screen edges
    V3 c = { p.x + F.x * dist, p.y + F.y * dist, p.z + F.z * dist };
    V3 *v = (V3 *)((uint8_t *)R3_sverts + OFF_ARRAY_DATA);
    v[0] = (V3){ c.x - R.x * half - Up.x * half, c.y - R.y * half - Up.y * half, c.z - R.z * half - Up.z * half };
    v[1] = (V3){ c.x + R.x * half - Up.x * half, c.y + R.y * half - Up.y * half, c.z + R.z * half - Up.z * half };
    v[2] = (V3){ c.x + R.x * half + Up.x * half, c.y + R.y * half + Up.y * half, c.z + R.z * half + Up.z * half };
    v[3] = (V3){ c.x - R.x * half + Up.x * half, c.y - R.y * half + Up.y * half, c.z - R.z * half + Up.z * half };
    // storm grey-blue; snow and fog a lighter grey so they read as dull, not as dusk
    bool pale = [cond isEqualToString:@"snow"] || [cond isEqualToString:@"fog"];
    uint8_t r = pale ? 70 : 16, g = pale ? 76 : 24, b = pale ? 86 : 36, a = (uint8_t)(MIN(0.85f, shade) * 255);
    uint8_t *q = (uint8_t *)R3_scols + OFF_ARRAY_DATA;
    for (int j = 0; j < 4; j++) { q[j * 4] = r; q[j * 4 + 1] = g; q[j * 4 + 2] = b; q[j * 4 + 3] = a; }
    ((qc_inst1)g_r3[R3_VERTS])(R3_smesh, R3_sverts, NULL);
    ((qc_inst1)g_r3[R3_COLORS])(R3_smesh, R3_scols, NULL);
    ((qc_inst0)g_r3[R3_BOUNDS])(R3_smesh, NULL);
}

// v143: one particle system, three weathers. kind: 0 none, 1 rain, 2 snow, 3 wind.
//   rain -- streaks along each drop's velocity, landing in ripples (above)
//   snow -- small flat flakes drifting down slowly, swaying, no ripples
//   wind -- a few long faint streaks blowing sideways low over the ground, fading in and out
// Sizes and speeds are shares of D (camera -> anchor) like the rain; snow_* / wind_* in
// weather.rainfx tune them. Each streak is widened across the line of sight (cross of its
// direction and the view), so it faces the camera whichever way it points.
#define R3_KIND_RAIN 1
#define R3_KIND_SNOW 2
#define R3_KIND_WIND 3
static void rain3d_frame(int kind, float mist_want, float shade_want) {
    if (!g_r3_ok) return;
    static bool hidden = true;
    bool raining = kind != 0 || mist_want > 0 || shade_want > 0;
    static int last_kind = 0;
    if (kind != last_kind) {                    // new weather: everything starts over
        last_kind = kind;
        for (int i = 0; i < R3_MAX_DROPS; i++) R3_d[i].vy = 0;
        for (int i = 0; i < R3_MAX_RIPPLES; i++) R3_rstart[i] = 0;
    }
    if (!raining) {
        if (!hidden && r3_alive(R3_go)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_go, false, NULL);
        if (!hidden && r3_alive(R3_rgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_rgo, false, NULL);
        if (!hidden && r3_alive(R3_fgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_fgo, false, NULL);
        if (!hidden && r3_alive(R3_sgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_sgo, false, NULL);
        hidden = true;
        r3_debug(false, nil);
        return;
    }
    if (hidden && r3_alive(R3_go)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_go, true, NULL);
    if (hidden && r3_alive(R3_rgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_rgo, true, NULL);
    hidden = false;
    CFTimeInterval t0 = CACurrentMediaTime();
    if (R3_go && (!r3_alive(R3_go) || !r3_alive(R3_mesh))) {
        WLOG(@"rain3d: rain object gone (scene change?)");
        R3_go = R3_mesh = NULL; R3_built_for = nil;
        if (!r3_alive(R3_rgo)) R3_rgo = R3_rmesh = NULL;
    }
    if (!rain3d_build()) return;
    // Camera.main is a tag search: once a second, not every frame
    static void *ctr = NULL;
    static CFTimeInterval cam_at = 0;
    if (!r3_alive(ctr) || t0 - cam_at > 1.0) {
        cam_at = t0;
        void *cam = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
        void *tr = r3_alive(cam) ? ((qc_inst0)g_qc[QC_COMP_TR])(cam, NULL) : NULL;
        if (r3_alive(tr) && tr != ctr) { ctr = tr; r3_pin(tr); }
        else if (!r3_alive(tr)) ctr = NULL;
        r3_find_anchor();
    }
    if (!ctr) return;
    // nothing to rain around (a menu scene, loading): draw nothing this frame
    bool anchored = r3_alive(R3_anchor);
    if (r3_alive(R3_go)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_go, anchored && kind, NULL);
    if (r3_alive(R3_rgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_rgo, anchored && kind, NULL);
    if (!anchored && r3_alive(R3_fgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_fgo, false, NULL);
    if (!anchored && r3_alive(R3_sgo)) ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(R3_sgo, false, NULL);
    if (!anchored) { r3_debug([rj(g_r3_cfg, @"hud") boolValue], @"rain: no anchor (no Pokemon, no avatar)"); return; }

    static CFTimeInterval last = 0;
    float dt = (last && t0 > last) ? (float)MIN(0.05, t0 - last) : 0.016f;
    last = t0;
    V3 p = ((r3_getv3)g_r3[R3_GETPOS])(ctr, NULL);
    V3 f = ((r3_getv3)g_r3[R3_FORWARD])(ctr, NULL);
    V3 an = ((r3_getv3)g_r3[R3_GETPOS])(R3_anchor, NULL);
    R3_ground = R3_anchor_ground + R3_ground_off;
    float camh = p.y - R3_ground;
    float adx = an.x - p.x, ady = an.y - p.y, adz = an.z - p.z;
    float D = MAX(0.05f, sqrtf(adx * adx + ady * ady + adz * adz));   // camera -> anchor: THE scale
    // v204: a new anchor or a jump in scale (leaving a catch: D ~3 -> ~49) starts every drop
    // over. Without it the catch's tiny, slow flakes kept falling in a clump on the map.
    {
        static const char *was_kind = NULL;
        static float was_D = 0;
        if (!was_kind || strcmp(was_kind, R3_anchor_kind) || (was_D > 0 && (D > was_D * 2 || D < was_D * 0.5f))) {
            for (int i = 0; i < R3_MAX_DROPS; i++) R3_d[i].vy = 0;
            for (int i = 0; i < R3_MAX_RIPPLES; i++) R3_rstart[i] = 0;
        }
        was_kind = R3_anchor_kind;
        was_D = D;
    }
    // the rain's centre: the anchor, nudged a little further from the camera so the
    // ground behind it is covered as well as the space in front
    float hl0 = sqrtf(adx * adx + adz * adz);
    float fx = an.x + (hl0 > 1e-3f ? adx / hl0 : f.x) * R3_ahead * D;
    float fz = an.z + (hl0 > 1e-3f ? adz / hl0 : f.z) * R3_ahead * D;
    float focus = D;
    float area = R3_area * D, speed = R3_speed * D, wid = R3_wid * D;
    float fall = MAX(R3_fall * D, camh + R3_len * D);             // start above the camera's eye line
    float near2 = (R3_near * D) * (R3_near * D);
    // the camera's horizontal right: each streak is widened along it so it faces the camera
    float hl = sqrtf(f.x * f.x + f.z * f.z);
    float rx = hl > 1e-3f ? f.z / hl : 1, rz = hl > 1e-3f ? -f.x / hl : 0;
    // wind: one direction, strength breathing with slow gusts
    float gust = R3_wind + R3_gust * (sinf((float)t0 * 0.37f) * 0.6f + sinf((float)t0 * 1.13f + 1.7f) * 0.4f);
    float wx = 0.8f, wz = 0.6f;                                   // blows from one side of the world

    // the catch screen: the Pokemon anchor, or (during "A wild X appeared!", before it
    // exists) a camera this close to the avatar can only be the catch camera
    bool catch_screen = !strcmp(R3_anchor_kind, "pokemon") || D < 12;
    time_t tt = time(NULL);
    struct tm lt;
    localtime_r(&tt, &lt);
    bool night = lt.tm_hour >= 20 || lt.tm_hour < 6;
    r3_draw_mist(catch_screen ? mist_want : 0, p, f, D, night);
    r3_draw_shade(shade_want, p, f, D, rj(g_wx, @"condition"));
    if (!kind) return;                            // fog / cloudy: sheets only, nothing falls
    V3 *v = (V3 *)((uint8_t *)R3_verts + OFF_ARRAY_DATA);
    uint8_t *c = (uint8_t *)R3_cols + OFF_ARRAY_DATA;
    bool snow = kind == R3_KIND_SNOW, wind = kind == R3_KIND_WIND;
    if (snow) speed = r3f(@"snow_speed", 0.12f) * D;
    if (wind) speed = r3f(@"wind_speed", 1.6f) * D;
    float flake = MAX(0.0005f, MIN(0.03f, r3f(@"snow_size", 0.006f))) * D;
    float wlen = MAX(0.02f, MIN(0.4f, r3f(@"wind_length", 0.15f))) * D;
    float walpha = MAX(0, MIN(1, r3f(@"wind_alpha", 0.22f)));
    float salpha = MAX(0, MIN(1, r3f(@"snow_alpha", 0.85f)));
    int live_n = wind ? MAX(1, R3_n / 8) : R3_n;                 // wind: a few gusts, not a storm
    uint8_t cr = snow || wind ? 255 : R3_cr, cg = snow || wind ? 255 : R3_cg, cb = snow || wind ? 255 : R3_cb;
    for (int i = 0; i < R3_n; i++) {
        R3Drop *d = &R3_d[i];
        int b = i * 4;
        if (i >= live_n) {                                        // unused this weather: collapsed
            for (int k = 0; k < 4; k++) { v[b + k] = (V3){ fx, R3_ground, fz }; c[(b + k) * 4 + 3] = 0; }
            continue;
        }
        bool respawn = d->vy == 0;
        if (!respawn) {
            d->age += dt;
            if (wind) {
                float drift = speed * (1.0f + gust - R3_wind + d->drift);
                d->x += wx * drift * dt;
                d->z += wz * drift * dt;
                d->y += sinf((float)t0 * 2.0f + d->drift * 40) * 0.02f * D * dt;
                if (d->age >= d->life) respawn = true;
            } else {
                float drift = (gust + d->drift) * (snow ? R3_speed * D * 0.35f : speed);
                float sway = snow ? sinf((float)t0 * 1.3f + d->drift * 50) * speed * 0.6f : 0;
                d->x += (wx * drift + sway * rz) * dt;
                d->z += (wz * drift - sway * rx) * dt;
                d->y -= d->vy * dt;
                if (d->y <= R3_ground) {                          // it LANDED
                    if (!snow && r3_rand() < R3_splash) r3_ripple_at(d->x, d->z, R3_rsize * D, t0);
                    respawn = true;
                }
            }
            float dx = d->x - fx, dz = d->z - fz;
            if (dx * dx + dz * dz > area * area * 1.7f) respawn = true;   // the camera moved on
        }
        if (respawn) {
            bool first = d->vy == 0;
            float ang = r3_rand() * 6.2831853f, rad = sqrtf(r3_rand()) * area;
            d->x = fx + cosf(ang) * rad;
            d->z = fz + sinf(ang) * rad;
            d->age = 0;
            d->drift = (r3_rand() - 0.5f) * R3_gust;              // each one catches the wind a bit differently
            if (wind) {
                d->y = R3_ground + fall * 0.35f * r3_rand();
                d->vy = 1;                                        // (only "alive" for the wind)
                d->len = wlen * (0.6f + 0.8f * r3_rand());
                d->life = 0.6f + 0.9f * r3_rand();
                if (first) d->age = d->life * r3_rand();
                d->a = walpha * (0.6f + 0.4f * r3_rand());
            } else {
                d->y = R3_ground + fall * (first ? r3_rand() : 0.85f + 0.3f * r3_rand());
                d->vy = speed * (0.8f + 0.4f * r3_rand());        // heavier drops fall faster...
                d->len = snow ? flake * (0.7f + 0.6f * r3_rand())
                              : R3_len * D * (d->vy / speed) * (0.8f + 0.4f * r3_rand());   // ...and streak longer
                d->a = (snow ? salpha : R3_alpha) * (0.5f + 0.5f * r3_rand());
            }
        }
        // the quad: from the tip back along its direction u, widened across the line of sight
        float ux, uy, uz, len = d->len, wd = wid;
        uint8_t atip, atail;
        if (wind) {
            ux = -wx; uy = 0; uz = -wz;
            float t = d->age / d->life;
            atip = atail = (uint8_t)(d->a * 255 * sinf(3.1415926f * MIN(1, t)));   // fade in and out
            atail = 0;
        } else if (snow) {
            ux = 0; uy = 1; uz = 0;
            wd = d->len * 0.5f;
            atip = atail = (uint8_t)(d->a * 255);                 // a flake is solid, no tail
        } else {
            float drift = (gust + d->drift) * speed;
            float vx = wx * drift, vz = wz * drift, vy = -d->vy;
            float vl = sqrtf(vx * vx + vy * vy + vz * vz);
            ux = -vx / vl; uy = -vy / vl; uz = -vz / vl;
            len = MIN(d->len, d->y - R3_ground + d->len * 0.02f);   // never poke through the ground
            atip = (uint8_t)(d->a * 255); atail = 0;              // bright tip, fading tail
        }
        V3 bot = { d->x, d->y, d->z };
        V3 top = { d->x + ux * len, d->y + uy * len, d->z + uz * len };
        float ex = d->x - p.x, ey = d->y - p.y, ez = d->z - p.z;
        if (ex * ex + ey * ey + ez * ez < near2) atip = atail = 0;   // too close: the pale-bar problem
        // side = u x (view direction), normalised, times the half-width
        float sx = uy * ez - uz * ey, sy = uz * ex - ux * ez, sz = ux * ey - uy * ex;
        float sl = sqrtf(sx * sx + sy * sy + sz * sz);
        if (sl < 1e-6f) { sx = rx; sy = 0; sz = rz; sl = 1; }
        sx = sx / sl * wd; sy = sy / sl * wd; sz = sz / sl * wd;
        v[b + 0] = (V3){ bot.x - sx, bot.y - sy, bot.z - sz };
        v[b + 1] = (V3){ bot.x + sx, bot.y + sy, bot.z + sz };
        v[b + 2] = (V3){ top.x + sx, top.y + sy, top.z + sz };
        v[b + 3] = (V3){ top.x - sx, top.y - sy, top.z - sz };
        for (int k = 0; k < 4; k++) {
            uint8_t *q = c + (b + k) * 4;
            q[0] = cr; q[1] = cg; q[2] = cb;
            q[3] = k < 2 ? atip : atail;
        }
    }
    ((qc_inst1)g_r3[R3_VERTS])(R3_mesh, R3_verts, NULL);
    ((qc_inst1)g_r3[R3_COLORS])(R3_mesh, R3_cols, NULL);
    ((qc_inst0)g_r3[R3_BOUNDS])(R3_mesh, NULL);
    r3_draw_ripples(t0, D);
    static CFTimeInterval dbg_at = 0;
    if (t0 - dbg_at > 0.25) {
        dbg_at = t0;
        // v142: Camera.main is NULL for a moment while the catch screen swaps cameras; calling
        // into it then threw inside the game and crashed it (v141). Only ask a live camera.
        void *cam_now = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
        float fov = r3_alive(cam_now) ? ((float (*)(void *, void *))g_r3[R3_FOV])(cam_now, NULL) : 0;
        NSString *tall = R3_anchor_h > 0 ? [NSString stringWithFormat:@"  pokemon %.2f tall", R3_anchor_h] : @"";
        NSString *l1 = [NSString stringWithFormat:@"%s v148  anchor: %s", snow ? "snow" : wind ? "wind" : "rain",
                        R3_anchor_kind];
        NSString *l2 = [NSString stringWithFormat:@"cam    (%.2f, %.2f, %.2f)  fov %.0f", p.x, p.y, p.z, fov];
        NSString *l3 = [NSString stringWithFormat:@"anchor (%.2f, %.2f, %.2f)  ground y %.2f%@", an.x, an.y, an.z,
                        R3_ground, tall];
        NSString *l4 = [NSString stringWithFormat:@"dist %.2f  area %.2f  fall %.2f  len %.3f  ripple %.3f",
                        D, area, fall, R3_len * D, R3_rsize * D];
        r3_debug([rj(g_r3_cfg, @"hud") boolValue], [@[l1, l2, l3, l4] componentsJoinedByString:@"\n"]);
    }

    static int logged = 0;
    if (logged++ == 30)
        WLOG(@"rain3d: [%s] camera (%.2f, %.2f, %.2f), anchor (%.2f, %.2f, %.2f), ground %.2f, dist %.2f, "
             @"area %.2f, fall %.2f", R3_anchor_kind, p.x, p.y, p.z, an.x, an.y, an.z, R3_ground, focus, area, fall);
    // what the rain costs per frame, every 10 s
    static double spent = 0; static int frames = 0; static CFTimeInterval since = 0;
    spent += CACurrentMediaTime() - t0; frames++;
    if (!since) since = t0;
    if (t0 - since >= 10.0) {
        WLOG(@"rain3d: %d frames in %.0f s (%.0f/s), %.0f us each, %d builds, camera %.1f up",
             frames, t0 - since, frames / (t0 - since), spent / frames * 1e6, R3_builds, camh);
        spent = 0; frames = 0; since = t0;
    }
}


// v144: once a second, where the camera is relative to the anchor -- for the fog, which has
// to know it whether or not anything is falling. Uses the rain's camera/anchor lookups.
static void weather_fog_tick(NSString *cond, bool on_map) {
    if (!g_r3_ok) {                            // no 3D lookups: the old map-only fog
        weather_scene_apply(cond, on_map, 0, on_map ? "map" : "none");
        return;
    }
    void *cam = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
    void *ctr = r3_alive(cam) ? ((qc_inst0)g_qc[QC_COMP_TR])(cam, NULL) : NULL;
    r3_find_anchor();
    if (!r3_alive(ctr) || !r3_alive(R3_anchor)) {
        weather_scene_apply(cond, false, 0, "none");
        return;
    }
    V3 p = ((r3_getv3)g_r3[R3_GETPOS])(ctr, NULL);
    V3 an = ((r3_getv3)g_r3[R3_GETPOS])(R3_anchor, NULL);
    float dx = an.x - p.x, dy = an.y - p.y, dz = an.z - p.z;
    weather_scene_apply(cond, true, MAX(0.05f, sqrtf(dx * dx + dy * dy + dz * dz)), R3_anchor_kind);
}

// v175: the way the map camera faces, for the GPS joystick (windstockgps.dylib looks up
// ws_camera_yaw by name and steers "up" = into the screen instead of north). Read on the
// main thread (Unity's) every 0.1 s; the dylib's step timer runs there too and only reads
// the cached number. Degrees clockwise from Unity +z, taken as north (+x east). Only on the
// map -- the catch camera faces the Pokemon, not anywhere you'd walk.
static double g_cam_yaw = 0;
static bool g_cam_yaw_ok = false;

extern "C" __attribute__((visibility("default"), used))
bool ws_camera_yaw(double *deg) {
    if (!g_cam_yaw_ok) return false;
    if (deg) *deg = g_cam_yaw;
    return true;
}

static void cam_yaw_tick(void) {
    static void *ctr = NULL;
    static CFTimeInterval at = 0;
    CFTimeInterval t0 = CACurrentMediaTime();
    if (!r3_alive(ctr) || t0 - at > 1.0) {   // Camera.main + the anchor search: once a second
        at = t0;
        void *cam = ((qc_inst0)g_r3[R3_CAMMAIN])(NULL, NULL);
        void *tr = r3_alive(cam) ? ((qc_inst0)g_qc[QC_COMP_TR])(cam, NULL) : NULL;
        if (r3_alive(tr) && tr != ctr) { ctr = tr; r3_pin(tr); }
        else if (!r3_alive(tr)) ctr = NULL;
        r3_find_anchor();
    }
    if (!r3_alive(ctr) || strcmp(R3_anchor_kind, "map")) { g_cam_yaw_ok = false; return; }
    V3 f = ((r3_getv3)g_r3[R3_FORWARD])(ctr, NULL);
    if (f.x * f.x + f.z * f.z < 1e-6f) { g_cam_yaw_ok = false; return; }   // straight down: no yaw
    double yaw = fmod(atan2(f.x, f.z) * 180.0 / M_PI + 360.0, 360.0);
    static int logged = 0;
    if (!g_cam_yaw_ok && logged++ < 5) WLOG(@"gps steer: map camera yaw %.0f", yaw);
    g_cam_yaw = yaw;
    g_cam_yaw_ok = true;
}

// v203: the weather is READY when the map first shows. The last known reply is kept on the
// phone and used from the moment the tweak loads (if it's under WX_CACHE_MAX_S old), the
// server is asked straight away and then every 5 s until it knows where the trainer is, and
// "unknown" answers in the first two minutes (before login the server has no location) don't
// throw the kept weather away.
#define WX_CACHE_KEY   @"windstock.weather.last"
#define WX_CACHE_MAX_S (6 * 3600)
static bool g_wx_live = false;                 // a real (known) reply arrived this session
static CFTimeInterval g_wx_started = 0;
static void wx_cache_load(void) {
    g_wx_started = CACurrentMediaTime();
    NSDictionary *c = [[NSUserDefaults standardUserDefaults] dictionaryForKey:WX_CACHE_KEY];
    double age = [NSDate date].timeIntervalSince1970 - [c[@"saved_at"] doubleValue];
    NSData *d = [c[@"reply"] isKindOfClass:[NSData class]] ? c[@"reply"] : nil;
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]] || age < 0 || age > WX_CACHE_MAX_S) {
        WLOG(@"weather: no kept weather%@", c ? [NSString stringWithFormat:@" (%.0f min old)", age / 60] : @"");
        return;
    }
    g_wx_tint = j;
    if (WEATHER_FX) g_wx = j;
    WLOG(@"weather: kept weather %@ from %.0f min ago, used until the server answers", rj(j, @"condition"), age / 60);
}
static void wx_cache_save(NSData *raw) {
    if (!raw) return;
    [[NSUserDefaults standardUserDefaults] setObject:@{ @"saved_at": @([NSDate date].timeIntervalSince1970), @"reply": raw }
                                              forKey:WX_CACHE_KEY];
}

__attribute__((unused))
static void weather_poll(void) {
    // v150: shelved -- g_wx stays nil, no condition. v200: still asked for the weather tint,
    // which reads its own copy (g_wx_tint), so rain, fog, shade and the icon stay off.
    if (!WEATHER_FX && !WEATHER_PARTICLES && !g_tint_ok) return;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:WEATHER_URL]];
    rq.timeoutInterval = 6;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (e) {
                static int w = 0;
                if (w++ < 3) WLOG(@"weather: poll failed: %@", e.localizedDescription);
                return;
            }
            if (![j isKindOfClass:[NSDictionary class]]) return;
            bool known = [rj(j, @"known") boolValue];
            if (known) { g_wx_live = true; wx_cache_save(d); }
            else if (g_wx_tint && CACurrentMediaTime() - g_wx_started < 120) return;   // keep the kept weather
            NSString *was = rj(g_wx_tint, @"condition"), *now = rj(j, @"condition");
            if (!(was == now || [was isEqualToString:now]))
                WLOG(@"weather: %@ -> %@ (%@°C, boosts %@)%@", was ?: @"(none)", now ?: @"(unknown)",
                     rj(j, @"temp_c"), rj(j, @"boosted_names"),
                     rj(j, @"error") ? [NSString stringWithFormat:@" server error: %@", rj(j, @"error")] : @"");
            g_wx_tint = j;
            if (WEATHER_FX) g_wx = j;
        });
    }] resume];
}

__attribute__((unused))
static UIImage *wx_shape(CGSize size, CGFloat alpha) {
    return ws_draw_image(size, ^(CGContextRef cg) {
        [[UIColor colorWithWhite:1 alpha:alpha] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height)
                                    cornerRadius:MIN(size.width, size.height) / 2] fill];
    });
}

// v43: a rain streak that fades out at both ends -- a hard-edged bar reads as a white
// stick, a gradient one reads as a fast-moving drop.
__attribute__((unused))
static UIImage *wx_streak(CGFloat w, CGFloat h, CGFloat alpha) {
    return ws_draw_image(CGSizeMake(w, h), ^(CGContextRef c) {
        CGFloat comps[12] = {1, 1, 1, 0,  1, 1, 1, alpha,  1, 1, 1, 0};
        CGFloat stops[3] = {0.0, 0.45, 1.0};
        CGColorSpaceRef sp = CGColorSpaceCreateDeviceRGB();
        CGGradientRef g = CGGradientCreateWithColorComponents(sp, comps, stops, 3);
        CGContextAddPath(c, [UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, w, h)
                                                      cornerRadius:w / 2].CGPath);
        CGContextClip(c);
        CGContextDrawLinearGradient(c, g, CGPointMake(w / 2, 0), CGPointMake(w / 2, h), 0);
        CGGradientRelease(g);
        CGColorSpaceRelease(sp);
    });
}

__attribute__((unused))
static CAEmitterCell *wx_cell(UIImage *img, float rate, CGFloat velocity, CGFloat velocityRange,
                              CGFloat longitude, CGFloat longitudeRange, float lifetime,
                              CGFloat scale, CGFloat scaleRange) {
    CAEmitterCell *c = [CAEmitterCell emitterCell];
    c.contents = (id)img.CGImage;
    c.birthRate = rate;
    c.velocity = velocity;
    c.velocityRange = velocityRange;
    c.emissionLongitude = longitude;
    c.emissionRange = longitudeRange;
    c.lifetime = lifetime;
    c.scale = scale;
    c.scaleRange = scaleRange;
    return c;
}

// Build the effect for a condition at the current view size.
__attribute__((unused))
static void weather_layout(NSString *cond) {
    CGSize sz = W_tint.bounds.size;
    W_emitter.frame = W_tint.bounds;
    W_fx_far.frame = W_fx_near.frame = W_tint.bounds;
    wx_seed_drops(cond, W_tint.bounds.size);
    g_wx_drawn = cond;
    g_wx_size = sz;
    UIColor *tint = UIColor.clearColor;
    NSArray *cells = @[];
    W_emitter.emitterShape = kCAEmitterLayerLine;
    W_emitter.emitterPosition = CGPointMake(sz.width / 2, -20);
    W_emitter.emitterSize = CGSizeMake(sz.width * 1.3, 1);
    if ([cond isEqualToString:@"rainy"]) {
        // Three layers so the rain has depth: faint+slow far away, brighter+faster near.
        tint = [UIColor colorWithRed:0.16 green:0.22 blue:0.31 alpha:0.24];
        // A white drop vanishes over bright green ground, so each layer is a dark
        // streak with a brighter one just behind it -- readable on light AND dark map.
        CAEmitterCell *shade = wx_cell(wx_streak(3, 34, 0.30), 55, 1050, 180,
                                       M_PI_2 + 0.10, 0.015, 2.6, 0.8, 0.2);
        shade.color = [UIColor colorWithRed:0.12 green:0.18 blue:0.28 alpha:1].CGColor;
        CAEmitterCell *far = wx_cell(wx_streak(2, 26, 0.45), 60, 750, 120,
                                     M_PI_2 + 0.09, 0.015, 3.0, 0.5, 0.1);
        far.color = [UIColor colorWithRed:0.80 green:0.88 blue:1.0 alpha:1].CGColor;
        CAEmitterCell *near = wx_cell(wx_streak(3, 44, 0.60), 30, 1450, 250,
                                      M_PI_2 + 0.11, 0.02, 2.4, 1.0, 0.2);
        near.color = [UIColor colorWithRed:0.88 green:0.94 blue:1.0 alpha:1].CGColor;
        near.alphaRange = 0.15;
        far.alphaRange = 0.15;
        cells = @[shade, far, near];
    } else if ([cond isEqualToString:@"snow"]) {
        tint = [UIColor colorWithWhite:1 alpha:0.10];
        CAEmitterCell *flake = wx_cell(wx_shape(CGSizeMake(6, 6), 0.75), 40, 120, 50,
                                       M_PI_2, 0.7, 14, 0.55, 0.4);
        flake.xAcceleration = 6;
        flake.spinRange = 2;
        cells = @[flake];
    } else if ([cond isEqualToString:@"windy"]) {
        tint = [UIColor colorWithWhite:0.95 alpha:0.05];
        W_emitter.emitterPosition = CGPointMake(-30, sz.height / 2);
        W_emitter.emitterSize = CGSizeMake(1, sz.height);
        cells = @[wx_cell(wx_shape(CGSizeMake(40, 1.6), 0.28), 18, 1400, 300, 0.05, 0.04, 2.0, 0.8, 0.5)];
    } else if ([cond isEqualToString:@"fog"]) {
        tint = [UIColor colorWithWhite:0.93 alpha:0.38];
    } else if ([cond isEqualToString:@"cloudy"]) {
        tint = [UIColor colorWithRed:0.30 green:0.33 blue:0.38 alpha:0.18];
    } else if ([cond isEqualToString:@"partly_cloudy"]) {
        tint = [UIColor colorWithRed:0.30 green:0.33 blue:0.38 alpha:0.08];
    } else if ([cond isEqualToString:@"sunny"]) {
        tint = [UIColor colorWithRed:1.0 green:0.82 blue:0.40 alpha:0.10];
    } else if ([cond isEqualToString:@"clear"]) {
        tint = [UIColor colorWithRed:0.08 green:0.12 blue:0.30 alpha:0.14];
    }
    W_tint.backgroundColor = tint;
    W_emitter.emitterCells = cells;
    // splash flecks along the ground (rain only), in their own emitter
    [W_splash removeFromSuperlayer];
    W_splash = nil;
    if ([cond isEqualToString:@"rainy"] && sz.height > 100) {
        W_splash = [CAEmitterLayer layer];
        W_splash.frame = W_tint.bounds;
        W_splash.renderMode = kCAEmitterLayerUnordered;
        W_splash.emitterShape = kCAEmitterLayerLine;
        W_splash.emitterPosition = CGPointMake(sz.width / 2, sz.height * 0.82);
        W_splash.emitterSize = CGSizeMake(sz.width, sz.height * 0.3);
        CAEmitterCell *sp = wx_cell(wx_shape(CGSizeMake(7, 2.5), 0.30), 26, 26, 14,
                                    -M_PI_2, M_PI, 0.5, 0.8, 0.4);
        sp.alphaSpeed = -2.0;
        W_splash.emitterCells = @[sp];
        [W_tint.layer addSublayer:W_splash];
    }
}

__attribute__((unused))
static void weather_tick(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (!W_layer || W_layer.superview != parent) {
        [W_layer removeFromSuperview];
        W_layer = [[UIView alloc] initWithFrame:parent.bounds];
        W_layer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        W_layer.userInteractionEnabled = NO;
        W_tint = [[UIView alloc] initWithFrame:W_layer.bounds];
        W_tint.clipsToBounds = YES;            // the map scene, not the HUD around it
        [W_layer addSubview:W_tint];
        W_fx_far = [CAShapeLayer layer];
        W_fx_far.strokeColor = [UIColor colorWithRed:0.78 green:0.86 blue:1.0 alpha:0.42].CGColor;
        W_fx_far.fillColor = UIColor.clearColor.CGColor;
        W_fx_far.lineWidth = 1.6;
        W_fx_far.lineCap = kCALineCapRound;
        [W_tint.layer addSublayer:W_fx_far];
        W_fx_near = [CAShapeLayer layer];
        W_fx_near.strokeColor = [UIColor colorWithRed:0.90 green:0.95 blue:1.0 alpha:0.75].CGColor;
        W_fx_near.fillColor = UIColor.clearColor.CGColor;
        W_fx_near.lineWidth = 2.6;
        W_fx_near.lineCap = kCALineCapRound;
        W_fx_near.shadowColor = [UIColor colorWithWhite:0 alpha:1].CGColor;
        W_fx_near.shadowOpacity = 0.35;        // keeps drops readable over bright ground
        W_fx_near.shadowRadius = 1.5;
        W_fx_near.shadowOffset = CGSizeMake(0.5, 0.5);
        [W_tint.layer addSublayer:W_fx_near];
        W_emitter = [CAEmitterLayer layer];
        W_emitter.renderMode = kCAEmitterLayerUnordered;   // v41: normal blending, not glowing
        [W_tint.layer addSublayer:W_emitter];
        W_pill = [UILabel new];
        W_pill.translatesAutoresizingMaskIntoConstraints = NO;
        // v34: a game-style weather chip -- dark translucent rounded square, white glyph,
        // temperature under it, in the top-right corner the way the real game shows weather.
        W_chip = [UIView new];
        W_chip.translatesAutoresizingMaskIntoConstraints = NO;
        W_chip.backgroundColor = UIColor.clearColor;   // v35: bare glyph, no panel behind it
        [W_layer addSubview:W_chip];
        W_icon = [UIImageView new];
        W_icon.translatesAutoresizingMaskIntoConstraints = NO;
        W_icon.contentMode = UIViewContentModeScaleAspectFit;
        W_icon.layer.shadowColor = UIColor.blackColor.CGColor;
        W_icon.layer.shadowOpacity = 0.35;
        W_icon.layer.shadowRadius = 2;
        W_icon.layer.shadowOffset = CGSizeMake(0, 1);
        [W_chip addSubview:W_icon];
        W_pill = [UILabel new];
        W_pill.translatesAutoresizingMaskIntoConstraints = NO;
        W_pill.font = [UIFont systemFontOfSize:10 weight:UIFontWeightHeavy];
        W_pill.textColor = UIColor.whiteColor;
        W_pill.textAlignment = NSTextAlignmentCenter;
        [W_chip addSubview:W_pill];
        [NSLayoutConstraint activateConstraints:@[
            // v44: top CENTRE -- the game's own buttons sit top-left and top-right
            [W_chip.topAnchor constraintEqualToAnchor:ws_safe_guide(W_layer).topAnchor constant:4],
            [W_chip.centerXAnchor constraintEqualToAnchor:W_layer.centerXAnchor],
            [W_chip.widthAnchor constraintEqualToConstant:34],
            [W_chip.heightAnchor constraintEqualToConstant:34],
            [W_icon.topAnchor constraintEqualToAnchor:W_chip.topAnchor constant:0],
            [W_icon.centerXAnchor constraintEqualToAnchor:W_chip.centerXAnchor],
            [W_icon.widthAnchor constraintEqualToConstant:34],
            [W_icon.heightAnchor constraintEqualToConstant:34],
            [W_pill.topAnchor constraintEqualToAnchor:W_icon.bottomAnchor constant:0],
            [W_pill.leadingAnchor constraintEqualToAnchor:W_chip.leadingAnchor],
            [W_pill.trailingAnchor constraintEqualToAnchor:W_chip.trailingAnchor],
        ]];
        [parent addSubview:W_layer];
        g_wx_drawn = nil;
        WLOG(@"weather: overlay attached to Unity view");
    }
    NSString *cond = rj(g_wx, @"condition");
    // v40: only while the MAP is the live screen. The map music alone isn't enough --
    // menus (bag, Pokedex, shop) keep it playing -- so ask the game: MapExploreState
    // is the map's GameState, and GameState.IsActiveState says whether it's on screen.
    // If the type can't be resolved we fall back to the music, as before.
    static void *map_type = NULL;
    static int map_type_tried = 0;
    if (!map_type && map_type_tried < 40) {
        map_type_tried++;
        map_type = raid_type("Niantic.Holoholo.Map.MapExploreState, Assembly-CSharp");
        if (map_type) WLOG(@"weather: map state type resolved");
    }
    bool on_map = g_map_active;
    if (map_type) {
        void *st = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, map_type, NULL);
        on_map = looks_like_ptr(st) && *(uint8_t *)((uint8_t *)st + OFF_KB_STATE_ACTIVE);
    }
    bool show = cond && on_map && !WX_HOLD;
    if (cond && !WX_HOLD) weather_fog_tick(cond, on_map);
    // v202: the particles may run on their own (WEATHER_PARTICLES) from the tint's copy of /weather
    NSDictionary *pwx = WEATHER_FX ? g_wx : WEATHER_PARTICLES ? g_wx_tint : nil;
    NSString *pcond = rj(pwx, @"condition");
    g_r3_cfg = rj(pwx, @"rainfx");                // v141: new key, new meaning (shares of distance)
    // v141: map AND catch screen. v143: snow and wind too
    g_wx_fx = WX_HOLD ? 0 : [pcond isEqualToString:@"rainy"] ? R3_KIND_RAIN
            : [pcond isEqualToString:@"snow"] ? R3_KIND_SNOW : [pcond isEqualToString:@"windy"] ? R3_KIND_WIND : 0;
    // v145: how thick the catch screen's fog sheets are for this weather (weather.rainfx.mist_*)
    g_wx_mist = WX_HOLD || !cond ? 0
              : [cond isEqualToString:@"fog"]    ? r3f(@"mist_fog", 1.0f)
              : [cond isEqualToString:@"rainy"]  ? r3f(@"mist_rain", 0.35f)
              : [cond isEqualToString:@"snow"]   ? r3f(@"mist_snow", 0.45f)
              : [cond isEqualToString:@"cloudy"] ? r3f(@"mist_cloudy", 0.0f) : 0;
    // v148: how much the weather dims the scene (weather.rainfx.shade_*). Full strength by
    // day; the game's own night map is dark already, so nights get shade_night of it.
    {
        float sh = WX_HOLD || !cond ? 0
                 : [cond isEqualToString:@"rainy"]  ? r3f(@"shade_rainy", 0.38f)
                 : [cond isEqualToString:@"snow"]   ? r3f(@"shade_snow", 0.16f)
                 : [cond isEqualToString:@"fog"]    ? r3f(@"shade_fog", 0.22f)
                 : [cond isEqualToString:@"cloudy"] ? r3f(@"shade_cloudy", 0.24f)
                 : [cond isEqualToString:@"windy"]  ? r3f(@"shade_windy", 0.10f)
                 : [cond isEqualToString:@"partly_cloudy"] ? r3f(@"shade_partly_cloudy", 0.08f) : 0;
        NSInteger hr = [[NSCalendar currentCalendar] component:NSCalendarUnitHour fromDate:[NSDate date]];
        if (hr >= 20 || hr < 6) sh *= MAX(0, MIN(1, r3f(@"shade_night", 0.25f)));   // same night as the fog sheets
        g_wx_shade = MAX(0, MIN(0.85f, sh));
    }
    W_layer.hidden = !show;
    W_tint.hidden = !WX_OVERLAY;                  // only the chip; the scene does the rest
    W_emitter.birthRate = (show && WX_OVERLAY) ? 1 : 0;
    W_splash.birthRate = (show && WX_OVERLAY) ? 1 : 0;   // stop spawning particles while hidden
    if (!show) return;
    W_layer.frame = parent.bounds;
    // map scene = everything between the status bar and the bottom button bar
    CGFloat wx_top = ws_safe_insets(parent).top;
    CGFloat wx_bottom = ws_safe_insets(parent).bottom + 96;
    CGRect scene = CGRectMake(0, wx_top, parent.bounds.size.width,
                              MAX(120, parent.bounds.size.height - wx_top - wx_bottom));
    if (!CGRectEqualToRect(W_tint.frame, scene)) {
        W_tint.frame = scene;
        WLOG(@"weather: map scene %.0fx%.0f at y=%.0f", scene.size.width, scene.size.height, scene.origin.y);
    }
    if (![cond isEqualToString:g_wx_drawn] || !CGSizeEqualToSize(g_wx_size, W_tint.bounds.size))
        weather_layout(cond);
    W_pill.text = @"";        // v36: the glyph alone, no temperature
    static NSString *icon_for = nil;
    if (!W_icon.image || ![icon_for isEqualToString:cond]) {
        icon_for = cond;
        W_icon.image = wx_icon_image(cond, 34);   // renderer handles @2x/@3x itself
    }
    [parent bringSubviewToFront:W_layer];
}

// 60 Hz: move the drops. Cheap (one path rebuild) and only runs while weather shows.
__attribute__((unused))
static void fog_smooth_frame(void) {
    if (!g_wx_scene_ok || !g_fog_have) return;
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    float dt = (last && now > last) ? (float)MIN(0.1, now - last) : 0.016f;
    last = now;
    if (!g_fog_live) return;                   // menus / loading: leave the scene alone
    FogState &c = g_fog_c, &t = g_fog_t;
    if (t.on && !c.on) {                       // rolling in: start far away in the new colour
        c = t; c.on = true;
        if (!g_fog_snap) { c.s = FOG_FAR; c.e = FOG_FAR * 1.5f; }
    }
    float k = g_fog_snap ? 1.0f : 1.0f - expf(-dt / FOG_EASE_S);
    g_fog_snap = false;
    float ts = t.on ? t.s : FOG_FAR, te = t.on ? t.e : FOG_FAR * 1.5f;
    if (t.on) { c.r += (t.r - c.r) * k; c.g += (t.g - c.g) * k; c.b += (t.b - c.b) * k; }
    c.s += (ts - c.s) * k;
    c.e += (te - c.e) * k;
    if (!t.on && c.on && c.s > FOG_FAR * 0.9f) c.on = false;   // fully rolled out
    ((wx_set_bool)g_wxfn[WX_FOG])(c.on, NULL);
    if (c.on) {
        ((wx_set_color)g_wxfn[WX_FOGCOLOR])(c.r, c.g, c.b, 1.0f, NULL);
        ((wx_set_float)g_wxfn[WX_FOGSTART])(c.s, NULL);
        ((wx_set_float)g_wxfn[WX_FOGEND])(MAX(c.e, c.s + 1.0f), NULL);
    }
}

// v149: WHY THE MAP LOST ITS FOG. A 0.35 map method (0x96174, void (this, float t)) runs every
// map frame: it evaluates three curves at t and writes RenderSettings.fogStart/EndDistance
// (0x96264 / 0x96288) -- the game's own zoom haze. It silently replaced our distances, so on
// the map only the colour survived (the darkening), while catches and the stop-spin screen,
// where it doesn't run, showed the fog. It has no direct callers (MethodInfo only), so it is
// redirected: the game's version runs, then ours goes straight back on top, same frame.
#define RVA_MAP_FOGDIST     0x96174
#define FIRST_MAP_FOGDIST   0x6dbb33ed
static void (*o_map_fogdist)(void *, float, void *) = NULL;
static void hk_map_fogdist(void *self, float t, void *mi) {
    o_map_fogdist(self, t, mi);
    if (!g_fog_live || !g_fog_c.on) return;       // no weather fog: the game's haze stands
    ((wx_set_bool)g_wxfn[WX_FOG])(true, NULL);
    ((wx_set_color)g_wxfn[WX_FOGCOLOR])(g_fog_c.r, g_fog_c.g, g_fog_c.b, 1.0f, NULL);
    ((wx_set_float)g_wxfn[WX_FOGSTART])(g_fog_c.s, NULL);
    ((wx_set_float)g_wxfn[WX_FOGEND])(MAX(g_fog_c.e, g_fog_c.s + 1.0f), NULL);
}
static void install_map_fogdist(uintptr_t base, uintptr_t dstart, size_t dsize) {
    if (*(uint32_t *)(base + RVA_MAP_FOGDIST) != FIRST_MAP_FOGDIST) {
        WLOG(@"weather: map fog-distance method doesn't match -- map fog may be overridden");
        return;
    }
    o_map_fogdist = (void (*)(void *, float, void *))(base + RVA_MAP_FOGDIST);
    bool ok = redirect_method_pointer(dstart, dsize, base + RVA_MAP_FOGDIST,
                                      (uintptr_t)&hk_map_fogdist, "map fog distances");
    WLOG(@"weather: map fog-distance hook %s", ok ? "armed" : "NOT armed");
}

// ----------------------------------------------------------------- Halloween look (no-JIT, 0.35)
// Niantic.Holoholo.Map.TimeOfDay decides day or night (get_DayPeriod: the hour against its
// sunrise/sunset fields) and ApplyTimeOfDay puts that period's ambient light, fog colour and
// sky texture on the scene. get_DayPeriod is only reached through the ITimeOfDayService
// interface (0 direct callers), so it is redirected: while the server's look says "night" it
// answers Night, which the map, the sky dome and the catch screen all follow. The tint goes
// into the object's own ambientColorNight (and the fog colour into fogColorNight, so the
// game's version never flashes blue), then the game's ApplyTimeOfDay is run again.
#define RVA_TOD_DAYPERIOD   0x8C48C
#define RVA_TOD_APPLY       0x8C52C
#define FIRST_TOD           0xa9be4ff4
#define OFF_TOD_AMB_NIGHT   0x40      // Color ambientColorNight
#define OFF_TOD_FOG_NIGHT   0x60      // Color fogColorNight
#define OFF_TOD_SKY_NIGHT   0xB0      // Texture skyDomeNightTex

// v160: FOG IN THE SKY. Scene fog only colours geometry, and the sky is a dome drawn with an
// unlit shader that ignores fog -- so the look's orange haze stopped dead at the edge of the
// ground, a solid band with a ruler-straight top against the night sky. (v159 stood a
// see-through sheet in front of the dome; it never showed on a phone.) Now the dome's own
// night texture is swapped for one with the haze painted in: the game's SkyNight
// (windstock_sky_night.png in the app, 1024 px) with the fog colour solid at the horizon
// and thinning to nothing `sh` degrees up. The dome maps v = 0.5 to the horizon and climbs
// 0.0183 per degree, wrapping at ~27 degrees -- hence the 25 degree cap.
static const QcFn kSky[] = {
    { "Texture2D.SetPixels32(Color32[])", 0x8D3E54, 0x52800002 },
    { "Texture2D.Apply()",                0x8D4090, 0x320003e1 },
};
static void *g_skyfn[2];
static bool g_sky_ok = false, g_r3_fn_ok = false;
#define SKY_N 1024
#define SKY_V_PER_DEG 0.0183f
#define OFF_TOD_SKY_DAY     0xA8      // Texture skyDomeDayTex

// ----------------------------------------------------------------- weather tint (v200, 0.35)
// The ground, the sky and the catch backdrop take the weather's colour. All three are the
// game's own textures on the game's own materials, so the tweak paints recoloured copies and
// puts them in their place -- nothing is drawn on top, nothing is hooked for it:
//   * map ground: materials "Ground" (GroundDisc) and "Park", shader Niantic/World Map/Ground,
//     multiply a grass texture (_MainTex) by a near-to-far colour ramp (_ColorRamp, 256x4).
//     The grass is greyed by the tint's amount and the ramp takes the tint.
//   * sky: TimeOfDay.skyDomeDayTex / skyDomeNightTex, which ApplyTimeOfDay puts on the dome --
//     the slot the Halloween sky fog (v160) uses, so the fog is painted over the tinted night.
//   * catch: M_ParkScene_background / _foreground share one atlas (sky band, trees, grass).
//     SwapTextureByTime puts the day or night one on at every encounter, so it is swapped
//     back whenever it shows up. Sky-blue pixels take the sky tint, the rest the ground's.
// A tint is a colour, an amount (0 = the game's picture) and a light (brightness): each pixel
// moves toward the colour's hue at its own brightness x light. Colours per weather come from
// the server's /weather reply ("tint", settings weather.tint), else from tint_default().
// The game's pictures can't be read back from the GPU, so the sources ship in the app as
// windstock_tint_*.png (work/tools/export_tint_textures.py) + windstock_sky_night.png.
struct WxTint { float r, g, b, a, l; };
// v208: NIGHT is darker. After dark every tint's amount x na and light x nl, and the game's
// night light (TimeOfDay.ambientColorNight) x dark -- the weather's own dimming, rain most.
// v205: catch = the catch backdrop's grass and trees, its own tint (the map's ground went its own way)
struct WxTints { WxTint ground, sky, catch_; float dark, na, nl; };
static const WxTints kTintNone = { {}, {}, {}, 1, 1.3f, 0.72f };
static WxTints g_tint = kTintNone;             // on screen now (main thread)
static int g_tint_gen = 1;                     // bumped on every change
static bool g_tint_night = false;              // the map is in its night period (or the look says night)
static char g_tint_state[24] = "-";            // for X-WS-Tweak
static const QcFn kTint[] = {
    { "Material.get_mainTexture",            0x8B45F4, 0xa9be4ff4 },
    { "Material.set_mainTexture",            0x8B4684, 0xa9bd57f6 },
    { "Material.SetTexture(string,Texture)", 0x8B46F4, 0xa9be4ff4 },
    { "Material.GetTexture(string)",         0x8B4654, 0xa9be4ff4 },
    { "Texture.set_wrapMode",                0x8D3798, 0xa9bd57f6 },
};
enum { TF_GETMAIN, TF_SETMAIN, TF_SETTEX, TF_GETTEX, TF_WRAP, TF_COUNT };
static void *g_tintfn[TF_COUNT];
static void *g_tint_s_main = NULL, *g_tint_s_ramp = NULL;   // "_MainTex", "_ColorRamp" (managed)

static NSString *tint_name(void *o) {
    void *s = r3_alive(o) ? ((qc_inst0)g_r3[R3_NAME])(o, NULL) : NULL;
    if (!looks_like_ptr(s)) return nil;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len < 0 || len > 256) return nil;
    return [NSString stringWithCharacters:(unichar *)((uint8_t *)s + 0x14) length:len];
}

static WxTints tint_default(NSString *c) {
    struct Row { const char *cond; WxTint g, s, c; float dark; };
    // v205 (user): rain's old ground (pale, almost white on the map) is now snow's; rain is darker.
    // The catch screen keeps the v200 colours (c).
    static const Row rows[] = {   // map ground r, g, b, amount, light | sky | catch ground | night light x
        { "sunny",         { 1.00f, 0.91f, 0.66f, 0.15f, 1.04f }, { 0, 0, 0, 0, 1 },
                           { 1.00f, 0.91f, 0.66f, 0.15f, 1.04f }, 1.00f },
        { "partly_cloudy", { 0.72f, 0.78f, 0.72f, 0.18f, 0.97f }, { 0.73f, 0.78f, 0.84f, 0.25f, 1.00f },
                           { 0.72f, 0.78f, 0.72f, 0.18f, 0.97f }, 0.92f },
        { "cloudy",        { 0.56f, 0.64f, 0.60f, 0.45f, 0.92f }, { 0.66f, 0.71f, 0.75f, 0.60f, 0.95f },
                           { 0.56f, 0.64f, 0.60f, 0.45f, 0.92f }, 0.82f },
        { "rainy",         { 0.30f, 0.40f, 0.42f, 0.85f, 0.50f }, { 0.49f, 0.54f, 0.60f, 0.75f, 0.80f },
                           { 0.37f, 0.50f, 0.53f, 0.70f, 0.80f }, 0.68f },
        { "snow",          { 0.37f, 0.50f, 0.53f, 0.70f, 0.80f }, { 0.85f, 0.88f, 0.92f, 0.60f, 1.00f },
                           { 0.95f, 0.97f, 1.00f, 0.85f, 1.25f }, 0.95f },
        { "fog",           { 0.79f, 0.83f, 0.84f, 0.55f, 1.00f }, { 0.84f, 0.86f, 0.87f, 0.80f, 1.05f },
                           { 0.79f, 0.83f, 0.84f, 0.55f, 1.00f }, 0.82f },
        { "windy",         { 0.78f, 0.85f, 0.69f, 0.12f, 1.00f }, { 0.80f, 0.85f, 0.90f, 0.10f, 1.00f },
                           { 0.78f, 0.85f, 0.69f, 0.12f, 1.00f }, 0.92f },
    };
    WxTints t = kTintNone;
    const char *cs = c.UTF8String;
    for (const Row &r : rows) if (cs && !strcmp(cs, r.cond)) { t.ground = r.g; t.sky = r.s; t.catch_ = r.c; t.dark = r.dark; }
    return t;
}
// The tints for a condition: the server's [r, g, b, amount, light] when it sends them.
static WxTints tint_for(NSString *cond, NSDictionary *srv) {
    WxTints t = kTintNone;
    if (![cond isKindOfClass:[NSString class]]) return t;
    t = tint_default(cond);
    if (![srv isKindOfClass:[NSDictionary class]]) return t;
    WxTint *dst[3] = { &t.ground, &t.sky, &t.catch_ };
    NSString *keys[3] = { @"ground", @"sky", @"catch" };
    for (int i = 0; i < 3; i++) {
        NSArray *v = rj(srv, keys[i]);
        if (![v isKindOfClass:[NSArray class]] || v.count < 4) continue;
        float f[5] = { 0, 0, 0, 0, 1 };
        for (NSUInteger j = 0; j < MIN((NSUInteger)5, v.count); j++)
            if ([v[j] isKindOfClass:[NSNumber class]]) f[j] = [v[j] floatValue];
        *dst[i] = (WxTint){ MAX(0.0f, MIN(1.0f, f[0])), MAX(0.0f, MIN(1.0f, f[1])), MAX(0.0f, MIN(1.0f, f[2])),
                            MAX(0.0f, MIN(1.0f, f[3])), MAX(0.1f, MIN(2.0f, f[4])) };
    }
    float (^num)(NSString *, float, float, float) = ^float(NSString *k, float d, float lo, float hi) {
        id v = rj(srv, k);
        return [v isKindOfClass:[NSNumber class]] ? MAX(lo, MIN(hi, [v floatValue])) : d;
    };
    t.dark = num(@"night_dark", t.dark, 0.2f, 1.0f);
    t.na = num(@"night_amount", t.na, 0.0f, 3.0f);
    t.nl = num(@"night_light", t.nl, 0.1f, 2.0f);
    return t;
}
static inline bool tint_on(const WxTint &t) { return t.a > 0.004f; }
// The night version of a tint: more of it, darker.
static inline WxTint tint_at_night(WxTint t, const WxTints &all) {
    if (tint_on(t)) { t.a = MIN(1.0f, t.a * all.na); t.l = MAX(0.1f, t.l * all.nl); }
    return t;
}

static inline float tint_lum(float r, float g, float b) { return 0.299f * r + 0.587f * g + 0.114f * b; }
// One RGBA pixel (0..255) toward the tint's hue at its own brightness x light; k scales the amount.
static inline void tint_px(uint8_t *p, const WxTint &t, float k) {
    float a = t.a * k;
    if (a <= 0.004f) return;
    float r = p[0] * (1 / 255.0f), g = p[1] * (1 / 255.0f), b = p[2] * (1 / 255.0f);
    float L = tint_lum(r, g, b) * t.l / MAX(0.05f, tint_lum(t.r, t.g, t.b));
    p[0] = (uint8_t)(255.0f * (r + (MIN(1.0f, t.r * L) - r) * a) + 0.5f);
    p[1] = (uint8_t)(255.0f * (g + (MIN(1.0f, t.g * L) - g) * a) + 0.5f);
    p[2] = (uint8_t)(255.0f * (b + (MIN(1.0f, t.b * L) - b) * a) + 0.5f);
}

// A source picture: RGBA, straight alpha, Unity's row order (row 0 = bottom). Cached; NULL if missing.
struct TintPic { int w, h; float avg; uint8_t *px; };
static const TintPic *tint_pic(const char *name, int w, int h) {
    static NSMutableDictionary<NSString *, id> *cache = nil;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *key = @(name);
    id hit = cache[key];
    if (hit) return [hit isKindOfClass:[NSValue class]] ? (const TintPic *)[hit pointerValue] : NULL;
    cache[key] = [NSNull null];
    NSString *p = [[NSBundle mainBundle] pathForResource:key ofType:@"png"];
    UIImage *img = p ? [UIImage imageWithContentsOfFile:p] : nil;
    if (!img.CGImage) { WLOG(@"tint: no %@.png", key); return NULL; }
    uint8_t *buf = (uint8_t *)calloc((size_t)w * h, 4);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef cx = buf ? CGBitmapContextCreate(buf, w, h, 8, w * 4, cs,
                                                  kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big) : NULL;
    CGColorSpaceRelease(cs);
    if (!cx) { free(buf); WLOG(@"tint: %@.png could not be decoded", key); return NULL; }
    CGContextSetBlendMode(cx, kCGBlendModeCopy);
    CGContextDrawImage(cx, CGRectMake(0, 0, w, h), img.CGImage);
    CGContextRelease(cx);
    TintPic *pic = (TintPic *)calloc(1, sizeof *pic);
    pic->w = w; pic->h = h; pic->px = (uint8_t *)malloc((size_t)w * h * 4);
    double sum = 0;
    for (int y = 0; y < h; y++) {              // memory row 0 is the top of the picture
        const uint8_t *src = buf + (size_t)(h - 1 - y) * w * 4;
        uint8_t *dst = pic->px + (size_t)y * w * 4;
        for (int x = 0; x < w; x++, src += 4, dst += 4) {
            int a = src[3];
            for (int c = 0; c < 3; c++) dst[c] = (a > 0 && a < 255) ? (uint8_t)MIN(255, src[c] * 255 / a) : src[c];
            dst[3] = (uint8_t)a;
            sum += tint_lum(dst[0], dst[1], dst[2]);
        }
    }
    free(buf);
    pic->avg = (float)(sum / ((double)w * h) / 255.0);
    cache[key] = [NSValue valueWithPointer:pic];
    return pic;
}

// Our textures: each painted from its picture, repainted in place when the weather changes.
enum { TS_GROUND_RAMP, TS_GROUND_TEX, TS_PARK_RAMP, TS_PARK_TEX, TS_SKY_DAY, TS_SKY_NIGHT,
       TS_CATCH_DAY, TS_CATCH_NIGHT, TS_COUNT };
struct TintSlot { const char *pic; int w, h, wrap; void *tex; int gen, look; };
static TintSlot g_ts[TS_COUNT] = {
    // wrap = the game's own texture's (1 clamp, 0 repeat). v202: the catch atlas REPEATS -- its
    // panorama runs past the edge, and clamping it smeared the last column into streaks.
    { "windstock_tint_ground_ramp", 256, 4, 1 },
    { "windstock_tint_ground_tex", 256, 256, 0 },
    { "windstock_tint_park_ramp", 256, 4, 1 },
    { "windstock_tint_park_tex", 128, 128, 0 },
    { "windstock_tint_sky_day", 1024, 1024, 1 },
    { "windstock_sky_night", 1024, 1024, 0 },
    { "windstock_tint_catch_day", 1024, 1024, 0 },
    { "windstock_tint_catch_night", 1024, 1024, 0 },
};

static void *tint_tex_new(int w, int h) {
    void *t_tex = mt_type("UnityEngine.Texture2D, UnityEngine"), *t_int = mt_type("System.Int32");
    void *args = r3_array("System.Object", 2);
    if (!looks_like_ptr(t_tex) || !looks_like_ptr(t_int) || !args) return NULL;
    int32_t wh[2] = { w, h };
    for (int i = 0; i < 2; i++) {              // new Texture2D(w, h): two boxed ints
        void *b = ((qc_static1)g_r3[R3_NEW])(NULL, t_int, NULL);
        if (!looks_like_ptr(b)) return NULL;
        *(int32_t *)((uint8_t *)b + 0x10) = wh[i];
        ((void **)((uint8_t *)args + OFF_ARRAY_DATA))[i] = b;
    }
    void *t = ((r3_static2)g_r3[R3_NEW_ARGS])(NULL, t_tex, args, NULL);
    if (!r3_alive(t)) return NULL;
    r3_pin(t);
    return t;
}
// A Color32[] of n pixels, one per size, shared by every texture of that size.
static void *tint_cols(int n) {
    static std::unordered_map<int, void *> arrays;
    auto it = arrays.find(n);
    if (it != arrays.end()) return it->second;
    void *c = r3_array("UnityEngine.Color32, UnityEngine", n);
    if (!c) return NULL;
    r3_pin(c);
    arrays[n] = c;
    return c;
}

// v160's sky fog, painted over a night sky in place: the look's fog colour solid at the
// horizon, thinning to nothing k.sh degrees up. The dome maps v = 0.5 to the horizon and
// climbs 0.0183 per degree, wrapping at ~27 degrees -- hence the 25 degree cap.
static void sky_fog_band(uint8_t *out, int N, const HwLook &k) {
    float top = MIN(0.97f, 0.5f + k.sh * SKY_V_PER_DEG);
    int fr = (int)(MAX(0, MIN(1, k.fr)) * 255), fg = (int)(MAX(0, MIN(1, k.fg)) * 255), fb = (int)(MAX(0, MIN(1, k.fb)) * 255);
    for (int y = 0; y < N; y++) {              // Unity's row 0 is the bottom of the picture
        float v = (y + 0.5f) / N, a;
        if (v <= 0.5f) a = MAX(0.0f, MIN(1.0f, (v - 0.30f) / 0.15f));       // under the ground: out of sight
        else { float t = (v - 0.5f) / (top - 0.5f); a = t < 1 ? (1 - t) * (1 - t) : 0; }
        int ai = (int)(a * 256);
        if (ai <= 0) continue;
        uint8_t *dst = out + (size_t)y * N * 4;
        for (int x = 0; x < N; x++) {
            dst[x * 4 + 0] = (uint8_t)((dst[x * 4 + 0] * (256 - ai) + fr * ai) >> 8);
            dst[x * 4 + 1] = (uint8_t)((dst[x * 4 + 1] * (256 - ai) + fg * ai) >> 8);
            dst[x * 4 + 2] = (uint8_t)((dst[x * 4 + 2] * (256 - ai) + fb * ai) >> 8);
        }
    }
}

// Slot i painted for the current weather (and, for the night sky, the current look); NULL if
// it can't be made. Cheap when nothing changed.
static void *tint_slot(int i) {
    TintSlot &s = g_ts[i];
    bool night_sky = i == TS_SKY_NIGHT;
    if (r3_alive(s.tex) && s.gen == g_tint_gen && (!night_sky || s.look == g_look_gen)) return s.tex;
    if (!g_sky_ok) return NULL;
    const TintPic *pic = tint_pic(s.pic, s.w, s.h);
    if (!pic) return NULL;
    void *cols = tint_cols(s.w * s.h);
    if (!r3_alive(s.tex)) {
        s.tex = tint_tex_new(s.w, s.h);
        if (!s.tex) { WLOG(@"tint: texture %s could not be made", s.pic); return NULL; }
        if (s.wrap) ((void (*)(void *, int32_t, void *))g_tintfn[TF_WRAP])(s.tex, s.wrap, NULL);
    }
    if (!cols) return NULL;
    CFTimeInterval t0 = CACurrentMediaTime();
    size_t n = (size_t)s.w * s.h;
    uint8_t *out = (uint8_t *)cols + OFF_ARRAY_DATA;
    memcpy(out, pic->px, n * 4);
    // the night skies and the night catch picture always; the ground while the map is at night
    bool at_night = i == TS_SKY_NIGHT || i == TS_CATCH_NIGHT || (g_tint_night && i <= TS_PARK_TEX);
    WxTint G = at_night ? tint_at_night(g_tint.ground, g_tint) : g_tint.ground;
    WxTint S = at_night ? tint_at_night(g_tint.sky, g_tint) : g_tint.sky;
    WxTint C = at_night ? tint_at_night(g_tint.catch_, g_tint) : g_tint.catch_;
    switch (i) {
    case TS_GROUND_RAMP: case TS_PARK_RAMP:
        for (size_t p = 0; p < n; p++) tint_px(out + p * 4, G, 1);
        break;
    case TS_GROUND_TEX: case TS_PARK_TEX: {   // greyed, with its average brightness at white
        float shift = (1 - pic->avg) * 255, a = G.a;
        for (size_t p = 0; p < n; p++) {
            uint8_t *q = out + p * 4;
            float gr = MIN(255.0f, tint_lum(q[0], q[1], q[2]) + shift);
            for (int c = 0; c < 3; c++) q[c] = (uint8_t)(q[c] + (gr - q[c]) * a + 0.5f);
        }
        break;
    }
    case TS_SKY_DAY: case TS_SKY_NIGHT:
        for (size_t p = 0; p < n; p++) { tint_px(out + p * 4, S, 1); out[p * 4 + 3] = 255; }
        if (night_sky) {
            HwLook k = g_look;
            if (k.fog && k.sky) {
                sky_fog_band(out, s.w, k);
                snprintf(g_sky_state, sizeof g_sky_state, "on(%.0fdeg)", k.sh);
            } else strlcpy(g_sky_state, "off", sizeof g_sky_state);
        }
        break;
    case TS_CATCH_DAY: case TS_CATCH_NIGHT:   // sky-blue pixels: the sky's tint; the rest: the ground's
        for (size_t p = 0; p < n; p++) {
            uint8_t *q = out + p * 4;
            float sk = MAX(0.0f, MIN(1.0f, (q[2] - MAX(q[0], q[1]) + 10) / 40.0f));
            tint_px(q, C, 1 - sk);
            tint_px(q, S, sk);
        }
        break;
    }
    ((qc_inst1)g_skyfn[0])(s.tex, cols, NULL);
    ((qc_inst0)g_skyfn[1])(s.tex, NULL);
    s.gen = g_tint_gen; s.look = g_look_gen;
    WLOG(@"tint: painted %s (%dx%d) in %.0f ms", s.pic, s.w, s.h, (CACurrentMediaTime() - t0) * 1000);
    return s.tex;
}

// The sky for day or night, or NULL = the game's own (no tint, and at night no Halloween fog).
static void *tint_sky_tex(bool night) {
    bool fog = night && g_look.fog && g_look.sky;
    if (!tint_on(g_tint.sky) && !fog) return NULL;
    return tint_slot(night ? TS_SKY_NIGHT : TS_SKY_DAY);
}

static int (*o_tod_period)(void *, void *) = NULL;
static void (*o_tod_apply)(void *, void *) = NULL;
static void *g_tod = NULL;                     // the TimeOfDay the hook last saw
// The look's light/fog and our skies into the TimeOfDay's own fields, then the game's
// ApplyTimeOfDay puts them on the scene. Does nothing unless the look or the weather changed.
static void tod_update(void *self) {
    static void *seen = NULL;
    static int look_done = -1, tint_done = -1;
    static UColor amb0, fog0;
    static void *sky0n = NULL, *sky0d = NULL;
    void **skyn = (void **)((uint8_t *)self + OFF_TOD_SKY_NIGHT);
    void **skyd = (void **)((uint8_t *)self + OFF_TOD_SKY_DAY);
    UColor *amb = (UColor *)((uint8_t *)self + OFF_TOD_AMB_NIGHT);
    UColor *fogc = (UColor *)((uint8_t *)self + OFF_TOD_FOG_NIGHT);
    if (self != seen) {                        // a new TimeOfDay: these are the game's colours
        seen = self; g_tod = self; amb0 = *amb; fog0 = *fogc; look_done = tint_done = -1;
        // v203: day or night BEFORE the first paint, so the ground isn't painted twice
        bool night = g_look.night || (o_tod_period && o_tod_period(self, NULL) == 1);
        if (night != g_tint_night) { g_tint_night = night; g_tint_gen++; }
        sky0n = g_sky_ok && r3_alive(*skyn) ? *skyn : NULL;
        sky0d = g_sky_ok && r3_alive(*skyd) ? *skyd : NULL;
        if (sky0n) r3_pin(sky0n);              // ours take their place in the fields: keep the game's alive
        if (sky0d) r3_pin(sky0d);
        WLOG(@"look: TimeOfDay %p, night light (%.2f %.2f %.2f), night fog (%.2f %.2f %.2f), skies %p %p",
             self, amb0.r, amb0.g, amb0.b, fog0.r, fog0.g, fog0.b, sky0d, sky0n);
    }
    if (look_done == g_look_gen && tint_done == g_tint_gen) return;
    look_done = g_look_gen; tint_done = g_tint_gen;   // first: ApplyTimeOfDay comes back through here
    HwLook k = g_look;
    *amb = amb0; *fogc = fog0;
    if (k.tint) {
        // the tint's hue at the game's own brightness, so the map gets no darker
        float l0 = 0.299f * amb0.r + 0.587f * amb0.g + 0.114f * amb0.b;
        float l1 = MAX(0.02f, 0.299f * k.tr + 0.587f * k.tg + 0.114f * k.tb);
        float sc = l0 / l1;
        amb->r = amb0.r + (MIN(1.0f, k.tr * sc) - amb0.r) * k.ta;
        amb->g = amb0.g + (MIN(1.0f, k.tg * sc) - amb0.g) * k.ta;
        amb->b = amb0.b + (MIN(1.0f, k.tb * sc) - amb0.b) * k.ta;
    }
    if (k.fog) { fogc->r = k.fr; fogc->g = k.fg; fogc->b = k.fb; }
    if ((tint_on(g_tint.ground) || tint_on(g_tint.sky)) && g_tint.dark < 0.999f) {   // v208: darker nights
        amb->r *= g_tint.dark; amb->g *= g_tint.dark; amb->b *= g_tint.dark;
    }
    if (sky0n) {
        void *mine = tint_sky_tex(true);
        *skyn = mine ? mine : sky0n;
        if (!mine) strlcpy(g_sky_state, "off", sizeof g_sky_state);
    } else strlcpy(g_sky_state, g_sky_ok ? "no-game-sky" : "no-functions", sizeof g_sky_state);
    if (sky0d) {
        void *mine = tint_sky_tex(false);
        *skyd = mine ? mine : sky0d;
    }
    if (o_tod_apply) o_tod_apply(self, NULL);
    WLOG(@"look: applied (night %d fog %d tint %d, weather sky %.2f) -> night light (%.2f %.2f %.2f)",
         k.night, k.fog, k.tint, g_tint.sky.a, amb->r, amb->g, amb->b);
}
static int hk_tod_period(void *self, void *mi) {
    if (looks_like_ptr(self)) tod_update(self);
    return g_look.night ? 1 : o_tod_period(self, mi);
}
static bool install_tod_hook(uintptr_t base, uintptr_t dstart, size_t dsize, const char *version) {
    if (strcmp(version, "0.35") != 0) return false;
    if (*(uint32_t *)(base + RVA_TOD_DAYPERIOD) != FIRST_TOD || *(uint32_t *)(base + RVA_TOD_APPLY) != FIRST_TOD) {
        WLOG(@"look: TimeOfDay doesn't match -- night-all-day, tint and weather sky OFF (fog still works)");
        return false;
    }
    o_tod_period = (int (*)(void *, void *))(base + RVA_TOD_DAYPERIOD);
    o_tod_apply = (void (*)(void *, void *))(base + RVA_TOD_APPLY);
    bool ok = redirect_method_pointer(dstart, dsize, base + RVA_TOD_DAYPERIOD,
                                      (uintptr_t)&hk_tod_period, "TimeOfDay.get_DayPeriod");
    WLOG(@"look: day/night hook %s", ok ? "armed" : "NOT armed");
    return ok;
}
// v200: the hook is shared by the Halloween look and the weather sky -- armed if either is on.
static void install_halloween_look(uintptr_t base, uintptr_t dstart, size_t dsize, const char *version) {
    if (strcmp(version, "0.35") != 0) return;
    g_sky_ok = g_r3_fn_ok;                     // needs Activator / Array.CreateInstance / GCHandle
    for (int i = 0; i < 2 && g_sky_ok; i++) {
        if (*(uint32_t *)(base + kSky[i].rva) != kSky[i].first) {
            WLOG(@"look: %s doesn't match -- sky fog OFF", kSky[i].name);
            g_sky_ok = false;
        }
        g_skyfn[i] = (void *)(base + kSky[i].rva);
    }
    install_tod_hook(base, dstart, dsize, version);
}
static bool install_weather_tint(uintptr_t base, const char *version) {
    if (strcmp(version, "0.35") != 0 || !g_sky_ok || !g_mt[MT_FIND_ALL] || !g_qc[QC_STR]) {
        WLOG(@"tint: needs 0.35 + texture/lookup functions -- weather tint OFF");
        return false;
    }
    for (int i = 0; i < TF_COUNT; i++) {
        uint32_t w = *(uint32_t *)(base + kTint[i].rva);
        if (w != kTint[i].first) {
            WLOG(@"tint: %s first word %08x != %08x -- weather tint OFF", kTint[i].name, w, kTint[i].first);
            return false;
        }
        g_tintfn[i] = (void *)(base + kTint[i].rva);
    }
    g_tint_s_main = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"_MainTex", NULL);
    g_tint_s_ramp = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"_ColorRamp", NULL);
    if (!looks_like_ptr(g_tint_s_main) || !looks_like_ptr(g_tint_s_ramp)) return false;
    r3_pin(g_tint_s_main); r3_pin(g_tint_s_ramp);
    WLOG(@"tint: %d functions verified", TF_COUNT);
    return true;
}

// The game's materials we recolour. Ground/Park: both textures swapped once and put back when
// the tint goes; the catch ones get the game's day/night picture back at every encounter.
enum { TK_GROUND, TK_PARK, TK_CATCH };
struct TintMat { void *mat; int kind; bool mine; void *o_main, *o_ramp, *o_day, *o_night; };
static std::vector<TintMat> g_tmats;
static std::unordered_set<void *> g_tmat_other;   // materials already looked at that aren't ours
static void tint_scan(void) {
    static void *t_mat = NULL;
    if (!looks_like_ptr(t_mat)) t_mat = mt_type("UnityEngine.Material, UnityEngine");
    if (!looks_like_ptr(t_mat)) return;
    g_tmats.erase(std::remove_if(g_tmats.begin(), g_tmats.end(),
                                 [](const TintMat &m) { return !r3_alive(m.mat); }), g_tmats.end());
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_mat, NULL);
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + OFF_ARRAY_LEN) : 0;
    if (g_tmat_other.size() > 20000) g_tmat_other.clear();
    bool added = false;
    for (int64_t i = 0; i < n; i++) {
        void *m = *(void **)((uint8_t *)arr + OFF_ARRAY_DATA + i * 8);
        if (!r3_alive(m) || g_tmat_other.count(m)) continue;
        bool known = false;
        for (const TintMat &t : g_tmats) if (t.mat == m) { known = true; break; }
        if (known) continue;
        NSString *nm = [tint_name(m) stringByReplacingOccurrencesOfString:@" (Instance)" withString:@""];
        int kind = [nm isEqualToString:@"Ground"] ? TK_GROUND : [nm isEqualToString:@"Park"] ? TK_PARK
                 : ([nm isEqualToString:@"M_ParkScene_background"] || [nm isEqualToString:@"M_ParkScene_foreground"]) ? TK_CATCH : -1;
        if (kind < 0) { g_tmat_other.insert(m); continue; }
        r3_pin(m);
        g_tmats.push_back((TintMat){ m, kind, false, NULL, NULL, NULL, NULL });
        added = true;
    }
    if (added) {
        int c[3] = { 0, 0, 0 };
        for (const TintMat &t : g_tmats) c[t.kind]++;
        WLOG(@"tint: materials Ground x%d, Park x%d, catch x%d (%lld loaded)", c[0], c[1], c[2], n);
    }
}
static void tint_materials(void) {
    typedef void *(*gettex)(void *, void *, void *);
    typedef void (*settex)(void *, void *, void *, void *);
    bool ground = tint_on(g_tint.ground), any = tint_on(g_tint.catch_) || tint_on(g_tint.sky);
    for (TintMat &m : g_tmats) {
        if (!r3_alive(m.mat)) continue;
        if (m.kind != TK_CATCH) {
            int rs = m.kind == TK_GROUND ? TS_GROUND_RAMP : TS_PARK_RAMP;
            if (ground) {
                void *ramp = tint_slot(rs), *tex = tint_slot(rs + 1);   // repainted here when the weather changes
                if (m.mine || !ramp || !tex) continue;
                m.o_main = ((gettex)g_tintfn[TF_GETTEX])(m.mat, g_tint_s_main, NULL);
                m.o_ramp = ((gettex)g_tintfn[TF_GETTEX])(m.mat, g_tint_s_ramp, NULL);
                if (looks_like_ptr(m.o_main)) r3_pin(m.o_main);
                if (looks_like_ptr(m.o_ramp)) r3_pin(m.o_ramp);
                ((settex)g_tintfn[TF_SETTEX])(m.mat, g_tint_s_main, tex, NULL);
                ((settex)g_tintfn[TF_SETTEX])(m.mat, g_tint_s_ramp, ramp, NULL);
                m.mine = true;
                WLOG(@"tint: %s ground on", m.kind == TK_GROUND ? "map" : "park");
            } else if (m.mine) {
                ((settex)g_tintfn[TF_SETTEX])(m.mat, g_tint_s_main, m.o_main, NULL);
                ((settex)g_tintfn[TF_SETTEX])(m.mat, g_tint_s_ramp, m.o_ramp, NULL);
                m.mine = false;
                WLOG(@"tint: %s ground back to the game's", m.kind == TK_GROUND ? "map" : "park");
            }
            continue;
        }
        void *cur = ((qc_inst0)g_tintfn[TF_GETMAIN])(m.mat, NULL);
        void *day = g_ts[TS_CATCH_DAY].tex, *night = g_ts[TS_CATCH_NIGHT].tex;
        if (cur && (cur == day || cur == night)) {
            if (any) tint_slot(cur == day ? TS_CATCH_DAY : TS_CATCH_NIGHT);   // repaint if the weather changed
            else {
                void *orig = cur == day ? m.o_day : m.o_night;
                if (r3_alive(orig)) ((qc_inst1)g_tintfn[TF_SETMAIN])(m.mat, orig, NULL);
            }
            continue;
        }
        if (!any || !r3_alive(cur)) continue;
        bool is_night = [tint_name(cur) rangeOfString:@"Night"].location != NSNotFound;
        void *&orig = is_night ? m.o_night : m.o_day;
        if (orig != cur) { orig = cur; r3_pin(cur); }
        void *mine = tint_slot(is_night ? TS_CATCH_NIGHT : TS_CATCH_DAY);
        if (mine) ((qc_inst1)g_tintfn[TF_SETMAIN])(m.mat, mine, NULL);
    }
}
// 5 times a second (main thread): the weather -> the tints -> sky, ground and catch backdrop.
static void tint_tick(void) {
    if (!g_tint_ok) return;
    NSString *cond = rj(g_wx_tint, @"condition");
    WxTints n = tint_for(cond, rj(g_wx_tint, @"tint"));
    if (memcmp(&n, &g_tint, sizeof n) != 0) {
        g_tint = n;
        g_tint_gen++;
        snprintf(g_tint_state, sizeof g_tint_state, "%s", cond ? cond.UTF8String : "none");
        WLOG(@"tint: %@ -> ground (%.2f %.2f %.2f x %.2f, light %.2f), sky (%.2f %.2f %.2f x %.2f, light %.2f)",
             cond ?: @"(no weather)", n.ground.r, n.ground.g, n.ground.b, n.ground.a, n.ground.l,
             n.sky.r, n.sky.g, n.sky.b, n.sky.a, n.sky.l);
    }
    // v208: the ground has one picture for day and night, so it's repainted when the period changes
    bool night = g_look.night || (r3_alive(g_tod) && o_tod_period && o_tod_period(g_tod, NULL) == 1);
    if (night != g_tint_night) {
        g_tint_night = night;
        g_tint_gen++;
        WLOG(@"tint: %s (night x%.2f amount, x%.2f light, night light x%.2f)", night ? "night" : "day",
             g_tint.na, g_tint.nl, g_tint.dark);
    }
    if (r3_alive(g_tod)) tod_update(g_tod);
    static int ticks = 0;
    // once a second: new materials (the catch screen's load late); v203: every tick until the map's
    // ground is found, so it's recoloured before the map is on screen
    bool have_ground = false;
    for (const TintMat &m : g_tmats) if (m.kind == TK_GROUND) { have_ground = true; break; }
    if (!have_ground || ticks++ % 5 == 0) tint_scan();
    tint_materials();
}

static void weather_frame(void) {
    fog_smooth_frame();
    rain3d_frame(WX_HOLD ? 0 : g_wx_fx, WX_HOLD ? 0 : g_wx_mist, WX_HOLD ? 0 : g_wx_shade);
    if (!WX_OVERLAY || !W_fx_near || W_layer.hidden || !g_drop_count) return;
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (last && now > last) ? MIN(0.05, now - last) : 0.016;
    last = now;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];     // no implicit animation on the path
    wx_step_drops(W_tint.bounds.size, dt);
    [CATransaction commit];
}

// ----------------------------------------------------------------- shinies (no-JIT, 0.35)
// The 2016 client has no shinies. The server (work/server/shiny.py) decides ONCE per spawn
// whether it's shiny; a shiny has its own model bundle pm####_s (tools/make_shiny_bundle.py).
// BundleManager.PokemonAssetName(int) is what turns a Pokemon number into the model the
// game loads ("pm0025"); it's redirected (method-pointer table -- 0.35 RVA via port_rva.py,
// unique, 0 direct callers) to answer "pm0025_s" when the Pokemon on screen is shiny:
//   * details screen: the PokemonInfoPanel's Pokemon is in the server's shiny list
//   * otherwise (encounter): the encounter this trainer just opened is shiny
// The map never asks while an encounter is open, so map models stay normal.
#define SHINY 1
#define SHINY_URL                 @"https://pgorelease.nianticlabs.com/shiny/state"
#define RVA_POKEMON_ASSET_NAME    0x2012D0
#define FIRST_POKEMON_ASSET_NAME  0xa9be4ff4

static NSDictionary *g_shiny_state = nil;
static uintptr_t g_shiny_base = 0;
static void *g_hc_type = NULL, *g_enc_type = NULL;
static NSMutableSet<NSString *> *g_shiny_done = nil;    // "hc:pid" already reloaded
static NSTimeInterval g_shiny_state_at = 0;

static void shiny_store(NSDictionary *j) {
    if (![j isKindOfClass:[NSDictionary class]]) return;
    g_shiny_state = j;
    g_shiny_state_at = [NSDate date].timeIntervalSince1970;
    qc_level_from(j);                          // v199: Quick Catch unlocks at level 2
    bool hw = [rj(j, @"theme") isEqual:@"halloween"];
    if (hw != g_halloween) {
        g_halloween = hw;
        WLOG(@"event: halloween %s", hw ? "on" : "off");
        dispatch_async(dispatch_get_main_queue(), ^{ refresh(); });   // the Halloween music, if it's night
    }
    // v157: the look. Stored on the main thread, where Unity reads it.
    HwLook n; memset(&n, 0, sizeof n);
    NSDictionary *lk = rj(j, @"look");
    if ([lk isKindOfClass:[NSDictionary class]] && ws_mod(@"halloween_look", true)) {
        float (^num)(id, float) = ^float(id v, float d) {
            return [v isKindOfClass:[NSNumber class]] ? [v floatValue] : d;
        };
        NSArray *fc = rj(lk, @"fog_color"), *tc = rj(lk, @"tint_color");
        bool fok = [fc isKindOfClass:[NSArray class]] && fc.count == 3;
        bool tok = [tc isKindOfClass:[NSArray class]] && tc.count == 3;
        n.night = [rj(lk, @"night") boolValue];
        n.fog = fok && [rj(lk, @"fog") boolValue];
        n.tint = tok && [rj(lk, @"tint") boolValue];
        if (fok) { n.fr = num(fc[0], 0.85f); n.fg = num(fc[1], 0.41f); n.fb = num(fc[2], 0.12f); }
        if (tok) { n.tr = num(tc[0], 0.48f); n.tg = num(tc[1], 0.24f); n.tb = num(tc[2], 1.0f); }
        n.fs = MAX(0.0f, num(rj(lk, @"fog_start"), 35));
        n.fe = MAX(n.fs + 1.0f, num(rj(lk, @"fog_end"), 380));
        n.ta = MAX(0.0f, MIN(1.0f, num(rj(lk, @"tint_amount"), 0.6f)));
        id sky = rj(lk, @"fog_sky");                                   // an older server: on
        n.sky = n.fog && (![sky isKindOfClass:[NSNumber class]] || [sky boolValue]);
        n.sh = MAX(2.0f, MIN(25.0f, num(rj(lk, @"fog_sky_height"), 20)));
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (memcmp(&n, &g_look, sizeof n) == 0) return;
        g_look = n;
        g_look_gen++;
        WLOG(@"look: night %d, fog %d (%.2f %.2f %.2f, %.0f-%.0f), tint %d (%.2f %.2f %.2f x %.2f), sky %d (%.0f deg)",
             n.night, n.fog, n.fr, n.fg, n.fb, n.fs, n.fe, n.tint, n.tr, n.tg, n.tb, n.ta, n.sky, n.sh);
        refresh();                             // the night music follows
    });
}

// v158: scheduled events run on the PLAYER's clock (events.py), so a server in another
// timezone has to know this phone's UTC offset. Sent with every state request.
static void shiny_stamp_tz(NSMutableURLRequest *rq) {
    [rq setValue:[NSString stringWithFormat:@"%ld", (long)[NSTimeZone localTimeZone].secondsFromGMT]
        forHTTPHeaderField:@"X-WS-TZ"];
    // v160: which tweak this is and how the sky fog fared -- the phone's log is out of reach
    [rq setValue:[NSString stringWithFormat:@"%d sky=%s tint=%s", WS_TWEAK_BUILD, g_sky_state, g_tint_state] forHTTPHeaderField:@"X-WS-Tweak"];
}

// Blocking fetch, used only at the moment the game asks for a shiny-capable model.
static NSDictionary *shiny_fetch_sync(double timeout) {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SHINY_URL]];
    rq.timeoutInterval = timeout;
    shiny_stamp_tz(rq);
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSDictionary *out = nil;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        if ([j isKindOfClass:[NSDictionary class]]) out = j;
        dispatch_semaphore_signal(done);
    }] resume];
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)((timeout + 0.3) * NSEC_PER_SEC)));
    if (out) shiny_store(out);
    return out;
}

static void shiny_poll(void) {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:SHINY_URL]];
    rq.timeoutInterval = 5;
    shiny_stamp_tz(rq);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq
        completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ shiny_store(j); });
    }] resume];
}

// uid of the Pokemon on an open details screen, or 0
static uint64_t shiny_panel_uid(void) {
    if (!g_ap[AP_PANEL_PROTO]) return 0;
    // v78: the details screen leaves its objects behind when it closes, so the uid alone kept
    // the sparkles running. Three gates, logged so a stuck one is obvious:
    //   the panel's GameObject is active, its GuiController says IsVisible, and a proto is set.
    if (!g_ap_type_panel) g_ap_type_panel = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInfoPanel, Assembly-CSharp");
    void *panel = looks_like_ptr(g_ap_type_panel) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_ap_type_panel, NULL) : NULL;
    int active = -1, visible = -1;
    if (looks_like_ptr(panel) && g_qc[QC_COMP_GO] && g_mt[MT_ACTIVE]) {
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(panel, NULL);
        active = looks_like_ptr(go) ? (((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL) ? 1 : 0) : -1;
    }
    static void *info_t = NULL;
    if (!info_t) info_t = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInfoGuiController, Assembly-CSharp");
    void *info = looks_like_ptr(info_t) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, info_t, NULL) : NULL;
    if (looks_like_ptr(info) && g_shiny_base && *(uint32_t *)(g_shiny_base + 0xCE94C) == 0xa9be4ff4)
        visible = ((bool (*)(void *, void *))(g_shiny_base + 0xCE94C))(info, NULL) ? 1 : 0;
    else if (looks_like_ptr(info))
        visible = 2;                                   // couldn't ask: don't let it block
    void *proto = looks_like_ptr(panel) ? ((qc_inst0)g_ap[AP_PANEL_PROTO])(panel, NULL) : NULL;
    uint64_t uid = looks_like_ptr(proto) ? *(uint64_t *)((uint8_t *)proto + OFF_PROTO_ID) : 0;
    bool open = uid && active != 0 && visible != 0 && looks_like_ptr(info);
    static int last = -99;
    int state = (active + 2) * 100 + (visible + 2) * 10 + (open ? 1 : 0);
    if (state != last) {
        last = state;
        WLOG(@"shiny: details panel active=%d visible=%d info=%d uid=%llu -> %s", active, visible,
             looks_like_ptr(info) ? 1 : 0, (unsigned long long)uid, open ? "OPEN" : "closed");
    }
    return open ? uid : 0;
}

static bool shiny_uid(uint64_t uid) {
    if (!uid) return false;
    NSString *key = [NSString stringWithFormat:@"%llu", (unsigned long long)uid];
    NSArray *uids = rj(g_shiny_state, @"shiny_uids");
    return [uids isKindOfClass:[NSArray class]] && [uids containsObject:key];
}


// ---- v54: where the Pokemon is on screen, so sparkles sit on it and follow it (scrolling)
#define RVA_CAMERA_MAIN        0x88FB5C   // Camera.get_main            (0.29 0x86E4A4)
#define FIRST_CAMERA_MAIN      0xa9be4ff4
// v56: 0x88F6CC is Camera.WorldToVIEWPORTPoint (0.29 0x86E0D0), not WorldToScreenPoint
// (that's 0x88F610) -- confirmed by walking the Camera methods in both builds. v54/v55
// divided its 0..1 result by the pixel size, putting every sparkle in the bottom-left
// corner. Viewport coordinates are what we want anyway: no pixel sizes involved.
#define RVA_CAMERA_W2S         0x88F6CC   // Camera.WorldToViewportPoint (0.29 0x86E0D0)
#define FIRST_CAMERA_W2S       0xa9bf7bfd
#define RVA_CAMERA_PIXEL_W     0x88F200   // Camera.get_pixelWidth      (0.29 0x86DC04)
#define RVA_CAMERA_PIXEL_H     0x88F264   // Camera.get_pixelHeight     (0.29 0x86DC68)
#define RVA_TRANSFORM_POSITION 0x8D531C   // Transform.get_position     (0.29 0x8B3B40)
#define FIRST_TRANSFORM_POS    0xa9bf7bfd
// v94: RectTransform.get_rect (0.29 0x89D070) and Transform.TransformPoint(Vector3) (0.29
// 0x8B4E6C; two masked matches in 0.35 -- this is the one at get_position + 0x132C, the same
// spacing as 0.29). Both start with the same stp as get_position.
#define RVA_RECT_GET_RECT      0x8BE6E4
#define RVA_TRANSFORM_POINT    0x8D6648
#define RVA_HC_VIEW_WAIST      0x497D0    // HoloCharacter.get_ViewWaist (0.29 0x4E748)
// v57: pick the camera that actually DRAWS the model (culling mask includes its layer,
// frontmost depth). v56 tried Camera.main first -- on the details screen that's the map
// camera still running behind the menu, so the sparkles landed off-centre.
// Addresses verified by walking both builds from proven neighbours.
#define RVA_CAMERA_DEPTH       0x88EC4C   // Camera.get_depth        (0.29 0x86D650)
#define RVA_CAMERA_W2SCREEN    0x88F610   // Camera.WorldToScreenPoint (0.29 0x86E014), verified by walk
#define RVA_CAMERA_CULLMASK    0x88ED88   // Camera.get_cullingMask  (0.29 0x86D78C)
#define RVA_GAMEOBJECT_LAYER   0x89B778   // GameObject.get_layer    (0.29 0x879FA8)
typedef struct { float x, y, z; } WsV3;
static bool g_spk_anchor_ok = false;
static void *g_camera_type = NULL;

static bool spk_screen_point(void *hc, CGSize view, CGPoint *out, int kind_hint) {
    if (!g_spk_anchor_ok || !looks_like_ptr(hc)) return false;
    void *tr = ((qc_inst0)(g_shiny_base + RVA_HC_VIEW_WAIST))(hc, NULL);
    if (!looks_like_ptr(tr)) tr = ((qc_inst0)g_qc[QC_COMP_TR])(hc, NULL);
    if (!looks_like_ptr(tr)) return false;
    WsV3 w = ((WsV3 (*)(void *, void *))(g_shiny_base + RVA_TRANSFORM_POSITION))(tr, NULL);
    void *model_go = ((qc_inst0)g_qc[QC_COMP_GO])(tr, NULL);
    int32_t layer = looks_like_ptr(model_go) ?
        ((int32_t (*)(void *, void *))(g_shiny_base + RVA_GAMEOBJECT_LAYER))(model_go, NULL) : -1;
    if (!g_camera_type) g_camera_type = mt_type("UnityEngine.Camera, UnityEngine");
    if (!looks_like_ptr(g_camera_type) || !g_mt[MT_FIND_ALL]) return false;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_camera_type, NULL);
    uint64_t n = looks_like_ptr(arr) ? *(uint64_t *)((uint8_t *)arr + 0x18) : 0;

    // v58: screen PIXELS (WorldToScreenPoint already includes the camera's own viewport
    // rectangle), scaled by the full-screen size = the largest active camera's pixel size.
    // Viewport fractions (v56/v57) are relative to the camera's rect, which on the details
    // screen isn't the whole screen.
    typedef struct { void *cam; float depth; WsV3 sp; int32_t pw, ph; } Cand;
    Cand cands[32]; int nc = 0;
    int32_t screen_w = 0, screen_h = 0;
    for (uint64_t i = 0; i < n && i < 32; i++) {
        void *cam = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if (!looks_like_ptr(cam)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(cam, NULL);
        if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        int32_t pw = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_PIXEL_W))(cam, NULL);
        int32_t ph = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_PIXEL_H))(cam, NULL);
        if (pw > screen_w) screen_w = pw;
        if (ph > screen_h) screen_h = ph;
        int32_t mask = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_CULLMASK))(cam, NULL);
        if (layer >= 0 && layer < 32 && !(mask & (1 << layer))) continue;   // doesn't draw it
        Cand c = { cam, ((float (*)(void *, void *))(g_shiny_base + RVA_CAMERA_DEPTH))(cam, NULL),
                   ((WsV3 (*)(void *, WsV3, void *))(g_shiny_base + RVA_CAMERA_W2SCREEN))(cam, w, NULL),
                   pw, ph };
        cands[nc++] = c;
    }
    if (screen_w <= 0 || screen_h <= 0) return false;
    static int logged[3];
    int k = kind_hint == 2 ? 2 : 1;
    bool log_now = logged[k]++ < 3;
    int best = -1;
    for (int i = 0; i < nc; i++) {
        Cand c = cands[i];
        bool usable = c.sp.z > 0 && c.sp.x > -screen_w * 0.2 && c.sp.x < screen_w * 1.2 &&
                      c.sp.y > -screen_h * 0.2 && c.sp.y < screen_h * 1.2;
        if (log_now)
            WLOG(@"shiny: %s cam %d %p depth %.0f px %dx%d -> screen %.0f,%.0f z %.1f%s",
                 k == 2 ? "details" : "encounter", i, c.cam, c.depth, c.pw, c.ph,
                 c.sp.x, c.sp.y, c.sp.z, usable ? "" : " (unusable)");
        if (!usable) continue;
        // frontmost depth wins; on a tie prefer the camera with the SMALLER pixel area
        // (a dedicated model camera rather than a full-screen scene camera)
        if (best < 0 || c.depth > cands[best].depth ||
            (c.depth == cands[best].depth && (long)c.pw * c.ph < (long)cands[best].pw * cands[best].ph))
            best = i;
    }
    if (best < 0) return false;
    out->x = cands[best].sp.x / screen_w * view.width;
    out->y = view.height - cands[best].sp.y / screen_h * view.height;   // origin bottom-left
    if (log_now)
        WLOG(@"shiny: %s sparkles at %.0f,%.0f using cam %d (layer %d, screen %dx%d)",
             k == 2 ? "details" : "encounter", out->x, out->y, best, layer, screen_w, screen_h);
    return true;
}

// ---- sparkles: hand-stepped (Core Animation particles don't run in this app)
// v91: the REAL shiny sparkle. The 0.71 client's ShinyFX prefab (two ParticleSystems we read
// out of its Data files) is recreated here: the same texture (Star02, pre-tinted in
// ShinyStar.inc.h), colour, timeline, lifetimes, speeds and size/alpha curves. Unity units are
// mapped to points by SPK_UNIT (a Pokemon is about 1-2 units tall on the encounter screen).
//   * sparkle_vortex: 8 "spokes" on a 0.75-unit ring, each emitting 10/s for 0.5 s. A
//     particle lives 0.5 s, drifts outward 0.75 -> 1.5 u/s, spins, size 1 -> 0.25 by 26% of
//     its life -> 0.2, and fades out over the last 38%.
//   * center_burst, 1.0 s in: 10-20 particles from the middle at 2-3 u/s, life 0.2-0.5 s,
//     size 0.4-0.6 with a twinkling size curve, alpha 1 -> 0.
#include "ShinyStar.inc.h"
#define SPK_MAX 256
#define SPK_UNIT(sz) ((sz).width * 0.28)
// x/y are OFFSETS from the Pokemon's on-screen position (so the sparkles follow it)
enum { SPK_SPOKE = 0, SPK_BURST = 1, SPK_TWINKLE = 2 };
typedef struct { CGFloat x, y, vx, vy, life, max, size, rot, spin, delay, turn; int kind; } Spark;
static Spark g_spk[SPK_MAX];
static int g_spk_n = 0;
static UIView *SPK_view = nil;
static CALayer *SPK_layers[SPK_MAX];
static CGImageRef SPK_star = NULL;
static NSTimeInterval g_spk_twinkle_until = 0;   // (unused since v53: encounter = burst only)
static uint64_t g_spk_panel_uid = 0;             // details: twinkle while this Pokemon is open
static int g_spk_anchor_kind = 0;                // 1 = encounter Pokemon, 2 = details Pokemon
static CGPoint g_spk_anchor;
static bool g_spk_anchor_have = false;
// v99: the encounter burst stayed where it started. v106: it follows the Pokemon again;
// this now just marks that the first position fix has been taken (so it can snap once).
static bool g_spk_anchor_locked = false;
static void *shiny_encounter_character(void);
static void *shiny_panel_character(void);
static void *shiny_encounter_character_fwd(void) { return shiny_encounter_character(); }
static CGFloat spk_rand(void) { return (CGFloat)arc4random_uniform(10000) / 10000.0; }
static CGFloat spk_between(CGFloat a, CGFloat b) { return a + (b - a) * spk_rand(); }

static Spark *spk_new(int kind, CGFloat x, CGFloat y, CGFloat vx, CGFloat vy, CGFloat life,
                      CGFloat size, CGFloat delay) {
    if (g_spk_n >= SPK_MAX) return NULL;
    Spark *s = &g_spk[g_spk_n++];
    *s = (Spark){ x, y, vx, vy, life, life, size, spk_rand() * 2 * M_PI, 0, delay, 0, kind };
    return s;
}

// details-screen twinkle (unchanged behaviour, real star)
static void spk_add(CGFloat x, CGFloat y, CGFloat vx, CGFloat vy, CGFloat life, CGFloat size) {
    spk_new(SPK_TWINKLE, x, y, vx, vy, life, size * 2.6, 0);
}

static void spk_ensure_view(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (SPK_view && SPK_view.superview == parent) return;
    [SPK_view removeFromSuperview];
    if (!SPK_star) {
        UIImage *img = [UIImage imageWithData:[NSData dataWithBytes:kShinyStarPNG length:sizeof(kShinyStarPNG)]];
        SPK_star = CGImageRetain(img.CGImage);
    }
    SPK_view = [[UIView alloc] initWithFrame:parent.bounds];
    SPK_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    SPK_view.userInteractionEnabled = NO;
    for (int i = 0; i < SPK_MAX; i++) {
        CALayer *l = [CALayer layer];
        l.contents = (__bridge id)SPK_star;
        l.hidden = YES;
        l.actions = @{ @"position": [NSNull null], @"bounds": [NSNull null], @"transform": [NSNull null],
                       @"opacity": [NSNull null], @"hidden": [NSNull null] };
        [SPK_view.layer addSublayer:l];
        SPK_layers[i] = l;
    }
    [parent addSubview:SPK_view];
}

// The encounter burst: ShinyFX's timeline, laid out up front with per-particle delays.
// (v101: back to this after v100's copy of today's game -- the user preferred it.)
static void shiny_burst(void) {
    spk_ensure_view();
    if (!SPK_view) return;
    g_spk_anchor_kind = 1;
    g_spk_anchor_locked = false;                        // take a fresh fix, then hold it
    CGFloat u = SPK_UNIT(SPK_view.bounds.size);
    // v96: a swirl, and fewer -- each particle's heading TURNS as it flies (ShinyFX's parent
    // is "sparkle_vortex"). v97: faster and further apart -- each spoke's three leave at
    // their own angle and swirl at their own rate, so they fan out.
    for (int k = 0; k < 8; k++) {                       // sparkle_vortex: 8 spokes x 3
        CGFloat base = k * M_PI / 4;
        for (int e = 0; e < 3; e++) {
            CGFloat a = base + (e - 1) * 0.28 + spk_between(-0.08, 0.08);
            CGFloat cx = cos(a) * 1.25 * u, cy = -sin(a) * 1.25 * u;
            CGFloat sp = spk_between(1.8, 2.4) * u;
            Spark *s = spk_new(SPK_SPOKE, cx, cy, cos(a) * sp, -sin(a) * sp,
                               spk_between(0.9, 1.2), u * spk_between(0.6, 0.85), e * 0.15);
            if (s) { s->spin = spk_between(-M_PI, M_PI); s->turn = spk_between(1.8, 3.0); }  // rad/s, clockwise
        }
    }
    int n = 8 + arc4random_uniform(5);                  // center_burst, 0.8 s in
    for (int i = 0; i < n; i++) {
        CGFloat a = (i + spk_between(-0.3, 0.3)) * 2 * M_PI / n, sp = spk_between(3.6, 4.8) * u;
        Spark *s = spk_new(SPK_BURST, 0, 0, cos(a) * sp, sin(a) * sp,
                           spk_between(0.7, 1.1), spk_between(0.45, 0.65) * u, 0.8);
        // v98: straight out -- only the ring swirls, the final burst flies in straight lines
        if (s) { s->rot = spk_between(0.698, 0.873); s->spin = spk_between(-0.785, 0.785); }
    }
    g_spk_twinkle_until = 0;
    [SPK_view.superview bringSubviewToFront:SPK_view];
}

// thin four-point star path -- the storage-list sparkle still draws with this
static void spk_star(UIBezierPath *p, CGFloat x, CGFloat y, CGFloat r) {
    CGFloat t = r * 0.28;
    [p moveToPoint:CGPointMake(x, y - r)];
    [p addLineToPoint:CGPointMake(x + t, y - t)];
    [p addLineToPoint:CGPointMake(x + r, y)];
    [p addLineToPoint:CGPointMake(x + t, y + t)];
    [p addLineToPoint:CGPointMake(x, y + r)];
    [p addLineToPoint:CGPointMake(x - t, y + t)];
    [p addLineToPoint:CGPointMake(x - r, y)];
    [p addLineToPoint:CGPointMake(x - t, y - t)];
    [p closePath];
}

// piecewise-linear curve through (t, v) keys
static CGFloat spk_curve(const CGFloat (*keys)[2], int n, CGFloat t) {
    if (t <= keys[0][0]) return keys[0][1];
    for (int i = 1; i < n; i++)
        if (t <= keys[i][0]) {
            CGFloat f = (t - keys[i - 1][0]) / MAX(1e-4, keys[i][0] - keys[i - 1][0]);
            return keys[i - 1][1] + (keys[i][1] - keys[i - 1][1]) * f;
        }
    return keys[n - 1][1];
}
static const CGFloat SPK_SPOKE_SIZE[][2] = { {0, 1}, {0.3, 0.6}, {1, 0.3} };
static const CGFloat SPK_BURST_SIZE[][2] = { {0, 0}, {0.11, 1}, {0.21, 0.31}, {0.39, 0.74},
                                             {0.63, 0.28}, {0.79, 0.35}, {1, 0.05} };

static void spk_hide_all(void) {
    for (int i = 0; i < SPK_MAX; i++) if (SPK_layers[i] && !SPK_layers[i].hidden) SPK_layers[i].hidden = YES;
}

static void shiny_frame(void) {
    static CFTimeInterval last = 0;
    CFTimeInterval now = CACurrentMediaTime();
    CGFloat dt = (last && now > last) ? MIN(0.05, now - last) : 0.016;
    last = now;
    bool twinkle = g_spk_panel_uid != 0;
    if (twinkle) g_spk_anchor_kind = 2;
    if (!g_spk_n && !twinkle) {
        [CATransaction begin]; [CATransaction setDisableActions:YES];
        spk_hide_all();
        [CATransaction commit];
        g_spk_anchor_kind = 0;
        g_spk_anchor_locked = false;
        return;
    }
    spk_ensure_view();
    if (!SPK_view) return;
    CGSize sz = SPK_view.bounds.size;
    // Re-find the Pokemon every few frames (never keep a pointer that may be destroyed).
    static int frame = 0;
    if (g_spk_anchor_kind == 2) {
        // v59: details screen -- sparkles drift over the whole screen, no anchoring
        g_spk_anchor = CGPointZero;
        g_spk_anchor_have = true;
    } else if (frame++ % 2 == 0) {
        // v106: follow the Pokemon again (v99-v105 held the first fix). The first fix snaps;
        // after that the anchor eases toward the Pokemon so its idle bob doesn't shake the
        // sparkles, and a missed lookup keeps the last position instead of blinking out.
        void *hc = g_spk_anchor_kind == 1 ? shiny_encounter_character_fwd() : NULL;
        CGPoint pt;
        if (hc && spk_screen_point(hc, sz, &pt, g_spk_anchor_kind)) {
            if (!g_spk_anchor_locked) {
                g_spk_anchor = pt;
                g_spk_anchor_locked = true;              // (now means "have a first fix")
            } else {
                CGFloat f = MIN(1.0, dt * 2 * 10);       // two frames' worth, ~0.1 s to settle
                g_spk_anchor.x += (pt.x - g_spk_anchor.x) * f;
                g_spk_anchor.y += (pt.y - g_spk_anchor.y) * f;
            }
            g_spk_anchor_have = true;
        } else if (!g_spk_anchor_locked) {
            g_spk_anchor_have = false;
        }
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    if (!g_spk_anchor_have) {                    // can't see it: draw nothing this frame
        spk_hide_all();
        [CATransaction commit];
        return;
    }
    if (twinkle && spk_rand() < 0.12) {          // gentle sparkles anywhere on the screen
        spk_add(spk_rand() * sz.width, spk_rand() * sz.height, (spk_rand() - 0.5) * 12,
                -6 - spk_rand() * 12, 0.8 + spk_rand() * 0.6, 3.5 + spk_rand() * 4);
    }
    int keep = 0, shown = 0;
    for (int i = 0; i < g_spk_n; i++) {
        Spark s = g_spk[i];
        if (s.delay > 0) { s.delay -= dt; g_spk[keep++] = s; continue; }   // not born yet
        s.life -= dt;
        if (s.life <= 0) continue;
        CGFloat t = 1 - s.life / s.max;                         // 0 -> 1 over its life
        CGFloat size, alpha, speed = 1;
        if (s.kind == SPK_SPOKE) {
            size = spk_curve(SPK_SPOKE_SIZE, 3, t);
            alpha = t < 0.5 ? 1 : 1 - (t - 0.5) / 0.5;
            speed = 1.0 - 0.45 * t;                              // ease out: spread, then drift
        } else if (s.kind == SPK_BURST) {
            size = spk_curve(SPK_BURST_SIZE, 7, t);
            alpha = 1 - t;
            speed = 1.0 - 0.7 * t;
        } else {                                                 // twinkle: in, hold, out
            size = t < 0.2 ? t / 0.2 : (t > 0.7 ? (1 - t) / 0.3 : 1);
            alpha = size;
        }
        if (s.turn != 0) {                                       // curve: rotate the heading
            CGFloat c = cos(s.turn * dt), sn = sin(s.turn * dt);
            CGFloat vx = s.vx * c - s.vy * sn;
            s.vy = s.vx * sn + s.vy * c; s.vx = vx;
        }
        s.x += s.vx * speed * dt; s.y += s.vy * speed * dt;
        s.rot += s.spin * dt;
        g_spk[keep++] = s;
        if (shown >= SPK_MAX) continue;
        CALayer *l = SPK_layers[shown++];
        CGFloat d = MAX(1, s.size * size);
        l.bounds = CGRectMake(0, 0, d, d);
        l.position = CGPointMake(g_spk_anchor.x + s.x, g_spk_anchor.y + s.y);
        l.transform = CATransform3DMakeRotation(s.rot, 0, 0, 1);
        l.opacity = alpha;
        l.hidden = NO;
    }
    g_spk_n = keep;
    for (int i = shown; i < SPK_MAX; i++) if (SPK_layers[i] && !SPK_layers[i].hidden) SPK_layers[i].hidden = YES;
    [CATransaction commit];
    [SPK_view.superview bringSubviewToFront:SPK_view];
}

// Details screen: keep twinkling while a shiny is open (checked twice a second).
static void shiny_apply_to(void *hc, const char *where, bool burst);
static void *shiny_encounter_character(void);
static void *shiny_panel_character(void);
static bool shiny_gym_tick(void);
static void shiny_map_guards(void);
// v185: has the game finished loading this model? Both "tapping a shiny sometimes leaves the
// screen white" device logs reloaded the details model ~5 ms after the panel opened, while the
// game's OWN load of it was still in flight: the forced second load replaces that request and
// the screen never hears its model arrive. So reload only once HoloCharacter.Asset (+0x68) is
// set and has stayed the same for 0.3 s. Gyms use it too (defenders, fighters).
static bool shiny_model_settled(void *hc) {
    static NSMutableDictionary<NSNumber *, NSArray *> *seen = nil;     // hc -> [asset, since]
    if (!seen) seen = [NSMutableDictionary dictionary];
    if (!looks_like_ptr(hc)) return false;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    NSNumber *key = @((uintptr_t)hc);
    uintptr_t asset = (uintptr_t)*(void **)((uint8_t *)hc + 0x68);   // = OFF_HC_ASSET
    NSArray *was = seen[key];
    if (!was || [was[0] unsignedLongValue] != asset) {
        if (seen.count > 64) [seen removeAllObjects];
        seen[key] = @[@(asset), @(now)];
        return false;
    }
    if (asset && now - [was[1] doubleValue] >= 0.3) return true;
    static NSTimeInterval logged = 0;
    if (now - logged > 2.0) { logged = now; WLOG(@"shiny: model %p still loading -- shiny waits", hc); }
    return false;
}

static void shiny_tick(void) {
    if (!g_game_live) return;
    if (!g_shiny_done) g_shiny_done = [NSMutableSet set];
    uint64_t uid = shiny_panel_uid();
    static uint64_t asked_uid = 0;
    if (uid && !shiny_uid(uid) && uid != asked_uid) {    // e.g. just caught: list may be stale
        asked_uid = uid;
        shiny_fetch_sync(1.0);
    }
    // v79: the panel object AND its GuiController both still claim to be open after the
    // details screen closes (measured on device). The 3D model is the honest signal: it is
    // deactivated with the screen, and shiny_panel_character() only returns ACTIVE models.
    void *panel_char = (uid && shiny_uid(uid)) ? shiny_panel_character() : NULL;
    uint64_t want = panel_char ? uid : 0;
    // v80: the panel, its GuiController and even the 3D model all still look "open" after the
    // details screen closes, so ask the screen's CANVAS whether its GameObject is still on
    // (GuiController.get_Canvas 0.35 0xCE8FC). And whatever that says, the twinkle now stops
    // by itself a few seconds after it starts -- a shiny should sparkle as it appears, not forever.
    if (want) {
        static void *info_t2 = NULL;
        if (!info_t2) info_t2 = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInfoGuiController, Assembly-CSharp");
        void *info2 = looks_like_ptr(info_t2) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, info_t2, NULL) : NULL;
        int canvas_on = -1;
        if (looks_like_ptr(info2) && g_shiny_base && *(uint32_t *)(g_shiny_base + 0xCE8FC) == 0xa9be4ff4) {
            void *canvas = ((qc_inst0)(g_shiny_base + 0xCE8FC))(info2, NULL);
            void *cgo = looks_like_ptr(canvas) ? ((qc_inst0)g_qc[QC_COMP_GO])(canvas, NULL) : NULL;
            canvas_on = looks_like_ptr(cgo) ? (((bool (*)(void *, void *))g_mt[MT_ACTIVE])(cgo, NULL) ? 1 : 0) : -1;
        }
        static int last_canvas = -9;
        if (canvas_on != last_canvas) { last_canvas = canvas_on; WLOG(@"shiny: details canvas on=%d", canvas_on); }
        if (canvas_on == 0) want = 0;
    }
    static NSTimeInterval spark_started = 0;
    if (want && want != g_spk_panel_uid) spark_started = [NSDate date].timeIntervalSince1970;
    if (want && spark_started && [NSDate date].timeIntervalSince1970 - spark_started > 4.0) {
        if (g_spk_panel_uid) WLOG(@"shiny: details sparkles done (4 s)");
        g_spk_panel_uid = 0;
        want = 0;
    }
    if (want != g_spk_panel_uid && !(want == 0 && g_spk_panel_uid == 0)) {
        WLOG(@"shiny: details %s (%llu)", want ? "open -- sparkles on" : "closed -- sparkles off",
             (unsigned long long)(want ? want : g_spk_panel_uid));
        g_spk_panel_uid = want;
    }
    if (!g_enc_type) g_enc_type = mt_type("Niantic.Holoholo.Encounter.EncounterUIController, Assembly-CSharp");
    bool in_enc = looks_like_ptr(g_enc_type) &&
                  looks_like_ptr(((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_enc_type, NULL));
    static bool was_enc = false;
    if (in_enc && !was_enc) shiny_fetch_sync(1.0);      // the encounter just opened: ask now
    was_enc = in_enc;
    if (panel_char) {                                     // details first (post-catch screen too)
        // v185: "tapping a shiny sometimes leaves the screen white" -- see shiny_model_settled.
        if (shiny_model_settled(panel_char)) shiny_apply_to(panel_char, "details", false);
    } else if (in_enc) {
        NSDictionary *enc = rj(g_shiny_state, @"encounter");
        if ([rj(enc, @"shiny") boolValue]) shiny_apply_to(shiny_encounter_character(), "encounter", true);
    } else if (shiny_gym_tick()) {
        // at a gym: defenders / fighters handled above
    } else {
        if (g_shiny_done.count) [g_shiny_done removeAllObjects];   // back on the map: forget reloads
        shiny_map_guards();
    }
}


// ---- v52: reload the model shiny (measured v51: the game never calls PokemonAssetName --
// HoloCharacter.LoadPokemon formats "pm{0:0000}" itself, and it has 14 direct callers so it
// can't be redirected). Instead, when a shiny is on screen, CALL LoadPokemon(id, forceLoad)
// on its HoloCharacter with the format literal's usage slot briefly pointing at
// "pm{0:0000}_s", then put the slot back. Data write only -- no-JIT safe.
#define RVA_HC_LOAD_POKEMON   0x4A470     // HoloCharacter.LoadPokemon(int, bool)   (0.29 0x4F3E8)
#define FIRST_HC_LOAD_POKEMON 0xa9bd57f6
#define RVA_HC_POKEMON_ID     0x4983C     // HoloCharacter.get_PokemonId            (0.29 0x4E7B4)
#define FIRST_HC_POKEMON_ID   0xb9402400
#define RVA_PM_FORMAT_SLOT    0x1E6FC28   // usage slot of "pm{0:0000}" read at LoadPokemon+0xA8

static void shiny_reload(void *hc, int32_t pid) {
    void **slot = (void **)(g_shiny_base + RVA_PM_FORMAT_SLOT);
    void *orig = *slot;
    if (!looks_like_ptr(orig) || !il2cpp_string_equals(orig, "pm{0:0000}")) {
        WLOG(@"shiny: format slot not ready (%p) -- skipped", orig);
        return;
    }
    void *fmt = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"pm{0:0000}_s", NULL);
    if (!looks_like_ptr(fmt)) return;
    *slot = fmt;
    ((void (*)(void *, int32_t, bool, void *))(g_shiny_base + RVA_HC_LOAD_POKEMON))(hc, pid, true, NULL);
    *slot = orig;
}

// v55: reload ONLY the model that is actually on screen (v52 reloaded every active Pikachu,
// map ones included, which broke tapping on the map). v53/v54 read the owner's field at the
// 0.29 dump's offset (EncounterPokemon.character @0x78, PokemonInfoPanel.CharacterModel
// @0x298) and found nothing on 0.35 -- the layout moved. So: collect the ACTIVE
// HoloCharacters, then scan the owner object's fields for the one that points at one of
// them. Works whatever the field offset is, and logs the offset it found.
static void *g_encpoke_type = NULL;

static NSArray<NSValue *> *shiny_active_characters(void) {
    NSMutableArray *out = [NSMutableArray array];
    if (!g_hc_type) g_hc_type = mt_type("HoloCharacter, Assembly-CSharp");
    if (!looks_like_ptr(g_hc_type) || !g_mt[MT_FIND_ALL] || !g_mt[MT_ACTIVE]) return out;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_hc_type, NULL);
    if (!looks_like_ptr(arr)) return out;
    uint64_t n = *(uint64_t *)((uint8_t *)arr + 0x18);
    for (uint64_t i = 0; i < n && i < 4096; i++) {
        void *hc = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if (!looks_like_ptr(hc)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(hc, NULL);
        if (looks_like_ptr(go) && ((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL))
            [out addObject:[NSValue valueWithPointer:hc]];
    }
    return out;
}

// the HoloCharacter that `owner` holds a reference to (any field in the first 0x400 bytes)
static void *shiny_owned_character(void *owner, const char *label) {
    if (!looks_like_ptr(owner)) return NULL;
    NSArray<NSValue *> *active = shiny_active_characters();
    if (!active.count) return NULL;
    NSMutableSet *set = [NSMutableSet set];
    for (NSValue *v in active) [set addObject:@((uintptr_t)v.pointerValue)];
    for (uintptr_t off = 0x18; off < 0x400; off += 8) {
        void *p = *(void **)((uint8_t *)owner + off);
        if (looks_like_ptr(p) && [set containsObject:@((uintptr_t)p)]) {
            static NSMutableSet *logged;
            if (!logged) logged = [NSMutableSet set];
            NSString *k = [NSString stringWithFormat:@"%s:%lx", label, (unsigned long)off];
            if (![logged containsObject:k]) {
                [logged addObject:k];
                WLOG(@"shiny: %s model found at field +0x%lx", label, (unsigned long)off);
            }
            return p;
        }
    }
    static int warned = 0;
    if (warned++ < 5) WLOG(@"shiny: %s object %p holds none of the %lu active models", label, owner,
                           (unsigned long)active.count);
    return NULL;
}

static void *shiny_encounter_character(void) {
    if (!g_encpoke_type) {
        g_encpoke_type = mt_type("Niantic.Holoholo.Encounter.EncounterPokemon, Assembly-CSharp");
        if (!looks_like_ptr(g_encpoke_type)) WLOG(@"shiny: EncounterPokemon type not found");
    }
    void *ep = looks_like_ptr(g_encpoke_type) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_encpoke_type, NULL) : NULL;
    return shiny_owned_character(ep, "encounter");
}

static void *shiny_panel_character(void) {
    if (!g_ap_type_panel) g_ap_type_panel = mt_type("Niantic.Holoholo.UI.Pokemon.PokemonInfoPanel, Assembly-CSharp");
    void *panel = looks_like_ptr(g_ap_type_panel) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_ap_type_panel, NULL) : NULL;
    return shiny_owned_character(panel, "details");
}

static void shiny_apply_to(void *hc, const char *where, bool burst) {
    if (!looks_like_ptr(hc)) return;
    int32_t pid = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_HC_POKEMON_ID))(hc, NULL);
    NSArray *species = rj(g_shiny_state, @"species");
    if (pid <= 0 || ![species containsObject:@(pid)]) return;
    NSString *key = [NSString stringWithFormat:@"%p:%d", hc, pid];
    if ([g_shiny_done containsObject:key]) return;
    [g_shiny_done addObject:key];
    WLOG(@"shiny: #%d on the %s -- reloading %p as pm%04d_s", pid, where, hc, pid);
    shiny_reload(hc, pid);
    if (burst) shiny_burst();
}

// ---- v116: shinies at gyms. The gym screen stands each defender on a GymApproachPlatform
// (it holds the defender's HoloCharacter); a gym battle has one PlayerBattlePokemon and one
// EnemyBattlePokemon, each holding the fighter's model. The server's /shiny/state "gym" block
// says which defender species at the open gym are shiny and, mid-battle, whether the two
// fighters are. Only models owned by those objects are touched -- never the map's.
static int32_t hc_pid(void *hc) {
    return looks_like_ptr(hc) ? ((int32_t (*)(void *, void *))(g_shiny_base + RVA_HC_POKEMON_ID))(hc, NULL) : 0;
}
static bool go_active(void *comp) {
    void *go = looks_like_ptr(comp) ? ((qc_inst0)g_qc[QC_COMP_GO])(comp, NULL) : NULL;
    return looks_like_ptr(go) && ((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL);
}
// ---- v116: the Pokemon standing on top of a gym on the MAP. MapGym holds it as its guard
// HoloCharacter and reloads it every time the tower swaps from the team logo back to the
// Pokemon (GuardAnimation -> ShowGuardPokemon), so a one-off reload isn't enough: remember
// the asset our shiny reload produced (HoloCharacter.Asset, +0x68 -- 0.35 get_Asset 0x49720
// is `ldr x0,[x0,#0x68]`) and reload again whenever the game has put a different one there.
// Wild map Pokemon are deliberately left alone (the user wants shinies to show on tap).
#define RVA_MAPGYM_POI_ID     0x2629E8    // MapGym.get_PoiId   (0.29 0x245C20)
#define FIRST_MAPGYM_POI_ID   0xf9405800  // ldr x0, [x0, #0xb0]
#define OFF_HC_ASSET          0x68
static NSString *il2cpp_nsstring(void *str) {
    if (!looks_like_ptr(str)) return nil;
    int32_t len = *(int32_t *)((uint8_t *)str + 0x10);
    if (len <= 0 || len > 256) return nil;
    return [NSString stringWithCharacters:(const unichar *)((uint8_t *)str + 0x14) length:(NSUInteger)len];
}
static void shiny_map_guards(void) {
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - last < 0.6) return;
    last = now;
    NSDictionary *guards = rj(rj(g_shiny_state, @"map"), @"guards");
    if (![guards isKindOfClass:[NSDictionary class]] || !guards.count) return;
    static int ok = -1;
    if (ok < 0) {
        ok = *(uint32_t *)(g_shiny_base + RVA_MAPGYM_POI_ID) == FIRST_MAPGYM_POI_ID;
        WLOG(@"shiny: map gym guards %s", ok ? "on" : "OFF (MapGym.get_PoiId doesn't match)");
    }
    if (!ok || !g_mt[MT_FIND_ALL] || !g_mt[MT_ACTIVE]) return;
    static void *t_gym = NULL;
    if (!t_gym) t_gym = mt_type("Niantic.Holoholo.Gym.MapGym, Assembly-CSharp");
    if (!looks_like_ptr(t_gym)) return;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_gym, NULL);
    uint64_t n = looks_like_ptr(arr) ? *(uint64_t *)((uint8_t *)arr + 0x18) : 0;
    if (!n) return;
    NSArray<NSValue *> *active = shiny_active_characters();
    NSMutableSet *set = [NSMutableSet set];
    for (NSValue *v in active) [set addObject:@((uintptr_t)v.pointerValue)];
    static NSMutableDictionary<NSNumber *, NSNumber *> *shiny_asset = nil;   // hc -> asset we made
    static NSMutableDictionary<NSNumber *, NSArray *> *pending = nil;        // hc -> [old asset, t]
    if (!shiny_asset) { shiny_asset = [NSMutableDictionary dictionary]; pending = [NSMutableDictionary dictionary]; }
    for (uint64_t i = 0; i < n && i < 256; i++) {
        void *g = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if (!go_active(g)) continue;
        NSString *poi = il2cpp_nsstring(((qc_inst0)(g_shiny_base + RVA_MAPGYM_POI_ID))(g, NULL));
        NSNumber *want = poi ? guards[poi] : nil;
        if (!want) continue;
        void *hc = NULL;                                 // its guard: the active model it holds
        for (uintptr_t off = 0x18; off < 0x200 && !hc; off += 8) {
            void *p = *(void **)((uint8_t *)g + off);
            if (looks_like_ptr(p) && [set containsObject:@((uintptr_t)p)]) hc = p;
        }
        if (!hc || hc_pid(hc) != want.intValue) continue;
        NSNumber *key = @((uintptr_t)hc);
        void *asset = *(void **)((uint8_t *)hc + OFF_HC_ASSET);
        NSArray *pd = pending[key];
        if (pd) {
            if (asset && (uintptr_t)asset != [pd[0] unsignedLongValue]) {
                shiny_asset[key] = @((uintptr_t)asset);   // the shiny model has arrived
                [pending removeObjectForKey:key];
            } else if (now - [pd[1] doubleValue] > 5.0) {
                [pending removeObjectForKey:key];        // never arrived: try again
            }
            continue;
        }
        if (!asset || (uintptr_t)asset == [shiny_asset[key] unsignedLongValue]) continue;
        WLOG(@"shiny: gym %@ guard #%d on the map -- reloading shiny", poi, want.intValue);
        pending[key] = @[@((uintptr_t)asset), @(now)];
        shiny_reload(hc, want.intValue);
    }
}

static bool shiny_gym_tick(void) {
    static void *t_plat = NULL, *t_me = NULL, *t_foe = NULL;
    if (!t_plat) t_plat = mt_type("Niantic.Holoholo.Gym.GymApproachPlatform, Assembly-CSharp");
    if (!t_me)   t_me   = mt_type("Niantic.Holoholo.Battle.PlayerBattlePokemon, Assembly-CSharp");
    if (!t_foe)  t_foe  = mt_type("Niantic.Holoholo.Battle.EnemyBattlePokemon, Assembly-CSharp");
    if (!g_mt[MT_FIND_ALL] || !g_mt[MT_ACTIVE]) return false;
    void *me  = looks_like_ptr(t_me)  ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_me, NULL)  : NULL;
    void *foe = looks_like_ptr(t_foe) ? ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_foe, NULL) : NULL;
    NSMutableArray<NSValue *> *plats = [NSMutableArray array];
    if (looks_like_ptr(t_plat)) {
        void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_plat, NULL);
        uint64_t n = looks_like_ptr(arr) ? *(uint64_t *)((uint8_t *)arr + 0x18) : 0;
        for (uint64_t i = 0; i < n && i < 32; i++) {
            void *pl = *(void **)((uint8_t *)arr + 0x20 + i * 8);
            if (go_active(pl)) [plats addObject:[NSValue valueWithPointer:pl]];
        }
    }
    bool in_battle = looks_like_ptr(me) || looks_like_ptr(foe);
    if (!in_battle && !plats.count) return false;
    // Ask the server when the gym opens and whenever the fight changes hands.
    static int32_t last_sig = -1;
    int32_t sig = (in_battle ? 1 : 2) * 1000000 + (int32_t)plats.count * 10000 +
                  hc_pid(shiny_owned_character(foe, "gym defender")) * 1 ;
    NSDictionary *gym = rj(g_shiny_state, @"gym");
    // v185: in the BACKGROUND. This used to be shiny_fetch_sync -- up to 1.3 s with the game
    // thread frozen, and the signature changes several times while the camera flies in
    // (platforms appearing one by one, the battle starting, the defender's model arriving),
    // so the gym/battle transition could hang for seconds. The answer lands on a later tick.
    static NSTimeInterval asked_at = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ((sig != last_sig || ![gym isKindOfClass:[NSDictionary class]]) && now - asked_at > 0.5) {
        last_sig = sig;
        asked_at = now;
        shiny_poll();
    }
    if (![gym isKindOfClass:[NSDictionary class]]) return true;
    NSDictionary *bt = rj(gym, @"battle");
    if (in_battle && [bt isKindOfClass:[NSDictionary class]]) {
        void *mc = shiny_owned_character(me, "gym attacker");
        if (mc && [rj(bt, @"atk_shiny") boolValue] && hc_pid(mc) == [rj(bt, @"atk_pid") intValue])
            { if (shiny_model_settled(mc)) shiny_apply_to(mc, "gym (your Pokemon)", false); }
        void *fc = shiny_owned_character(foe, "gym defender");
        if (fc && [rj(bt, @"def_shiny") boolValue] && hc_pid(fc) == [rj(bt, @"def_pid") intValue])
            { if (shiny_model_settled(fc)) shiny_apply_to(fc, "gym (defender)", false); }
    }
    NSArray *pids = rj(gym, @"shiny_pids");
    if ([pids isKindOfClass:[NSArray class]] && pids.count) {
        for (NSValue *v in plats) {
            void *hc = shiny_owned_character(v.pointerValue, "gym platform");
            if (hc && [pids containsObject:@(hc_pid(hc))] && shiny_model_settled(hc)) shiny_apply_to(hc, "gym platform", false);
        }
    }
    return true;
}



// v63: a UI transform -> UIKit point. The storage canvas is drawn by a camera (its
// positions are world units, not pixels -- v62 put every sparkle bottom-left), so project
// through the frontmost active camera whose culling mask includes the label's layer.
static bool spk_world_screen(WsV3 w, int32_t layer, CGSize view, CGPoint *out);
static int32_t spk_tr_layer(void *tr) {
    void *go = ((qc_inst0)g_qc[QC_COMP_GO])(tr, NULL);
    return looks_like_ptr(go) ? ((int32_t (*)(void *, void *))(g_shiny_base + RVA_GAMEOBJECT_LAYER))(go, NULL) : -1;
}
static bool spk_tr_screen(void *tr, CGSize view, CGPoint *out) {
    if (!g_spk_anchor_ok || !looks_like_ptr(tr)) return false;
    WsV3 w = ((WsV3 (*)(void *, void *))(g_shiny_base + RVA_TRANSFORM_POSITION))(tr, NULL);
    return spk_world_screen(w, spk_tr_layer(tr), view, out);
}
// v94: any world point (not just a transform's origin) -- the research buttons project the
// corners of the Nearby box through this.
static bool spk_world_screen(WsV3 w, int32_t layer, CGSize view, CGPoint *out) {
    if (!g_spk_anchor_ok) return false;
    if (!g_camera_type) g_camera_type = mt_type("UnityEngine.Camera, UnityEngine");
    if (!looks_like_ptr(g_camera_type)) return false;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_camera_type, NULL);
    uint64_t n = looks_like_ptr(arr) ? *(uint64_t *)((uint8_t *)arr + 0x18) : 0;
    int32_t sw = 0, sh = 0; float best_depth = -1e9; bool have = false; WsV3 best = {0, 0, 0};
    for (uint64_t i = 0; i < n && i < 32; i++) {
        void *cam = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if (!looks_like_ptr(cam)) continue;
        void *cgo = ((qc_inst0)g_qc[QC_COMP_GO])(cam, NULL);
        if (!looks_like_ptr(cgo) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(cgo, NULL)) continue;
        int32_t pw = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_PIXEL_W))(cam, NULL);
        int32_t ph = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_PIXEL_H))(cam, NULL);
        if (pw > sw) sw = pw;
        if (ph > sh) sh = ph;
        int32_t mask = ((int32_t (*)(void *, void *))(g_shiny_base + RVA_CAMERA_CULLMASK))(cam, NULL);
        if (layer >= 0 && layer < 32 && !(mask & (1 << layer))) continue;
        float depth = ((float (*)(void *, void *))(g_shiny_base + RVA_CAMERA_DEPTH))(cam, NULL);
        // v64: only a camera that actually puts the label ON screen counts -- while storage
        // opens, other cameras (map, model) also include the UI layer and threw the
        // sparkles off screen until storage was reopened
        WsV3 sp = ((WsV3 (*)(void *, WsV3, void *))(g_shiny_base + RVA_CAMERA_W2SCREEN))(cam, w, NULL);
        if (!(sp.x >= 0 && sp.x <= pw && sp.y >= 0 && sp.y <= ph)) continue;
        if (have && depth <= best_depth) continue;
        best = sp; best_depth = depth; have = true;
    }
    if (!have || sw <= 0 || sh <= 0) return false;
    out->x = best.x / sw * view.width;
    out->y = view.height - best.y / sh * view.height;
    return true;
}

// ---- v62: a little sparkle next to shiny Pokemon in storage. The game's fonts (Lato) have
// no star glyph (v60's ✦ vanished, v61 showed "*"), so the sparkle is DRAWN: a gold
// four-point star in a UIKit overlay, placed right of each shiny row's "Name" label.
// Storage is a Screen Space Overlay canvas, so Transform.position is in screen PIXELS
// (origin bottom-left). Rows are recycled on scroll, so the label transforms are re-found
// every 0.25 s and their positions re-read every frame (30 Hz) so the sparkle follows.
// v61's "*" suffix is stripped from any label that still has it.
static const unichar kShinyMarker = 0x2009;
#define STG_MAX 64
static CGPoint g_stg_pt[STG_MAX];     // where each sparkle goes, worked out on the slow tick
static CGFloat g_stg_w[STG_MAX];      // estimated half-width of the name, in points
static int g_stg_n = 0;
static UIView *STG_view = nil;
static CAShapeLayer *STG_layer = nil;

static void *shiny_row_text(void *row, void **name_tr_out) {
    // v65: a fresh string every time -- a cached managed string isn't GC-rooted, so after
    // the first storage visit it could be collected and Find("Name") failed from then on
    void *name_path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"Name", NULL);
    if (!looks_like_ptr(name_path) || !looks_like_ptr(g_iv_type_text)) return NULL;
    void *row_tr = ((qc_inst0)g_qc[QC_COMP_TR])(row, NULL);
    void *name_tr = looks_like_ptr(row_tr) ? ((qc_inst1)g_qc[QC_FIND])(row_tr, name_path, NULL) : NULL;
    if (!looks_like_ptr(name_tr)) return NULL;
    *name_tr_out = name_tr;
    void *name_go = ((qc_inst0)g_qc[QC_COMP_GO])(name_tr, NULL);
    return looks_like_ptr(name_go) ? ((qc_inst1)g_mt[MT_GETCOMPONENT])(name_go, g_iv_type_text, NULL) : NULL;
}

static void shiny_storage_tick(void) {
    g_stg_n = 0;
    if (!g_iv_set_text || !mt_storage_open()) return;
    int dbg_rows = 0, dbg_text = 0;
    if (!g_iv_type_text) g_iv_type_text = mt_type("UnityEngine.UI.Text, UnityEngine.UI");
    void *list = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_mt_type_list, NULL);
    void *rows = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, g_mt_type_row, NULL);
    if (!looks_like_ptr(list) || !looks_like_ptr(rows)) return;
    int64_t n = *(int64_t *)((uint8_t *)rows + 0x18);
    if (n < 0 || n > 512) return;
    for (int64_t i = 0; i < n; i++) {
        void *row = *(void **)((uint8_t *)rows + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(row)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(row, NULL);
        if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        void *proto = mt_proto_at(list, *(int32_t *)((uint8_t *)row + OFF_ROW_BOUNDINDEX));
        void *name_tr = NULL;
        dbg_rows++;
        void *text = shiny_row_text(row, &name_tr);
        if (!looks_like_ptr(text)) continue;
        dbg_text++;
        NSString *cur = il2cpp_to_ns(*(void **)((uint8_t *)text + OFF_TEXT_STRING));
        if (!cur) continue;
        // v129: "Shiny<thin space>Name" (was "Name<thin space>Shiny"); strip either form
        NSString *mk = [NSString stringWithCharacters:&kShinyMarker length:1];
        NSString *pre = [@"Shiny" stringByAppendingString:mk];
        NSString *base = cur;
        if ([base hasPrefix:pre]) base = [base substringFromIndex:pre.length];
        NSRange mark = [base rangeOfString:mk];
        if (mark.location != NSNotFound) base = [base substringToIndex:mark.location];
        bool shiny = looks_like_ptr(proto) && !*(uint8_t *)((uint8_t *)proto + OFF_PROTO_EGG) &&
                     shiny_uid(*(uint64_t *)((uint8_t *)proto + OFF_PROTO_ID));
        // v81: say it in the name instead of drawing a sparkle next to it -- the game's font has
        // no star glyph, and the drawn one needed the row's screen position every frame.
        NSString *want = shiny ? [pre stringByAppendingString:base] : base;
        if (![want isEqualToString:cur]) {
            void *ws = ((qc_static1)g_qc[QC_STR])(NULL, (void *)want.UTF8String, NULL);
            if (looks_like_ptr(ws)) ((qc_inst1)g_iv_set_text)(text, ws, NULL);
        }
        // v101: no sparkle drawn next to the row any more (user's call) -- the "Shiny "
        // label says it. shiny_storage_frame() hides its overlay while g_stg_n stays 0.
        (void)name_tr;
    }
    static int last = -1;
    if (g_stg_n != last) { last = g_stg_n; WLOG(@"shiny: storage labelled (%d rows, %d labels)", dbg_rows, dbg_text); }
}

static void shiny_storage_frame(void) {
    bool show = g_stg_n > 0 && g_spk_anchor_ok && mt_storage_open();
    if (!show) { if (STG_view) STG_view.hidden = YES; return; }
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (!STG_view || STG_view.superview != parent) {
        [STG_view removeFromSuperview];
        STG_view = [[UIView alloc] initWithFrame:parent.bounds];
        STG_view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        STG_view.userInteractionEnabled = NO;
            STG_layer = [CAShapeLayer layer];
        // white like the encounter sparkle (v93), with a soft cool glow so it shows on white
        STG_layer.fillColor = [UIColor colorWithWhite:1 alpha:1].CGColor;
        STG_layer.shadowColor = [UIColor colorWithRed:0.45 green:0.62 blue:0.85 alpha:1].CGColor;
        STG_layer.shadowOpacity = 0.9; STG_layer.shadowRadius = 3; STG_layer.shadowOffset = CGSizeZero;
        [STG_view.layer addSublayer:STG_layer];
        [parent addSubview:STG_view];
    }
    STG_view.hidden = NO;
    [parent bringSubviewToFront:STG_view];
    double t = CACurrentMediaTime();
    UIBezierPath *path = [UIBezierPath bezierPath];
    static int logged = 0;
    for (int i = 0; i < g_stg_n; i++) {
        CGFloat x = g_stg_pt[i].x + g_stg_w[i], y = g_stg_pt[i].y - 1;
        if (logged < 6) { logged++; WLOG(@"shiny: storage sparkle at pt(%.1f,%.1f)", x, y); }
        CGFloat r = 6.5 + 1.5 * sin(t * 4 + i);          // gentle twinkle
        spk_star(path, x, y, r);
        spk_star(path, x + 7, y - 6, 2.5 + 1.0 * sin(t * 5 + i + 1.7));
    }
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    STG_layer.path = path.CGPath;
    [CATransaction commit];
}

static void *(*o_asset_name)(void *, int32_t, void *);
static void *hk_asset_name(void *self, int32_t pid, void *mi) {
    void *orig = o_asset_name(self, pid, mi);
    if (!g_shiny_state) shiny_fetch_sync(1.0);
    NSArray *species = rj(g_shiny_state, @"species");
    if (![species isKindOfClass:[NSArray class]] || ![species containsObject:@(pid)]) return orig;
    bool shiny = false;
    const char *where = "encounter";
    uint64_t uid = shiny_panel_uid();
    if (uid) {
        where = "details";
        if ([NSDate date].timeIntervalSince1970 - g_shiny_state_at > 1.0) shiny_fetch_sync(1.0);
        shiny = shiny_uid(uid);
    } else {
        NSDictionary *enc = rj(shiny_fetch_sync(1.2) ?: g_shiny_state, @"encounter");
        shiny = [rj(enc, @"shiny") boolValue] && [rj(enc, @"pokemon_id") intValue] == pid;
    }
    if (!shiny) return orig;
    char name[16];
    snprintf(name, sizeof name, "pm%04d_s", pid);
    void *s = ((qc_static1)g_qc[QC_STR])(NULL, (void *)name, NULL);
    if (!looks_like_ptr(s)) return orig;
    WLOG(@"shiny: #%d on the %s -> loading %s", pid, where, name);
    return s;
}

static bool install_shinies(uintptr_t base, uintptr_t dstart, size_t dsize) {
    uint32_t w = *(uint32_t *)(base + RVA_POKEMON_ASSET_NAME);
    if (w != FIRST_POKEMON_ASSET_NAME) {
        WLOG(@"shiny: PokemonAssetName %08x != %08x -- shinies OFF", w, FIRST_POKEMON_ASSET_NAME);
        return false;
    }
    if (*(uint32_t *)(base + RVA_HC_LOAD_POKEMON) != FIRST_HC_LOAD_POKEMON ||
        *(uint32_t *)(base + RVA_HC_POKEMON_ID) != FIRST_HC_POKEMON_ID) {
        WLOG(@"shiny: HoloCharacter functions don't match -- shinies OFF");
        return false;
    }
    g_shiny_base = base;
    g_spk_anchor_ok = *(uint32_t *)(base + RVA_CAMERA_MAIN) == FIRST_CAMERA_MAIN &&
                      *(uint32_t *)(base + RVA_CAMERA_W2S) == FIRST_CAMERA_W2S &&
                      *(uint32_t *)(base + RVA_TRANSFORM_POSITION) == FIRST_TRANSFORM_POS;
    if (!g_spk_anchor_ok) WLOG(@"shiny: camera functions don't match -- sparkles can't follow the Pokemon");
    o_asset_name = (void *(*)(void *, int32_t, void *))(base + RVA_POKEMON_ASSET_NAME);
    if (!redirect_method_pointer(dstart, dsize, base + RVA_POKEMON_ASSET_NAME,
                                 (uintptr_t)&hk_asset_name, "PokemonAssetName")) return false;
    WLOG(@"shiny: armed (models from %@)", SHINY_URL);
    return true;
}

// ----------------------------------------------------------------- Shiny Incense (v110)
// The Shiny Incense is Item 402 (ITEM_INCENSE_SPICY). Tapping it in the bag showed the "use"
// popup and then did nothing: PlayerBuffService.SelectBuff asks ItemFactory.Create(402) for
// the buff, and the factory only has prefabs for items the 2016 game shipped (Incense 401,
// Lucky Egg 301), so it returns null and there is nothing to activate. And the Incense class
// can't just be reused as-is: Incense.get_ItemId is hard-coded (`mov w0, #401; ret`), and
// Activate() sends UseIncense with that id.
//   * ItemFactory.Create(402) -> builds the ordinary Incense (401) and remembers the object;
//   * Incense.get_ItemId      -> 402 for a remembered object, 401 for every other.
// So the game sends USE_INCENSE incense_type=402, which the server burns as the Shiny Incense
// (protocol.build_use_incense_response); the popup/active-buff art follows the id too.
// Both have exactly one method-table entry and 0 direct callers in 0.35 (checked offline).
#define RVA_ITEMFACTORY_CREATE   0x768E4    // 0.29 0x2593A4
#define FIRST_ITEMFACTORY_CREATE 0xa9bd57f6
#define RVA_INCENSE_ITEMID       0x75A2C    // 0.29 0x25878C
#define FIRST_INCENSE_ITEMID     0x52803220 // mov w0, #401
#define ITEM_INCENSE_ORDINARY    401
#define ITEM_SHINY_INCENSE       402
// v111: v110 only hooked the plain Create(Item); the bag goes through the GENERIC one --
// PlayerBuffService.SelectBuff calls IItemFactory.Create<T>(Item), a generic virtual call
// that lands in the shared Create<object> body (0.29 0xB42D34 -> 0.35 0xB66D30; one table
// entry, 0 direct callers). Same arguments plus the generic MethodInfo, passed through as-is.
#define RVA_ITEMFACTORY_CREATE_T   0xB66D30
#define FIRST_ITEMFACTORY_CREATE_T 0xa9bd57f6
static void *(*o_item_create)(void *, int32_t, void *) = NULL;
static void *(*o_item_create_t)(void *, int32_t, void *) = NULL;
static std::unordered_set<void *> g_shiny_incense;
// v112: its own icon (the timer, the "use" popup) and blue smoke.
//   * icon: ItemBase.sprite (0x28; get_GuiSprite = ldr x0,[x0,#0x28] in 0.35) is the prefab's
//     Incense art -- pointed at Store_Windstock_shinyincense (patch_badges.py; loaded through
//     the store's sprite table) on the object we hand out.
//   * smoke: patch_badges.py moves the shared incense_fx material to Particles/Alpha Blended
//     with a neutral tint; while a Shiny Incense burns, the renderers of its emitters
//     (emitter_pink under incense_avatar_fx / incense_pokemon_fx) get their own material copy
//     tinted blue. 2 x pink (1, .51, .93) x tint (.1, .7, 1) = sky blue (.2, .71, 1).
#define OFF_ITEMBASE_SPRITE     0x28
#define RVA_OBJECT_GET_NAME     0x8ABA50   // 0.29 0x88A280
#define RVA_RENDERER_GET_MAT    0x8C0A40   // icall "UnityEngine.Renderer::get_material()"
#define RVA_MATERIAL_SETCOLOR   0x8B458C   // Material.SetColor(string, Color), 0.29 0x892FC4
#define RVA_TRANSFORM_PARENT    0x8D5C2C   // 0.29 0x8B4450
#define RVA_INCENSE_ACTIVATE    0x75D20    // 0.29 0x258A80
static uintptr_t g_si_base = 0;
static void *(*o_incense_activate)(void *, void *) = NULL;
static NSTimeInterval g_si_lit_until = 0;     // bridges the gap until /shiny/state says it's burning
static void *g_si_sprite = NULL;
static NSString *si_name(void *obj) {
    if (!looks_like_ptr(obj)) return nil;
    void *s = ((void *(*)(void *, void *))(g_si_base + RVA_OBJECT_GET_NAME))(obj, NULL);
    if (!looks_like_ptr(s)) return nil;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    if (len < 0 || len > 256) return nil;
    return [NSString stringWithCharacters:(unichar *)((uint8_t *)s + 0x14) length:len];
}
static void *si_find_sprite(void) {
    if (g_si_sprite || !g_mt[MT_FIND_ALL]) return g_si_sprite;
    void *type = mt_type("UnityEngine.Sprite, UnityEngine");
    void *arr = looks_like_ptr(type) ? ((qc_static1)g_mt[MT_FIND_ALL])(NULL, type, NULL) : NULL;
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    for (int64_t i = 0; i < n; i++) {
        void *sp = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if ([si_name(sp) isEqualToString:@"Store_Windstock_shinyincense"]) { g_si_sprite = sp; break; }
    }
    WLOG(@"shiny incense: icon sprite %@ (%lld sprites loaded)", g_si_sprite ? @"found" : @"NOT loaded", n);
    return g_si_sprite;
}
static void *shiny_incense_create(void *(*orig)(void *, int32_t, void *), void *self, int32_t item,
                                  void *mi, const char *via) {
    if (item != ITEM_SHINY_INCENSE) return orig(self, item, mi);
    void *inc = orig(self, ITEM_INCENSE_ORDINARY, mi);
    if (looks_like_ptr(inc)) {
        g_shiny_incense.insert(inc);
        void *sp = si_find_sprite();
        if (sp) *(void **)((uint8_t *)inc + OFF_ITEMBASE_SPRITE) = sp;   // Boehm GC: no barrier needed
    }
    WLOG(@"shiny incense: item %d -> Incense object %p (%s)", item, inc, via);
    return inc;
}
static void *hk_incense_activate(void *self, void *mi) {
    if (g_shiny_incense.count(self)) {
        g_si_lit_until = [NSDate date].timeIntervalSince1970 + 60;
        WLOG(@"shiny incense: lit -- smoke goes blue");
    }
    return o_incense_activate(self, mi);
}
static bool si_burning(void) {
    id ms = [g_shiny_state isKindOfClass:[NSDictionary class]] ? g_shiny_state[@"incense_ms"] : nil;
    return ([ms isKindOfClass:[NSNumber class]] && [ms longLongValue] > 0) ||
           [NSDate date].timeIntervalSince1970 < g_si_lit_until;
}
static void shiny_incense_tick(void) {
    static std::unordered_set<void *> tinted;
    static void *t_renderer = NULL;
    if (!g_game_live || !g_mt[MT_FIND_ALL]) return;
    if (!si_burning()) { tinted.clear(); return; }
    if (!t_renderer) t_renderer = mt_type("UnityEngine.Renderer, UnityEngine");
    if (!looks_like_ptr(t_renderer)) return;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_renderer, NULL);
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    void *tint_key = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"_TintColor", NULL);
    for (int64_t i = 0; i < n; i++) {
        void *r = *(void **)((uint8_t *)arr + 0x20 + i * 8);
        if (!looks_like_ptr(r) || tinted.count(r)) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(r, NULL);
        if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        if (![si_name(go) isEqualToString:@"emitter_pink"]) continue;
        void *parent = ((void *(*)(void *, void *))(g_si_base + RVA_TRANSFORM_PARENT))(
                           ((qc_inst0)g_qc[QC_COMP_TR])(r, NULL), NULL);
        if (![si_name(parent) hasPrefix:@"incense_"]) continue;          // lures keep their pink
        void *mat = ((void *(*)(void *, void *))(g_si_base + RVA_RENDERER_GET_MAT))(r, NULL);
        if (!looks_like_ptr(mat) || !looks_like_ptr(tint_key)) continue;
        ((void (*)(void *, void *, UColor, void *))(g_si_base + RVA_MATERIAL_SETCOLOR))(
            mat, tint_key, (UColor){0.1f, 0.7f, 1.0f, 0.5f}, NULL);
        tinted.insert(r);
        WLOG(@"shiny incense: %@ smoke tinted blue", si_name(parent));
    }
}
static void *hk_item_create(void *self, int32_t item, void *mi) {
    return shiny_incense_create(o_item_create, self, item, mi, "Create");
}
static void *hk_item_create_t(void *self, int32_t item, void *mi) {
    return shiny_incense_create(o_item_create_t, self, item, mi, "Create<T>");
}
static int32_t hk_incense_itemid(void *self, void *mi) {
    return g_shiny_incense.count(self) ? ITEM_SHINY_INCENSE : ITEM_INCENSE_ORDINARY;
}
static bool install_shiny_incense(uintptr_t base, uintptr_t dstart, size_t dsize) {
    if (*(uint32_t *)(base + RVA_ITEMFACTORY_CREATE) != FIRST_ITEMFACTORY_CREATE ||
        *(uint32_t *)(base + RVA_INCENSE_ITEMID) != FIRST_INCENSE_ITEMID) {
        WLOG(@"shiny incense: ItemFactory.Create / Incense.get_ItemId don't match -- OFF");
        return false;
    }
    if (*(uint32_t *)(base + RVA_ITEMFACTORY_CREATE_T) != FIRST_ITEMFACTORY_CREATE_T) {
        WLOG(@"shiny incense: ItemFactory.Create<T> doesn't match -- OFF");
        return false;
    }
    g_si_base = base;
    o_item_create = (void *(*)(void *, int32_t, void *))(base + RVA_ITEMFACTORY_CREATE);
    o_item_create_t = (void *(*)(void *, int32_t, void *))(base + RVA_ITEMFACTORY_CREATE_T);
    bool ok = redirect_method_pointer(dstart, dsize, base + RVA_INCENSE_ITEMID,
                                      (uintptr_t)&hk_incense_itemid, "Incense.get_ItemId");
    // either Create path may build the buff (bag = Create<T>, startup = either): hook both
    bool c1 = redirect_method_pointer(dstart, dsize, base + RVA_ITEMFACTORY_CREATE,
                                      (uintptr_t)&hk_item_create, "ItemFactory.Create");
    bool c2 = redirect_method_pointer(dstart, dsize, base + RVA_ITEMFACTORY_CREATE_T,
                                      (uintptr_t)&hk_item_create_t, "ItemFactory.Create<T>");
    ok = ok && (c1 || c2);
    if (*(uint32_t *)(base + RVA_INCENSE_ACTIVATE) == 0xa9bd57f6) {
        o_incense_activate = (void *(*)(void *, void *))(base + RVA_INCENSE_ACTIVATE);
        redirect_method_pointer(dstart, dsize, base + RVA_INCENSE_ACTIVATE,
                                (uintptr_t)&hk_incense_activate, "Incense.Activate");
    }
    WLOG(@"shiny incense: %s", ok ? "armed (bag item 402 uses the Incense)" : "NOT armed");
    return ok;
}

// ----------------------------------------------------------------- XP bonus buff (v133)
// An event XP bonus (server events.json xp_bonus; /shiny/state sends
// {"xp_bonus": {"mult": 2, "label": "2x XP"}} while it runs) shows as a buff beside the Lucky
// Egg's: the game's own ActiveBuffGui, with the Windstock W (Store_Windstock_xpbonus, added by
// patch_badges.py) and the label where the countdown would be.
//   * the buff is a real LuckyEgg from ItemFactory.Create(301), given the W sprite, then added the way PlayerBuffService.OnStartup adds
//     a burning egg (SetParent + AddBuff) -- minus ActivateFromStartup, whose ApplyFX would
//     put the egg sparkle on the trainer.
//   * UpdateBuffInfo writes "mm:ss" into timeLeftLabel every frame and has a direct caller,
//     so it can't be redirected; PlayerBuffService.Update can (Unity calls it through its
//     MethodInfo, 0 direct callers). It is just `b UpdateAllActiveBuffs`, so right after it
//     returns our label goes over the time, in the same frame -- the time never shows.
//   * v134: the ring is the time left in the event. A scheduled bonus comes with its window
//     (start_ms/end_ms) and those become the egg's Start/EndTimestamp, so the game's own
//     progress = (now - start) / (end - start) runs the ring down. Set by hand = no window:
//     a start a minute ago and an end ten years out keep the ring full.
//   * the bonus ending sets the egg's EndTimestamp to its start: the game's own loop then
//     completes it (BuffComplete + Dispose) like any egg that ran out.
//   * IsBuffTypeActive and ActivateBuff both ask "is a buff of this type running?" through a
//     lambda; both skip ours, so a real Lucky Egg can still be used (the server stacks them).
// Offsets are 0.35's, read off its code (PlayerBuffGuiController.buffGuis is 0x90 there, not
// the dump's 0x78).
#define RVA_BUFFSVC_UPDATE       0x78D94    // 0.29 0x25B7C4
#define FIRST_BUFFSVC_UPDATE     0x14000001 // b UpdateAllActiveBuffs
#define RVA_BUFFSVC_ADDBUFF      0x78790    // 0.29 0x25B1C0
#define FIRST_BUFFSVC_ADDBUFF    0xa9bd57f6
#define RVA_LUCKYEGG_SETPARENT   0x7749C    // 0.29 0x259F5C
#define FIRST_LUCKYEGG_SETPARENT 0xa9be4ff4
#define RVA_BUFF_TYPE_PRED       0x79160    // IsBuffTypeActive's lambda (0.29 0x25BB90)
#define RVA_BUFF_SAME_PRED       0x790A4    // ActivateBuff's lambda (0.29 0x25BAD4)
#define FIRST_BUFF_PRED          0xa9bd57f6
#define RVA_XPB_SET_TEXT         0x87F9D8   // Text.set_text (as kSetText)
#define PBS_OFF_GUI              0x28       // PlayerBuffService.gameOverlayGui
#define PBS_OFF_FACTORY          0x50       //   .itemFactory
#define PBS_OFF_BUFFS            0x68       //   .activeBuffs (List<IPlayerBuff>)
#define PBG_OFF_BUFFGUIS         0x90       // PlayerBuffGuiController.buffGuis (Dictionary)
#define ABG_OFF_LABEL            0x30       // ActiveBuffGui.timeLeftLabel
#define EGG_OFF_ACTIVE           0x58       // LuckyEgg.<IsActive>
#define EGG_OFF_START            0x60       //   .<StartTimestamp> (ms)
#define EGG_OFF_END              0x68       //   .<EndTimestamp> (ms)
#define ITEM_LUCKY_EGG           301
static uintptr_t g_xpb_base = 0;
static void (*o_buffsvc_update)(void *, void *) = NULL;
static bool (*o_buff_type_pred)(void *, void *, void *) = NULL;
static bool (*o_buff_same_pred)(void *, void *, void *) = NULL;
static void *g_xpb_svc = NULL;          // the PlayerBuffService our eggs were added to
// v146: one buff per event bonus. /shiny/state "buffs": [{"id", "icon", "label", "start_ms",
// "end_ms"}] -- xp (the W), candy, shiny, and the spawn boost (Halloween: "Dark&Shadow", a
// ghost). Each is its own fake Lucky Egg with its own sprite (Store_Windstock_<icon>, added
// by patch_badges.py; a missing one falls back to the W). An older server sends only
// "xp_bonus", which becomes the one "xp" buff as before.
struct XpbBuff { void *egg = NULL; void *str = NULL; NSString *label = nil; NSTimeInterval last_try = 0; };
static std::unordered_map<std::string, XpbBuff> g_xpb;       // buff id -> its state
static std::unordered_map<std::string, void *> g_xpb_sprites; // icon -> Sprite (NULL = not loaded)
static std::unordered_set<void *> g_xpb_eggs;   // ours, live or running out

static void *xpb_find_sprite(NSString *icon) {
    std::string key = icon.UTF8String ?: "";
    auto hit = g_xpb_sprites.find(key);
    if (hit != g_xpb_sprites.end() && hit->second) return hit->second;
    if (!g_mt[MT_FIND_ALL]) return NULL;
    static NSTimeInterval last_scan = 0;            // a sprite that isn't there: rescan now and then
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (hit != g_xpb_sprites.end() && now - last_scan < 30) return NULL;
    last_scan = now;
    void *type = mt_type("UnityEngine.Sprite, UnityEngine");
    void *arr = looks_like_ptr(type) ? ((qc_static1)g_mt[MT_FIND_ALL])(NULL, type, NULL) : NULL;
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    for (int64_t i = 0; i < n; i++) {
        void *sp = *(void **)((uint8_t *)arr + OFF_ARRAY_DATA + i * 8);
        NSString *nm = si_name(sp);
        if ([nm hasPrefix:@"Store_Windstock_"])
            g_xpb_sprites[[nm substringFromIndex:16].UTF8String] = sp;
    }
    void *sp = g_xpb_sprites[key];
    WLOG(@"xp bonus: %@ sprite %@ (%lld sprites loaded)", icon, sp ? @"found" : @"NOT loaded", n);
    return sp;
}
// List<T>: _items @0x10, _size @0x18
static bool xpb_listed(void *list, void *obj) {
    if (!looks_like_ptr(list)) return false;
    void *items = *(void **)((uint8_t *)list + 0x10);
    int32_t n = *(int32_t *)((uint8_t *)list + 0x18);
    if (!looks_like_ptr(items) || n < 0 || n > *(int64_t *)((uint8_t *)items + 0x18)) return false;
    for (int32_t i = 0; i < n; i++)
        if (*(void **)((uint8_t *)items + OFF_ARRAY_DATA + i * 8) == obj) return true;
    return false;
}
// Dictionary<K,V> (Mono 2.x): keySlots @0x20, valueSlots @0x28, touchedSlots @0x30
static void *xpb_dict_get(void *dict, void *key) {
    if (!looks_like_ptr(dict)) return NULL;
    void *keys = *(void **)((uint8_t *)dict + 0x20), *vals = *(void **)((uint8_t *)dict + 0x28);
    int32_t n = *(int32_t *)((uint8_t *)dict + 0x30);
    if (!looks_like_ptr(keys) || !looks_like_ptr(vals) || n < 0) return NULL;
    n = (int32_t)MIN((int64_t)n, MIN(*(int64_t *)((uint8_t *)keys + 0x18), *(int64_t *)((uint8_t *)vals + 0x18)));
    for (int32_t i = 0; i < n; i++)
        if (*(void **)((uint8_t *)keys + OFF_ARRAY_DATA + i * 8) == key)
            return *(void **)((uint8_t *)vals + OFF_ARRAY_DATA + i * 8);
    return NULL;
}
static int64_t xpb_now_ms(void) { return (int64_t)([NSDate date].timeIntervalSince1970 * 1000.0); }
// the egg's timestamps: the event's window, or (no window) a ring that stays full
static void xpb_window(NSDictionary *bonus, int64_t *start, int64_t *end) {
    id s = rj(bonus, @"start_ms"), e = rj(bonus, @"end_ms");
    if ([s isKindOfClass:[NSNumber class]] && [e isKindOfClass:[NSNumber class]] &&
        [e longLongValue] > [s longLongValue]) {
        *start = [s longLongValue];
        *end = [e longLongValue];
        return;
    }
    static int64_t t0 = 0;                          // fixed per run, so the ring doesn't creep
    if (!t0) t0 = xpb_now_ms() - 60 * 1000;
    *start = t0;
    *end = t0 + 10LL * 365 * 24 * 3600 * 1000;
}

static void xpb_start(void *svc, XpbBuff &b, NSDictionary *bonus) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (now - b.last_try < 5) return;               // a failed try waits before the next
    b.last_try = now;
    NSString *icon = rj(bonus, @"icon");
    if (![icon isKindOfClass:[NSString class]] || !icon.length) icon = @"xpbonus";
    void *factory = *(void **)((uint8_t *)svc + PBS_OFF_FACTORY);
    void *sprite = xpb_find_sprite(icon);
    if (!sprite) sprite = xpb_find_sprite(@"xpbonus");      // a client without the new art: the W
    if (!looks_like_ptr(factory) || !sprite) return;
    void *egg = ((void *(*)(void *, int32_t, void *))(g_xpb_base + RVA_ITEMFACTORY_CREATE))(factory, ITEM_LUCKY_EGG, NULL);
    if (!looks_like_ptr(egg)) { WLOG(@"xp bonus: ItemFactory gave no Lucky Egg"); return; }
    *(void **)((uint8_t *)egg + OFF_ITEMBASE_SPRITE) = sprite;
    xpb_window(bonus, (int64_t *)((uint8_t *)egg + EGG_OFF_START), (int64_t *)((uint8_t *)egg + EGG_OFF_END));
    *(uint8_t *)((uint8_t *)egg + EGG_OFF_ACTIVE) = 1;
    void *tr = ((qc_inst0)g_qc[QC_COMP_TR])(svc, NULL);
    ((void (*)(void *, void *, void *))(g_xpb_base + RVA_LUCKYEGG_SETPARENT))(egg, tr, NULL);
    g_xpb_eggs.insert(egg);
    ((void (*)(void *, void *, void *))(g_xpb_base + RVA_BUFFSVC_ADDBUFF))(svc, egg, NULL);
    b.egg = egg;
    WLOG(@"xp bonus: %@ buff on (egg %p)", icon, egg);
}

static void xpb_relabel(void *svc, XpbBuff &b, NSString *label) {
    void *gui = *(void **)((uint8_t *)svc + PBS_OFF_GUI);
    void *abg = looks_like_ptr(gui) ? xpb_dict_get(*(void **)((uint8_t *)gui + PBG_OFF_BUFFGUIS), b.egg) : NULL;
    void *text = looks_like_ptr(abg) ? *(void **)((uint8_t *)abg + ABG_OFF_LABEL) : NULL;
    if (!looks_like_ptr(text)) return;
    if (!b.str || ![label isEqualToString:b.label]) {
        b.str = ((qc_static1)g_qc[QC_STR])(NULL, (void *)label.UTF8String, NULL);
        b.label = label;
        WLOG(@"xp bonus: label \"%@\"", label);
    }
    if (looks_like_ptr(b.str))
        ((qc_inst1)(g_xpb_base + RVA_XPB_SET_TEXT))(text, b.str, NULL);
}

// the buffs the server wants now: id -> its dictionary
static NSDictionary *xpb_wanted(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray *list = rj(g_shiny_state, @"buffs");
    if ([list isKindOfClass:[NSArray class]]) {
        for (NSDictionary *b in list) {
            if (![b isKindOfClass:[NSDictionary class]]) continue;
            NSString *bid = rj(b, @"id"), *label = rj(b, @"label");
            if ([bid isKindOfClass:[NSString class]] && [label isKindOfClass:[NSString class]] && label.length)
                out[bid] = b;
        }
        return out;
    }
    NSDictionary *xp = rj(g_shiny_state, @"xp_bonus");     // an older server: the XP bonus only
    if ([xp isKindOfClass:[NSDictionary class]] && [rj(xp, @"label") isKindOfClass:[NSString class]] &&
        [(NSString *)rj(xp, @"label") length])
        out[@"xp"] = xp;
    return out;
}

static void hk_buffsvc_update(void *self, void *mi) {
    o_buffsvc_update(self, mi);                     // the game writes the countdowns
    if (self != g_xpb_svc) {                        // first frame, or a new service: our eggs went with the old one
        g_xpb_svc = self;
        g_xpb.clear();
        g_xpb_eggs.clear();
    }
    void *list = *(void **)((uint8_t *)self + PBS_OFF_BUFFS);
    for (auto it = g_xpb_eggs.begin(); it != g_xpb_eggs.end();) {    // forget eggs the game let go of
        if (xpb_listed(list, *it)) { ++it; continue; }
        for (auto &kv : g_xpb)
            if (kv.second.egg == *it) kv.second.egg = NULL;
        it = g_xpb_eggs.erase(it);
    }
    NSDictionary *wanted = xpb_wanted();
    for (NSString *bid in wanted) {
        NSDictionary *bonus = wanted[bid];
        int64_t w_start = 0, w_end = 0;
        xpb_window(bonus, &w_start, &w_end);
        if (w_end - xpb_now_ms() < 1000) continue;         // its last second: let it run out
        XpbBuff &b = g_xpb[bid.UTF8String];
        if (!b.egg) xpb_start(self, b, bonus);
        if (b.egg) {
            *(int64_t *)((uint8_t *)b.egg + EGG_OFF_START) = w_start;  // follows schedule edits;
            *(int64_t *)((uint8_t *)b.egg + EGG_OFF_END) = w_end;      // used on the next frame
            xpb_relabel(self, b, rj(bonus, @"label"));
        }
    }
    for (auto &kv : g_xpb) {                        // bonuses that ended: their eggs run out
        XpbBuff &b = kv.second;
        if (!b.egg) continue;
        NSDictionary *bonus = wanted[@(kv.first.c_str())];
        int64_t w_start = 0, w_end = 0;
        if (bonus) xpb_window(bonus, &w_start, &w_end);
        if (bonus && w_end - xpb_now_ms() >= 1000) continue;
        *(int64_t *)((uint8_t *)b.egg + EGG_OFF_END) = *(int64_t *)((uint8_t *)b.egg + EGG_OFF_START) + 1;
        WLOG(@"xp bonus: %s over -- egg %p runs out", kv.first.c_str(), b.egg);
        b.egg = NULL;                               // the game completes it next frame
        b.str = NULL;
    }
}
static bool hk_buff_type_pred(void *self, void *buff, void *mi) {
    return g_xpb_eggs.count(buff) ? false : o_buff_type_pred(self, buff, mi);
}
static bool hk_buff_same_pred(void *self, void *buff, void *mi) {
    return g_xpb_eggs.count(buff) ? false : o_buff_same_pred(self, buff, mi);
}

static bool install_xp_bonus(uintptr_t base, uintptr_t dstart, size_t dsize) {
    struct { uintptr_t rva; uint32_t word; const char *name; } chk[] = {
        { RVA_BUFFSVC_UPDATE, FIRST_BUFFSVC_UPDATE, "PlayerBuffService.Update" },
        { RVA_BUFFSVC_ADDBUFF, FIRST_BUFFSVC_ADDBUFF, "PlayerBuffService.AddBuff" },
        { RVA_LUCKYEGG_SETPARENT, FIRST_LUCKYEGG_SETPARENT, "LuckyEgg.SetParent" },
        { RVA_BUFF_TYPE_PRED, FIRST_BUFF_PRED, "IsBuffTypeActive lambda" },
        { RVA_BUFF_SAME_PRED, FIRST_BUFF_PRED, "ActivateBuff lambda" },
        { RVA_ITEMFACTORY_CREATE, FIRST_ITEMFACTORY_CREATE, "ItemFactory.Create" },
        { RVA_XPB_SET_TEXT, 0xa9bd57f6, "Text.set_text" },
    };
    for (auto &c : chk)
        if (*(uint32_t *)(base + c.rva) != c.word) {
            WLOG(@"xp bonus: %s doesn't match -- OFF", c.name);
            return false;
        }
    g_xpb_base = base;
    o_buffsvc_update = (void (*)(void *, void *))(base + RVA_BUFFSVC_UPDATE);
    o_buff_type_pred = (bool (*)(void *, void *, void *))(base + RVA_BUFF_TYPE_PRED);
    o_buff_same_pred = (bool (*)(void *, void *, void *))(base + RVA_BUFF_SAME_PRED);
    // the lambdas first: without them the fake egg would block real Lucky Eggs
    if (!redirect_method_pointer(dstart, dsize, base + RVA_BUFF_TYPE_PRED,
                                 (uintptr_t)&hk_buff_type_pred, "IsBuffTypeActive lambda") ||
        !redirect_method_pointer(dstart, dsize, base + RVA_BUFF_SAME_PRED,
                                 (uintptr_t)&hk_buff_same_pred, "ActivateBuff lambda") ||
        !redirect_method_pointer(dstart, dsize, base + RVA_BUFFSVC_UPDATE,
                                 (uintptr_t)&hk_buffsvc_update, "PlayerBuffService.Update")) {
        WLOG(@"xp bonus: NOT armed");
        return false;
    }
    WLOG(@"xp bonus: armed (event bonus shows as a W buff)");
    return true;
}

// ----------------------------------------------------------------- water on the map (v113)
// Lakes, rivers and the sea never drew. The map tiles (Google Mobile Maps, passed straight
// through) DO carry water -- decrypted 2026-09-25: each tile has a style table of fill
// colours, and water areas use Google's current water blue #90DAEE. The client's native
// nia::map::gmm::AreaBuilder decides what an area IS purely from that colour: its SetStyle
// (vtable slot 6) walks a list of LayerRules, each a set of MaskedColors, and the first
// rule with (colour ^ value) & mask == 0 sets the area's FeatureKind (+0x20) and draw
// parameter (+0x24). Those rules were written for Google's 2016 palette, so today's water
// colour matches nothing and the area is dropped. The C# side then never gets OnArea(WATER).
// Fix: wrap slot 6. If no rule matched and the fill colour is water-blue, give the area the
// kind + parameter of the client's own water rule (found by its bluish colour, logged once).
// AreaBuilder vtable: typeinfo name N3nia3map3gmm11AreaBuilderE -> 0x101e45958 (__DATA).
#define RVA_AREA_VTABLE     0x1E45958
#define RVA_AREA_SETSTYLE   0x165A7F4
#define OFF_AREA_KIND       0x20
#define WATER_UNSET         ((int32_t)0x80000000)
static void (*o_area_setstyle)(void *, int32_t) = NULL;
static int32_t g_water_kind = WATER_UNSET, g_water_param = 0;
static int32_t g_park_kind = WATER_UNSET, g_park_param = 0;     // v114
static bool g_parks_on = true;
static bool water_blue(uint32_t c) {
    int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    return b >= r + 40 && b + 12 >= g && b >= 150;      // #90DAEE yes, parks #C3F1D5 no
}
static bool park_green(uint32_t c) {                    // v114: #C3F1D5 today, #CADFAA in 2016
    int r = (c >> 16) & 0xFF, g = (c >> 8) & 0xFF, b = c & 0xFF;
    return g >= r + 15 && g >= b + 15 && g >= 180;      // water #90DAEE no
}
static uint32_t area_colour(void *self, int32_t idx) {
    uint8_t *ctx = *(uint8_t **)((uint8_t *)self + 0x8);
    if (!ctx) return 0;
    uint8_t *begin = *(uint8_t **)ctx, *end = *(uint8_t **)(ctx + 0x8);
    if (!begin || idx < 0 || (int64_t)idx >= (end - begin) / 160) return 0;
    uint8_t *e = begin + (int64_t)idx * 160;
    if (!(e[0] & 1)) return 0;
    uint32_t *vb = *(uint32_t **)(e + 0x8), *ve = *(uint32_t **)(e + 0x10);
    return (vb && vb != ve) ? *vb : 0;
}
static void water_learn_rules(void *self) {       // once: log the client's rules, find its water
    static bool done = false;
    if (done) return;
    done = true;
    uint8_t *ctx = *(uint8_t **)((uint8_t *)self + 0x8);
    if (!ctx) return;
    int32_t n = *(int32_t *)(ctx + 0x48);
    uint8_t *rep = *(uint8_t **)(ctx + 0x50);
    WLOG(@"water: %d area rule(s)", n);
    for (int32_t i = 0; rep && i < n && i < 200; i++) {
        uint8_t *r = *(uint8_t **)(rep + 8 + 8 * i);
        if (!r) continue;
        int32_t m = *(int32_t *)(r + 0x20);
        uint8_t *mrep = *(uint8_t **)(r + 0x28);
        int32_t kind = *(int32_t *)(r + 0x4c), param = *(int32_t *)(r + 0x50), skip = *(int32_t *)(r + 0x30);
        NSMutableString *cols = [NSMutableString string];
        bool blue = false, green = false;
        for (int32_t k = 0; mrep && k < m && k < 16; k++) {
            uint8_t *mc = *(uint8_t **)(mrep + 8 + 8 * k);
            if (!mc) continue;
            uint32_t v = *(uint32_t *)(mc + 0x14), mask = *(uint32_t *)(mc + 0x18);
            [cols appendFormat:@" %08x/%08x", v, mask];
            if (water_blue(v) && (mask & 0x00FFFFFF) == 0x00FFFFFF) blue = true;
            if (park_green(v) && (mask & 0x00FFFFFF) == 0x00FFFFFF) green = true;
        }
        WLOG(@"water:   rule %d kind %d param %d skip %d:%@%@", i, kind, param, skip, cols,
             blue ? @"  <- water" : green ? @"  <- park" : @"");
        if (blue && !skip && g_water_kind == WATER_UNSET) { g_water_kind = kind; g_water_param = param; }
        if (green && !skip && g_park_kind == WATER_UNSET) { g_park_kind = kind; g_park_param = param; }
    }
    if (g_water_kind == WATER_UNSET) { g_water_kind = 58; WLOG(@"water: no blue rule -- using FeatureKind WATER (58)"); }
    WLOG(@"water: water areas -> kind %d param %d", g_water_kind, g_water_param);
    if (g_park_kind == WATER_UNSET) WLOG(@"water: no green rule -- parks stay off");
    else WLOG(@"water: park areas -> kind %d param %d", g_park_kind, g_park_param);
}
static void hk_area_setstyle(void *self, int32_t idx) {
    int32_t *k = (int32_t *)((uint8_t *)self + OFF_AREA_KIND);
    int32_t save0 = k[0], save1 = k[1];
    water_learn_rules(self);
    k[0] = WATER_UNSET;
    o_area_setstyle(self, idx);
    if (k[0] != WATER_UNSET) return;                    // a rule matched: the client's call
    k[0] = save0; k[1] = save1;
    uint32_t c = area_colour(self, idx);
    static uint32_t seen[48]; static int nseen = 0;
    bool known = false;
    for (int i = 0; i < nseen; i++) if (seen[i] == c) { known = true; break; }
    bool park = g_parks_on && g_park_kind != WATER_UNSET && park_green(c);
    if (!known && nseen < 48) { seen[nseen++] = c; WLOG(@"water: unmatched area colour %08x%s", c,
                                water_blue(c) ? " -> drawn as water" : park ? " -> drawn as park" : ""); }
    if (c && water_blue(c)) { k[0] = g_water_kind; k[1] = g_water_param; }
    else if (c && park) { k[0] = g_park_kind; k[1] = g_park_param; }
}
static bool install_water(uintptr_t base) {
    void **slot = (void **)(base + RVA_AREA_VTABLE + 6 * sizeof(void *));
    if ((uintptr_t)*slot != base + RVA_AREA_SETSTYLE ||
        *(uint32_t *)(base + RVA_AREA_SETSTYLE) != 0xf940040a) {       // ldr x10, [x0, #0x8]
        WLOG(@"water: AreaBuilder vtable doesn't match -- OFF");
        return false;
    }
    vm_address_t page = (vm_address_t)slot & ~(vm_address_t)vm_page_mask;
    if (vm_protect(mach_task_self(), page, vm_page_size, false, VM_PROT_READ | VM_PROT_WRITE) != KERN_SUCCESS) {
        WLOG(@"water: vm_protect failed -- OFF");
        return false;
    }
    g_parks_on = ws_mod(@"parks", true);                // read once, not on the map thread
    o_area_setstyle = (void (*)(void *, int32_t))*slot;
    *slot = (void *)&hk_area_setstyle;
    WLOG(@"water: AreaBuilder.SetStyle wrapped (Google's water/park colours -> water/park)");
    return true;
}

// v109: the in-game Windstock menu + night dark mode (v108) were removed at the user's
// request -- the launcher has the mods menu, and the dark mode didn't look good.
// ----------------------------------------------------------------- colored names (v118, 0.35)
// The server colours names with Unity rich text (<color=#rrggbb>..</color>, see
// work/server/colortags.py). Gym names render it, but several labels -- the profile name,
// the PokeStop name -- ship with Text.supportRichText off and print the tags as text.
// Text.set_text (virtual, slot 65) is redirected: a string carrying "<color=" switches rich
// text on for that label before the real setter runs. Nothing else is touched.
// The profile name also has a LetterSpacing mesh effect. Unity 5.3 still emits a (collapsed)
// quad per tag character, so spacing by quad index would open gaps where the tags were --
// its ModifyMesh is skipped for rich-text labels that carry colour tags.
// 0.35 RVAs, masked-matched against the 0.29 dump: set_text 0x85EFF8 -> 0x87F9D8,
// set_supportRichText 0x85F164 -> 0x87FB44, get_supportRichText 0x85F148 -> 0x87FB28,
// LetterSpacing.ModifyMesh 0xC3354 -> 0xD2FB8 (unique hit). BaseMeshEffect.m_Graphic @0x20.
static const QcFn kRich[] = {
    { "Text.set_text",                0x87F9D8, 0xa9bd57f6 },
    { "Text.set_supportRichText",     0x87FB44, 0xa9be4ff4 },
    { "Text.get_supportRichText",     0x87FB28, 0xf9405c00 },
    { "LetterSpacing.ModifyMesh",     0x0D2FB8, 0xa9bd57f6 },
};
#define OFF_MESHFX_GRAPHIC 0x20
static void (*o_rich_set_text)(void *, void *, void *);
static void (*o_rich_set_support)(void *, bool, void *);
static bool (*o_rich_get_support)(void *, void *);
static void (*o_letterspacing_modify)(void *, void *, void *);
static void *g_rich_klass[8];             // Text classes seen in set_text (Text + subclasses)
static int g_rich_log = 0;

static bool il2cpp_string_contains(void *s, const char *ascii) {
    if (!looks_like_ptr(s)) return false;
    int32_t len = *(int32_t *)((uint8_t *)s + 0x10);
    const uint16_t *c = (const uint16_t *)((uint8_t *)s + 0x14);
    size_t n = strlen(ascii);
    if (len < (int32_t)n || len > 4096) return false;
    for (int32_t i = 0; i + (int32_t)n <= len; i++) {
        size_t j = 0;
        while (j < n && c[i + j] == (uint16_t)ascii[j]) j++;
        if (j == n) return true;
    }
    return false;
}

static void rich_note_klass(void *text) {
    void *k = *(void **)text;
    for (int i = 0; i < 8; i++) {
        if (g_rich_klass[i] == k) return;
        if (!g_rich_klass[i]) { g_rich_klass[i] = k; return; }
    }
}

static bool rich_is_text(void *obj) {
    if (!looks_like_ptr(obj)) return false;
    void *k = *(void **)obj;
    for (int i = 0; i < 8 && g_rich_klass[i]; i++) if (g_rich_klass[i] == k) return true;
    return false;
}

// v210: Gen 2 has no entries in the game's i18n table, so the label shows the raw key
// ("pokemon_name_0152"). Swap those keys for the real names (152..251).
static const char *const kGen2Names[100] = { "Chikorita", "Bayleef", "Meganium", "Cyndaquil", "Quilava", "Typhlosion", "Totodile", "Croconaw", "Feraligatr", "Sentret", "Furret", "Hoothoot", "Noctowl", "Ledyba", "Ledian", "Spinarak", "Ariados", "Crobat", "Chinchou", "Lanturn", "Pichu", "Cleffa", "Igglybuff", "Togepi", "Togetic", "Natu", "Xatu", "Mareep", "Flaaffy", "Ampharos", "Bellossom", "Marill", "Azumarill", "Sudowoodo", "Politoed", "Hoppip", "Skiploom", "Jumpluff", "Aipom", "Sunkern", "Sunflora", "Yanma", "Wooper", "Quagsire", "Espeon", "Umbreon", "Murkrow", "Slowking", "Misdreavus", "Unown", "Wobbuffet", "Girafarig", "Pineco", "Forretress", "Dunsparce", "Gligar", "Steelix", "Snubbull", "Granbull", "Qwilfish", "Scizor", "Shuckle", "Heracross", "Sneasel", "Teddiursa", "Ursaring", "Slugma", "Magcargo", "Swinub", "Piloswine", "Corsola", "Remoraid", "Octillery", "Delibird", "Mantine", "Skarmory", "Houndour", "Houndoom", "Kingdra", "Phanpy", "Donphan", "Porygon2", "Stantler", "Smeargle", "Tyrogue", "Hitmontop", "Smoochum", "Elekid", "Magby", "Miltank", "Blissey", "Raikou", "Entei", "Suicune", "Larvitar", "Pupitar", "Tyranitar", "Lugia", "Ho-Oh", "Celebi" };
static void *gen2_name_for(void *value) {
    if (!looks_like_ptr(value)) return NULL;
    int32_t len = *(int32_t *)((uint8_t *)value + 0x10);
    if (len != 17) return NULL;                                  // "pokemon_name_0152"
    const uint16_t *c = (const uint16_t *)((uint8_t *)value + 0x14);
    static const char pre[] = "pokemon_name_0";
    for (int i = 0; i < 14; i++) if (c[i] != (uint16_t)pre[i]) return NULL;
    int a = c[14] - '0', b2 = c[15] - '0', d = c[16] - '0';
    if (a < 0 || a > 9 || b2 < 0 || b2 > 9 || d < 0 || d > 9) return NULL;
    int id = 0 * 1000 + a * 100 + b2 * 10 + d;
    if (c[14] == '0' && false) return NULL;
    // the key is "pokemon_name_" + 4 digits; the leading 0 is in the prefix, so id = 3 digits here
    if (id < 152 || id > 251 || !g_qc[QC_STR]) return NULL;
    void *r = ((qc_static1)g_qc[QC_STR])(NULL, (void *)kGen2Names[id - 152], NULL);
    return looks_like_ptr(r) ? r : NULL;
}
static void hk_rich_set_text(void *self, void *value, void *m) {
    if (looks_like_ptr(self)) { void *g2 = gen2_name_for(value); if (g2) value = g2; }
    if (looks_like_ptr(self) && il2cpp_string_contains(value, "<color=")) {
        rich_note_klass(self);
        if (!o_rich_get_support(self, NULL)) {
            o_rich_set_support(self, true, NULL);
            if (g_rich_log++ < 20) WLOG(@"colored names: rich text on for %p", self);
        }
    } else if (looks_like_ptr(self)) {
        rich_note_klass(self);
    }
    o_rich_set_text(self, value, m);
}

static void hk_letterspacing_modify(void *self, void *vh, void *m) {
    void *g = looks_like_ptr(self) ? *(void **)((uint8_t *)self + OFF_MESHFX_GRAPHIC) : NULL;
    if (rich_is_text(g) && o_rich_get_support(g, NULL) &&
        il2cpp_string_contains(*(void **)((uint8_t *)g + OFF_TEXT_STRING), "<color="))
        return;                                  // leave the mesh as Text built it
    o_letterspacing_modify(self, vh, m);
}

static bool install_colored_names(uintptr_t base, const char *version, uintptr_t dstart, size_t dsize) {
    if (strcmp(version, "0.35") != 0) { WLOG(@"colored names: 0.35 only -- off on %s", version); return false; }
    for (const QcFn &f : kRich) {
        uint32_t w = *(uint32_t *)(base + f.rva);
        if (w != f.first) { WLOG(@"colored names: %s first word %08x != %08x -- OFF", f.name, w, f.first); return false; }
    }
    o_rich_set_text        = (void (*)(void *, void *, void *))(base + kRich[0].rva);
    o_rich_set_support     = (void (*)(void *, bool, void *))(base + kRich[1].rva);
    o_rich_get_support     = (bool (*)(void *, void *))(base + kRich[2].rva);
    o_letterspacing_modify = (void (*)(void *, void *, void *))(base + kRich[3].rva);
    if (!redirect_method_pointer(dstart, dsize, base + kRich[0].rva, (uintptr_t)&hk_rich_set_text, "Text.set_text"))
        return false;
    redirect_method_pointer(dstart, dsize, base + kRich[3].rva, (uintptr_t)&hk_letterspacing_modify,
                            "LetterSpacing.ModifyMesh");
    WLOG(@"colored names: armed");
    return true;
}

// ----------------------------------------------------------------- plain login (v156)
// Signing in is an email and password made on the Windstock website, so the two screens in
// front of the login form are noise: the date-of-birth picker and the "Google" button.
//   * LoginAgeGateState.EnterState (virtual, slot 11) is redirected. The original builds the
//     picker (guiFactory.Create + InitializeDropdowns); ours runs only the base
//     GameState.EnterState and then, between frames, calls LoginState.AgeGateSubmitted(30)
//     -- exactly what the Submit button ends in. ExitState checks guiController for null
//     before destroying it, so never building the picker is safe.
//   * LoginChoiceGuiController.Start is redirected. The original shows each provider button
//     the country's rules allow; afterwards ours switches the Google one off, leaving only
//     the Pokemon Trainer Club button -- which is the Windstock login.
// RVAs: 0.29 from the dump, 0.35 by masked matching (tools/port_rva.py) and read from the
// disassembly of Start (get_gameObject / SetActive are its two calls in the button loop).
struct LoginRvas {
    const char *version;
    uintptr_t age_enter, state_enter, age_submitted, choice_start, get_go, set_active;
    uint32_t choice_word;                 // Start+0x40: ldr x0, [x20, #loginState]
    int off_buttons;                      // LoginChoiceGuiController.authProviderButtons
};
static const LoginRvas kLogin[] = {
    { "0.35", 0x07A9D8, 0x2404F8, 0x07AD2C, 0x07ADE4, 0x892004, 0x89B850, 0xf9404a80, 0xA0 },
    { "0.29", 0x25D204, 0x231458, 0x076C98, 0x25D560, 0x87080C, 0x87A080, 0xf9403e80, 0x88 },
};
#define OFF_AGEGATE_LOGINSTATE 0x48       // LoginAgeGateState.loginState (both builds)
#define OFF_UNITY_CACHED_PTR   0x10       // UnityEngine.Object.m_CachedPtr: 0 once destroyed
#define AUTH_PROVIDER_GOOGLE   1
#define LOGIN_AGE              30         // any adult age: every country's rule lets it through
static void (*o_state_enter)(void *, void *);
static void (*o_age_submitted)(void *, int32_t, void *);
static void (*o_choice_start)(void *, void *);
static void *(*o_login_get_go)(void *, void *);
static void (*o_login_set_active)(void *, bool, void *);
static int g_login_off_buttons = 0;

static void hk_agegate_enter(void *self, void *m) {
    o_state_enter(self, NULL);
    void *login = looks_like_ptr(self) ? *(void **)((uint8_t *)self + OFF_AGEGATE_LOGINSTATE) : NULL;
    if (!looks_like_ptr(login)) { WLOG(@"plain login: age gate has no LoginState -- left as is"); return; }
    // not from inside EnterState: answering changes the state, like a tap on Submit would
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!*(void **)((uint8_t *)login + OFF_UNITY_CACHED_PTR)) return;      // scene went away
        WLOG(@"plain login: age gate answered");
        o_age_submitted(login, LOGIN_AGE, NULL);
    });
}

static void hk_choice_start(void *self, void *m) {
    o_choice_start(self, m);
    void *arr = looks_like_ptr(self) ? *(void **)((uint8_t *)self + g_login_off_buttons) : NULL;
    if (!looks_like_ptr(arr)) return;
    // AuthProviderButton[]: length @0x18, then { RectTransform ButtonRoot; int ButtonProvider } x n
    int32_t n = *(int32_t *)((uint8_t *)arr + 0x18);
    for (int32_t i = 0; i < n && i < 8; i++) {
        uint8_t *e = (uint8_t *)arr + 0x20 + 16 * i;
        void *root = *(void **)e;
        if (*(int32_t *)(e + 8) != AUTH_PROVIDER_GOOGLE || !looks_like_ptr(root)) continue;
        void *go = o_login_get_go(root, NULL);
        if (!looks_like_ptr(go)) continue;
        o_login_set_active(go, false, NULL);
        WLOG(@"plain login: Google button hidden");
    }
}

static bool install_plain_login(uintptr_t base, const char *version, uintptr_t dstart, size_t dsize) {
    const LoginRvas *t = NULL;
    for (const LoginRvas &c : kLogin) if (strcmp(c.version, version) == 0) t = &c;
    if (!t) return false;
    struct { const char *name; uintptr_t at; uint32_t word; } checks[] = {
        { "LoginAgeGateState.EnterState",       t->age_enter,            0xa9be4ff4 },
        { "LoginAgeGateState.EnterState+0x30",  t->age_enter + 0x30,     0xf9003a60 },   // str x0, [x19, #0x70]
        { "GameState.EnterState",               t->state_enter,          0x320003e8 },
        { "LoginState.AgeGateSubmitted",        t->age_submitted,        0xa9bd57f6 },
        { "LoginState.AgeGateSubmitted+0x54",   t->age_submitted + 0x54, 0x3902e268 },   // strb w8, [x19, #0xb8]
        { "LoginChoiceGuiController.Start",     t->choice_start,         0xa9bb67fa },
        { "LoginChoiceGuiController.Start+0x40", t->choice_start + 0x40, t->choice_word },
        { "Component.get_gameObject",           t->get_go,               0xa9be4ff4 },
        { "GameObject.SetActive",               t->set_active,           0xa9bd57f6 },
    };
    for (auto &c : checks) {
        uint32_t w = *(uint32_t *)(base + c.at);
        if (w != c.word) { WLOG(@"plain login: %s word %08x != %08x -- OFF", c.name, w, c.word); return false; }
    }
    o_state_enter      = (void (*)(void *, void *))(base + t->state_enter);
    o_age_submitted    = (void (*)(void *, int32_t, void *))(base + t->age_submitted);
    o_choice_start     = (void (*)(void *, void *))(base + t->choice_start);
    o_login_get_go     = (void *(*)(void *, void *))(base + t->get_go);
    o_login_set_active = (void (*)(void *, bool, void *))(base + t->set_active);
    g_login_off_buttons = t->off_buttons;
    bool age = redirect_method_pointer(dstart, dsize, base + t->age_enter, (uintptr_t)&hk_agegate_enter,
                                       "LoginAgeGateState.EnterState");
    bool google = redirect_method_pointer(dstart, dsize, base + t->choice_start, (uintptr_t)&hk_choice_start,
                                          "LoginChoiceGuiController.Start");
    WLOG(@"plain login: age gate %@, Google button %@", age ? @"skipped" : @"left", google ? @"hidden" : @"left");
    return age || google;
}

#define WS_TWEAK_VERSION 210
#include "Research.inc.mm"

__attribute__((constructor))
static void init(void) {
    WLOG(@"---- windstock tweak v%d loaded (no-JIT, images=%u) ----", WS_TWEAK_VERSION, _dyld_image_count());
    install_crash_reporter();
    if (ws_mod(@"fps60", true)) install_60fps();
    install_in_app_links();
    const struct mach_header_64 *mh = guest_header();
    if (!mh) { WLOG(@"guest image not found -- nothing redirected"); return; }
    uintptr_t base = (uintptr_t)mh;

    const Rvas *t = NULL;
    for (const Rvas &c : kTables) {
        uintptr_t a[5] = { c.play, c.stopall, c.pause, c.unpause, c.get_name };
        bool ok = true;
        for (int i = 0; i < 5 && ok; i++) ok = *(uint32_t *)(base + a[i]) == kPrologue[i];
        if (ok) { t = &c; break; }
    }
    if (!t) {
        WLOG(@"unknown client build -- nothing redirected. PlayMusic words: 0.35=%08x 0.29=%08x",
             *(uint32_t *)(base + kTables[0].play), *(uint32_t *)(base + kTables[1].play));
        return;
    }
    WLOG(@"client %s detected", t->version);

    if (ws_mod(@"water", true) && strcmp(t->version, "0.35") == 0) install_water(base);   // v113

    uintptr_t dstart = 0; size_t dsize = 0;
    if (!guest_data_range(mh, &dstart, &dsize)) { WLOG(@"guest __DATA not found -- nothing redirected"); return; }
    WLOG(@"guest __DATA %p (+0x%zx)", (void *)dstart, dsize);

    if (ws_mod(@"colored_names", true)) install_colored_names(base, t->version, dstart, dsize);   // v118
    if (ws_mod(@"plain_login", true)) install_plain_login(base, t->version, dstart, dsize);       // v156

    g_get_name = (void *(*)(void *, void *))(base + t->get_name);
    o_play    = (void (*)(void *, void *, void *))(base + t->play);
    o_stopall = (void (*)(void *, void *))(base + t->stopall);
    o_pause   = (void (*)(void *, void *))(base + t->pause);
    o_unpause = (void (*)(void *, void *))(base + t->unpause);

    // PlayMusic drives everything; the other three only keep state tidy. If PlayMusic can't
    // be redirected (e.g. a second loaded copy already did it), redirect nothing else either.
    if (!redirect_method_pointer(dstart, dsize, base + t->play, (uintptr_t)&hk_play, "PlayMusic")) return;
    redirect_method_pointer(dstart, dsize, base + t->stopall, (uintptr_t)&hk_stopall, "StopAll");
    redirect_method_pointer(dstart, dsize, base + t->pause,   (uintptr_t)&hk_pause,   "Pause");
    redirect_method_pointer(dstart, dsize, base + t->unpause, (uintptr_t)&hk_unpause, "Unpause");

#if QUICK_CATCH
    // v161: the call table is shared (weather, shinies, research...), so it is always set up;
    // the Quick Catch switch only decides whether the Run button gets pinned
    bool qc_ok = install_quick_catch(base, t->version);
    bool qc_on = qc_ok && ws_mod(@"quick_catch", true);
#else
    bool qc_ok = false, qc_on = false;
#endif
#if MASS_TRANSFER
    g_mt_ready = ws_mod(@"mass_transfer", true) &&
                 install_mass_transfer(base, t->version, qc_ok, dstart, dsize);
#endif
#if IV_DISPLAY
    // shares the mass-transfer call table (storage lookup, rows, GetComponent)
    bool iv_ok = ws_mod(@"iv_display", true) && g_mt_ready && install_iv_display(base);
#else
    bool iv_ok = false;
#endif
#if APPRAISAL_IVS
    // needs the quick-catch table (strings, types, FindObjectOfType) -- 0.35 only
    if (ws_mod(@"appraisal_ivs", true) && qc_ok && g_mt_ready)
        install_appraisal_ivs(base, dstart, dsize);
#endif
#if SOUND_PACKS
    // v123: Back to Launcher in Settings -- needs quick catch's lookups and mass transfer's GetComponent
    bool ls_ok = ws_mod(@"launcher_button", true) && qc_ok && g_mt_ready &&
                 strcmp(t->version, "0.35") == 0 && install_launcher_row(base, dstart, dsize);
    // v166: Keep Ball row in Settings + carrying the ball over -- same lookups as the launcher row
    bool kb_ok = ws_mod(@"keep_ball", true) && qc_ok && g_mt_ready &&
                 strcmp(t->version, "0.35") == 0 && install_keep_ball(base, dstart, dsize);
    bool sp_ok = ws_mod(@"sound_packs", true) && strcmp(t->version, "0.35") == 0 &&
                 install_sound_packs(base, dstart, dsize);
#else
    bool sp_ok = false;
#endif
    // v110: the Shiny Incense (bag item 402) actually burns -- see install_shiny_incense
    bool si_ok = ws_mod(@"shiny", true) && strcmp(t->version, "0.35") == 0 && qc_ok && g_mt_ready &&
                 install_shiny_incense(base, dstart, dsize);
    // v133: an event XP bonus shows as a W buff -- reads /shiny/state (the shiny poll)
    if (ws_mod(@"xp_bonus", true) && ws_mod(@"shiny", true) && strcmp(t->version, "0.35") == 0 &&
        qc_ok && g_mt_ready)
        install_xp_bonus(base, dstart, dsize);
#if SHINY
    // needs quick catch (string + object lookup); appraisal's panel lookup is optional
    bool shiny_ok = ws_mod(@"shiny", true) && qc_ok && g_mt_ready &&
                    strcmp(t->version, "0.35") == 0 && install_shinies(base, dstart, dsize);
#else
    bool shiny_ok = false;
#endif
#if RAIDS
    // needs quick catch (type lookup) and mass transfer (bag lookup for the team swap)
    bool raid_ok = ws_mod(@"raids", true) && qc_ok && g_mt_ready &&
                   install_raids(base, dstart, dsize);
#else
    bool raid_ok = false;
#endif
#if RESEARCH
    // needs quick catch (component/GameObject lookups) and mass transfer (type lookup, FindObjectsOfType)
    bool rs_ok = ws_mod(@"research", true) && qc_ok && g_mt_ready &&
                 strcmp(t->version, "0.35") == 0 && install_research(base, dstart, dsize);
#else
    bool rs_ok = false;
#endif
    dispatch_async(dispatch_get_main_queue(), ^{
        if (si_ok)   // blue smoke while a Shiny Incense burns
            ws_timer(0.5, YES, ^(NSTimer *timer) { shiny_incense_tick(); });
#if SHINY
        if (shiny_ok) {
            shiny_poll();
            ws_timer(5.0, YES, ^(NSTimer *timer) { shiny_poll(); });
            ws_timer(0.3, YES, ^(NSTimer *timer) { shiny_tick(); });
            if (g_mt_ready && (g_iv_set_text || install_iv_display(base)))   // storage sparkle labels
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{ ws_timer(0.1, YES, ^(NSTimer *timer) { shiny_storage_tick(); });
                  ws_timer(1.0 / 30.0, YES, ^(NSTimer *timer) { shiny_storage_frame(); }); });
            ws_timer(1.0 / 60.0, YES, ^(NSTimer *timer) { shiny_frame(); });
        }
#endif
#if WEATHER
        g_wx_scene_ok = ws_mod(@"weather", true) && install_weather_scene(base, t->version);
        if (g_wx_scene_ok) install_map_fogdist(base, dstart, dsize);   // v149
        g_r3_fn_ok = qc_ok && install_rain3d(base, t->version);
        bool tint_mod = ws_mod(@"weather_tint", true);
        if (ws_mod(@"halloween_look", true) || tint_mod) install_halloween_look(base, dstart, dsize, t->version);   // v157
        g_tint_ok = tint_mod && g_mt_ready && install_weather_tint(base, t->version);   // v200
        if (g_tint_ok) ws_timer(0.2, YES, ^(NSTimer *timer) { tint_tick(); });
        g_r3_ok = g_wx_scene_ok && g_r3_fn_ok && ws_mod(@"weather_rain3d", true);
        if (g_r3_fn_ok && ws_mod(@"gps_camera_steer", true))   // v175: GPS joystick follows the camera
            ws_timer(0.1, YES, ^(NSTimer *timer) { cam_yaw_tick(); });
        // weather: fetch now-ish and every minute; effects follow the map music every second
        // v203: the kept weather now, the server's straight away, every 5 s until it knows, then every minute
        wx_cache_load();
        weather_poll();
        ws_timer(5, YES, ^(NSTimer *timer) { if (!g_wx_live) weather_poll(); });
        ws_timer(60, YES, ^(NSTimer *timer) { if (g_wx_live) weather_poll(); });
        ws_timer(1.0, YES, ^(NSTimer *timer) { weather_tick(); });
        ws_timer(1.0 / 60.0, YES, ^(NSTimer *timer) { weather_frame(); });
#endif
        if (rs_ok)     // binoculars button on the map + the Research screens
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
                ws_timer(0.1, YES, ^(NSTimer *timer) { rs_tick(); }); });   // v105: 0.1 s, follows Nearby
        if (raid_ok)   // gym screen check + lobby poll, between frames on the main thread
            ws_timer(0.5, YES, ^(NSTimer *timer) { raid_tick(); });
        if (ls_ok || kb_ok)   // Settings' Back to Launcher / Keep Ball rows: added whenever a Settings screen appears
            ws_timer(0.25, YES, ^(NSTimer *timer) { ls_tick(); });
        if (kb_ok)   // follow the ball in use; put it back when the next encounter starts
            ws_timer(0.1, YES, ^(NSTimer *timer) { kb_tick(); });
        if (sp_ok)   // the SFX icall slots fill soon after launch; keep trying until all three are swapped
            ws_timer(0.5, YES, ^(NSTimer *timer) { sound_packs_tick(base); });
        // quick catch polls on the main thread (Unity's thread on iOS), between frames
        if (qc_on)
            ws_timer(0.5, YES, ^(NSTimer *timer) { quick_catch_tick(); });
        if (g_mt_ready) {
            // the Unity view appears after launch: keep (re)attaching the long-press to it
            ws_timer(2.0, YES, ^(NSTimer *timer) { mt_install_gesture(); });
            ws_timer(0.25, YES, ^(NSTimer *timer) { mt_refresh_rows(); });
            ws_timer(0.4, YES, ^(NSTimer *timer) { mt_release_next(); });
        }
        if (iv_ok)
            ws_timer(0.25, YES, ^(NSTimer *timer) { iv_refresh_rows(); });
        // catch 6:59 -> 7:00 PM (and 5:59 -> 6:00 AM) while the map is already playing
        ws_timer(30, YES, ^(NSTimer *timer) { refresh(); });
        // heartbeat: if the log stops without a CRASH block, the process was SIGKILLed
        ws_timer(10, YES, ^(NSTimer *timer) {
            WLOG(@"alive (map_active=%d night=%d)", g_map_active, is_night_now());
        });
        // Settings > Music toggle: react as soon as the pref flips (checked every second -- one
        // NSUserDefaults read -- since PlayerPrefs writes don't always post a change notification).
        ws_timer(1.0, YES, ^(NSTimer *timer) {
            static int last = -1;
            int now = game_pref_enabled(PREF_MUSIC_ENABLED);
            if (now != last) {
                WLOG(@"music: Settings music %@ (pref value %@)", now ? @"on" : @"off",
                     [[NSUserDefaults standardUserDefaults] objectForKey:PREF_MUSIC_ENABLED] ?: @"unset");
                last = now;
                refresh();
            }
        });
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { g_inactive = true; [g_player pause]; }];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *n) { g_inactive = false; refresh(); }];
        // posted by the launcher (WSGuestLoader) -- by name, we don't link against it
        [nc addObserverForName:@"WSLauncherShown" object:nil queue:nil
                    usingBlock:^(NSNotification *n) { g_in_launcher = true; [g_player pause]; }];
        [nc addObserverForName:@"WSGuestResumed" object:nil queue:nil
                    usingBlock:^(NSNotification *n) { g_in_launcher = false; refresh(); }];
    });
    WLOG(@"night music ready (%02d:00-%02d:00)", NIGHT_START_HOUR, NIGHT_END_HOUR);
}
