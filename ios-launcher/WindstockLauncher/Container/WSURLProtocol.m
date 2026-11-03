#import "WSURLProtocol.h"
#import "WSLog.h"
#import "WSPaths.h"

#import <Security/Security.h>
#import <objc/runtime.h>

static NSArray<NSString *> *gHostnames = nil;
static NSString *gTargetHost = @"127.0.0.1";
static NSArray<NSString *> *gObserve = nil;
static uint16_t gPort = 0;
static uint16_t gPlainPort = 0;
static BOOL gEnabled = NO;
static NSUInteger gCount = 0;
static BOOL gInstalled = NO;
/// Marks a request we have already rewritten, so it is not caught again.
static NSString *const kHandled = @"WSURLProtocolHandled";

#pragma mark - session configuration swizzle

// +registerClass: only affects +[NSURLSession sharedSession] and
// NSURLConnection. Anything built from a fresh configuration -- which is most
// code -- ignores it unless the class is in protocolClasses, so the two
// configuration factories are swizzled to add it.
static NSURLSessionConfiguration *ws_inject(NSURLSessionConfiguration *configuration) {
    if (!configuration) return configuration;
    NSMutableArray *classes =
        [NSMutableArray arrayWithArray:configuration.protocolClasses ?: @[]];
    Class protocolClass = NSClassFromString(@"WSURLProtocol");
    if (protocolClass && ![classes containsObject:protocolClass]) {
        [classes insertObject:protocolClass atIndex:0];
        configuration.protocolClasses = classes;
    }
    return configuration;
}

static NSURLSessionConfiguration *(*ws_orig_default)(id, SEL);
static NSURLSessionConfiguration *(*ws_orig_ephemeral)(id, SEL);

static NSURLSessionConfiguration *ws_default_configuration(id self, SEL _cmd) {
    return ws_inject(ws_orig_default(self, _cmd));
}

static NSURLSessionConfiguration *ws_ephemeral_configuration(id self, SEL _cmd) {
    return ws_inject(ws_orig_ephemeral(self, _cmd));
}

static void ws_swizzle_configurations(void) {
    Method defaultMethod = class_getClassMethod(NSURLSessionConfiguration.class,
                                                @selector(defaultSessionConfiguration));
    if (defaultMethod) {
        ws_orig_default = (void *)method_setImplementation(defaultMethod,
                                                           (IMP)ws_default_configuration);
    }
    Method ephemeralMethod = class_getClassMethod(NSURLSessionConfiguration.class,
                                                  @selector(ephemeralSessionConfiguration));
    if (ephemeralMethod) {
        ws_orig_ephemeral = (void *)method_setImplementation(ephemeralMethod,
                                                             (IMP)ws_ephemeral_configuration);
    }
}

#pragma mark -

@interface WSURLProtocol () <NSURLSessionDataDelegate>
@property (nonatomic, strong) NSURLSessionDataTask *task;
@property (nonatomic, strong) NSURLSession *session;
/// Passing through untouched and only reporting the outcome.
@property (nonatomic, assign) BOOL observing;
@property (nonatomic, assign) long long observedBytes;
/// Map tiles only: the request body and Google's answer, kept so they can be saved
/// (ws_capture_tile) and decoded on the Mac -- to see what the live tiles contain.
@property (nonatomic, strong) NSData *capturedRequest;
@property (nonatomic, strong) NSMutableData *capturedResponse;
@end

// Saves up to 40 map-tile exchanges to Documents/Windstock/gmm/<ms>-<n>.req / .resp.
// Streets show but water doesn't (2026-09-25); these are what tell us why.
static void ws_capture_tile(NSData *request, NSData *response) {
    static int saved = 0;
    if (saved >= 40 || !response.length) return;
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    NSString *dir = [docs stringByAppendingPathComponent:@"Windstock/gmm"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES
                                               attributes:nil error:nil];
    NSString *stem = [dir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"%lld-%02d", (long long)(NSDate.date.timeIntervalSince1970 * 1000), saved]];
    [request ?: [NSData data] writeToFile:[stem stringByAppendingString:@".req"] atomically:YES];
    [response writeToFile:[stem stringByAppendingString:@".resp"] atomically:YES];
    saved++;
    WSLog(@"net", @"saved map tile exchange %d (%lu B request, %lu B answer)", saved,
          (unsigned long)request.length, (unsigned long)response.length);
}

