// WSTweak -- the LiveContainer-side port of phone071/agent (Android frida agent).
//
// LiveContainer runs the stock guest app without the Windstock launcher and without
// frida, so the two things the Android agent does in-process are done here instead, as
// a tweak dylib LiveContainer loads into the guest before it starts:
//
//   * redirect (lib/redirect.js): Niantic / Pokemon / Zendesk hostnames resolve to the
//     server instead of Niantic. getaddrinfo + the CFNetwork async resolver + the
//     mDNSResponder path are rebound with fishhook (same code as the launcher's
//     WSNetRedirect). No port rewrite: this server binds 443 and 80 itself, unlike the
//     launcher's loopback server.
//
//   * trust (lib/trust.js): the server's cert is signed by a private CA the device does
//     not know, so every TLS handshake to it would fail. Rather than add the CA (no
//     in-process trust store to add to here), SecTrustEvaluate is wrapped: a handshake
//     that the system would REJECT is forced to succeed. Handshakes that already pass
//     (real Google sign-in, which is not redirected) are left exactly as they were, so
//     this is not a blanket accept-everything -- only what the OS was about to reject.
//     NiaNet (the RPC), Mono's TLS and GTMSessionFetcher all evaluate through
//     SecTrustEvaluate, so this one hook covers every path.
//
// The RPC is NOT bypassed at the managed layer the way the Android agent does it
// (N2ServerSend_), because that needs il2cpp hooking; redirect + trust lets the client's
// own native RPC reach the server over its normal TLS instead. SSO is already http
// (global-metadata patched), so that hop needs no trust.
//
// Server address: baked in at build time (@SERVER@), overridable at runtime by an env
// var WS_SERVER or a file <guest Documents>/ws_server.txt (one line, an IPv4 literal).

#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <objc/runtime.h>
#import <os/log.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <netdb.h>
#import <netinet/in.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/socket.h>
#import "fishhook.h"

// Jitless il2cpp RPC bypass (il2hook.c): capture the PTC ticket + POST the plain
// RequestEnvelope to the server, intercepting before the native rpc2 platform wrap.
extern void ws_il2_init(const char *server);

#define WS_DEFAULT_SERVER "@SERVER@"

static void wslog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSString *m = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    // %{public}s so the message isn't redacted to <private> in the device log.
    os_log(OS_LOG_DEFAULT, "[WSTweak] %{public}s", m.UTF8String);
}

#pragma mark - config

static NSArray<NSString *> *gHostnames;
static char gTargetHost[256] = WS_DEFAULT_SERVER;
static struct in_addr gTargetV4;
static BOOL gTargetV4Valid = NO;

static NSString *ws_read_override(void) {
    const char *env = getenv("WS_SERVER");
    if (env && *env) return [@(env) stringByTrimmingCharactersInSet:
                             NSCharacterSet.whitespaceAndNewlineCharacterSet];
    // The guest's sandbox Documents dir -- what LiveContainer hands the app as HOME.
    NSString *docs = NSSearchPathForDirectoriesInDomains(
        NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs) {
        NSString *p = [docs stringByAppendingPathComponent:@"ws_server.txt"];
        NSString *s = [NSString stringWithContentsOfFile:p
                                                encoding:NSUTF8StringEncoding error:NULL];
        s = [s stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (s.length) return s;
    }
    return nil;
}

static void ws_set_target(NSString *host) {
    if (host.length == 0) host = @(WS_DEFAULT_SERVER);
    strlcpy(gTargetHost, host.UTF8String, sizeof gTargetHost);
    gTargetV4Valid = inet_pton(AF_INET, gTargetHost, &gTargetV4) == 1;
    wslog(@"server -> %@%@", host, gTargetV4Valid ? @"" : @" (not an IPv4 literal)");
}

static BOOL ws_host_matches(const char *node) {
    if (!node) return NO;
    NSString *host = [@(node) lowercaseString];
    if (host.length == 0) return NO;
    for (NSString *p in gHostnames) {
        if ([p hasPrefix:@"*."]) {
            if ([host hasSuffix:[p substringFromIndex:1]]) return YES;   // ".nianticlabs.com"
            if ([host isEqualToString:[p substringFromIndex:2]]) return YES;
        } else if ([host isEqualToString:p]) {
            return YES;
        }
    }
    return NO;
}

static void ws_trace(const char *node, BOOL matched) {
    static atomic_ulong seen = 0;
    if (atomic_fetch_add(&seen, 1) < 40 && node)
        wslog(@"resolve %s%s", node, matched ? " -> server" : "");
}

#pragma mark - resolver hooks (redirect)

static int (*orig_getaddrinfo)(const char *, const char *,
                               const struct addrinfo *, struct addrinfo **);
static int my_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res) {
    BOOL m = ws_host_matches(node);
    ws_trace(node, m);
    return orig_getaddrinfo(m ? gTargetHost : node, service, hints, res);
}

