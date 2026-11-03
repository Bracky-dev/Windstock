#import "WSNetRedirect.h"
#import "WSLog.h"
#import "fishhook.h"

#import <arpa/inet.h>
#import <dlfcn.h>
#import <netdb.h>
#import <netinet/in.h>
#import <os/lock.h>
#import <stdatomic.h>
#import <sys/socket.h>

static NSArray<NSString *> *gHostnames = nil;
static os_unfair_lock gHostLock = OS_UNFAIR_LOCK_INIT;
static atomic_bool gEnabled = false;
static atomic_uint gLocalPort = 0;
static atomic_uint gPlainPort = 0;
/// The destination, as a C string the hooks can hand straight to the real
/// getaddrinfo, plus its parsed form so the port rewrite can recognise a
/// connection that is already heading there.
static char gTargetHost[256] = "127.0.0.1";
static struct in_addr gTargetV4;
static BOOL gTargetV4Valid = NO;
static os_unfair_lock gTargetLock = OS_UNFAIR_LOCK_INIT;
static atomic_ulong gLookups = 0;
static atomic_ulong gConnections = 0;
static BOOL gInstalled = NO;

#pragma mark - matching

/// Log the first few lookups whatever the answer. Without this there is no
/// way to tell "the client asked and we declined" from "the client never
/// asked", and those need completely different fixes.
static void ws_trace_lookup(const char *node, BOOL matched) {
    static atomic_ulong seen = 0;
    unsigned long n = atomic_fetch_add(&seen, 1);
    if (n < 40 && node) {
        WSLog(@"net", @"lookup %s%s", node, matched ? " (redirected)" : "");
    }
}

static BOOL ws_host_matches(const char *node) {
    if (!node || !atomic_load(&gEnabled)) return NO;
    NSString *host = [@(node) lowercaseString];
    if (host.length == 0) return NO;

    os_unfair_lock_lock(&gHostLock);
    NSArray<NSString *> *patterns = gHostnames;
    os_unfair_lock_unlock(&gHostLock);

    for (NSString *raw in patterns) {
        NSString *p = raw.lowercaseString;
        if ([p hasPrefix:@"*."]) {
            if ([host hasSuffix:[p substringFromIndex:1]]) return YES;      // ".niantic.com"
            if ([host isEqualToString:[p substringFromIndex:2]]) return YES; // bare apex
        } else if ([host isEqualToString:p]) {
            return YES;
        }
    }
    return NO;
}

/// Copy the target into caller storage: the hooks run on arbitrary threads
/// while the UI can be rewriting it.
static void ws_copy_target(char *out, size_t cap) {
    os_unfair_lock_lock(&gTargetLock);
    strlcpy(out, gTargetHost, cap);
    os_unfair_lock_unlock(&gTargetLock);
}

static void ws_note_lookup(const char *node) {
    unsigned long n = atomic_fetch_add(&gLookups, 1) + 1;
    // Only the first few are worth a line each; after that this would drown
    // the log during a session.
    if (n <= 20) {
        char target[256];
        ws_copy_target(target, sizeof target);
        WSLog(@"net", @"resolve %s -> %s", node, target);
    }
}

#pragma mark - getaddrinfo

static int (*ws_orig_getaddrinfo)(const char *, const char *,
                                  const struct addrinfo *, struct addrinfo **);

static int ws_getaddrinfo(const char *node, const char *service,
                          const struct addrinfo *hints, struct addrinfo **res) {
    ws_trace_lookup(node, ws_host_matches(node));
    if (ws_host_matches(node)) {
        ws_note_lookup(node);
        char target[256];
        ws_copy_target(target, sizeof target);
        return ws_orig_getaddrinfo(target, service, hints, res);
    }
    return ws_orig_getaddrinfo(node, service, hints, res);
}

#pragma mark - getaddrinfo_async_start (what CFNetwork actually calls)

