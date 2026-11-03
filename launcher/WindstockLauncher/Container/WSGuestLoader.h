//  WSGuestLoader.h -- load the game into this process and hand control to it.
//
//  The guest's Mach-O was turned into a dylib at build time (tools/patch_macho.py)
//  and lives at Frameworks/pokemongo.framework/pokemongo. That exact filename
//  matters: the windstock tweak finds the game by looking for a loaded image
//  whose path ends in "/pokemongo".
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const WSGuestLoaderErrorDomain;

/// The tweak posts this (by name -- it does not link against the launcher)
/// when the player taps the in-game launcher button.
extern NSNotificationName const WSGuestLoaderReturnToLauncherRequest;
/// Posted after the swap in either direction, for the launcher's UI and the
/// tweak (which pauses its own AVAudioPlayer music while the game is hidden).
extern NSNotificationName const WSGuestLoaderDidShowLauncher;
extern NSNotificationName const WSGuestLoaderDidResumeGuest;

typedef NS_ENUM(NSInteger, WSGuestLoaderError) {
    WSGuestLoaderErrorNoExecutable = 1,
    WSGuestLoaderErrorNoBundle,
    WSGuestLoaderErrorDlopenFailed,
    WSGuestLoaderErrorNoImage,
    WSGuestLoaderErrorNoEntryPoint,
    WSGuestLoaderErrorAlreadyLaunched,
};

@interface WSGuestLoader : NSObject

/// YES once launchWithError: has handed control to the game.
@property (class, readonly) BOOL hasLaunched;

/// YES while the game is running but parked behind the launcher's UI.
@property (class, readonly) BOOL isShowingLauncher;

/// Pauses the game and puts the launcher's own window back on screen. The
/// game stays loaded -- it cannot be loaded twice in one process -- so the
/// way back is +resumeGuest, not another launch. Posted by the tweak's
/// in-game button as WSGuestLoaderReturnToLauncherRequest.
+ (void)returnToLauncher;

/// Hides the launcher again and unpauses the game.
+ (void)resumeGuest;

/// Dylibs to load after the guest and before its entry point -- the tweak, in
/// load order. Paths that do not exist are skipped.
+ (void)setInjectedDylibs:(NSArray<NSString *> *)paths;

/// Loads the guest, swizzles NSBundle.mainBundle onto it, injects the tweaks,
/// rebinds UIApplicationMain in the guest image, then calls the guest's entry
/// point. On success this never returns: the guest's run loop takes over the
/// process.
///
/// `executablePath` is a Mach-O that has already been converted to a dylib and
/// signed with this process's own team -- an app imported at runtime, or the
/// one embedded at build time. `bundlePath` is the .app directory
/// NSBundle.mainBundle is swizzled onto.
+ (BOOL)launchExecutable:(NSString *)executablePath
              bundlePath:(NSString *)bundlePath
                   error:(NSError **)error;

/// Launches whatever was embedded at build time, if anything.
+ (BOOL)launchWithError:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
