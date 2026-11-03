#import "WSLog.h"
#import "WSPaths.h"

#import <UIKit/UIKit.h>
#import <execinfo.h>
#import <fcntl.h>
#import <mach/mach.h>
#import <os/log.h>
#import <os/proc.h>
#import <signal.h>
#import <sys/time.h>
#import <unistd.h>

// strftime rather than NSDateFormatter: WSLog is called from the guest's
// threads and from the Python server thread, and NSDateFormatter is not safe
// to share across them.
static NSString *ws_timestamp(void) {
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char buf[32];
    size_t n = strftime(buf, sizeof buf, "%H:%M:%S", &tm);
    snprintf(buf + n, sizeof buf - n, ".%03d", (int)(tv.tv_usec / 1000));
    return @(buf);
}

NSNotificationName const WSLogDidAppendNotification = @"WSLogDidAppend";

static const NSUInteger kMaxLines = 2000;

@implementation WSLogStore {
    NSMutableArray<NSString *> *_lines;
    NSLock *_lock;
    NSFileHandle *_file;
}

+ (WSLogStore *)shared {
    static WSLogStore *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [WSLogStore new]; });
    return shared;
}

- (instancetype)init {
    if (!(self = [super init])) return nil;
    _lines = [NSMutableArray arrayWithCapacity:kMaxLines];
    _lock = [NSLock new];
    [self openFile];
    return self;
}

- (void)openFile {
    NSString *dir = WSPaths.logsDir;
    if (![WSPaths ensureDirectory:dir error:nil]) return;
    NSString *path = [dir stringByAppendingPathComponent:@"launcher.log"];
    NSFileManager *fm = NSFileManager.defaultManager;
    // Keep one previous run around; a crash loop otherwise erases the evidence.
    NSDictionary *attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs && attrs.fileSize > 4 * 1024 * 1024) {
        NSString *old = [dir stringByAppendingPathComponent:@"launcher.previous.log"];
        [fm removeItemAtPath:old error:nil];
        [fm moveItemAtPath:path toPath:old error:nil];
    }
    if (![fm fileExistsAtPath:path]) [fm createFileAtPath:path contents:nil attributes:nil];
    _file = [NSFileHandle fileHandleForWritingAtPath:path];
    [_file seekToEndOfFile];
}

- (void)append:(NSString *)line {
    [_lock lock];
    [_lines addObject:line];
    if (_lines.count > kMaxLines) {
        [_lines removeObjectsInRange:NSMakeRange(0, _lines.count - kMaxLines)];
    }
    NSData *data = [[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding];
    @try { [_file writeData:data]; } @catch (NSException *e) { /* disk full, keep going */ }
    [_lock unlock];

    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:WSLogDidAppendNotification
                                                          object:nil];
    });
}

- (NSArray<NSString *> *)lines {
    [_lock lock];
    NSArray *copy = [_lines copy];
    [_lock unlock];
    return copy;
}

- (NSString *)text {
    return [self.lines componentsJoinedByString:@"\n"];
}

- (void)clear {
    [_lock lock];
    [_lines removeAllObjects];
    [_lock unlock];
}

@end

void WSLogv(NSString *category, NSString *format, va_list args) {
    NSString *body = [[NSString alloc] initWithFormat:format arguments:args];
    WSLogStore *store = WSLogStore.shared;
    NSString *line = [NSString stringWithFormat:@"%@ [%@] %@",
                      ws_timestamp(), category, body];
    os_log(OS_LOG_DEFAULT, "%{public}s", line.UTF8String);
    [store append:line];
}

void WSLog(NSString *category, NSString *format, ...) {
    va_list args;
    va_start(args, format);
    WSLogv(category, format, args);
    va_end(args);
}

void WSLogMessage(NSString *category, NSString *message) {
    WSLog(category, @"%@", message);
}

// ------------------------------------------------------------- exit trace
// The launcher was dying on players' phones with nothing to show for it: no
// crash report, nothing in the tweak's crash log, the log just stops. That
// leaves exit(), a signal nobody catches, or a SIGKILL from iOS -- and this
// tells them apart. exit() and the catchable signals write a line; a run that
// ends with neither was killed from outside, and the run-state file says
// whether the app was on screen when it happened.
static int g_trace_fd = -1;
static char g_state_path[PATH_MAX];

static void ws_trace_line(const char *text) {
    if (g_trace_fd < 0) return;
    struct timeval tv;
    gettimeofday(&tv, NULL);
    struct tm tm;
    localtime_r(&tv.tv_sec, &tm);
    char buf[512];
    int n = snprintf(buf, sizeof buf, "%02d:%02d:%02d.%03d [exit] %s\n",
                     tm.tm_hour, tm.tm_min, tm.tm_sec, (int)(tv.tv_usec / 1000), text);
    if (n > (int)sizeof buf - 1) n = (int)sizeof buf - 1;
    if (n > 0) write(g_trace_fd, buf, (size_t)n);
}