typedef void (*ws_gai_async_cb)(int32_t, int32_t, const struct addrinfo *, void *);
static int32_t (*ws_orig_gai_async)(void *, const char *, const char *,
                                    const struct addrinfo *, ws_gai_async_cb, void *);

static int32_t ws_gai_async(void *port, const char *node, const char *service,
                            const struct addrinfo *hints,
                            ws_gai_async_cb callback, void *context) {
    char target[256];
    ws_trace_lookup(node, ws_host_matches(node));
    if (ws_host_matches(node)) {
        ws_note_lookup(node);
        ws_copy_target(target, sizeof target);
        node = target;
    }
    return ws_orig_gai_async(port, node, service, hints, callback, context);
}

#pragma mark - DNSServiceGetAddrInfo (mDNSResponder path)

typedef int32_t (*ws_dnssd_fn)(void *, uint32_t, uint32_t, uint32_t,
                               const char *, void *, void *);
static ws_dnssd_fn ws_orig_dnssd;

static int32_t ws_dnssd(void *sdRef, uint32_t flags, uint32_t interfaceIndex,
                        uint32_t protocol, const char *hostname,
                        void *callback, void *context) {
    char target[256];
    ws_trace_lookup(hostname, ws_host_matches(hostname));
    if (ws_host_matches(hostname)) {
        ws_note_lookup(hostname);
        ws_copy_target(target, sizeof target);
        hostname = target;
    }
    return ws_orig_dnssd(sdRef, flags, interfaceIndex, protocol, hostname,
                         callback, context);
}

#pragma mark - connect (443 -> the port we could actually bind)

/// Rewrites a loopback address on the client's port to the port the embedded
/// server could actually bind. Returns YES when it changed something.
/// 443 -> the TLS port, 80 -> the plain one. The client's RPC is https but
/// its SSO was patched to http, so both have to land somewhere.
static uint16_t ws_target_for_port(uint16_t port) {
    if (port == 443) return (uint16_t)atomic_load(&gLocalPort);
    if (port == 80) return (uint16_t)atomic_load(&gPlainPort);
    return 0;
}

/// Is this connection heading for the host we redirect to? Loopback when the
/// server is embedded; the Mac's address when it is not. Anything else is
/// somebody else's traffic and must be left alone.
static BOOL ws_is_target_v4(const struct sockaddr_in *in) {
    os_unfair_lock_lock(&gTargetLock);
    BOOL haveLiteral = gTargetV4Valid;
    struct in_addr literal = gTargetV4;
    os_unfair_lock_unlock(&gTargetLock);
    if (haveLiteral) return in->sin_addr.s_addr == literal.s_addr;
    // A target we could not parse as a literal (a hostname) resolves through
    // the getaddrinfo hook, so we cannot match it here -- fall back to
    // loopback, which is the embedded case.
    return in->sin_addr.s_addr == htonl(INADDR_LOOPBACK);
}

static BOOL ws_rewrite_port(const struct sockaddr *addr, socklen_t len,
                            struct sockaddr_storage *out, socklen_t *outLen) {
    if (!atomic_load(&gEnabled) || !addr) return NO;

    if (addr->sa_family == AF_INET && len >= (socklen_t)sizeof(struct sockaddr_in)) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        uint16_t target = ws_target_for_port(ntohs(in->sin_port));
        if (ws_is_target_v4(in) && target &&
            target != ntohs(in->sin_port)) {
            memcpy(out, in, sizeof *in);
            ((struct sockaddr_in *)out)->sin_port = htons(target);
            *outLen = sizeof(struct sockaddr_in);
            return YES;
        }
    } else if (addr->sa_family == AF_INET6 && len >= (socklen_t)sizeof(struct sockaddr_in6)) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        uint16_t target = ws_target_for_port(ntohs(in6->sin6_port));
        if (IN6_IS_ADDR_LOOPBACK(&in6->sin6_addr) && target &&
            target != ntohs(in6->sin6_port)) {
            memcpy(out, in6, sizeof *in6);
            ((struct sockaddr_in6 *)out)->sin6_port = htons(target);
            *outLen = sizeof(struct sockaddr_in6);
            return YES;
        }
    }
    return NO;
}