static BOOL ws_is_map_tiles(NSURL *url) {
    return [url.host.lowercaseString isEqualToString:@"mobilemaps.clients.google.com"];
}

@implementation WSURLProtocol

+ (NSArray<NSString *> *)hostnames { return gHostnames ?: @[]; }
+ (void)setHostnames:(NSArray<NSString *> *)hostnames { gHostnames = [hostnames copy]; }
+ (NSString *)targetHost { return gTargetHost ?: @"127.0.0.1"; }

+ (void)setTargetHost:(NSString *)host {
    NSString *trimmed = [(host ?: @"") stringByTrimmingCharactersInSet:
                         NSCharacterSet.whitespaceAndNewlineCharacterSet];
    gTargetHost = trimmed.length ? [trimmed copy] : @"127.0.0.1";
}

+ (uint16_t)localPort { return gPort; }
+ (void)setLocalPort:(uint16_t)port { gPort = port; }
+ (uint16_t)localPlainPort { return gPlainPort; }
+ (void)setLocalPlainPort:(uint16_t)port { gPlainPort = port; }
+ (BOOL)isEnabled { return gEnabled; }
+ (void)setEnabled:(BOOL)enabled { gEnabled = enabled; }
+ (NSUInteger)interceptedCount { return gCount; }

+ (void)install {
    if (gInstalled) return;
    gInstalled = YES;
    [NSURLProtocol registerClass:self];
    ws_swizzle_configurations();
    WSLog(@"net", @"URL interception installed");
}

#pragma mark - matching

+ (NSArray<NSString *> *)observeHostnames { return gObserve ?: @[]; }
+ (void)setObserveHostnames:(NSArray<NSString *> *)names { gObserve = [names copy]; }

