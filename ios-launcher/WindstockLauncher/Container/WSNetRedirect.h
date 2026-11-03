//  WSNetRedirect.h -- make the game's hardcoded Niantic hostnames land on the
//  server running inside this same app.
//
//  There is no DNS profile and no VPN here, so the redirect has to happen in
//  process. Two things have to be bent:
//
//    * name resolution -- pgorelease.nianticlabs.com must answer 127.0.0.1;
//    * the port -- the client dials 443, which an unprivileged app cannot bind,
//      so loopback connections to 443 are rewritten to the port the embedded
//      server actually listens on.
//
//  The hooks are installed process-wide rather than only in the guest image.
//  il2cpp's socket code lives in the guest binary, but anything the client
//  routes through NSURLSession resolves inside CFNetwork, and only a global
//  rebind catches both. Non-matching hostnames are passed straight through.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WSNetRedirect : NSObject

/// Hostname patterns to send to loopback. "*.nianticlabs.com" matches any
/// subdomain; anything else is an exact, case-insensitive match.
@property (class, copy) NSArray<NSString *> *hostnames;

/// Where matching hostnames are sent. "127.0.0.1" for the embedded server;
/// a LAN or Tailscale address when the server runs on a Mac. Remote mode used
/// to switch these hooks OFF and assume a DNS profile or a VPN was doing the
/// job -- on iOS nothing is, which is why hosting on the Mac never worked.
@property (class, copy) NSString *targetHost;

/// The TLS port the server listens on; :443 is sent here. Equal ports mean no
/// rewrite, which is the normal case for a Mac that can bind 443.
@property (class) uint16_t localPort;

/// The plain-HTTP port; loopback :80 is sent here. The client's SSO is
/// patched to use http, so both mappings are needed.
@property (class) uint16_t localPlainPort;

/// Master switch -- off while the server is stopped, so the client falls back
/// to whatever DNS redirect the user already has.
@property (class, getter=isEnabled) BOOL enabled;

/// Installs the symbol rebinds. Idempotent; call once at startup.
+ (void)install;

/// How many lookups have been redirected -- shown in the server screen so a
/// "nothing happens" report can be told apart from "the client never asked".
@property (class, readonly) NSUInteger redirectedLookups;
@property (class, readonly) NSUInteger redirectedConnections;

@end

NS_ASSUME_NONNULL_END