/// Every outbound connection, for the first few. Silence here means the
/// traffic is leaving from another process (WebKit has its own), which needs
/// a completely different fix from a hook that is simply on the wrong symbol.
static void ws_trace_connect(const char *via, const struct sockaddr *addr,
                             BOOL rewritten) {
    static atomic_ulong seen = 0;
    if (atomic_fetch_add(&seen, 1) >= 40 || !addr) return;
    char text[INET6_ADDRSTRLEN] = "?";
    uint16_t port = 0;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *in = (const struct sockaddr_in *)addr;
        inet_ntop(AF_INET, &in->sin_addr, text, sizeof text);
        port = ntohs(in->sin_port);
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *in6 = (const struct sockaddr_in6 *)addr;
        inet_ntop(AF_INET6, &in6->sin6_addr, text, sizeof text);
        port = ntohs(in6->sin6_port);
    }
    WSLog(@"net", @"%s %s:%u%s", via, text, (unsigned)port,
          rewritten ? " (port rewritten)" : "");
}

static int (*ws_orig_connect)(int, const struct sockaddr *, socklen_t);

static int ws_connect(int fd, const struct sockaddr *addr, socklen_t len) {
    struct sockaddr_storage rewritten;
    socklen_t rewrittenLen = 0;
    if (ws_rewrite_port(addr, len, &rewritten, &rewrittenLen)) {
        ws_trace_connect("connect", addr, YES);
        atomic_fetch_add(&gConnections, 1);
        return ws_orig_connect(fd, (const struct sockaddr *)&rewritten, rewrittenLen);
    }
    ws_trace_connect("connect", addr, NO);
    return ws_orig_connect(fd, addr, len);
}

// connectx() is what Apple's own networking stack calls; plain connect() only
// catches code using the classic BSD path. Hooking one and not the other is
// how a redirect can look installed and still never fire.
typedef struct {
    const struct sockaddr *sae_srcaddr;
    socklen_t sae_srcaddrlen;
    const struct sockaddr *sae_dstaddr;
    socklen_t sae_dstaddrlen;
} ws_sa_endpoints_t;

static int (*ws_orig_connectx)(int, const ws_sa_endpoints_t *, uint32_t, unsigned int,
                               const struct iovec *, unsigned int, size_t *, uint32_t *);

static int ws_connectx(int fd, const ws_sa_endpoints_t *endpoints, uint32_t associd,
                       unsigned int flags, const struct iovec *iov, unsigned int iovcnt,
                       size_t *len, uint32_t *connid) {
    if (endpoints && endpoints->sae_dstaddr) {
        struct sockaddr_storage rewritten;
        socklen_t rewrittenLen = 0;
        if (ws_rewrite_port(endpoints->sae_dstaddr, endpoints->sae_dstaddrlen,
                            &rewritten, &rewrittenLen)) {
            ws_trace_connect("connectx", endpoints->sae_dstaddr, YES);
            ws_sa_endpoints_t copy = *endpoints;
            copy.sae_dstaddr = (const struct sockaddr *)&rewritten;
            copy.sae_dstaddrlen = rewrittenLen;
            atomic_fetch_add(&gConnections, 1);
            return ws_orig_connectx(fd, &copy, associd, flags, iov, iovcnt, len, connid);
        }
        ws_trace_connect("connectx", endpoints->sae_dstaddr, NO);
    }
    return ws_orig_connectx(fd, endpoints, associd, flags, iov, iovcnt, len, connid);
}

#pragma mark -

@implementation WSNetRedirect

+ (NSArray<NSString *> *)hostnames {
    os_unfair_lock_lock(&gHostLock);
    NSArray *copy = gHostnames ?: @[];
    os_unfair_lock_unlock(&gHostLock);
    return copy;
}

