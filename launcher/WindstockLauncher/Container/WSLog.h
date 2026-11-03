//  WSLog.h -- one log the whole launcher shares.
//
//  Once the guest takes over the process the SwiftUI UI is gone, so anything
//  worth reading after a failed launch has to survive on disk. Every line goes
//  to <launcherRoot>/logs/launcher.log as well as to an in-memory ring the UI
//  renders live.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Posted (on the main queue) whenever a line is appended.
extern NSNotificationName const WSLogDidAppendNotification;

#ifdef __cplusplus
extern "C" {
#endif
void WSLogv(NSString *category, NSString *format, va_list args);
void WSLog(NSString *category, NSString *format, ...) NS_FORMAT_FUNCTION(2, 3);
/// Non-variadic entry point. C variadics are not callable from Swift, so Swift
/// formats its own string and comes through here.
void WSLogMessage(NSString *category, NSString *message);
/// Call once, first thing in main(). Ignores SIGPIPE, and makes a run that
/// ends without a crash report say why in the log (see WSLog.m).
void WSExitTraceInstall(void);
#ifdef __cplusplus
}
#endif

@interface WSLogStore : NSObject

@property (class, readonly) WSLogStore *shared;

/// Newest last. Capped at 2000 lines.
- (NSArray<NSString *> *)lines;
- (NSString *)text;
- (void)clear;
- (void)append:(NSString *)line;

@end

NS_ASSUME_NONNULL_END
