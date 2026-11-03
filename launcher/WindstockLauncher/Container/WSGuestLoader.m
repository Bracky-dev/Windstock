#import "WSGuestLoader.h"
#import "WSPaths.h"
#import "WSContainer.h"
#import "WSLog.h"
#import "fishhook.h"

#import <UIKit/UIKit.h>
@protocol WSWindowProviding <NSObject>
- (UIWindow *)window;
- (void)setWindow:(UIWindow *)window;
@end

#import <objc/message.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <string.h>

NSString *const WSGuestLoaderErrorDomain = @"com.windstock.launcher.guest";
NSNotificationName const WSGuestLoaderReturnToLauncherRequest = @"WSReturnToLauncher";
NSNotificationName const WSGuestLoaderDidShowLauncher = @"WSLauncherShown";
NSNotificationName const WSGuestLoaderDidResumeGuest = @"WSGuestResumed";

static BOOL gLaunched = NO;
static NSArray<NSString *> *gInjected = nil;
static NSBundle *gGuestBundle = nil;

#pragma mark - NSBundle.mainBundle swizzle

// Unity asks NSBundle.mainBundle for bundlePath and builds ".../Data" from it,
// and the il2cpp resource loader does the same. Swizzling the class method is
// enough for the 0.35 client; we install it immediately before loading the
// guest so the launcher's own UI keeps seeing the real bundle.
@interface NSBundle (WSGuest)
@end

@implementation NSBundle (WSGuest)
+ (NSBundle *)ws_mainBundle {
    return gGuestBundle ?: [self ws_mainBundle];
}
@end

static void ws_swizzle_main_bundle(void) {
    Class meta = object_getClass([NSBundle class]);
    Method orig = class_getClassMethod([NSBundle class], @selector(mainBundle));
    Method repl = class_getClassMethod([NSBundle class], @selector(ws_mainBundle));
    if (!orig || !repl) {
        WSLog(@"guest", @"could not find mainBundle methods to swizzle");
        return;
    }
    method_exchangeImplementations(orig, repl);
    (void)meta;
}

#pragma mark - UIApplicationMain interception

static int (*ws_orig_UIApplicationMain)(int, char *[], NSString *, NSString *);

// The guest calls UIApplicationMain from its own main(). We have already called
// it once for the launcher's UI, and calling it twice in one process is not
// allowed -- so we adopt the guest's delegate onto the running UIApplication
// instead, drive the launch callbacks by hand, and then park so the guest's
// main() never returns.
//
// Parking is not optional, though it looks like it should be. Unity's main is
//
//     int main(...) { @autoreleasepool { UIApplicationMain(...); } return 0; }
//
// so returning drains an autorelease pool that normally lives for as long as
// the app does, and Unity crashes in its deferred startUnity: a moment later
// with EXC_BAD_ACCESS. Measured on device, not guessed. The cost is a run
// loop nested inside UIKit's own, which is a suspect for text input problems
// -- but a game that runs beats a game that crashes.
// Everything the guest made a window for, put on the launcher's scene and
// bring to the front; everything the launcher made, take off the scene.
//
// UnityAppController builds its UIWindow with -initWithFrame: and calls
// makeKeyAndVisible, which on iOS 13+ shows nothing at all while windowScene
// is nil -- a black screen over a perfectly healthy app. It also does not
// necessarily build that window during didFinishLaunching, so adopting once
// is not enough: this runs again on a timer for a few seconds and picks up
// whatever appears.
static NSArray<UIWindow *> *gLauncherWindows;
static UIWindow *gLauncherMainWindow;     // the SwiftUI window, to bring back
static UIWindowScene *gScene;
static id gGuestDelegate;
// While the launcher is back on screen the guest's windows are hidden, and the
// adoption pass must not "rescue" them or hide the launcher again.
static BOOL gShowingLauncher = NO;
static NSArray<UIWindow *> *gGuestWindows;

// Clock and battery stay on screen in the launcher and in the game. Info.plist
// leaves the bar visible with view-controller-based appearance off, which makes
// UIApplication's setter the one that counts -- and Unity calls it to hide the
// bar as it starts. So the setter only ever shows it.
static void (*ws_orig_setStatusBarHidden)(id, SEL, BOOL, UIStatusBarAnimation);
static void (*ws_orig_setStatusBarHiddenPlain)(id, SEL, BOOL);

static void ws_setStatusBarHidden(id self, SEL _cmd, BOOL hidden, UIStatusBarAnimation anim) {
    ws_orig_setStatusBarHidden(self, _cmd, NO, anim);
}

