// WSLog -- captures the game's own log output (Unity Debug.Log / NSLog / stdout / stderr)
// and sends it to the server, because iOS keeps it out of the device syslog.
//
//   * stdout and stderr are replaced with a pipe; a reader thread tees every line back
//     to the real fds (so nothing is lost) and emits it.
//   * NSLog is rebound with fishhook (Unity's printf_console and most plugins use it).
//   * Every line goes to <guest Documents>/wslog.txt. Lines that look interesting
//     (raid / lobby / battle / exception / error / null / fail / warn) are also sent to the
//     server as a one-shot GET /wslog?m=<line>, which the server log shows as
//     "[bridge] GET /wslog?m=..." -- no server change needed. Create an empty file
//     <guest Documents>/ws_logall to send every line instead.
//
// Server address: baked at build time (@SERVER@), override with env WS_SERVER or
// <guest Documents>/ws_server.txt (one IPv4 line), same as WSTweak.
//
// Build: tweak-livecontainer/build_log.sh [server-ip]  ->  WSLog.dylib

#import <Foundation/Foundation.h>
#import <os/log.h>
#import <arpa/inet.h>
#import <netinet/in.h>
#import <sys/socket.h>
#import <unistd.h>
#import <dlfcn.h>
#import <stdatomic.h>
#import <mach-o/dyld.h>
#import "fishhook.h"

#define WS_DEFAULT_SERVER "@SERVER@"

static char gServer[64] = WS_DEFAULT_SERVER;
static BOOL gAll;
static NSFileHandle *gFile;
static dispatch_queue_t gQ;
static int gRealOut = -1, gRealErr = -1;
static atomic_int gSent;

static void (*orig_NSLogv)(NSString *, va_list);

static void ws_read_config(void) {
    const char *env = getenv("WS_SERVER");
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (env && *env) {
        strlcpy(gServer, env, sizeof gServer);
    } else if (docs) {
        NSString *s = [NSString stringWithContentsOfFile:[docs stringByAppendingPathComponent:@"ws_server.txt"]
                                                encoding:NSUTF8StringEncoding error:nil];
        s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length) strlcpy(gServer, s.UTF8String, sizeof gServer);
    }
    if (docs) {
        gAll = YES; (void)[NSFileManager.defaultManager fileExistsAtPath:[docs stringByAppendingPathComponent:@"ws_logall"]];
        NSString *p = [docs stringByAppendingPathComponent:@"wslog.txt"];
        [NSFileManager.defaultManager createFileAtPath:p contents:nil attributes:nil];
        gFile = [NSFileHandle fileHandleForWritingAtPath:p];
        [gFile seekToEndOfFile];
    }
}

static BOOL ws_interesting(const char *s) {
    static const char *keys[] = { "raid", "lobby", "battle", "exception", "error", "null",
                                  "fail", "warn", "assert", "timeout", "invalid", "missing" };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++)
        if (strcasestr(s, keys[i])) return YES;
    return NO;
}

// One-shot GET so the line shows in the server's access log.
static void ws_send(NSString *line) {
    if (atomic_fetch_add(&gSent, 1) > 20000) return;           // hard cap per launch
    NSString *enc = [line stringByAddingPercentEncodingWithAllowedCharacters:
                     NSCharacterSet.alphanumericCharacterSet];
    if (enc.length > 600) enc = [enc substringToIndex:600];
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return;
    struct timeval tv = { 1, 0 };
    setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, sizeof tv);
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, sizeof tv);
    struct sockaddr_in sa; memset(&sa, 0, sizeof sa);
    sa.sin_family = AF_INET; sa.sin_port = htons(80);
    inet_pton(AF_INET, gServer, &sa.sin_addr);
    if (connect(fd, (struct sockaddr *)&sa, sizeof sa) == 0) {
        char req[1024];
        int n = snprintf(req, sizeof req,
            "GET /wslog?m=%s HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n", enc.UTF8String);
        write(fd, req, n);
    }
    close(fd);
}

static void ws_emit(NSString *line) {
    if (!line.length) return;
    dispatch_async(gQ, ^{
        if (gFile) [gFile writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
        if (gAll || ws_interesting(line.UTF8String)) ws_send(line);
    });
}

#pragma mark - NSLog

static void my_NSLogv(NSString *fmt, va_list ap) {
    va_list cp; va_copy(cp, ap);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:cp];
    va_end(cp);
    ws_emit(m);
    if (orig_NSLogv) orig_NSLogv(fmt, ap);
}

static void my_NSLog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    my_NSLogv(fmt, ap);
    va_end(ap);
}

#pragma mark - stdout / stderr

static void ws_capture_fd(int target, int *saved) {
    int p[2];
    if (pipe(p) != 0) return;
    *saved = dup(target);
    dup2(p[1], target);
    close(p[1]);
    int rd = p[0], real = *saved;
    NSThread *t = [[NSThread alloc] initWithBlock:^{
        char buf[4096]; NSMutableData *acc = [NSMutableData data];
        ssize_t n;
        while ((n = read(rd, buf, sizeof buf)) > 0) {
            write(real, buf, n);                              // tee to the real fd
            [acc appendBytes:buf length:n];
            const char *b = acc.bytes; NSUInteger start = 0;
            for (NSUInteger i = 0; i < acc.length; i++) {
                if (b[i] == '\n') {
                    NSString *l = [[NSString alloc] initWithBytes:b + start length:i - start
                                                         encoding:NSUTF8StringEncoding];
                    if (l) ws_emit(l);
                    start = i + 1;
                }
            }
            [acc replaceBytesInRange:NSMakeRange(0, start) withBytes:NULL length:0];
            if (acc.length > 65536) [acc setLength:0];
        }
    }];
    t.name = @"WSLog.reader";
    [t start];
}

static struct rebinding gBinds[2];

// Only the game's own images: fishhook patching a system framework from the shared cache
// faults (KERN_PROTECTION_FAILURE in rebind_symbols_for_image), so skip those.
static void ws_image_added(const struct mach_header *mh, intptr_t slide) {
    Dl_info info;
    if (!dladdr(mh, &info) || !info.dli_fname) return;
    const char *p = info.dli_fname;
    if (!strncmp(p, "/System/", 8) || !strncmp(p, "/usr/", 5) || !strncmp(p, "/Library/", 9)
        || !strncmp(p, "/private/preboot/", 17) || strstr(p, "/WSLog.dylib")) return;
    rebind_symbols_image((void *)mh, slide, gBinds, 2);
}

__attribute__((constructor))
static void ws_log_init(void) {
    @autoreleasepool {
        ws_read_config();
        gQ = dispatch_queue_create("WSLog", DISPATCH_QUEUE_SERIAL);
        orig_NSLogv = dlsym(RTLD_DEFAULT, "NSLogv");
        gBinds[0] = (struct rebinding){"NSLog", my_NSLog, NULL};
        gBinds[1] = (struct rebinding){"NSLogv", my_NSLogv, NULL};
        _dyld_register_func_for_add_image(ws_image_added);
        ws_capture_fd(STDOUT_FILENO, &gRealOut);
        ws_capture_fd(STDERR_FILENO, &gRealErr);
        os_log(OS_LOG_DEFAULT, "[WSLog] installed server=%{public}s all=%d", gServer, gAll);
        ws_emit([NSString stringWithFormat:@"[WSLog] installed (server %s, all=%d)", gServer, gAll]);
    }
}
