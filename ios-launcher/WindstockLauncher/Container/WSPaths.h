//  WSPaths.h -- every path the launcher uses, in one place.
//
//  The container redirects HOME/CFFIXED_USER_HOME at process start, before
//  Foundation has cached anything, so NSHomeDirectory() inside this process
//  means *the guest's* home from then on. The launcher's own state therefore
//  must never be addressed relatively: it always goes through here, which
//  remembers the real sandbox home captured in main().
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WSPaths : NSObject

/// The app's true sandbox home, captured before any redirection. Never nil
/// after WSContainerCaptureRealHome() has run.
@property (class, readonly) NSString *realHome;

/// <realHome>/Documents/Windstock -- launcher state (prefs, mods, logs).
@property (class, readonly) NSString *launcherRoot;
/// <launcherRoot>/mods.json
@property (class, readonly) NSString *modsConfigFile;
/// <launcherRoot>/launcher.json
@property (class, readonly) NSString *launcherPrefsFile;
/// <launcherRoot>/logs
@property (class, readonly) NSString *logsDir;
/// <launcherRoot>/server -- writable copy of the server's data dir.
@property (class, readonly) NSString *serverDataDir;

/// <realHome>/Documents/Containers/<profile> -- the guest's fake home.
+ (NSString *)containerForProfile:(NSString *)profile;
/// Creates Documents/Library/{Caches,Preferences,Application Support}/tmp.
+ (BOOL)prepareContainer:(NSString *)container error:(NSError **)error;

/// <bundle>/Guest/game -- the guest's resources (everything but its
/// Mach-O, which lives in Frameworks/ so the sideload signer signs it).
@property (class, readonly, nullable) NSString *guestBundlePath;
/// <bundle>/Frameworks/libpokemongo.dylib
@property (class, readonly, nullable) NSString *guestExecutablePath;
/// <bundle>/Frameworks/windstock.dylib -- the mods tweak, or nil if absent.
@property (class, readonly, nullable) NSString *tweakPath;

/// Frameworks/windstockgps.dylib -- location spoofing. Separate from the mods
/// tweak because it hooks only CoreLocation, so it is not tied to a client
/// build and can be carried, or left out, on its own.
@property (class, readonly, nullable) NSString *gpsTweakPath;
/// <bundle>/PythonServer -- the staged server source tree.
@property (class, readonly) NSString *pythonServerDir;
/// <bundle>/Frameworks -- also where the Python extension modules live.
@property (class, readonly) NSString *frameworksDir;
/// <bundle>/python-stdlib
@property (class, readonly) NSString *pythonStdlibDir;

/// The launcher's own bundle path, valid even after the mainBundle swizzle.
@property (class, readonly) NSString *hostBundlePath;

+ (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error;

@end

NS_ASSUME_NONNULL_END