static void ws_setStatusBarHiddenPlain(id self, SEL _cmd, BOOL hidden) {
    ws_orig_setStatusBarHiddenPlain(self, _cmd, NO);
}

static void ws_keep_status_bar(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        Class cls = UIApplication.class;
        Method m = class_getInstanceMethod(cls, @selector(setStatusBarHidden:withAnimation:));
        if (m) ws_orig_setStatusBarHidden = (void *)method_setImplementation(m, (IMP)ws_setStatusBarHidden);
        m = class_getInstanceMethod(cls, @selector(setStatusBarHidden:));
        if (m) ws_orig_setStatusBarHiddenPlain = (void *)method_setImplementation(m, (IMP)ws_setStatusBarHiddenPlain);
    });
    if (ws_orig_setStatusBarHidden)
        ws_orig_setStatusBarHidden(UIApplication.sharedApplication,
                                   @selector(setStatusBarHidden:withAnimation:),
                                   NO, UIStatusBarAnimationNone);
}

static void ws_adopt_guest_windows(void) {
    if (gShowingLauncher) return;
    UIApplication *app = UIApplication.sharedApplication;
    NSUInteger adopted = 0;

    // -[UIApplication windows] and not scene.windows, deprecation and all: a
    // window whose windowScene is nil -- which is exactly the kind the guest
    // makes, and the only kind we need to find -- does not appear in any
    // scene's list.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *windows = [app.windows copy];
#pragma clang diagnostic pop

    for (UIWindow *window in windows) {
        if ([gLauncherWindows containsObject:window]) {
            // Hiding is not enough; while it is still on the scene it can
            // stay the key window and keep the guest's window off screen.
            window.hidden = YES;
            if (window.windowScene) window.windowScene = nil;
            continue;
        }
        // Only touch a window that still needs adopting. Calling
        // makeKeyAndVisible on every pass makes the screen flash at the timer
        // interval and, worse, snatches key status back from whatever the
        // player just tapped -- so a text field can never keep focus.
        if (!window.windowScene && gScene) {
            window.windowScene = gScene;
            window.hidden = NO;
            [window makeKeyAndVisible];
            adopted++;
        }
    }

    id delegate = app.delegate;
    if ([delegate respondsToSelector:@selector(window)]) {
        UIWindow *window = [delegate performSelector:@selector(window)];
        if (window && !window.windowScene && gScene) {
            window.windowScene = gScene;
            adopted++;
            window.hidden = NO;
            [window makeKeyAndVisible];
        }
    }

    // The scene delegate's own `window` property is how UIKit answers some
    // questions about which window a scene owns. Leaving it pointing at the
    // launcher's detached window is a good way to have a key window that
    // nothing can become first responder in.
    if (adopted && gScene) {
        id sceneDelegate = gScene.delegate;
        UIWindow *guestWindow = nil;
        for (UIWindow *window in windows) {
            if (![gLauncherWindows containsObject:window] && window.windowScene == gScene) {
                guestWindow = window;
                break;
            }
        }
        if (guestWindow && [sceneDelegate respondsToSelector:@selector(setWindow:)]) {
            [(id<WSWindowProviding>)sceneDelegate setWindow:guestWindow];
            WSLog(@"guest", @"scene delegate now points at the guest window");
        }
    }

    if (adopted) {
        WSLog(@"guest", @"adopted %lu guest window(s) onto the launcher's scene",
              (unsigned long)adopted);
    }
}

// Who has the screen, and can anything take the keyboard?
static void ws_log_responder_state(void) {
    UIApplication *app = UIApplication.sharedApplication;
    UIWindow *key = nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    NSArray<UIWindow *> *windows = app.windows;
#pragma clang diagnostic pop
    for (UIWindow *window in windows) {
        if (window.isKeyWindow) { key = window; break; }
    }
    WSLog(@"guest", @"windows=%lu key=%@ scene=%@ root=%@",
          (unsigned long)windows.count,
          key ? NSStringFromClass(key.class) : @"(none)",
          key.windowScene ? @"yes" : @"no",
          key.rootViewController ? NSStringFromClass(key.rootViewController.class) : @"(none)");
    for (UIScene *scene in app.connectedScenes) {
        WSLog(@"guest", @"scene %@ state=%ld", scene.session.persistentIdentifier,
              (long)scene.activationState);
    }
}

#pragma mark - back to the launcher and into the game again

static void ws_guest_send(SEL sel) {
    if (![gGuestDelegate respondsToSelector:sel]) return;
    ((void (*)(id, SEL, UIApplication *))objc_msgSend)(
        gGuestDelegate, sel, UIApplication.sharedApplication);
}

