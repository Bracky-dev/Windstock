//  WSURLProtocol.h -- send the client's HTTPS traffic to the local server.
//
//  The getaddrinfo/connect hooks catch code that resolves names itself, which
//  is what il2cpp and mono do. They catch nothing from NSURLSession: modern
//  CFNetwork resolves through Network.framework, which asks mDNSResponder over
//  XPC and never calls getaddrinfo in this process. Measured on device -- with
//  the game running and trying to log in, the hooks logged zero lookups and
//  the server saw zero requests.
//
//  So this intercepts a level up, where the request is still a URL. It also
//  removes the need to trust the server's CA: the connection to 127.0.0.1 is
//  made by us, so we can accept the certificate ourselves.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WSURLProtocol : NSURLProtocol

/// Hostnames to send to the local server; same patterns as WSNetRedirect.
@property (class, copy) NSArray<NSString *> *hostnames;
/// Hostnames to pass through UNCHANGED, logging status and size. For traffic
/// we do not serve but need to see the outcome of -- the Google map tiles.
@property (class, copy) NSArray<NSString *> *observeHostnames;
/// Where matching requests are sent: "127.0.0.1", or the Mac's address.
@property (class, copy) NSString *targetHost;
/// Ports the server listens on: TLS and plain.
@property (class) uint16_t localPort;
@property (class) uint16_t localPlainPort;
@property (class, getter=isEnabled) BOOL enabled;

/// Registers the protocol and makes NSURLSession's default configurations use
/// it -- +registerClass alone only covers the shared session.
+ (void)install;

/// How many requests have been rerouted, for the server screen.
@property (class, readonly) NSUInteger interceptedCount;

@end

NS_ASSUME_NONNULL_END
