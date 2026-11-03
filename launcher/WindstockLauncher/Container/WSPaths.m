#import "WSPaths.h"
#import "WSContainer.h"

@implementation WSPaths

+ (NSString *)realHome {
    const char *h = WSContainerRealHome();
    return h ? @(h) : NSHomeDirectory();
}

+ (NSString *)launcherRoot {
    return [[self.realHome stringByAppendingPathComponent:@"Documents"]
            stringByAppendingPathComponent:@"Windstock"];
}

+ (NSString *)modsConfigFile {
    return [self.launcherRoot stringByAppendingPathComponent:@"mods.json"];
}

+ (NSString *)launcherPrefsFile {
    return [self.launcherRoot stringByAppendingPathComponent:@"launcher.json"];
}

+ (NSString *)logsDir {
    return [self.launcherRoot stringByAppendingPathComponent:@"logs"];
}

+ (NSString *)serverDataDir {
    return [self.launcherRoot stringByAppendingPathComponent:@"server"];
}

+ (NSString *)containerForProfile:(NSString *)profile {
    NSString *base = [[self.realHome stringByAppendingPathComponent:@"Documents"]
                      stringByAppendingPathComponent:@"Containers"];
    return [base stringByAppendingPathComponent:profile.length ? profile : @"default"];
}

+ (BOOL)ensureDirectory:(NSString *)path error:(NSError **)error {
    return [NSFileManager.defaultManager createDirectoryAtPath:path
                                  withIntermediateDirectories:YES
                                                   attributes:nil
                                                        error:error];
}

+ (BOOL)prepareContainer:(NSString *)container error:(NSError **)error {
    NSArray<NSString *> *subdirs = @[
        @"Documents", @"tmp", @"Library", @"Library/Caches",
        @"Library/Preferences", @"Library/Application Support",
        @"Library/SplashBoard",
    ];
    for (NSString *sub in subdirs) {
        NSString *p = [container stringByAppendingPathComponent:sub];
        if (![self ensureDirectory:p error:error]) return NO;
    }
    return YES;
}

/// The launcher's own bundle, captured in main() -- NSBundle.mainBundle is
/// swizzled to the guest once the game boots, so it cannot be used here.
+ (NSString *)hostBundlePath {
    const char *p = WSContainerRealBundlePath();
    return p ? @(p) : NSBundle.mainBundle.bundlePath;
}

+ (NSString *)frameworksDir {
    return [self.hostBundlePath stringByAppendingPathComponent:@"Frameworks"];
}

+ (nullable NSString *)guestBundlePath {
    NSString *guestDir = [self.hostBundlePath stringByAppendingPathComponent:@"Guest"];
    NSArray<NSString *> *names = [NSFileManager.defaultManager contentsOfDirectoryAtPath:guestDir error:nil];
    for (NSString *name in names) {
        // Guest/game (any folder holding the game's Info.plist). Not a .app:
        // sideloaders reject a nested .app whose executable is missing.
        NSString *dir = [guestDir stringByAppendingPathComponent:name];
        if ([NSFileManager.defaultManager fileExistsAtPath:
                [dir stringByAppendingPathComponent:@"Info.plist"]]) {
            return dir;
        }
    }
    return nil;
}

+ (nullable NSString *)guestExecutablePath {
    // Frameworks/pokemongo.framework/pokemongo -- a framework because that is
    // what a sideload signer signs, and named exactly "pokemongo" because the
    // tweak finds the game by a path ending in "/pokemongo".
    NSString *p = [[self.frameworksDir
                    stringByAppendingPathComponent:@"pokemongo.framework"]
                   stringByAppendingPathComponent:@"pokemongo"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

+ (nullable NSString *)tweakPath {
    NSString *p = [self.frameworksDir stringByAppendingPathComponent:@"windstock.dylib"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

+ (nullable NSString *)gpsTweakPath {
    NSString *p = [self.frameworksDir stringByAppendingPathComponent:@"windstockgps.dylib"];
    return [NSFileManager.defaultManager fileExistsAtPath:p] ? p : nil;
}

+ (NSString *)pythonServerDir {
    return [self.hostBundlePath stringByAppendingPathComponent:@"PythonServer"];
}

+ (NSString *)pythonStdlibDir {
    return [self.hostBundlePath stringByAppendingPathComponent:@"python-stdlib"];
}

@end
