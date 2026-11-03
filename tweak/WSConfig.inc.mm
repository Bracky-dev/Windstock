// ---------------------------------------------------------------- mods config
//
// The launcher writes the mods menu out as JSON into the guest's container, and
// the tweak reads it once, here, at constructor time. Before the launcher
// existed every feature was a compile-time #define; those are still the master
// switches (a feature compiled out stays out), but anything compiled in can now
// be turned off per-run without a rebuild.
//
// Deliberately forgiving: no file, unreadable file, malformed JSON or a missing
// key all mean "use the built-in default", which is the behaviour this tweak
// had before the config existed. A mods menu that fails to load must never be
// the reason the game stops working.

static NSDictionary *ws_cfg_root(void) {
    static NSDictionary *cfg = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path = [NSHomeDirectory()
            stringByAppendingPathComponent:@"Documents/windstock-mods.json"];
        NSData *data = [NSData dataWithContentsOfFile:path];
        if (!data) {
            WLOG(@"config: no windstock-mods.json at %@ -- built-in defaults", path);
            cfg = @{};
            return;
        }
        NSError *err = nil;
        id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
        if (![parsed isKindOfClass:[NSDictionary class]]) {
            WLOG(@"config: %@ is not usable (%@) -- built-in defaults",
                 path.lastPathComponent, err.localizedDescription ?: @"not an object");
            cfg = @{};
            return;
        }
        cfg = parsed;
        WLOG(@"config: loaded %@", path);
    });
    return cfg;
}

static NSDictionary *ws_cfg_section(NSString *name) {
    id section = ws_cfg_root()[name];
    return [section isKindOfClass:[NSDictionary class]] ? section : @{};
}

/// Is a mod switched on? `fallback` is what the tweak did before the launcher.
static bool ws_mod(NSString *key, bool fallback) {
    id v = ws_cfg_section(@"mods")[key];
    bool on = [v isKindOfClass:[NSNumber class]] ? [v boolValue] : fallback;
    static NSMutableSet *logged = nil;
    if (!logged) logged = [NSMutableSet set];
    if (![logged containsObject:key]) {
        [logged addObject:key];
        WLOG(@"config: %@ = %s%s", key, on ? "on" : "off",
             [v isKindOfClass:[NSNumber class]] ? "" : " (default)");
    }
    return on;
}

/// A tunable number from the "values" section.
static double ws_value(NSString *key, double fallback) {
    id v = ws_cfg_section(@"values")[key];
    return [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : fallback;
}

__attribute__((unused))
static NSString *ws_text(NSString *key, NSString *fallback) {
    id v = ws_cfg_section(@"values")[key];
    return [v isKindOfClass:[NSString class]] ? v : fallback;
}

/// v152: where web views go when the server is NOT on this phone. The launcher's
/// "Windstock Online" mode writes {"web": "http://ip:port"}; nil = the embedded
/// server on loopback. Web views network out of process, so the launcher's
/// in-app redirect never sees them -- they need the real address.
static NSString *ws_web_base(void) {
    id v = ws_cfg_root()[@"web"];
    return ([v isKindOfClass:[NSString class]] && [v length]) ? v : nil;
}

/// A loopback plain-listener URL (http://127.0.0.1:8080/...) moved to the online
/// server when there is one; anything else comes back unchanged.
static NSURL *ws_web_rebase(NSURL *url) {
    NSString *base = ws_web_base();
    if (!base || !url) return url;
    if (![url.host isEqualToString:@"127.0.0.1"] || url.port.intValue != 8080) return url;
    NSURLComponents *to = [NSURLComponents componentsWithString:base];
    NSURLComponents *c = [NSURLComponents componentsWithURL:url resolvingAgainstBaseURL:NO];
    if (!to.host || !c) return url;
    c.scheme = to.scheme ?: @"http";
    c.host = to.host;
    c.port = to.port;
    return c.URL ?: url;
}