+ (void)setHostnames:(NSArray<NSString *> *)hostnames {
    os_unfair_lock_lock(&gHostLock);
    gHostnames = [hostnames copy];
    os_unfair_lock_unlock(&gHostLock);
}

+ (NSString *)targetHost {
    os_unfair_lock_lock(&gTargetLock);
    NSString *host = @(gTargetHost);
    os_unfair_lock_unlock(&gTargetLock);
    return host;
}

+ (void)setTargetHost:(NSString *)host {
    NSString *trimmed = [(host ?: @"") stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length == 0) trimmed = @"127.0.0.1";
    os_unfair_lock_lock(&gTargetLock);
    strlcpy(gTargetHost, trimmed.UTF8String, sizeof gTargetHost);
    // Remember the parsed form too: the connect hook has only a sockaddr to
    // work with and needs to know whether it is already pointed at us.
    gTargetV4Valid = inet_pton(AF_INET, gTargetHost, &gTargetV4) == 1;
    os_unfair_lock_unlock(&gTargetLock);
    WSLog(@"net", @"redirect target -> %@%@", trimmed,
          gTargetV4Valid ? @"" : @" (not an IPv4 literal)");
}

+ (uint16_t)localPort { return (uint16_t)atomic_load(&gLocalPort); }
+ (void)setLocalPort:(uint16_t)port { atomic_store(&gLocalPort, port); }

+ (uint16_t)localPlainPort { return (uint16_t)atomic_load(&gPlainPort); }
+ (void)setLocalPlainPort:(uint16_t)port { atomic_store(&gPlainPort, port); }

+ (BOOL)isEnabled { return atomic_load(&gEnabled); }
+ (void)setEnabled:(BOOL)enabled {
    atomic_store(&gEnabled, enabled);
    WSLog(@"net", @"redirect %@ (443->%u, 80->%u, %lu host patterns)",
          enabled ? @"ON" : @"off", (unsigned)self.localPort,
          (unsigned)self.localPlainPort, (unsigned long)self.hostnames.count);
}

+ (NSUInteger)redirectedLookups { return (NSUInteger)atomic_load(&gLookups); }
+ (NSUInteger)redirectedConnections { return (NSUInteger)atomic_load(&gConnections); }

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;

    // Resolve the originals BEFORE rebinding. fishhook rewrites the already
    // loaded images inside rebind_symbols(), so from that call onwards another
    // thread can be inside one of our hooks -- they must already have something
    // to forward to.
    ws_orig_getaddrinfo = dlsym(RTLD_DEFAULT, "getaddrinfo");
    ws_orig_connect = dlsym(RTLD_DEFAULT, "connect");
    ws_orig_gai_async = dlsym(RTLD_DEFAULT, "getaddrinfo_async_start");
    ws_orig_dnssd = dlsym(RTLD_DEFAULT, "DNSServiceGetAddrInfo");
    ws_orig_connectx = dlsym(RTLD_DEFAULT, "connectx");

    struct rebinding binds[] = {
        {"getaddrinfo", ws_getaddrinfo, NULL},
        {"connect", ws_connect, NULL},
        {"getaddrinfo_async_start", ws_gai_async, NULL},
        {"DNSServiceGetAddrInfo", ws_dnssd, NULL},
        {"connectx", ws_connectx, NULL},
    };
    rebind_symbols(binds, sizeof binds / sizeof binds[0]);

    WSLog(@"net", @"hooks installed (getaddrinfo=%s async=%s dnssd=%s connect=%s "
          @"connectx=%s)",
          ws_orig_getaddrinfo ? "y" : "n", ws_orig_gai_async ? "y" : "n",
          ws_orig_dnssd ? "y" : "n", ws_orig_connect ? "y" : "n",
          ws_orig_connectx ? "y" : "n");
}

@end