typedef void (*gai_cb)(int32_t, int32_t, const struct addrinfo *, void *);
static int32_t (*orig_gai_async)(void *, const char *, const char *,
                                 const struct addrinfo *, gai_cb, void *);
static int32_t my_gai_async(void *port, const char *node, const char *service,
                            const struct addrinfo *hints, gai_cb cb, void *ctx) {
    BOOL m = ws_host_matches(node);
    ws_trace(node, m);
    return orig_gai_async(port, m ? gTargetHost : node, service, hints, cb, ctx);
}

typedef int32_t (*dnssd_fn)(void *, uint32_t, uint32_t, uint32_t,
                            const char *, void *, void *);
static dnssd_fn orig_dnssd;
static int32_t my_dnssd(void *ref, uint32_t flags, uint32_t iface, uint32_t proto,
                        const char *hostname, void *cb, void *ctx) {
    BOOL m = ws_host_matches(hostname);
    ws_trace(hostname, m);
    return orig_dnssd(ref, flags, iface, proto, m ? gTargetHost : hostname, cb, ctx);
}

#pragma mark - SecTrustEvaluate hook (trust)

static OSStatus (*orig_SecTrustEvaluate)(SecTrustRef, SecTrustResultType *);
static OSStatus my_SecTrustEvaluate(SecTrustRef trust, SecTrustResultType *result) {
    OSStatus st = orig_SecTrustEvaluate(trust, result);
    if (st == errSecSuccess && result) {
        // Only rescue a verdict the OS was about to reject; leave real passes alone.
        if (*result != kSecTrustResultProceed && *result != kSecTrustResultUnspecified) {
            static atomic_ulong n = 0;
            if (atomic_fetch_add(&n, 1) < 20)
                wslog(@"trust: overriding result %d -> accept", (int)*result);
            *result = kSecTrustResultUnspecified;   // the "validated, no explicit anchor" pass
        }
    }
    return st;
}

// iOS 12+ API some stacks use instead; harmless to rebind if the app never calls it.
static Boolean (*orig_SecTrustEvaluateWithError)(SecTrustRef, CFErrorRef *);
static Boolean my_SecTrustEvaluateWithError(SecTrustRef trust, CFErrorRef *error) {
    Boolean ok = orig_SecTrustEvaluateWithError(trust, error);
    if (!ok) {
        static atomic_ulong n = 0;
        if (atomic_fetch_add(&n, 1) < 20) wslog(@"trust: SecTrustEvaluateWithError -> accept");
        if (error && *error) { CFRelease(*error); *error = NULL; }
        return true;
    }
    return ok;
}

#pragma mark - pinning override (NiaNet's own cert authenticators)

// The RPC does NOT go through SecTrustEvaluate: NiaNet's NIATrustedCertificatesAuthenticator
// (and PGPTrustedCertificatesAuthenticator) implement URLSession:didReceiveChallenge: and
// compare the server's cert against a built-in set themselves, then cancel the challenge --
// which resets the RPC connection before any request is sent. These classes only ever see
// Niantic / Pokemon-GO-Plus hosts, which are all our server now, so their challenge handler
// is replaced wholesale with "accept the server trust". This is the iOS equivalent of the
// 0.63 pin patch (pin/patch_pin_063.py), done at runtime instead of as a binary edit.
// Google sign-in uses a different class (GTMSessionFetcher) and is left alone.

