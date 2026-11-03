//  WSContainer.h -- process-level container setup.
//
//  Order matters here. WSContainerBootstrap() runs as the first statement of
//  main(), before UIApplicationMain and therefore before anything in the
//  process has asked Foundation for a path. That is the only moment at which
//  HOME / CFFIXED_USER_HOME / TMPDIR can be changed and have every later
//  NSHomeDirectory(), NSTemporaryDirectory() and
//  NSSearchPathForDirectoriesInDomains() agree with the change -- CoreFoundation
//  caches the home directory the first time it is asked.
//
//  Consequence for the rest of the app: the launcher's own UI is running with
//  a redirected home too, so launcher state goes through WSPaths (which
//  remembers the real one) rather than NSHomeDirectory().
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

#ifdef __cplusplus
extern "C" {
#endif

/// Call first thing in main(). Captures the real sandbox home and bundle path,
/// picks the active profile, creates its container and redirects the
/// environment into it. Safe to call twice; the second call does nothing.
void WSContainerBootstrap(void);

/// The sandbox home as it was before redirection.
const char *_Nullable WSContainerRealHome(void);
/// The launcher's own bundle path, captured before the mainBundle swizzle.
const char *_Nullable WSContainerRealBundlePath(void);
/// The container the environment currently points at, or NULL if bootstrap
/// decided not to redirect (safe mode).
const char *_Nullable WSContainerCurrentHome(void);
/// YES when a `safe-mode` marker file told bootstrap to skip redirection.
BOOL WSContainerIsSafeMode(void);

#ifdef __cplusplus
}
#endif

NS_ASSUME_NONNULL_END