/// Pass through untouched, but report what came back. The map tiles are the
/// case this exists for: the launcher must not answer them, and "[pass]" on
/// its own never told us whether Google said yes.
+ (BOOL)shouldObserveHost:(NSString *)host {
    if (host.length == 0) return NO;
    NSString *lower = host.lowercaseString;
    for (NSString *raw in gObserve) {
        NSString *pattern = raw.lowercaseString;
        if ([pattern hasPrefix:@"*."]) {
            if ([lower hasSuffix:[pattern substringFromIndex:1]]) return YES;
            if ([lower isEqualToString:[pattern substringFromIndex:2]]) return YES;
        } else if ([lower isEqualToString:pattern]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)shouldHandleHost:(NSString *)host {
    if (!gEnabled || gPort == 0 || host.length == 0) return NO;
    NSString *lower = host.lowercaseString;
    for (NSString *raw in gHostnames) {
        NSString *pattern = raw.lowercaseString;
        if ([pattern hasPrefix:@"*."]) {
            if ([lower hasSuffix:[pattern substringFromIndex:1]]) return YES;
            if ([lower isEqualToString:[pattern substringFromIndex:2]]) return YES;
        } else if ([lower isEqualToString:pattern]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
    if ([NSURLProtocol propertyForKey:kHandled inRequest:request]) return NO;
    NSString *scheme = request.URL.scheme.lowercaseString;
    if (![scheme isEqualToString:@"https"] && ![scheme isEqualToString:@"http"]) return NO;
    BOOL handle = [self shouldHandleHost:request.URL.host];
    BOOL observe = !handle && [self shouldObserveHost:request.URL.host];
    static NSUInteger seen = 0;
    if (seen++ < 40) {
        WSLog(@"net", @"saw %@ %@",
              handle ? @"[intercept]" : (observe ? @"[observe]" : @"[pass]"),
              request.URL.absoluteString);
    }
    return handle || observe;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }

#pragma mark - loading

- (void)startLoading {
    NSURL *original = self.request.URL;
    NSURLComponents *components = [NSURLComponents componentsWithURL:original
                                             resolvingAgainstBaseURL:NO];
    // Keep the scheme the client chose: its SSO is patched to plain http and
    // the server has a separate listener for that. Forcing https here sends
    // an http request into a TLS socket and it simply fails.
    BOOL secure = [original.scheme.lowercaseString isEqualToString:@"https"];
    NSString *target = gTargetHost ?: @"127.0.0.1";
    self.observing = [[self class] shouldObserveHost:original.host]
                     && ![[self class] shouldHandleHost:original.host];

    NSMutableURLRequest *rewritten = [self.request mutableCopy];
    if (self.observing && ws_is_map_tiles(original)) {
        // NSURLProtocol usually hands the body over as a stream; read it once, keep a
        // copy, and send it on as plain data so the request is unchanged
        NSData *body = self.request.HTTPBody;
        if (!body && self.request.HTTPBodyStream) {
            NSInputStream *in = self.request.HTTPBodyStream;
            NSMutableData *buf = [NSMutableData data];
            uint8_t chunk[16384];
            [in open];
            NSInteger n;
            while ((n = [in read:chunk maxLength:sizeof chunk]) > 0) [buf appendBytes:chunk length:(NSUInteger)n];
            [in close];
            body = buf;
            rewritten.HTTPBodyStream = nil;
            rewritten.HTTPBody = body;
        }
        self.capturedRequest = body;
        self.capturedResponse = [NSMutableData data];
    }
    if (self.observing) {
        // Untouched: same host, same port. We are here only to see the answer.
        WSLog(@"net", @"%@ %@ (observing)", self.request.HTTPMethod ?: @"GET",
              original.absoluteString);
    } else {
        components.host = target;
        components.scheme = secure ? @"https" : @"http";
        components.port = @(secure ? gPort : gPlainPort);
        rewritten.URL = components.URL;
        // The server routes on the Host header, so it has to keep saying what
        // the client originally asked for.
        [rewritten setValue:original.host forHTTPHeaderField:@"Host"];
        gCount++;
        WSLog(@"net", @"%@ %@ -> %@:%u", self.request.HTTPMethod ?: @"GET",
              original.absoluteString, target, (unsigned)(secure ? gPort : gPlainPort));
    }
    [NSURLProtocol setProperty:@YES forKey:kHandled inRequest:rewritten];

    NSURLSessionConfiguration *configuration =
        [NSURLSessionConfiguration ephemeralSessionConfiguration];
    configuration.protocolClasses = @[];        // no recursion
    self.session = [NSURLSession sessionWithConfiguration:configuration
                                                 delegate:self
                                            delegateQueue:nil];
    self.task = [self.session dataTaskWithRequest:rewritten];
    [self.task resume];
}

- (void)stopLoading {
    [self.task cancel];
    [self.session invalidateAndCancel];
    self.task = nil;
    self.session = nil;
}

#pragma mark - NSURLSessionDataDelegate

// The project's CA, read from the bundled PythonServer/certs/ca.crt (PEM).
// nil if the bundle has none, in which case only system trust applies.
static SecCertificateRef ws_bundled_ca(void) {
    static SecCertificateRef ca = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [WSPaths.pythonServerDir
            stringByAppendingPathComponent:@"certs/ca.crt"];
        NSString *pem = [NSString stringWithContentsOfFile:path
                                                  encoding:NSASCIIStringEncoding
                                                     error:NULL];
        NSMutableString *body = [NSMutableString string];
        for (NSString *line in [pem componentsSeparatedByCharactersInSet:
                                    NSCharacterSet.newlineCharacterSet]) {
            if (![line hasPrefix:@"-----"]) [body appendString:line];
        }
        NSData *der = body.length
            ? [[NSData alloc] initWithBase64EncodedString:body
                  options:NSDataBase64DecodingIgnoreUnknownCharacters]
            : nil;
        if (der) ca = SecCertificateCreateWithData(NULL, (__bridge CFDataRef)der);
        WSLog(@"net", ca ? @"server CA loaded from the bundle"
                         : @"no usable certs/ca.crt in the bundle -- system trust only");
    });
    return ca;
}

// We are the ones dialling the server, so we decide what to trust: a chain
// that ends at the CA shipped in the bundle, or at anything the device already
// trusts (so a Mac server with its own CA still works once that CA's profile
// is installed). Accepting the bundled CA here is what removes the "install
// the CA profile" step. The hostname is deliberately not checked -- we dialled
// this address ourselves, and the certificate names Niantic's hosts, not the
// loopback or LAN address, nor Google's map-tile host when tiles are served.
- (void)URLSession:(NSURLSession *)session
didReceiveChallenge:(NSURLAuthenticationChallenge *)challenge
 completionHandler:(void (^)(NSURLSessionAuthChallengeDisposition, NSURLCredential *))handler {
    SecTrustRef trust = challenge.protectionSpace.serverTrust;
    if (![challenge.protectionSpace.authenticationMethod
            isEqualToString:NSURLAuthenticationMethodServerTrust]
        || ![challenge.protectionSpace.host
                isEqualToString:(gTargetHost ?: @"127.0.0.1")]
        || trust == NULL) {
        handler(NSURLSessionAuthChallengePerformDefaultHandling, nil);
        return;
    }

    SecPolicyRef policy = SecPolicyCreateSSL(true, NULL);
    SecTrustSetPolicies(trust, policy);
    CFRelease(policy);
    SecCertificateRef ca = ws_bundled_ca();
    if (ca) {
        SecTrustSetAnchorCertificates(trust, (__bridge CFArrayRef)@[(__bridge id)ca]);
        SecTrustSetAnchorCertificatesOnly(trust, false);
    }

    CFErrorRef error = NULL;
    if (SecTrustEvaluateWithError(trust, &error)) {
        handler(NSURLSessionAuthChallengeUseCredential,
                [NSURLCredential credentialForTrust:trust]);
        return;
    }
    WSLog(@"net", @"refused %@'s certificate: %@", challenge.protectionSpace.host,
          ((__bridge NSError *)error).localizedDescription ?: @"not trusted");
    if (error) CFRelease(error);
    handler(NSURLSessionAuthChallengeCancelAuthenticationChallenge, nil);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
didReceiveResponse:(NSURLResponse *)response
 completionHandler:(void (^)(NSURLSessionResponseDisposition))handler {
    if (self.observing && [response isKindOfClass:NSHTTPURLResponse.class]) {
        NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
        WSLog(@"net", @"observed %ld %@ (%@)", (long)http.statusCode,
              task.originalRequest.URL.host ?: @"?",
              http.allHeaderFields[@"Content-Type"] ?: @"no content-type");
    }
    [self.client URLProtocol:self didReceiveResponse:response
          cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    handler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    if (self.observing) self.observedBytes += (long long)data.length;
    [self.capturedResponse appendData:data];
    [self.client URLProtocol:self didLoadData:data];
}

- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (error) {
        WSLog(@"net", @"request failed: %@%@", error.localizedDescription,
              self.observing ? @" (observed)" : @"");
        [self.client URLProtocol:self didFailWithError:error];
    } else {
        if (self.observing) {
            WSLog(@"net", @"observed body %lld bytes from %@", self.observedBytes,
                  task.originalRequest.URL.host ?: @"?");
        }
        if (self.capturedResponse) ws_capture_tile(self.capturedRequest, self.capturedResponse);
        [self.client URLProtocolDidFinishLoading:self];
    }
}

@end