// open/write/close only, so the signal handler can use it too.
static void ws_trace_state(const char *state) {
    if (!g_state_path[0]) return;
    int fd = open(g_state_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd < 0) return;
    write(fd, state, strlen(state));
    close(fd);
}

static void ws_trace_atexit(void) {
    ws_trace_line("exit() was called -- by:");
    void *frames[32];
    int n = backtrace(frames, 32);
    if (g_trace_fd >= 0 && n > 0) backtrace_symbols_fd(frames, n, g_trace_fd);
    ws_trace_state("exit");
}

static void ws_trace_signal(int sig) {
    char buf[64];
    snprintf(buf, sizeof buf, "killed by signal %d", sig);
    ws_trace_line(buf);
    snprintf(buf, sizeof buf, "signal %d", sig);
    ws_trace_state(buf);
    signal(sig, SIG_DFL);   // and die the way we would have
    raise(sig);
}

static NSString *ws_memory_text(void) {
    task_vm_info_data_t info;
    mach_msg_type_number_t count = TASK_VM_INFO_COUNT;
    if (task_info(mach_task_self(), TASK_VM_INFO, (task_info_t)&info, &count) != KERN_SUCCESS)
        return @"memory unknown";
    return [NSString stringWithFormat:@"%llu MB used, %zu MB left",
            info.phys_footprint >> 20, os_proc_available_memory() >> 20];
}

void WSExitTraceInstall(void) {
    // iOS closes a suspended app's sockets, and the next write to one raises
    // SIGPIPE, which ends the process without a crash report. The game's own
    // main() ignores it, but the server runs before the game does -- and
    // Python is started with install_signal_handlers = 0, so it does not.
    signal(SIGPIPE, SIG_IGN);

    NSString *dir = WSPaths.logsDir;
    if (![WSPaths ensureDirectory:dir error:nil]) return;
    NSString *statePath = [dir stringByAppendingPathComponent:@"run-state"];
    NSString *previous = [[NSString stringWithContentsOfFile:statePath
                                                    encoding:NSUTF8StringEncoding error:nil]
                          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if ([previous isEqualToString:@"active"] || [previous isEqualToString:@"inactive"]) {
        WSLog(@"exit", @"the last run died ON SCREEN (%@) with no exit() and no "
              @"catchable signal -- killed from outside (iOS, or a crash; see the "
              @"lines just above)", previous);
    } else if ([previous isEqualToString:@"background"]) {
        WSLog(@"exit", @"the last run ended in the background (iOS reclaiming a "
              @"suspended app is normal)");
    } else if (previous.length) {
        WSLog(@"exit", @"the last run ended with: %@", previous);
    }

    strlcpy(g_state_path, statePath.fileSystemRepresentation, sizeof g_state_path);
    g_trace_fd = open([dir stringByAppendingPathComponent:@"launcher.log"].fileSystemRepresentation,
                      O_WRONLY | O_CREAT | O_APPEND, 0644);
    ws_trace_state("inactive");

    atexit(ws_trace_atexit);
    // Not SEGV/BUS/ILL/ABRT/FPE/TRAP: those make a crash report, and the tweak
    // has its own handler for them.
    int quiet[] = { SIGTERM, SIGHUP, SIGINT, SIGQUIT, SIGALRM, SIGUSR1, SIGUSR2,
                    SIGXCPU, SIGXFSZ, SIGVTALRM, SIGPROF, SIGSYS, SIGEMT };
    for (size_t i = 0; i < sizeof quiet / sizeof quiet[0]; i++) signal(quiet[i], ws_trace_signal);

    NSDictionary<NSNotificationName, NSString *> *states = @{
        UIApplicationDidBecomeActiveNotification:     @"active",
        UIApplicationWillResignActiveNotification:    @"inactive",
        UIApplicationDidEnterBackgroundNotification:  @"background",
        UIApplicationWillEnterForegroundNotification: @"inactive",
        UIApplicationWillTerminateNotification:       @"terminated by iOS (willTerminate)",
    };
    [states enumerateKeysAndObjectsUsingBlock:^(NSNotificationName name, NSString *state, BOOL *stop) {
        [NSNotificationCenter.defaultCenter addObserverForName:name object:nil queue:nil
                                                    usingBlock:^(NSNotification *note) {
            ws_trace_state(state.UTF8String);
            NSString *event = [[name stringByReplacingOccurrencesOfString:@"UIApplication" withString:@""]
                               stringByReplacingOccurrencesOfString:@"Notification" withString:@""];
            WSLog(@"life", @"%@ (%@)", event, ws_memory_text());
        }];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification
                                                    object:nil queue:nil
                                                usingBlock:^(NSNotification *note) {
        WSLog(@"life", @"MEMORY WARNING from iOS (%@)", ws_memory_text());
    }];
}