typedef void (^ws_challenge_cb)(NSURLSessionAuthChallengeDisposition, NSURLCredential *);

static void ws_accept_challenge(id self, SEL _cmd, NSURLSession *session,
                                NSURLAuthenticationChallenge *challenge,
                                ws_challenge_cb completionHandler) {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    static atomic_ulong n = 0;
    if (atomic_fetch_add(&n, 1) < 20)
        wslog(@"pin: %@ accepting %@", NSStringFromClass([self class]),
              challenge.protectionSpace.host);
    if (trust) {
        completionHandler(NSURLSessionAuthChallengeUseCredential,
                          [NSURLCredential credentialForTrust:trust]);
    } else {
        completionHandler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
    }
}

// Returns YES once the class exists and its handler has been replaced.
static BOOL ws_override_pinner(const char *clsName) {
    Class cls = objc_getClass(clsName);
    if (!cls) return NO;
    SEL sel = @selector(URLSession:didReceiveChallenge:completionHandler:);
    // v@:@@@? -- void (self, _cmd, NSURLSession*, NSURLAuthenticationChallenge*, block)
    IMP prev = class_replaceMethod(cls, sel, (IMP)ws_accept_challenge, "v@:@@@?");
    wslog(@"pin: %s %s challenge handler", prev ? "replaced" : "added", clsName);
    return YES;
}

// The guest registers these ObjC classes some time after this dylib's constructor,
// so retry on the main queue until each is found (well before the post-login RPC).
static void ws_install_pinners(void) {
    static const char *names[] = { "NIATrustedCertificatesAuthenticator",
                                   "PGPTrustedCertificatesAuthenticator" };
    static BOOL done[2] = { NO, NO };
    for (int i = 0; i < 2; i++)
        if (!done[i]) done[i] = ws_override_pinner(names[i]);

    if ((!done[0] || !done[1])) {
        static int tries = 0;
        if (tries++ < 40) {  // ~20s of retries
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ ws_install_pinners(); });
        } else {
            wslog(@"pin: gave up finding authenticator classes");
        }
    }
}

#pragma mark - install

__attribute__((constructor))
static void ws_init(void) {
    @autoreleasepool {
        gHostnames = @[ @"*.nianticlabs.com", @"*.pokemon.com", @"*.zendesk.com" ];
        ws_set_target(ws_read_override());

        orig_getaddrinfo          = dlsym(RTLD_DEFAULT, "getaddrinfo");
        orig_gai_async            = dlsym(RTLD_DEFAULT, "getaddrinfo_async_start");
        orig_dnssd                = dlsym(RTLD_DEFAULT, "DNSServiceGetAddrInfo");
        orig_SecTrustEvaluate     = dlsym(RTLD_DEFAULT, "SecTrustEvaluate");
        orig_SecTrustEvaluateWithError = dlsym(RTLD_DEFAULT, "SecTrustEvaluateWithError");

        struct rebinding binds[] = {
            {"getaddrinfo", my_getaddrinfo, NULL},
            {"getaddrinfo_async_start", my_gai_async, NULL},
            {"DNSServiceGetAddrInfo", my_dnssd, NULL},
            {"SecTrustEvaluate", my_SecTrustEvaluate, NULL},
            {"SecTrustEvaluateWithError", my_SecTrustEvaluateWithError, NULL},
        };
        rebind_symbols(binds, sizeof binds / sizeof binds[0]);

        // NiaNet's RPC pinning lives in these; override them to accept our CA.
        // Retries on the main queue because the classes register after this runs.
        ws_install_pinners();

        // Jitless il2cpp hook: intercept the managed RPC send (N2ServerSend_) before
        // the native platform layer wraps it in the rpc2 envelope. Polls until the
        // delegate is created (post-login, pre-RPC), then overwrites its method_ptr.
        ws_il2_init(gTargetHost);

        wslog(@"installed (getaddrinfo=%s async=%s dnssd=%s SecTrustEvaluate=%s) hosts=%@",
              orig_getaddrinfo ? "y" : "n", orig_gai_async ? "y" : "n",
              orig_dnssd ? "y" : "n", orig_SecTrustEvaluate ? "y" : "n", gHostnames);
    }
}