static void ws_point_scene_at(UIWindow *window) {
    id sceneDelegate = gScene.delegate;
    if (window && [sceneDelegate respondsToSelector:@selector(setWindow:)]) {
        [(id<WSWindowProviding>)sceneDelegate setWindow:window];
    }
}

// Newer UnityAppControllers only unpause in applicationDidBecomeActive: when
// the pause was not "external"; an OS pause while we had it paused would mark
// it so and the game would stay frozen. The 0.35 build has no such ivar and
// unpauses unconditionally, so this is a no-op there.
static void ws_clear_external_pause(void) {
    Ivar ivar = class_getInstanceVariable([gGuestDelegate class], "_wasPausedExternal");
    if (!ivar) return;
    ptrdiff_t offset = ivar_getOffset(ivar);
    *((BOOL *)((uint8_t *)(__bridge void *)gGuestDelegate + offset)) = NO;
}

static void ws_observe_launcher_switch(void) {
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:WSGuestLoaderReturnToLauncherRequest object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        // Out of the tweak's button handler first: the window that owns the
        // button is about to be hidden under it.
        [NSTimer scheduledTimerWithTimeInterval:0.01 repeats:NO block:^(NSTimer *t) {
            [WSGuestLoader returnToLauncher];
        }];
    }];
    // The guest is the application delegate, so it hears the real lifecycle
    // too: lock the phone while the launcher is showing and on unlock Unity
    // unpauses itself behind our back. The notification comes after the
    // delegate call, so pausing it again here wins.
    [nc addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                usingBlock:^(NSNotification *note) {
        if (gShowingLauncher) ws_guest_send(@selector(applicationWillResignActive:));
    }];
}

static int ws_UIApplicationMain(int argc, char *argv[],
                                NSString *principalClassName,
                                NSString *delegateClassName) {
    WSLog(@"guest", @"UIApplicationMain intercepted (principal=%@ delegate=%@)",
          principalClassName ?: @"(nil)", delegateClassName ?: @"(nil)");

    UIApplication *app = UIApplication.sharedApplication;
    Class delegateClass = delegateClassName.length ? NSClassFromString(delegateClassName) : Nil;
    if (!delegateClass) {
        WSLog(@"guest", @"delegate class %@ not found -- falling back to the real "
                        @"UIApplicationMain, which will almost certainly abort",
              delegateClassName);
        return ws_orig_UIApplicationMain(argc, argv, principalClassName, delegateClassName);
    }

    id delegate = [[delegateClass alloc] init];
    // Keep it alive for the life of the process; UIApplication's delegate is weak.
    CFRetain((__bridge CFTypeRef)delegate);
    app.delegate = delegate;
    gGuestDelegate = delegate;
    ws_keep_status_bar();

    // The scene the launcher's own window is on. The guest will make a window
    // without one and expect it to appear, which on a scene-based system it
    // will not -- so keep a handle on the scene to graft its window onto.
    for (UIScene *candidate in app.connectedScenes) {
        if ([candidate isKindOfClass:UIWindowScene.class]) {
            gScene = (UIWindowScene *)candidate;
            break;
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    gLauncherWindows = [app.windows copy];
#pragma clang diagnostic pop
    if ([gScene.delegate respondsToSelector:@selector(window)]) {
        gLauncherMainWindow = [(id<WSWindowProviding>)gScene.delegate window];
    }
    ws_observe_launcher_switch();

    SEL willFinish = @selector(application:willFinishLaunchingWithOptions:);
    if ([delegate respondsToSelector:willFinish]) {
        ((BOOL (*)(id, SEL, UIApplication *, NSDictionary *))objc_msgSend)(
            delegate, willFinish, app, @{});
    }
    SEL didFinish = @selector(application:didFinishLaunchingWithOptions:);
    if ([delegate respondsToSelector:didFinish]) {
        ((BOOL (*)(id, SEL, UIApplication *, NSDictionary *))objc_msgSend)(
            delegate, didFinish, app, @{});
    }
    SEL didBecomeActive = @selector(applicationDidBecomeActive:);
    if ([delegate respondsToSelector:didBecomeActive]) {
        ((void (*)(id, SEL, UIApplication *))objc_msgSend)(delegate, didBecomeActive, app);
    }

    ws_adopt_guest_windows();

    // Unity can create or replace its window well after launch, so keep
    // looking for a while rather than assuming one pass caught it.
    // Unity can create its window after launch, so keep looking -- but only
    // for windows that have no scene yet, and give up once the guest has one.
    __block int ticks = 0;
    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES
                                      block:^(NSTimer *timer) {
        ws_adopt_guest_windows();
        if (++ticks >= 20) [timer invalidate];      // 10 seconds
    }];

    // A moment later, once UIKit has settled, report who actually owns the
    // screen and the keyboard. Cheap, and it is the first thing worth knowing
    // if input misbehaves.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        ws_log_responder_state();
    });

    WSLog(@"guest", @"delegate installed; parking on the run loop");
    CFRunLoopRun();
    return 0;
}

#pragma mark - image lookup

static const struct mach_header_64 *ws_find_image(const char *suffix, intptr_t *slideOut) {
    size_t want = strlen(suffix);
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        size_t len = strlen(name);
        if (len >= want && strcmp(name + len - want, suffix) == 0) {
            if (slideOut) *slideOut = _dyld_get_image_vmaddr_slide(i);
            return (const struct mach_header_64 *)_dyld_get_image_header(i);
        }
    }
    return NULL;
}

// The entry point survives the exec->dylib conversion as LC_MAIN's entryoff,
// which is a file offset from the start of the Mach-O header.
static void *ws_entry_point(const struct mach_header_64 *mh, intptr_t slide) {
    uintptr_t cur = (uintptr_t)mh + sizeof(struct mach_header_64);
    for (uint32_t i = 0; i < mh->ncmds; i++) {
        struct load_command *lc = (struct load_command *)cur;
        if (lc->cmd == LC_MAIN) {
            struct entry_point_command *ep = (struct entry_point_command *)lc;
            return (void *)((uintptr_t)mh + (uintptr_t)ep->entryoff);
        }
        cur += lc->cmdsize;
    }
    (void)slide;
    return NULL;
}

#pragma mark -

@implementation WSGuestLoader

+ (BOOL)hasLaunched { return gLaunched; }

+ (BOOL)isShowingLauncher { return gShowingLauncher; }

+ (void)returnToLauncher {
    if (!gLaunched || gShowingLauncher || !gLauncherMainWindow) return;
    WSLog(@"guest", @"back to the launcher -- pausing the game");
    // Unity's own background path: UnityPause(1), audio off, OnApplicationPause.
    ws_guest_send(@selector(applicationWillResignActive:));
    gShowingLauncher = YES;

    UIApplication *app = UIApplication.sharedApplication;
    NSMutableArray<UIWindow *> *hidden = [NSMutableArray array];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    for (UIWindow *window in app.windows) {
#pragma clang diagnostic pop
        if ([gLauncherWindows containsObject:window] || window.hidden) continue;
        if (window.windowScene != gScene) continue;
        // The key window first, so it is the one made key again on the way back.
        if (window.isKeyWindow) [hidden insertObject:window atIndex:0];
        else [hidden addObject:window];
        window.hidden = YES;
    }
    gGuestWindows = hidden;

    gLauncherMainWindow.windowScene = gScene;
    gLauncherMainWindow.hidden = NO;
    [gLauncherMainWindow makeKeyAndVisible];
    ws_point_scene_at(gLauncherMainWindow);
    [NSNotificationCenter.defaultCenter postNotificationName:WSGuestLoaderDidShowLauncher
                                                      object:nil];
}

+ (void)resumeGuest {
    if (!gShowingLauncher) return;
    WSLog(@"guest", @"back into the game (%lu window(s))", (unsigned long)gGuestWindows.count);
    // Detached, not just hidden -- see ws_adopt_guest_windows.
    gLauncherMainWindow.hidden = YES;
    gLauncherMainWindow.windowScene = nil;
    for (UIWindow *window in gGuestWindows) window.hidden = NO;
    UIWindow *main = gGuestWindows.firstObject;
    [main makeKeyAndVisible];
    ws_point_scene_at(main);
    gGuestWindows = nil;
    gShowingLauncher = NO;

    ws_clear_external_pause();
    ws_guest_send(@selector(applicationDidBecomeActive:));
    [NSNotificationCenter.defaultCenter postNotificationName:WSGuestLoaderDidResumeGuest
                                                      object:nil];
}

+ (void)setInjectedDylibs:(NSArray<NSString *> *)paths {
    gInjected = [paths copy];
}

+ (BOOL)launchWithError:(NSError **)error {
    NSString *exe = WSPaths.guestExecutablePath;
    if (!exe) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorNoExecutable
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"No game is embedded in this build and none "
                                                @"has been imported."}];
        return NO;
    }
    NSString *bundlePath = WSPaths.guestBundlePath;
    if (!bundlePath) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorNoBundle
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"No Guest/game resource bundle in the launcher."}];
        return NO;
    }
    return [self launchExecutable:exe bundlePath:bundlePath error:error];
}

+ (BOOL)launchExecutable:(NSString *)exe
              bundlePath:(NSString *)bundlePath
                   error:(NSError **)error {
    if (gLaunched) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorAlreadyLaunched
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"The game has already been launched in this process."}];
        return NO;
    }

    if (![NSFileManager.defaultManager fileExistsAtPath:exe]) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorNoExecutable
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                    @"No executable at %@", exe]}];
        return NO;
    }

    gGuestBundle = [NSBundle bundleWithPath:bundlePath];
    WSLog(@"guest", @"bundle %@", bundlePath);
    WSLog(@"guest", @"home   %s", WSContainerCurrentHome() ?: "(not redirected)");
    ws_swizzle_main_bundle();

    void *handle = dlopen(exe.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
    if (!handle) {
        NSString *why = @(dlerror() ?: "unknown");
        WSLog(@"guest", @"dlopen failed: %@", why);
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorDlopenFailed
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:@"dlopen(%@) failed: %@",
                                                 exe.lastPathComponent, why]}];
        return NO;
    }

    intptr_t slide = 0;
    NSString *suffix = [@"/" stringByAppendingString:exe.lastPathComponent];
    const struct mach_header_64 *mh = ws_find_image(suffix.UTF8String, &slide);
    if (!mh) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorNoImage
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                [NSString stringWithFormat:
                                                    @"The guest loaded but no image path ends in %@",
                                                    suffix]}];
        return NO;
    }
    WSLog(@"guest", @"image @ %p slide 0x%lx", mh, (unsigned long)slide);

    // Rebind inside the guest image only, so the launcher's own code keeps the
    // real UIApplicationMain and the real resolver.
    // Only in the guest image: the launcher's own code must keep the real
    // UIApplicationMain, which it already called.
    ws_orig_UIApplicationMain = dlsym(RTLD_DEFAULT, "UIApplicationMain");
    struct rebinding rebindings[] = {
        {"UIApplicationMain", ws_UIApplicationMain, NULL},
    };
    rebind_symbols_image((void *)mh, slide, rebindings, 1);

    // Tweaks load after the guest (their constructors look the guest image up)
    // and before the entry point (before il2cpp initialises).
    // Per-file results for the launcher's Custom dylibs list, written before
    // the guest takes over so the next launcher start can show them.
    NSMutableDictionary<NSString *, NSString *> *results = [NSMutableDictionary dictionary];
    for (NSString *path in gInjected) {
        if (![NSFileManager.defaultManager fileExistsAtPath:path]) {
            WSLog(@"guest", @"skipping missing tweak %@", path.lastPathComponent);
            results[path.lastPathComponent] = @"file missing";
            continue;
        }
        void *h = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL);
        NSString *why = h ? nil : @(dlerror() ?: "unknown");
        WSLog(@"guest", @"tweak %@ %@", path.lastPathComponent,
              h ? @"loaded" : [@"FAILED: " stringByAppendingString:why]);
        // dyld repeats the full path; the tail after the last "): " is the reason.
        NSRange tail = [why rangeOfString:@"): " options:NSBackwardsSearch];
        results[path.lastPathComponent] = h ? @"loaded"
            : (tail.location != NSNotFound ? [why substringFromIndex:NSMaxRange(tail)] : why);
    }
    NSString *dylibsDir = [WSPaths.launcherRoot stringByAppendingPathComponent:@"dylibs"];
    if ([NSFileManager.defaultManager fileExistsAtPath:dylibsDir]) {
        NSData *json = [NSJSONSerialization dataWithJSONObject:results options:0 error:nil];
        [json writeToFile:[dylibsDir stringByAppendingPathComponent:@"last-load.json"]
               atomically:YES];
    }

    int (*guestMain)(int, char **) = ws_entry_point(mh, slide);
    if (!guestMain) {
        if (error) *error = [NSError errorWithDomain:WSGuestLoaderErrorDomain
                                                code:WSGuestLoaderErrorNoEntryPoint
                                            userInfo:@{NSLocalizedDescriptionKey:
                                                @"No LC_MAIN in the guest image."}];
        return NO;
    }

    gLaunched = YES;
    WSLog(@"guest", @"entering guest main at %p", guestMain);

    char *argv[] = { (char *)exe.fileSystemRepresentation, NULL };
    guestMain(1, argv);
    // ws_UIApplicationMain parks on the run loop, so we only get here if the
    // guest returned on its own -- which for Unity means it failed to start.
    WSLog(@"guest", @"guest main returned");
    return YES;
}

@end
