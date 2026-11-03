// ----------------------------------------------------------------- Research (v66)
// Field Research (TODAY tab, with the 7-stamp Research Breakthrough), Special Research
// (SPECIAL tab) and Timed Research (its own tab while one runs) -- none of which exist in
// 0.35, so the screens are UIKit drawn over the Unity view and the server (research.py)
// does the counting and the rewards.
//
// The binoculars and Hub buttons are Unity UI on the Nearby box (v177, built into
// sharedassets0 by work/tools/research_buttons.py), so they come and go with Nearby and sit
// under the game's own menus; the tweak switches them on at level 5 and takes their taps.
// Art (official research icons, the game's Lato font, Pokemon icons) comes from the server.
#define RESEARCH 1
#ifdef RS_HOST_OVERRIDE                       // the Simulator harness points this at a local shim
#define RS_HOST RS_HOST_OVERRIDE
#else
#define RS_HOST @"https://pgorelease.nianticlabs.com"
#endif
// The embedded server's plain-HTTP listener, dialled directly -- see rs_map_view.
#ifndef RS_MAP_URL
#define RS_MAP_URL @"http://127.0.0.1:8080/research/map"
#endif

#if RESEARCH
#import <CoreText/CoreText.h>
#import <WebKit/WebKit.h>   // the Radar tab is the server's map page

static bool RS_stamp_pending = false;  // v180: a stamp was earned while Research was shut
static int FR_requests = 0;             // v186: friend requests waiting (the FRIENDS tab's dot)
static void fr_tick(UIView *parent);
static void fr_open(void);              // v187: the profile menu's FRIENDS entry
static void rs_sfx_modern(const char *name);
static int RS_peek_from = -1;            // v183: mid-drag between tabs: the tab we came from
static UIView *RS_peek_snap = nil;        //        and the picture of it
static bool RS_events_quiet = false;   // v178: Hub closing because Research opened -- no close sound
static bool RS_shown = false;     // the map buttons' spot is clear (Nearby up, nothing over it)
// The trainer's level, from the server. Research and the Windstock Hub unlock at 5, like the
// game's own feature gates -- until the first ping answers we keep both buttons hidden.
static int RS_level = 0;
#define RS_UNLOCK_LEVEL 5
static UIView *RS_screen = nil;
static UIScrollView *RS_scroll = nil;
static UIStackView *RS_stack = nil;
static UIStackView *RS_tabs = nil;
static NSDictionary *RS_state = nil;
static NSData *RS_state_raw = nil;
static NSTimeInterval RS_state_rx = 0;
static int RS_tab = 0;                    // 0 today, 1 special, 2 timed
static bool RS_busy = false;
static NSMutableDictionary<NSString *, UIImage *> *RS_images = nil;
static NSMutableDictionary<NSString *, NSMutableArray<UIImageView *> *> *RS_waiting = nil;
static bool RS_fonts = false;

static void rs_render(void);
static void rs_fetch(bool force);
static void rs_events_close(void);
static void rs_events_open(void);
static UIView *rs_events_prepare(void);
static UIView *rs_research_prepare(void);
static void rs_swap_to_hub(void);
static void rs_swap_to_research(void);
static UIView *rs_peek_to(int to);
static void rs_peek_end(bool keep);
static void rs_hub_drag_cancel(void);

// ---- look
static UIColor *rs_rgb(int hex) {
    return [UIColor colorWithRed:((hex >> 16) & 0xFF) / 255.0 green:((hex >> 8) & 0xFF) / 255.0
                            blue:(hex & 0xFF) / 255.0 alpha:1];
}
static UIColor *rs_ink(void)   { return rs_rgb(0x2E5C66); }   // card text
static UIColor *rs_ink2(void)  { return rs_rgb(0x8AA6AC); }
static UIColor *rs_green(void) { return rs_rgb(0x4CC7A0); }
static UIColor *rs_teal(void)  { return rs_rgb(0x2E93A8); }   // selected tab pill, progress fill
static UIColor *rs_gold(void)  { return rs_rgb(0xD6A93B); }   // task card edge

static UIFont *rs_font(CGFloat size, bool bold) {
    UIFont *f = RS_fonts ? [UIFont fontWithName:(bold ? @"Lato-Bold" : @"Lato-Regular") size:size] : nil;
    if (f) return f;
    UIFont *sys = [UIFont systemFontOfSize:size weight:bold ? UIFontWeightBold : UIFontWeightRegular];
    return ws_rounded(sys, size);
}

static UILabel *rs_label(NSString *text, CGFloat size, bool bold, UIColor *color) {
    UILabel *l = [UILabel new];
    l.text = text;
    l.font = rs_font(size, bold);
    l.textColor = color;
    l.numberOfLines = 0;
    return l;
}

static UIView *rs_card(void) {
    UIView *c = [UIView new];
    c.backgroundColor = UIColor.whiteColor;
    c.layer.cornerRadius = 16;
    c.layer.shadowColor = rs_rgb(0x2E5E5A).CGColor;
    c.layer.shadowOpacity = 0.14;
    c.layer.shadowRadius = 8;
    c.layer.shadowOffset = CGSizeMake(0, 3);
    return c;
}

static void rs_pin(UIView *v, UIView *in, UIEdgeInsets e) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [v.topAnchor constraintEqualToAnchor:in.topAnchor constant:e.top],
        [v.bottomAnchor constraintEqualToAnchor:in.bottomAnchor constant:-e.bottom],
        [v.leadingAnchor constraintEqualToAnchor:in.leadingAnchor constant:e.left],
        [v.trailingAnchor constraintEqualToAnchor:in.trailingAnchor constant:-e.right]]];
}

static UIStackView *rs_hstack(NSArray *views, CGFloat spacing) {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisHorizontal;
    s.spacing = spacing;
    s.alignment = UIStackViewAlignmentCenter;
    return s;
}

static UIStackView *rs_vstack(NSArray *views, CGFloat spacing) {
    UIStackView *s = [[UIStackView alloc] initWithArrangedSubviews:views];
    s.axis = UILayoutConstraintAxisVertical;
    s.spacing = spacing;
    return s;
}

static void rs_size(UIView *v, CGFloat w, CGFloat h) {
    v.translatesAutoresizingMaskIntoConstraints = NO;
    if (w > 0) [v.widthAnchor constraintEqualToConstant:w].active = YES;
    if (h > 0) [v.heightAnchor constraintEqualToConstant:h].active = YES;
}

// A tap on any view runs a block.
@interface WSResearchTap : NSObject
@property (nonatomic, copy) void (^block)(void);
- (void)fire:(UITapGestureRecognizer *)g;
@end
@implementation WSResearchTap
- (void)fire:(UITapGestureRecognizer *)g { if (self.block) self.block(); }
@end
// v179: a horizontal DRAG between pages. The page follows the finger and only turns once it
// has been dragged at least half the screen across; let go before that and it springs back
// (v178 used swipe recognisers, which fired on the smallest flick). Vertical drags are left to
// the screen's scroll view: it waits for this to fail, which it does at once on a vertical move.
// v182: easier -- a third of the width, or a quick flick that covers at least 15% of it
#define RS_DRAG_COMMIT 0.33                        // of the page width
#define RS_DRAG_FLICK_MIN 0.15                     // of the page width, for a flick
#define RS_DRAG_FLICK_SPEED 700                    // pt/s the finger is moving when it lets go
// v183: a pager -- the next page is RIGHT THERE beside the current one and comes in with the
// finger (v179-v182 moved the old page alone and slid the new one in from a page away after).
// begin(dir) sets the drag up for a direction and returns @[outgoing, incoming] (incoming may
// be missing: nothing that way, rubber-band); cancel(dir) undoes it when the finger lets go
// short or crosses back; commit(dir) makes it stick once the slide has finished.
@interface WSResearchDrag : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, copy) NSArray<UIView *> *(^begin)(int dir);
@property (nonatomic, copy) void (^cancel)(int dir, bool finished);   // finished: the finger is off
@property (nonatomic, copy) void (^commit)(int dir);
@property (nonatomic, strong) UIView *cur, *peer;
@property (nonatomic) int curDir;
- (void)pan:(UIPanGestureRecognizer *)g;
@end
@implementation WSResearchDrag
- (BOOL)gestureRecognizerShouldBegin:(UIGestureRecognizer *)g {
    CGPoint v = [(UIPanGestureRecognizer *)g velocityInView:g.view];
    return fabs(v.x) > fabs(v.y);
}
- (void)drop {                                   // abandon the current direction
    if (!self.curDir) return;
    self.cur.transform = CGAffineTransformIdentity;
    self.peer.transform = CGAffineTransformIdentity;
    if (self.cancel) self.cancel(self.curDir, false);
    self.cur = nil; self.peer = nil; self.curDir = 0;
}
- (void)pan:(UIPanGestureRecognizer *)g {
    CGFloat w = MAX(g.view.bounds.size.width, 1);
    CGFloat dx = [g translationInView:g.view].x;
    bool moving = g.state == UIGestureRecognizerStateBegan || g.state == UIGestureRecognizerStateChanged;
    // v184: no direction until the finger has really moved -- at Began dx can be 0, which read as
    // "right", set the wrong neighbour up and redrew twice (the lag, and a stale picture on top)
    if (moving && fabs(dx) < 2 && !self.curDir) return;
    int dir = dx < 0 ? 1 : -1;
    if (moving && dir != self.curDir && fabs(dx) >= 2) {
        [self drop];
        NSArray<UIView *> *v = self.begin ? self.begin(dir) : nil;
        if (!v.count) return;
        self.curDir = dir;
        self.cur = v[0];
        self.peer = v.count > 1 ? v[1] : nil;
    }
    UIView *c = self.cur, *in = self.peer;
    int d = self.curDir;
    if (!c) {
        if (!moving && self.cancel) self.cancel(0, true);   // let go before it ever moved
        return;
    }
    if (moving) {
        CGFloat x = in ? dx : dx / 3;               // nothing that way: rubber-band
        c.transform = CGAffineTransformMakeTranslation(x, 0);
        in.transform = CGAffineTransformMakeTranslation(x + d * w, 0);
        return;
    }
    CGFloat vx = [g velocityInView:g.view].x;
    bool flick = fabs(vx) >= RS_DRAG_FLICK_SPEED && (vx < 0) == (dx < 0) && fabs(dx) >= w * RS_DRAG_FLICK_MIN;
    bool go = g.state == UIGestureRecognizerStateEnded && in && (dx < 0) == (d > 0) &&
              (fabs(dx) >= w * RS_DRAG_COMMIT || flick);
    self.cur = nil; self.peer = nil; self.curDir = 0;
    void (^cancel)(int, bool) = self.cancel;
    void (^commit)(int) = self.commit;
    if (!go) {
        [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4
                            options:UIViewAnimationOptionBeginFromCurrentState
                         animations:^{
            c.transform = CGAffineTransformIdentity;
            in.transform = CGAffineTransformMakeTranslation(d * w, 0);
        } completion:^(BOOL f) {
            c.transform = CGAffineTransformIdentity; in.transform = CGAffineTransformIdentity;
            if (cancel) cancel(d, true);
        }];
        return;
    }
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{
        c.transform = CGAffineTransformMakeTranslation(-d * w, 0);
        in.transform = CGAffineTransformIdentity;
    } completion:^(BOOL f) {
        c.transform = CGAffineTransformIdentity;
        if (commit) commit(d);
    }];
}
@end
static void rs_on_drag(UIView *v, UIScrollView *scroll, NSArray<UIView *> *(^begin)(int dir),
                       void (^cancel)(int dir, bool finished), void (^commit)(int dir)) {
    WSResearchDrag *t = [WSResearchDrag new];
    t.begin = begin; t.cancel = cancel; t.commit = commit;
    UIPanGestureRecognizer *g = [[UIPanGestureRecognizer alloc] initWithTarget:t action:@selector(pan:)];
    g.delegate = t;
    objc_setAssociatedObject(g, "ws_drag", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    [v addGestureRecognizer:g];
    [scroll.panGestureRecognizer requireGestureRecognizerToFail:g];
}

// v178: the game's own UI sounds -- AudioSourceExt.PlayUISFX(clip) (0.35 0x206C20, 0.29
// 0x1F0910), which keeps to the Settings SFX switch and goes through the sound packs. The
// clips live in sharedassets0 and are found by name.
#define RVA_PLAY_UI_SFX   0x206C20
#define FIRST_PLAY_UI_SFX 0xa9bd57f6
#define RS_SFX_OPEN   "se_go_main_ball"         // the Poke Ball menu opening
#define RS_SFX_CLOSE  "se_go_main_ball_close"
static void *g_rs_ui_sfx = NULL;
static void rs_sfx(const char *clip_name) {
    static void *t_clip = NULL;
    if (!g_rs_ui_sfx || !g_get_name || !g_mt[MT_FIND_ALL]) return;
    if (!t_clip) t_clip = mt_type("UnityEngine.AudioClip, UnityEngine");
    if (!looks_like_ptr(t_clip)) return;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_clip, NULL);
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    for (int64_t i = 0; i < n && i < 2048; i++) {
        void *clip = *(void **)((uint8_t *)arr + OFF_ARRAY_DATA + i * 8);
        void *name = looks_like_ptr(clip) ? g_get_name(clip, NULL) : NULL;
        if (looks_like_ptr(name) && il2cpp_string_equals(name, clip_name)) {
            ((void (*)(void *, void *, bool, void *))g_rs_ui_sfx)(NULL, clip, false, NULL);
            return;
        }
    }
    static int missing = 0;
    if (missing++ < 5) WLOG(@"research: sound %s not found", clip_name);
}

// v179: the modern game's Research sounds (se_go_quests_*, taken from the 0.111 client) aren't
// in 0.35, so they ship as files in the game app (work/mods/ios-tweak-035/sounds, copied by
// embed_guest.sh) and play through AVAudioPlayer -- muted with Settings > Sound Effects like the
// game, and a sound pack's file of the same name wins.
#define RS_SFX_RESEARCH_OPEN  "se_go_quests_list"          // v181: the user's pick (quests-list.mp3)
#define RS_SFX_RESEARCH_CLOSE "se_go_quests_monitor_off"
#define RS_SFX_REWARDS        "se_go_quests_get_rewards"   // the Rewards card
#define RS_SFX_STAMP          "se_go_quests_stamp"         // a Breakthrough stamp earned
#define RS_SFX_PROGRESS       "se_go_quests_bar"           // the progress toast on the map
static void rs_sfx_modern(const char *name) {
    if (!game_pref_enabled(PREF_SFX_ENABLED)) return;
    NSURL *u = pack_clip_url(name);
    if (!u) {
        NSString *res = [NSString stringWithFormat:@"windstock_sfx_%s", name];
        for (NSString *e in @[@"mp3", @"m4a", @"wav"]) {
            NSString *p = [[NSBundle mainBundle] pathForResource:res ofType:e];
            if (p) { u = [NSURL fileURLWithPath:p]; break; }
        }
    }
    if (!u) { static int missing = 0; if (missing++ < 5) WLOG(@"research: sound %s not in the app", name); return; }
    static NSMutableArray<AVAudioPlayer *> *pool = nil;   // kept alive while they play; several may overlap
    if (!pool) pool = [NSMutableArray array];
    AVAudioPlayer *p = [[AVAudioPlayer alloc] initWithContentsOfURL:u error:nil];
    if (!p) return;
    [pool addObject:p];
    while (pool.count > 4) [pool removeObjectAtIndex:0];
    [p play];
}

static void rs_on_tap(UIView *v, void (^block)(void)) {
    WSResearchTap *t = [WSResearchTap new];
    t.block = block;
    UITapGestureRecognizer *g = [[UITapGestureRecognizer alloc] initWithTarget:t action:@selector(fire:)];
    objc_setAssociatedObject(g, "ws_tap", t, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    v.userInteractionEnabled = YES;
    [v addGestureRecognizer:g];
}

// The game's orange progress bar.
@interface WSResearchBar : UIView
@property (nonatomic) CGFloat fraction;
@property (nonatomic) int segments;               // one tick per step, like the modern bar
@property (nonatomic, strong) CAGradientLayer *fill;
@property (nonatomic, strong) CAShapeLayer *ticks;
@end
@implementation WSResearchBar
- (instancetype)init {
    if ((self = [super init])) {
        self.backgroundColor = rs_rgb(0xE6EEED);
        self.clipsToBounds = YES;
        _fill = [CAGradientLayer layer];
        _fill.colors = @[(id)rs_rgb(0x59D0D8).CGColor, (id)rs_rgb(0x36B3C6).CGColor];
        _fill.startPoint = CGPointMake(0, 0.5); _fill.endPoint = CGPointMake(1, 0.5);
        [self.layer addSublayer:_fill];
        _ticks = [CAShapeLayer layer];
        _ticks.fillColor = [UIColor colorWithWhite:1 alpha:0.9].CGColor;
        [self.layer addSublayer:_ticks];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.layer.cornerRadius = self.bounds.size.height / 2;
    [CATransaction begin]; [CATransaction setDisableActions:YES];
    CGFloat w = self.bounds.size.width * MAX(0, MIN(1, self.fraction));
    self.fill.frame = CGRectMake(0, 0, w, self.bounds.size.height);
    self.fill.cornerRadius = self.bounds.size.height / 2;
    UIBezierPath *t = [UIBezierPath bezierPath];
    for (int i = 1; i < self.segments && self.segments <= 12; i++) {
        CGFloat x = self.bounds.size.width * i / self.segments;
        [t appendPath:[UIBezierPath bezierPathWithRect:CGRectMake(x - 0.75, 0, 1.5, self.bounds.size.height)]];
    }
    self.ticks.frame = self.bounds;
    self.ticks.path = t.CGPath;
    [CATransaction commit];
}
@end

// ---- art from the server (cached in memory and on disk)
static NSString *rs_cache_path(NSString *path) {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSCachesDirectory, NSUserDomainMask, YES).firstObject
                     stringByAppendingPathComponent:@"windstock-research"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString *safe = [[path componentsSeparatedByCharactersInSet:
                       [[NSCharacterSet alphanumericCharacterSet] invertedSet]] componentsJoinedByString:@"_"];
    return [dir stringByAppendingPathComponent:safe];
}

static UIImageView *rs_image(NSString *path, CGFloat w, CGFloat h);

/** Art drawn in a colour (the official icons are white, which vanishes on a white card). */
static UIImageView *rs_image_tinted(NSString *path, CGFloat w, CGFloat h, UIColor *tint) {
    UIImageView *iv = rs_image(path, w, h);
    iv.tintColor = tint;
    objc_setAssociatedObject(iv, "ws_tint", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if (iv.image) iv.image = [iv.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    return iv;
}

static UIImageView *rs_image(NSString *path, CGFloat w, CGFloat h) {
    UIImageView *iv = [UIImageView new];
    iv.contentMode = (w > 0 || h > 0) ? UIViewContentModeScaleAspectFit : UIViewContentModeScaleAspectFill;
    iv.clipsToBounds = YES;
    rs_size(iv, w, h);
    if (![path isKindOfClass:[NSString class]] || !path.length) return iv;
    if (!RS_images) { RS_images = [NSMutableDictionary new]; RS_waiting = [NSMutableDictionary new]; }
    UIImage *have = RS_images[path];
    if (have) { iv.image = have; return iv; }
    (void)rs_image_tinted;
    NSString *file = rs_cache_path(path);
    UIImage *disk = [UIImage imageWithContentsOfFile:file];
    if (disk) { RS_images[path] = disk; iv.image = disk; return iv; }
    NSMutableArray *wait = RS_waiting[path];
    if (wait) { [wait addObject:iv]; return iv; }
    RS_waiting[path] = [NSMutableArray arrayWithObject:iv];
    NSURL *url = [NSURL URLWithString:[RS_HOST stringByAppendingString:path]];
    [[[NSURLSession sharedSession] dataTaskWithURL:url completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        UIImage *img = d ? [UIImage imageWithData:d scale:2] : nil;
        if (img && [(NSHTTPURLResponse *)r statusCode] == 200) [d writeToFile:file atomically:YES];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (img) RS_images[path] = img;
            for (UIImageView *v in RS_waiting[path]) {
                v.image = objc_getAssociatedObject(v, "ws_tint")
                    ? [img imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate] : img;
            }
            [RS_waiting removeObjectForKey:path];
        });
    }] resume];
    return iv;
}

static void rs_load_fonts(void) {
    for (NSString *name in @[@"Lato-Bold", @"Lato-Regular"]) {
        NSString *path = [NSString stringWithFormat:@"/research/font/%@.ttf", name];
        NSString *file = rs_cache_path(path);
        void (^reg)(NSData *) = ^(NSData *d) {
            CGDataProviderRef p = CGDataProviderCreateWithCFData((__bridge CFDataRef)d);
            CGFontRef f = p ? CGFontCreateWithDataProvider(p) : NULL;
            if (f) {
                CFErrorRef err = NULL;
                if (CTFontManagerRegisterGraphicsFont(f, &err) || [UIFont fontWithName:name size:12]) RS_fonts = true;
                if (err) CFRelease(err);
                CGFontRelease(f);
            }
            if (p) CGDataProviderRelease(p);
        };
        NSData *d = [NSData dataWithContentsOfFile:file];
        if (d.length > 1000) { reg(d); continue; }
        [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:[RS_HOST stringByAppendingString:path]]
            completionHandler:^(NSData *data, NSURLResponse *r, NSError *e) {
            if (data.length < 1000 || [(NSHTTPURLResponse *)r statusCode] != 200) return;
            [data writeToFile:file atomically:YES];
            dispatch_async(dispatch_get_main_queue(), ^{ reg(data); if (RS_screen && !RS_screen.hidden) rs_render(); });
        }] resume];
    }
}

// ---- networking
static void rs_apply(NSData *d) {
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]] || rj(j, @"today") == nil) return;
    bool same = RS_state_raw && [RS_state_raw isEqualToData:d];
    RS_state = j;
    RS_state_raw = d;
    RS_state_rx = [NSDate date].timeIntervalSince1970;
    if (rj(j, @"level")) RS_level = [rj(j, @"level") intValue];
    // v180: a new Breakthrough stamp -> the stamp sound, now if Research is open, else when it opens
    static int stamps = -1;
    int have = [rj(rj(rj(j, @"today"), @"breakthrough"), @"have") intValue];
    if (stamps >= 0 && have > stamps) RS_stamp_pending = true;
    stamps = have;
    if (RS_stamp_pending && RS_screen && !RS_screen.hidden) {
        RS_stamp_pending = false;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ rs_sfx_modern(RS_SFX_STAMP); });
    }
    if (!same && RS_screen && !RS_screen.hidden) rs_render();
}

static void rs_fetch(bool force) {
    if (RS_busy && !force) return;
    RS_busy = true;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/state"]];
    rq.timeoutInterval = 6;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            RS_busy = false;
            if (e) { static int w = 0; if (w++ < 3) WLOG(@"research: state failed: %@", e.localizedDescription); return; }
            rs_apply(d);
        });
    }] resume];
}

static void rs_show_rewards(NSArray *granted, NSString *err);
static bool rs_catch_ready(void);
static void rs_catch_start(uint64_t eid, NSString *name);

static void rs_claim(NSDictionary *body) {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/claim"]];
    rq.HTTPMethod = @"POST";
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    rq.timeoutInterval = 8;
    WLOG(@"research: claim %@", body);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![j isKindOfClass:[NSDictionary class]]) { rs_show_rewards(@[], @"Couldn't reach the server."); return; }
            NSArray *granted = rj(j, @"granted");
            NSMutableDictionary *st = [j mutableCopy];
            [st removeObjectForKey:@"granted"];
            [st removeObjectForKey:@"error"];
            rs_apply([NSJSONSerialization dataWithJSONObject:st options:0 error:nil]);
            rs_render();
            if ([granted isKindOfClass:[NSArray class]] && granted.count) rs_show_rewards(granted, nil);
            else if (rj(j, @"error")) rs_show_rewards(@[], @"That reward isn't ready yet.");
        });
    }] resume];
}

// ---- pieces
static UIView *rs_reward_bubble(NSDictionary *rw, CGFloat size, bool glow) {
    UIView *wrap = [UIView new];
    UIView *circle = [UIView new];
    circle.backgroundColor = glow ? rs_rgb(0xE9FBF1) : rs_rgb(0xF1F6F5);
    circle.layer.cornerRadius = size / 2;
    if (glow) { circle.layer.borderColor = rs_green().CGColor; circle.layer.borderWidth = 2; }
    rs_size(circle, size, size);
    [wrap addSubview:circle];
    UIImageView *icon = rs_image(rj(rw, @"icon"), size * 0.72, size * 0.72);
    [circle addSubview:icon];
    [NSLayoutConstraint activateConstraints:@[
        [icon.centerXAnchor constraintEqualToAnchor:circle.centerXAnchor],
        [icon.centerYAnchor constraintEqualToAnchor:circle.centerYAnchor]]];
    NSString *label = rj(rw, @"label");
    UILabel *l = rs_label(label ?: @"", 13, true, rs_ink());
    l.textAlignment = NSTextAlignmentCenter;
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [wrap addSubview:l];
    wrap.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [circle.topAnchor constraintEqualToAnchor:wrap.topAnchor],
        [circle.centerXAnchor constraintEqualToAnchor:wrap.centerXAnchor],
        [l.topAnchor constraintEqualToAnchor:circle.bottomAnchor constant:label.length ? 2 : 0],
        [l.centerXAnchor constraintEqualToAnchor:wrap.centerXAnchor],
        [l.bottomAnchor constraintEqualToAnchor:wrap.bottomAnchor],
        [wrap.widthAnchor constraintGreaterThanOrEqualToConstant:size],
        [wrap.widthAnchor constraintGreaterThanOrEqualToAnchor:l.widthAnchor]]];
    return wrap;
}

static UIView *rs_task_card(NSDictionary *t, void (^claim)(void), NSString *tag) {
    bool done = [rj(t, @"done") boolValue], claimed = [rj(t, @"claimed") boolValue];
    int prog = [rj(t, @"progress") intValue], need = MAX(1, [rj(t, @"count") intValue]);
    UIView *card = rs_card();
    card.layer.cornerRadius = 18;
    card.layer.borderWidth = 2.5;
    card.layer.borderColor = (done && !claimed ? rs_green() : rs_gold()).CGColor;
    card.clipsToBounds = NO;
    UILabel *text = rs_label(rj(t, @"text"), 17, true, claimed ? rs_ink2() : rs_ink());
    WSResearchBar *bar = [WSResearchBar new];
    bar.fraction = (CGFloat)prog / need;
    bar.segments = need;
    rs_size(bar, 0, 13);
    // the count sits UNDER the bar, at the fill, the way the modern screen does it
    UILabel *count = rs_label(claimed ? @"Complete" : done ? @"Tap to claim!" :
                              [NSString stringWithFormat:@"%d", prog], 14, true,
                              done && !claimed ? rs_rgb(0x2FB386) : rs_ink2());
    UIStackView *left = rs_vstack(@[text, bar, count], 6);
    left.alignment = UIStackViewAlignmentFill;        // or the bar collapses to nothing
    UIView *bubble = rs_reward_bubble(rj(t, @"reward"), 56, done && !claimed);
    [bubble setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = rs_hstack(@[left, bubble], 14);
    [card addSubview:row];
    rs_pin(row, card, UIEdgeInsetsMake(14, 16, 16, 14));
    if (tag.length) {                       // the little corner label (FIELD / SPECIAL / TIMED)
        UILabel *l = rs_label(tag.uppercaseString, 11, true, UIColor.whiteColor);
        l.textAlignment = NSTextAlignmentCenter;
        UIView *chip = [UIView new];
        chip.backgroundColor = done && !claimed ? rs_green() : rs_gold();
        chip.layer.cornerRadius = 8;
        ws_round_corners(chip.layer, kCALayerMinXMinYCorner | kCALayerMaxXMaxYCorner);
        chip.translatesAutoresizingMaskIntoConstraints = NO;
        [chip addSubview:l];
        rs_pin(l, chip, UIEdgeInsetsMake(2, 8, 2, 8));
        [card addSubview:chip];
        [NSLayoutConstraint activateConstraints:@[
            [chip.trailingAnchor constraintEqualToAnchor:card.trailingAnchor constant:-2],
            [chip.bottomAnchor constraintEqualToAnchor:card.bottomAnchor constant:-2]]];
    }
    if (claimed) card.alpha = 0.65;
    if (done && !claimed && claim) rs_on_tap(card, claim);
    return card;
}

static UIView *rs_green_button(NSString *title, bool enabled, void (^tap)(void)) {
    UIView *b = [UIView new];
    rs_size(b, 0, 50);
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = enabled ? @[(id)rs_rgb(0xA4E688).CGColor, (id)rs_rgb(0x48C59E).CGColor]
                       : @[(id)rs_rgb(0xD5DEDD).CGColor, (id)rs_rgb(0xC2CCCB).CGColor];
    g.startPoint = CGPointMake(0, 0.5); g.endPoint = CGPointMake(1, 0.5);
    g.cornerRadius = 25;
    g.frame = CGRectMake(0, 0, 600, 50);
    b.layer.cornerRadius = 25;
    b.clipsToBounds = YES;
    [b.layer addSublayer:g];
    UILabel *l = rs_label(title, 16, true, UIColor.whiteColor);
    l.textAlignment = NSTextAlignmentCenter;
    [b addSubview:l];
    rs_pin(l, b, UIEdgeInsetsZero);
    if (enabled && tap) rs_on_tap(b, tap);
    return b;
}

// The big amber pill the modern screen uses for a ready reward.
static UIView *rs_amber_button(NSString *title, void (^tap)(void)) {
    UIView *b = [UIView new];
    rs_size(b, 0, 54);
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)rs_rgb(0xF7B65C).CGColor, (id)rs_rgb(0xE8883A).CGColor];
    g.startPoint = CGPointMake(0, 0); g.endPoint = CGPointMake(0, 1);
    g.cornerRadius = 14;
    g.frame = CGRectMake(0, 0, 900, 54);
    b.layer.cornerRadius = 14;
    b.layer.borderWidth = 2.5;
    b.layer.borderColor = UIColor.whiteColor.CGColor;
    b.clipsToBounds = YES;
    [b.layer addSublayer:g];
    UILabel *l = rs_label(title, 19, true, UIColor.whiteColor);
    l.textAlignment = NSTextAlignmentCenter;
    [b addSubview:l];
    rs_pin(l, b, UIEdgeInsetsZero);
    if (tap) rs_on_tap(b, tap);
    return b;
}

static UIView *rs_section_title(NSString *s) {
    UILabel *l = rs_label(s.uppercaseString, 13, true, [UIColor colorWithWhite:1 alpha:0.75]);
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:l.text];
    [a addAttribute:NSKernAttributeName value:@(1.2) range:NSMakeRange(0, a.length)];
    l.attributedText = a;
    return l;
}

static UIView *rs_breakthrough(NSDictionary *bt) {
    UIView *card = [UIView new];
    int have = [rj(bt, @"have") intValue], need = MAX(1, [rj(bt, @"need") intValue]);
    UILabel *title = rs_label(@"Research Breakthrough", 18, true, UIColor.whiteColor);
    UILabel *sub = rs_label([rj(bt, @"can_claim") boolValue] ? @"Your Research Breakthrough is ready!" :
                            @"Complete a Field Research task each day to earn a stamp.",
                            13, false, [UIColor colorWithWhite:1 alpha:0.7]);
    NSMutableArray *stamps = [NSMutableArray array];
    for (int i = 0; i < need; i++) {
        if (i < have) {
            UIImageView *st = rs_image(@"/research/art/DailyQuestResearchStamp_01.png", 34, 34);
            [st setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                forAxis:UILayoutConstraintAxisHorizontal];
            [st setContentHuggingPriority:UILayoutPriorityRequired
                                  forAxis:UILayoutConstraintAxisHorizontal];
            [stamps addObject:st];
            continue;
        }
        UIView *ring = [UIView new];                   // a dashed circle with the day's number
        rs_size(ring, 34, 34);
        CAShapeLayer *dash = [CAShapeLayer layer];
        dash.path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(1, 1, 32, 32)].CGPath;
        dash.fillColor = UIColor.clearColor.CGColor;
        dash.strokeColor = [UIColor colorWithWhite:1 alpha:0.55].CGColor;
        dash.lineWidth = 2;
        dash.lineDashPattern = @[@4, @3];
        [ring.layer addSublayer:dash];
        UILabel *n = rs_label([NSString stringWithFormat:@"%d", i + 1], 14, true,
                              [UIColor colorWithWhite:1 alpha:0.75]);
        n.textAlignment = NSTextAlignmentCenter;
        n.translatesAutoresizingMaskIntoConstraints = NO;
        [ring addSubview:n];
        [NSLayoutConstraint activateConstraints:@[
            [n.centerXAnchor constraintEqualToAnchor:ring.centerXAnchor],
            [n.centerYAnchor constraintEqualToAnchor:ring.centerYAnchor]]];
        [stamps addObject:ring];
    }
    UIStackView *stampRow = rs_hstack(stamps, need > 7 ? 3 : 6);
    stampRow.distribution = UIStackViewDistributionFill;
    stampRow.alignment = UIStackViewAlignmentCenter;
    UIImageView *box = rs_image(@"/research/art/QuestReward.png", 78, 64);
    UIStackView *top = rs_hstack(@[rs_vstack(@[title, sub, stampRow], 6), box], 10);
    top.alignment = UIStackViewAlignmentCenter;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:top];
    if ([rj(bt, @"can_claim") boolValue])
        [parts addObject:rs_amber_button(@"CLAIM REWARD", ^{ rs_claim(@{@"kind": @"breakthrough"}); })];
    UIStackView *all = rs_vstack(parts, 12);
    [card addSubview:all];
    rs_pin(all, card, UIEdgeInsetsMake(14, 16, 14, 14));
    return card;
}

static NSString *rs_countdown(double ms) {
    long s = (long)MAX(0, ms / 1000);
    if (s >= 86400) return [NSString stringWithFormat:@"%ldd %ldh", s / 86400, (s % 86400) / 3600];
    if (s >= 3600) return [NSString stringWithFormat:@"%ldh %ldm", s / 3600, (s % 3600) / 60];
    return [NSString stringWithFormat:@"%ldm %lds", s / 60, s % 60];
}

static void rs_story(NSDictionary *s, bool timed) {
    // header: Professor Willow + title + description
    UIView *head = rs_card();
    UIImageView *willow = rs_image(@"/research/art/QuestIconProfessor.png", 64, 64);
    UILabel *title = rs_label(rj(s, @"title"), 20, true, rs_ink());
    NSMutableArray *headText = [NSMutableArray arrayWithObject:title];
    if (timed && [rj(s, @"ends_ms") doubleValue] > 0) {
        double left = [rj(s, @"ends_ms") doubleValue] - [rj(RS_state, @"server_ms") doubleValue]
                      - ([NSDate date].timeIntervalSince1970 - RS_state_rx) * 1000;
        UILabel *ends = rs_label([@"Ends in " stringByAppendingString:rs_countdown(left)], 13, true, rs_rgb(0xFF8C3A));
        [headText addObject:ends];
    }
    NSString *desc = rj(s, @"description");
    if (desc.length) [headText addObject:rs_label(desc, 14, false, rs_ink2())];
    UIStackView *hs = rs_hstack(@[willow, rs_vstack(headText, 4)], 12);
    hs.alignment = UIStackViewAlignmentTop;
    [head addSubview:hs];
    rs_pin(hs, head, UIEdgeInsetsMake(14, 14, 14, 14));
    [RS_stack addArrangedSubview:head];

    int steps = MAX(1, [rj(s, @"steps") intValue]), step = [rj(s, @"step") intValue];
    bool done = [rj(s, @"done") boolValue];
    // step progress: one segment per step
    NSMutableArray *segs = [NSMutableArray array];
    for (int i = 0; i < steps; i++) {
        UIView *seg = [UIView new];
        seg.backgroundColor = (done || i < step - 1) ? rs_rgb(0xFF9E45) : i == step - 1 ? rs_rgb(0xFFD08F) : rs_rgb(0xDDE7E6);
        seg.layer.cornerRadius = 4;
        rs_size(seg, 0, 8);
        [segs addObject:seg];
    }
    UIStackView *segRow = rs_hstack(segs, 4);
    segRow.distribution = UIStackViewDistributionFillEqually;
    segRow.alignment = UIStackViewAlignmentFill;
    UILabel *stepLabel = rs_label(done ? @"Research complete!" :
                                  [NSString stringWithFormat:@"Step %d of %d", step, steps], 15, true,
                                  UIColor.whiteColor);
    [RS_stack addArrangedSubview:rs_vstack(@[stepLabel, segRow], 8)];

    if (done) {
        UIView *c = rs_card();
        UIImageView *stamp = rs_image(@"/research/art/QuestSpecialResearchStamp_01.png", 96, 96);
        UILabel *l = rs_label(@"You've finished this research. Great work!", 15, true, rs_ink());
        l.textAlignment = NSTextAlignmentCenter;
        UIStackView *v = rs_vstack(@[stamp, l], 8);
        v.alignment = UIStackViewAlignmentCenter;
        [c addSubview:v];
        rs_pin(v, c, UIEdgeInsetsMake(18, 16, 18, 16));
        [RS_stack addArrangedSubview:c];
        return;
    }
    for (NSDictionary *t in rj(s, @"tasks") ?: @[]) {
        NSString *key = rj(t, @"key");
        NSString *tag = timed ? @"Timed" : @"Special";
        [RS_stack addArrangedSubview:rs_task_card(t, ^{ rs_claim(@{@"kind": @"task", @"key": key}); }, tag)];
    }
    // step rewards
    UIView *rc = rs_card();
    NSMutableArray *bubbles = [NSMutableArray array];
    for (NSDictionary *rw in rj(s, @"rewards") ?: @[]) [bubbles addObject:rs_reward_bubble(rw, 58, false)];
    UIStackView *brow = rs_hstack(bubbles, 22);
    UIStackView *center = rs_vstack(@[brow], 0);
    center.alignment = UIStackViewAlignmentCenter;
    NSString *sid = rj(s, @"id");
    bool can = [rj(s, @"can_claim_step") boolValue];
    UIView *btn = rs_green_button(can ? @"CLAIM REWARD" : @"COMPLETE ALL TASKS", can, ^{
        rs_claim(@{@"kind": @"step", @"id": sid});
    });
    UILabel *rewardsTitle = rs_label(@"REWARDS", 13, true, rs_ink2());
    rewardsTitle.textAlignment = NSTextAlignmentCenter;
    UIStackView *rv = rs_vstack(@[rewardsTitle, center, btn], 12);
    [rc addSubview:rv];
    rs_pin(rv, rc, UIEdgeInsetsMake(14, 16, 16, 16));
    [RS_stack addArrangedSubview:rc];
}

// ---- the Leaderboard tab (v124; in the Windstock Hub since v126). The launcher signs in to the player's Windstock profile
// and writes where they stand -- global position on the "most caught" board plus the top of
// the table -- to Documents/windstock-leaderboard.json in the game's container. No file (not
// signed in, or "Report my stats" off) means no tab.
static NSDictionary *RS_lb = nil;
static NSDate *RS_lb_mtime = nil;

static NSString *rs_lb_path(void) {
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/windstock-leaderboard.json"];
}

static int rs_num(id v) { return [v isKindOfClass:[NSNumber class]] ? [v intValue] : 0; }

static NSString *rs_thousands(int n) {
    static NSNumberFormatter *f = nil;
    if (!f) { f = [NSNumberFormatter new]; f.numberStyle = NSNumberFormatterDecimalStyle; }
    return [f stringFromNumber:@(n)] ?: [NSString stringWithFormat:@"%d", n];
}

/** Re-read the standing when the file changed. True when something changed. */
static bool rs_lb_load(void) {
    NSDate *m = [[NSFileManager defaultManager] attributesOfItemAtPath:rs_lb_path() error:nil].fileModificationDate;
    if (!m) {
        bool had = RS_lb != nil;
        RS_lb = nil; RS_lb_mtime = nil;
        return had;
    }
    if (RS_lb_mtime && [m isEqualToDate:RS_lb_mtime]) return false;
    NSData *d = [NSData dataWithContentsOfFile:rs_lb_path()];
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return false;
    RS_lb = j; RS_lb_mtime = m;
    return true;
}

static bool rs_lb_on(void) { return [rj(RS_lb, @"username") isKindOfClass:[NSString class]]; }

static UIColor *rs_team_color(int team) {
    switch (team) {
        case 1: return rs_rgb(0x3D8BFF);     // Mystic
        case 2: return rs_rgb(0xFF3D3D);     // Valor
        case 3: return rs_rgb(0xF2C200);     // Instinct
        default: return rs_rgb(0xC9D6D9);
    }
}

// v153: WEEKLY / ALL TIME boards, each by caught, spun or walked (+ level, all time only).
// The site sends every board in the standing's "boards"; an older site sends only the
// all-time caught one (rank/total/rows), which is what we fall back to.
static void rs_events_render(void);
static int RS_lb_period = 0;                    // 0 = this week, 1 = all time
static NSString *RS_lb_by = @"caught";

static NSArray *rs_lb_metrics(void) {
    return RS_lb_period == 0 ? @[@"caught", @"spun", @"walked"] : @[@"caught", @"spun", @"walked", @"level"];
}

static NSDictionary *rs_lb_board(void) {
    NSDictionary *boards = rj(RS_lb, @"boards");
    NSDictionary *b = [boards isKindOfClass:[NSDictionary class]]
        ? rj(rj(boards, RS_lb_period == 0 ? @"week" : @"all"), RS_lb_by) : nil;
    if ([b isKindOfClass:[NSDictionary class]]) return b;
    if (RS_lb_period == 1 && [RS_lb_by isEqual:@"caught"]) return RS_lb;     // pre-v153 site
    return nil;
}

static NSString *rs_km(id v) {
    double km = [v isKindOfClass:[NSNumber class]] ? [v doubleValue] : 0;
    return km < 100 ? [NSString stringWithFormat:@"%.1f km", km] : [NSString stringWithFormat:@"%@ km", rs_thousands((int)km)];
}

static NSString *rs_lb_value(NSDictionary *r, NSString *by) {
    if ([by isEqual:@"walked"]) return rs_km(rj(r, @"walked"));
    if ([by isEqual:@"level"]) return [NSString stringWithFormat:@"Lv %d", rs_num(rj(r, @"level"))];
    return rs_thousands(rs_num(rj(r, by)));
}

/** A row of pills; the selected one is teal. small = the metric chips under the period. */
static UIView *rs_lb_pills(NSArray *names, int selected, bool small, void (^pick)(int)) {
    UIStackView *strip = rs_hstack(@[], small ? 6 : 0);
    strip.distribution = UIStackViewDistributionFillEqually;
    for (int i = 0; i < (int)names.count; i++) {
        bool on = i == selected;
        UIView *pill = [UIView new];
        pill.backgroundColor = on ? rs_teal() : (small ? [UIColor colorWithWhite:1 alpha:0.14] : UIColor.clearColor);
        pill.layer.cornerRadius = small ? 14 : 17;
        UILabel *l = rs_label(names[i], small ? 12 : 14, true,
                              on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.72]);
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:names[i]];
        [a addAttribute:NSKernAttributeName value:@(small ? 0.6 : 1.2) range:NSMakeRange(0, a.length)];
        [a addAttribute:NSForegroundColorAttributeName
                  value:on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.72]
                  range:NSMakeRange(0, a.length)];
        l.attributedText = a;
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 1;
        l.adjustsFontSizeToFitWidth = YES;
        l.minimumScaleFactor = 0.6;
        [pill addSubview:l];
        l.translatesAutoresizingMaskIntoConstraints = NO;
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [pill.heightAnchor constraintEqualToConstant:small ? 28 : 34],
            [l.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
            [l.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor],
            [l.widthAnchor constraintLessThanOrEqualToAnchor:pill.widthAnchor constant:-10]]];
        int idx = i;
        rs_on_tap(pill, ^{ pick(idx); });
        [strip addArrangedSubview:pill];
    }
    return strip;
}

static void rs_lb_render(UIStackView *into) {
    NSArray *metrics = rs_lb_metrics();
    if (![metrics containsObject:RS_lb_by]) RS_lb_by = @"caught";
    [into addArrangedSubview:rs_lb_pills(@[@"WEEKLY", @"ALL TIME"], RS_lb_period, false, ^(int i) {
        RS_lb_period = i;
        rs_events_render();
    })];
    NSMutableArray *chips = [NSMutableArray array];
    for (NSString *m in metrics) [chips addObject:m.uppercaseString];
    [into addArrangedSubview:rs_lb_pills(chips, (int)[metrics indexOfObject:RS_lb_by], true, ^(int i) {
        RS_lb_by = rs_lb_metrics()[i];
        rs_events_render();
    })];

    NSDictionary *board = rs_lb_board();
    int rank = rs_num(rj(board, @"rank")), total = rs_num(rj(board, @"total"));
    NSString *me = rj(RS_lb, @"username");
    bool week = RS_lb_period == 0;
    NSString *what = [RS_lb_by isEqual:@"spun"] ? @"most PokéStops spun"
                   : [RS_lb_by isEqual:@"walked"] ? @"most km walked"
                   : [RS_lb_by isEqual:@"level"] ? @"highest level" : @"most Pokémon caught";

    UIView *head = rs_card();
    UILabel *kicker = rs_label(week ? @"YOUR POSITION THIS WEEK" : @"YOUR GLOBAL POSITION", 12, true, rs_ink2());
    UILabel *big = rs_label(rank > 0 ? [NSString stringWithFormat:@"#%d", rank] : @"—", 44, true, rs_teal());
    UILabel *sub = rs_label(!board ? @"Not available yet."
                            : rank > 0 ? [NSString stringWithFormat:@"of %d trainers · %@", total, what]
                            : week ? @"Play this week to get on the board!" : @"Catch a Pokémon to get on the board!",
                            14, true, rs_ink());
    NSMutableArray *hl = [NSMutableArray arrayWithArray:@[kicker, big, sub]];
    double ends = [rj(RS_lb, @"weekEndsAt") isKindOfClass:[NSNumber class]] ? [rj(RS_lb, @"weekEndsAt") doubleValue] : 0;
    if (week && ends > 0) {
        long h = MAX(0L, (long)((ends / 1000.0 - [NSDate date].timeIntervalSince1970) / 3600));
        [hl addObject:rs_label(h >= 48 ? [NSString stringWithFormat:@"New week in %ld days", h / 24]
                                       : [NSString stringWithFormat:@"New week in %ld h", MAX(1L, h)], 12, false, rs_ink2())];
    }
    for (UILabel *l in hl) l.textAlignment = NSTextAlignmentCenter;
    UIStackView *hv = rs_vstack(hl, 2);
    [head addSubview:hv];
    rs_pin(hv, head, UIEdgeInsetsMake(16, 16, 18, 16));
    [into addArrangedSubview:head];

    [into addArrangedSubview:rs_section_title([NSString stringWithFormat:@"Top trainers · %@%@",
                                               RS_lb_by, week ? @" this week" : @""])];
    NSArray *rows = [rj(board, @"rows") isKindOfClass:[NSArray class]] ? rj(board, @"rows") : @[];
    UIView *card = rs_card();
    UIStackView *list = rs_vstack(@[], 0);
    list.layer.cornerRadius = 16;
    list.clipsToBounds = YES;                       // the card keeps its shadow
    for (NSDictionary *r in rows) {
        if (![r isKindOfClass:[NSDictionary class]]) continue;
        int n = rs_num(rj(r, @"rank"));
        bool mine = [rj(r, @"username") isEqual:me];
        UILabel *pos = rs_label([NSString stringWithFormat:@"%d", n], 15, true, n <= 3 ? rs_gold() : rs_ink2());
        rs_size(pos, 30, 0);
        UIView *dot = [UIView new];
        dot.backgroundColor = rs_team_color(rs_num(rj(r, @"team")));
        dot.layer.cornerRadius = 5;
        rs_size(dot, 10, 10);
        NSString *who = [rj(r, @"username") isKindOfClass:[NSString class]] ? rj(r, @"username") : @"?";
        UILabel *name = rs_label(who, 15, true, rs_ink());
        name.numberOfLines = 1;
        // The detail line shows the stats the big number doesn't.
        NSMutableArray *bits = [NSMutableArray array];
        for (NSString *m in rs_lb_metrics()) {
            if ([m isEqual:RS_lb_by]) continue;
            [bits addObject:[m isEqual:@"level"] || [m isEqual:@"walked"] ? rs_lb_value(r, m)
                            : [NSString stringWithFormat:@"%@ %@", rs_lb_value(r, m), m]];
        }
        if (week) [bits insertObject:[NSString stringWithFormat:@"Lv %d", rs_num(rj(r, @"level"))] atIndex:0];
        UILabel *detail = rs_label([bits componentsJoinedByString:@" · "], 12, false, rs_ink2());
        detail.numberOfLines = 1;
        UIStackView *text = rs_vstack(@[name, detail], 1);
        [text setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        [text setContentCompressionResistancePriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
        UILabel *caught = rs_label(rs_lb_value(r, RS_lb_by), 16, true, mine ? rs_teal() : rs_ink());
        caught.numberOfLines = 1;
        [caught setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        [caught setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
        UIStackView *row = rs_hstack(@[pos, dot, text, caught], 10);
        UIView *cell = [UIView new];
        if (mine) cell.backgroundColor = [rs_teal() colorWithAlphaComponent:0.12];
        [cell addSubview:row];
        rs_pin(row, cell, UIEdgeInsetsMake(10, 14, 10, 16));
        [list addArrangedSubview:cell];
    }
    if (!list.arrangedSubviews.count) {
        UILabel *l = rs_label(week ? @"Nobody's scored this week yet. Go catch something!"
                                   : @"Nobody's on the board yet. Be the first!", 15, true, rs_ink2());
        l.textAlignment = NSTextAlignmentCenter;
        UIView *cell = [UIView new];
        [cell addSubview:l];
        rs_pin(l, cell, UIEdgeInsetsMake(20, 16, 20, 16));
        [list addArrangedSubview:cell];
    }
    [card addSubview:list];
    rs_pin(list, card, UIEdgeInsetsZero);
    [into addArrangedSubview:card];
    UILabel *foot = rs_label(@"Updates every 15 seconds while you play.", 12, false, [UIColor colorWithWhite:1 alpha:0.7]);
    foot.textAlignment = NSTextAlignmentCenter;
    [into addArrangedSubview:foot];
}

// ---- the screen
static void rs_close(void) {
    if (!RS_screen || RS_screen.hidden) return;
    UIView *screen = RS_screen;
    rs_sfx_modern(RS_SFX_RESEARCH_CLOSE);
    // v178: back down the way it came
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseIn |
                                                     UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ screen.transform = CGAffineTransformMakeTranslation(0, screen.bounds.size.height); }
                     completion:^(BOOL f) { if (f) { screen.hidden = YES; screen.transform = CGAffineTransformIdentity; } }];
}

/** v178: change tab -- by tapping one, or dragging (the new page slides in from that side). */
static void rs_set_tab(int to) {
    int count = [(rj(RS_state, @"timed") ?: @[]) count] ? 3 : 2;
    if (to < 0 || to >= count || to == RS_tab) return;
    int dir = to > RS_tab ? 1 : -1;
    RS_tab = to;
    [RS_scroll setContentOffset:CGPointZero animated:NO];
    rs_render();
    CGFloat w = RS_scroll.bounds.size.width;
    RS_stack.transform = CGAffineTransformMakeTranslation(dir * w, 0);
    RS_stack.alpha = 0.4;
    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ RS_stack.transform = CGAffineTransformIdentity; RS_stack.alpha = 1; }
                     completion:nil];
}

/** v184: just the tab pills (a finished drag only needs the highlight moved, not the cards) */
static void rs_render_tabs(void) {
    if (!RS_screen) return;
    NSArray *timed = rj(RS_state, @"timed") ?: @[];
    NSArray *names = timed.count ? @[@"TODAY", @"SPECIAL", @"TIMED"] : @[@"TODAY", @"SPECIAL"];
    if (RS_tab >= (int)names.count) RS_tab = 0;
    for (UIView *v in RS_tabs.arrangedSubviews) { [RS_tabs removeArrangedSubview:v]; [v removeFromSuperview]; }
    for (int i = 0; i < (int)names.count; i++) {
        UIView *tab = [UIView new];
        bool on = i == (RS_peek_from >= 0 ? RS_peek_from : RS_tab);   // v183: not the peeked one
        UILabel *l = rs_label(names[i], 15, true, on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.62]);
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:names[i]];
        [a addAttribute:NSKernAttributeName value:@(1.2) range:NSMakeRange(0, a.length)];
        [a addAttribute:NSForegroundColorAttributeName
                  value:on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.62]
                  range:NSMakeRange(0, a.length)];
        l.attributedText = a;
        l.textAlignment = NSTextAlignmentCenter;
        UIView *pill = [UIView new];
        pill.backgroundColor = on ? rs_teal() : UIColor.clearColor;
        pill.layer.cornerRadius = 17;
        [tab addSubview:pill];
        [pill addSubview:l];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [pill.topAnchor constraintEqualToAnchor:tab.topAnchor constant:6],
            [pill.bottomAnchor constraintEqualToAnchor:tab.bottomAnchor constant:-8],
            [pill.leadingAnchor constraintEqualToAnchor:tab.leadingAnchor constant:6],
            [pill.trailingAnchor constraintEqualToAnchor:tab.trailingAnchor constant:-6],
            [pill.heightAnchor constraintEqualToConstant:34],
            [l.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
            [l.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor]]];
        int idx = i;
        rs_on_tap(tab, ^{ rs_set_tab(idx); });
        [RS_tabs addArrangedSubview:tab];
    }
}

static void rs_render(void) {
    if (!RS_screen) return;
    NSArray *timed = rj(RS_state, @"timed") ?: @[];
    NSArray *special = rj(RS_state, @"special") ?: @[];
    rs_render_tabs();
    // content
    for (UIView *v in RS_stack.arrangedSubviews) { [RS_stack removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (!RS_state) {
        UILabel *l = rs_label(@"Loading research…", 16, true, rs_ink2());
        l.textAlignment = NSTextAlignmentCenter;
        [RS_stack addArrangedSubview:l];
        return;
    }
    if (RS_tab == 0) {
        NSDictionary *today = rj(RS_state, @"today");
        NSDictionary *bt = rj(today, @"breakthrough");
        if ([rj(bt, @"enabled") boolValue]) [RS_stack addArrangedSubview:rs_breakthrough(bt)];
        [RS_stack addArrangedSubview:rs_section_title(@"Field Research")];
        NSArray *tasks = rj(today, @"tasks") ?: @[];
        bool open = false;
        for (NSDictionary *t in tasks) {
            if (![rj(t, @"claimed") boolValue]) open = true;
            NSString *key = rj(t, @"key");
            NSString *tag = [key hasPrefix:@"given:"] ? @"Bonus" : @"Field";
            [RS_stack addArrangedSubview:rs_task_card(t, ^{ rs_claim(@{@"kind": @"task", @"key": key}); }, tag)];
        }
        if (!open) {
            UIView *c = rs_card();
            UILabel *l = rs_label(tasks.count ? @"All done for today! New Field Research arrives tomorrow."
                                              : @"No Field Research right now. Check back tomorrow!", 15, true, rs_ink2());
            l.textAlignment = NSTextAlignmentCenter;
            UIStackView *v = rs_vstack(@[l], 8);
            [c addSubview:v];
            rs_pin(v, c, UIEdgeInsetsMake(18, 16, 18, 16));
            [RS_stack addArrangedSubview:c];
        }
    } else {
        NSArray *list = RS_tab == 1 ? special : timed;
        if (!list.count) {
            UIView *c = rs_card();
            UILabel *l = rs_label(@"No Special Research yet. Professor Willow will be in touch!", 15, true, rs_ink2());
            l.textAlignment = NSTextAlignmentCenter;
            [c addSubview:l];
            rs_pin(l, c, UIEdgeInsetsMake(22, 16, 22, 16));
            [RS_stack addArrangedSubview:c];
        }
        for (NSUInteger i = 0; i < list.count; i++) {
            if (i) {
                UIView *gap = [UIView new];
                rs_size(gap, 0, 14);
                [RS_stack addArrangedSubview:gap];
            }
            rs_story(list[i], RS_tab == 2);
        }
    }
    UIView *pad = [UIView new];
    rs_size(pad, 0, 90);                    // room above the close button
    [RS_stack addArrangedSubview:pad];
}

static void rs_build(UIView *parent) {
    RS_screen = [[UIView alloc] initWithFrame:parent.bounds];
    RS_screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    UIImageView *photo = rs_image(@"/research/art/research_bg.jpg", 0, 0);
    photo.translatesAutoresizingMaskIntoConstraints = NO;
    [RS_screen addSubview:photo];
    UIView *scrim = [UIView new];                  // keeps the white text readable on the sky
    scrim.translatesAutoresizingMaskIntoConstraints = NO;
    CAGradientLayer *bg = [CAGradientLayer layer];
    bg.colors = @[(id)[rs_rgb(0x0C2A33) colorWithAlphaComponent:0.55].CGColor,
                  (id)[rs_rgb(0x0C2A33) colorWithAlphaComponent:0.30].CGColor,
                  (id)[rs_rgb(0x08202A) colorWithAlphaComponent:0.60].CGColor];
    bg.frame = CGRectMake(0, 0, 3000, 3000);
    [scrim.layer addSublayer:bg];
    [RS_screen addSubview:scrim];
    [NSLayoutConstraint activateConstraints:@[
        [photo.topAnchor constraintEqualToAnchor:RS_screen.topAnchor],
        [photo.bottomAnchor constraintEqualToAnchor:RS_screen.bottomAnchor],
        [photo.leadingAnchor constraintEqualToAnchor:RS_screen.leadingAnchor],
        [photo.trailingAnchor constraintEqualToAnchor:RS_screen.trailingAnchor],
        [scrim.topAnchor constraintEqualToAnchor:RS_screen.topAnchor],
        [scrim.bottomAnchor constraintEqualToAnchor:RS_screen.bottomAnchor],
        [scrim.leadingAnchor constraintEqualToAnchor:RS_screen.leadingAnchor],
        [scrim.trailingAnchor constraintEqualToAnchor:RS_screen.trailingAnchor]]];

    UIView *header = [UIView new];
    header.backgroundColor = [rs_rgb(0x0E262C) colorWithAlphaComponent:0.55];
    [RS_screen addSubview:header];
    RS_tabs = rs_hstack(@[], 0);
    RS_tabs.distribution = UIStackViewDistributionFillEqually;
    RS_tabs.alignment = UIStackViewAlignmentFill;
    [header addSubview:RS_tabs];
    header.translatesAutoresizingMaskIntoConstraints = NO;
    RS_tabs.translatesAutoresizingMaskIntoConstraints = NO;

    RS_scroll = [UIScrollView new];
    RS_scroll.alwaysBounceVertical = YES;
    RS_scroll.showsVerticalScrollIndicator = NO;
    [RS_screen insertSubview:RS_scroll belowSubview:header];
    RS_scroll.translatesAutoresizingMaskIntoConstraints = NO;
    RS_stack = rs_vstack(@[], 12);
    [RS_scroll addSubview:RS_stack];
    RS_stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *close = rs_image(@"/research/art/btn_close_normal.png", 60, 60);
    close.layer.shadowColor = UIColor.blackColor.CGColor;
    close.layer.shadowOpacity = 0.18; close.layer.shadowRadius = 5; close.layer.shadowOffset = CGSizeMake(0, 2);
    [RS_screen addSubview:close];
    rs_on_tap(close, ^{ rs_close(); });
    // v178: swipe between TODAY / SPECIAL / TIMED; past the last one is the Windstock Hub
    // v179: past the last tab is the Windstock Hub -- the two screens slide across together
    // v183: tabs are a pager -- the neighbour tab is drawn for real beside a picture of this one
    rs_on_drag(RS_screen, RS_scroll,
        ^NSArray<UIView *> *(int dir) {
            // v184: one picture of the page the drag started on, kept until the finger lets go;
            // turning back only redraws the cards for the other neighbour
            int base = RS_peek_from >= 0 ? RS_peek_from : RS_tab;
            int count = [(rj(RS_state, @"timed") ?: @[]) count] ? 3 : 2;
            if (dir > 0 && base >= count - 1) {
                rs_peek_end(false);
                UIView *hub = rs_events_prepare();
                return hub ? @[RS_screen, hub] : @[RS_screen];
            }
            if (base + dir < 0) { rs_peek_end(false); return @[(UIView *)RS_stack]; }
            UIView *snap = rs_peek_to(base + dir);
            return snap ? @[snap, (UIView *)RS_stack] : @[(UIView *)RS_stack];
        },
        ^(int dir, bool finished) {
            rs_hub_drag_cancel();
            if (finished) rs_peek_end(false);
        },
        ^(int dir) {
            if (RS_peek_from >= 0) rs_peek_end(true);
            else rs_swap_to_hub();
        });

    UILayoutGuide *safe = ws_safe_guide(RS_screen);
    [NSLayoutConstraint activateConstraints:@[
        [header.topAnchor constraintEqualToAnchor:RS_screen.topAnchor],
        [header.leadingAnchor constraintEqualToAnchor:RS_screen.leadingAnchor],
        [header.trailingAnchor constraintEqualToAnchor:RS_screen.trailingAnchor],
        [RS_tabs.topAnchor constraintEqualToAnchor:safe.topAnchor constant:4],
        [RS_tabs.bottomAnchor constraintEqualToAnchor:header.bottomAnchor],
        [RS_tabs.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:12],
        [RS_tabs.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-12],
        [RS_scroll.topAnchor constraintEqualToAnchor:header.bottomAnchor],
        [RS_scroll.bottomAnchor constraintEqualToAnchor:RS_screen.bottomAnchor],
        [RS_scroll.leadingAnchor constraintEqualToAnchor:RS_screen.leadingAnchor],
        [RS_scroll.trailingAnchor constraintEqualToAnchor:RS_screen.trailingAnchor],
        [RS_stack.topAnchor constraintEqualToAnchor:RS_scroll.topAnchor constant:16],
        [RS_stack.bottomAnchor constraintEqualToAnchor:RS_scroll.bottomAnchor constant:-16],
        [RS_stack.centerXAnchor constraintEqualToAnchor:RS_scroll.centerXAnchor],
        [RS_stack.widthAnchor constraintEqualToAnchor:RS_scroll.widthAnchor constant:-32],
        [close.centerXAnchor constraintEqualToAnchor:RS_screen.centerXAnchor],
        [close.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]]];
    RS_screen.hidden = YES;
    [parent addSubview:RS_screen];
}

static void rs_open(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (!RS_screen || RS_screen.superview != parent) {
        [RS_screen removeFromSuperview];
        RS_screen = nil;
        rs_build(parent);
    }
    bool was_open = !RS_screen.hidden;
    RS_screen.hidden = NO;
    RS_screen.alpha = 1;
    [parent bringSubviewToFront:RS_screen];
    // v178: slides up from the bottom, like the game's own menus
    if (!was_open) RS_screen.transform = CGAffineTransformMakeTranslation(0, parent.bounds.size.height);
    [UIView animateWithDuration:0.32 delay:0 usingSpringWithDamping:0.9 initialSpringVelocity:0.3
                        options:UIViewAnimationOptionBeginFromCurrentState
                     animations:^{ RS_screen.transform = CGAffineTransformIdentity; } completion:nil];
    if (!was_open) rs_sfx_modern(RS_SFX_RESEARCH_OPEN);
    if (!was_open && RS_stamp_pending) {
        RS_stamp_pending = false;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                       ^{ rs_sfx_modern(RS_SFX_STAMP); });
    }
    RS_events_quiet = true;     // swapping screens: one sound, not a close as well
    rs_events_close();
    RS_events_quiet = false;
    rs_render();
    rs_fetch(true);
    WLOG(@"research: opened");
}

static void rs_show_rewards(NSArray *granted, NSString *err) {
    UIView *parent = RS_screen ?: mt_unity_view();
    if (!parent) return;
    if (!err) rs_sfx_modern(RS_SFX_REWARDS);                  // v180
    UIView *dim = [[UIView alloc] initWithFrame:parent.bounds];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    dim.backgroundColor = [UIColor colorWithRed:0.10 green:0.20 blue:0.22 alpha:0.55];
    [parent addSubview:dim];
    UIView *card = rs_card();
    [dim addSubview:card];
    NSMutableArray *rows = [NSMutableArray array];
    UILabel *title = rs_label(err ? @"Oops" : @"Rewards", 24, true, rs_ink());
    title.textAlignment = NSTextAlignmentCenter;
    [rows addObject:title];
    if (err) [rows addObject:rs_label(err, 15, false, rs_ink2())];
    NSString *pokemon = nil;
    NSMutableArray<NSString *> *stored = [NSMutableArray array];   // v132: straight into storage
    uint64_t catch_eid = 0;
    for (NSDictionary *g in granted) {
        NSString *eid = rj(g, @"encounter_id");
        if ([eid isKindOfClass:[NSString class]] && !catch_eid) catch_eid = strtoull(eid.UTF8String, NULL, 10);
        UIImageView *icon = rs_image(rj(g, @"icon"), 52, 52);
        NSString *label = rj(g, @"label");
        NSString *text = [rj(g, @"kind") isEqual:@"encounter"] ?
            [rj(g, @"name") stringByReplacingOccurrencesOfString:@" encounter" withString:@""] :
            [NSString stringWithFormat:@"%@%@%@", label.length ? label : @"", label.length ? @" " : @"", rj(g, @"name") ?: @""];
        if ([rj(g, @"kind") isEqual:@"encounter"]) {
            if ([rj(g, @"stored") boolValue]) {
                NSNumber *cp = rj(g, @"cp");
                if ([cp isKindOfClass:[NSNumber class]]) text = [NSString stringWithFormat:@"%@  CP %@", text, cp];
                [stored addObject:text];
            } else {
                pokemon = text;
            }
        }
        UILabel *l = rs_label(text, 17, true, rs_ink());
        [rows addObject:rs_hstack(@[icon, l], 14)];
    }
    if (stored.count)
        [rows addObject:rs_label(stored.count == 1 ? @"Added to your Pokémon — find it in storage!"
                                                   : @"Added to your Pokémon — find them in storage!",
                                 14, false, rs_ink2())];
    bool native = pokemon && catch_eid && rs_catch_ready();
    if (pokemon && !native) {
        [rows addObject:rs_label([NSString stringWithFormat:@"%@ is waiting for you nearby — catch it on the map!", pokemon],
                                 14, false, rs_ink2())];
        [rows addObject:rs_label(@"(Note: you may have to walk a little so the phone gets new Pokémon)",
                                 12, false, rs_ink2())];
    }
    __weak UIView *weakDim = dim;
    void (^dismiss)(void) = ^{
        [UIView animateWithDuration:0.15 animations:^{ weakDim.alpha = 0; }
                         completion:^(BOOL f) { [weakDim removeFromSuperview]; }];
    };
    if (native) {
        // v128: straight into the game's own encounter, like a research reward in the modern game
        NSString *name = pokemon;
        [rows addObject:rs_green_button(@"Catch it!", true, ^{
            dismiss();
            rs_close();
            rs_catch_start(catch_eid, name);
        })];
        UIButton *later = [UIButton buttonWithType:UIButtonTypeSystem];
        [later setTitle:@"Later — it waits on the map" forState:UIControlStateNormal];
        later.titleLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        later.tintColor = rs_ink2();
        ws_on_event(later, UIControlEventTouchUpInside, ^{ dismiss(); });
        [rows addObject:later];
    } else {
        [rows addObject:rs_green_button(@"OK", true, dismiss)];
    }
    UIStackView *v = rs_vstack(rows, 14);
    [card addSubview:v];
    rs_pin(v, card, UIEdgeInsetsMake(22, 22, 20, 22));
    card.translatesAutoresizingMaskIntoConstraints = NO;
    NSLayoutConstraint *w = [card.widthAnchor constraintEqualToAnchor:dim.widthAnchor constant:-56];
    w.priority = UILayoutPriorityDefaultHigh;
    [NSLayoutConstraint activateConstraints:@[
        w, [card.widthAnchor constraintLessThanOrEqualToConstant:360],
        [card.centerXAnchor constraintEqualToAnchor:dim.centerXAnchor],
        [card.centerYAnchor constraintEqualToAnchor:dim.centerYAnchor]]];
    card.transform = CGAffineTransformMakeScale(0.7, 0.7);
    dim.alpha = 0;
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:0
                     animations:^{ dim.alpha = 1; card.transform = CGAffineTransformIdentity; } completion:nil];
}

// ---- the update toast: slides in from the right edge, above the binoculars button.
// Several tasks at once -> "N research tasks updated"; exactly one -> that task with its
// progress bar, the way the game shows a single quest moving.
static UIView *RS_toast = nil;
static UILabel *RS_toast_label = nil;
static UILabel *RS_toast_count = nil;
static WSResearchBar *RS_toast_bar = nil;
static UIStackView *RS_toast_row = nil;

/** Where the toast sits: just above the button stack, hugging the right edge. */
static CGFloat RS_btn_top = -1;     // screen y of the Unity Hub button's top (rs_unity_buttons)
static CGFloat rs_toast_y(UIView *parent, CGFloat h) {
    if (RS_btn_top > h + 12) return RS_btn_top - 12 - h;    // v177: the Unity Hub button's top
    return parent.bounds.size.height * 0.78 - h;
}

/** message: a line of its own (the leaderboard's), no progress row. */
static void rs_toast_show(int count, NSDictionary *task, NSString *message) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (!message && (count <= 0 || RS_level < RS_UNLOCK_LEVEL)) return;
    bool single = !message && count == 1 && [task isKindOfClass:[NSDictionary class]] && rj(task, @"text");
    if (!RS_toast || RS_toast.superview != parent) {
        [RS_toast removeFromSuperview];
        RS_toast = [UIView new];
        RS_toast.backgroundColor = UIColor.whiteColor;
        RS_toast.layer.shadowColor = UIColor.blackColor.CGColor;
        RS_toast.layer.shadowOpacity = 0.15; RS_toast.layer.shadowRadius = 6;
        RS_toast.userInteractionEnabled = NO;
        UIImageView *icon = rs_image(@"/research/art/QuestSymbolMap.png", 26, 26);
        icon.tintColor = rs_rgb(0x3E6A73);
        icon.tag = 7;
        RS_toast_label = rs_label(@"", 15, true, rs_rgb(0x3E6A73));
        RS_toast_label.numberOfLines = 0;           // long ones (nest migration) wrap
        RS_toast_label.lineBreakMode = NSLineBreakByWordWrapping;
        RS_toast_count = rs_label(@"", 12, true, rs_ink2());
        RS_toast_count.numberOfLines = 1;
        RS_toast_bar = [WSResearchBar new];
        rs_size(RS_toast_bar, 96, 7);
        UIStackView *prog = rs_hstack(@[RS_toast_bar, RS_toast_count], 7);
        prog.alignment = UIStackViewAlignmentCenter;
        UIStackView *text = rs_vstack(@[RS_toast_label, prog], 5);
        text.alignment = UIStackViewAlignmentLeading;
        RS_toast_row = rs_hstack(@[icon, text], 9);
        RS_toast_row.alignment = UIStackViewAlignmentCenter;
        [RS_toast addSubview:RS_toast_row];
        RS_toast_row.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [RS_toast_row.leadingAnchor constraintEqualToAnchor:RS_toast.leadingAnchor constant:14],
            [RS_toast_row.trailingAnchor constraintLessThanOrEqualToAnchor:RS_toast.trailingAnchor constant:-16],
            [RS_toast_row.centerYAnchor constraintEqualToAnchor:RS_toast.centerYAnchor]]];
        [parent addSubview:RS_toast];
    }
    UIImageView *icon = [RS_toast viewWithTag:7];
    if ([icon isKindOfClass:[UIImageView class]] && icon.image && icon.image.renderingMode != UIImageRenderingModeAlwaysTemplate)
        icon.image = [icon.image imageWithRenderingMode:UIImageRenderingModeAlwaysTemplate];
    RS_toast_label.font = rs_font(15, true);
    RS_toast_count.font = rs_font(12, true);
    if (single) {
        int have = [rj(task, @"progress") intValue], need = MAX(1, [rj(task, @"count") intValue]);
        RS_toast_label.text = rj(task, @"text");
        RS_toast_count.text = [NSString stringWithFormat:@"%d/%d", MIN(have, need), need];
        RS_toast_bar.segments = need <= 12 ? need : 0;
        RS_toast_bar.fraction = (CGFloat)MIN(have, need) / need;
        [RS_toast_bar setNeedsLayout];
    } else if (message) {
        RS_toast_label.text = message;
    } else {
        RS_toast_label.text = [NSString stringWithFormat:@"%d research tasks updated", count];
    }
    RS_toast_bar.superview.hidden = !single;      // the progress row
    CGSize sz = parent.bounds.size;
    // One line when it fits; otherwise wrap inside a toast no wider than ~3/4 of the screen
    CGFloat maxBody = MAX(120, MIN(sz.width - 24, 360) - (14 + 26 + 9 + 16));
    RS_toast_label.preferredMaxLayoutWidth = maxBody;
    CGSize lbl = [RS_toast_label sizeThatFits:CGSizeMake(maxBody, CGFLOAT_MAX)];
    CGFloat body = MIN(maxBody, MAX(ceil(lbl.width),
                       single ? 96 + 7 + [RS_toast_count intrinsicContentSize].width : 0));
    CGFloat lineH = ceil(RS_toast_label.font.lineHeight), extra = MAX(0, ceil(lbl.height) - lineH);
    CGFloat h = (single ? 58 : 44) + extra, w = 14 + 26 + 9 + body + 16;
    CGFloat y = rs_toast_y(parent, h);
    RS_toast.layer.cornerRadius = MIN(h / 2, 29);   // a wrapped (taller) toast keeps the pill's curve
    ws_round_corners(RS_toast.layer, kCALayerMinXMinYCorner | kCALayerMinXMaxYCorner);   // flush with the right edge
    [RS_toast.layer removeAllAnimations];
    RS_toast.frame = CGRectMake(sz.width, y, w, h);
    RS_toast.hidden = NO;
    [parent bringSubviewToFront:RS_toast];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.5 options:0
                     animations:^{ RS_toast.frame = CGRectMake(sz.width - w, y, w, h); }
                     completion:^(BOOL f) {
        if (!f) return;
        [UIView animateWithDuration:0.3 delay:2.6 options:UIViewAnimationOptionCurveEaseIn
                         animations:^{ RS_toast.frame = CGRectMake(sz.width, y, w, h); }
                         completion:^(BOOL g) { if (g) RS_toast.hidden = YES; }];
    }];
    if (!message) rs_sfx_modern(RS_SFX_PROGRESS);            // v180
    WLOG(@"research: toast '%@'%@", RS_toast_label.text, single ? RS_toast_count.text : @"");
}

static void rs_toast(int count, NSDictionary *task) { rs_toast_show(count, task, nil); }

// ---- toast timing. The server counts a catch the moment CatchPokemon arrives, which is when
// the ball LANDS -- before it shakes -- so a toast straight from /research/ping announced the
// catch before the player saw it. During an encounter we hold updates back and show them when
// the game plays its "Gotcha!" jingle (the catch is on screen), or back on the map if it fled
// or you ran. Encounter state comes from the music: '102_encounter' starts one, '101_gotcha' /
// '200_ME_gotcha' mean caught, 'walk' means back on the map (hk_play -> rs_music_changed).
#define RS_GOTCHA_DELAY  0.8     // let "Gotcha!" land first
#define RS_HOLD_MAX_S   90.0     // never sit on an update longer than this
static bool RS_in_encounter = false;
static int RS_held_count = 0;              // updates waiting for the catch to be seen
static NSDictionary *RS_held_task = nil;
static NSTimeInterval RS_held_since = 0;

static void rs_release_held(double delay) {
    if (!RS_held_count) return;
    int count = RS_held_count;
    NSDictionary *task = RS_held_task;
    RS_held_count = 0; RS_held_task = nil;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ rs_toast(count, task); });
}

static void rs_music_changed(NSString *name, bool map) {
    if ([name isEqualToString:@"102_encounter"]) {
        RS_in_encounter = true;
    } else if ([name hasSuffix:@"gotcha"]) {
        RS_in_encounter = false;
        rs_release_held(RS_GOTCHA_DELAY);
    } else if (map) {
        RS_in_encounter = false;
        rs_release_held(0.3);
    }
}

/** Show now, or hold it while an encounter is on screen. */
static void rs_announce(int count, NSDictionary *task) {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (RS_in_encounter && RS_held_count && now - RS_held_since > RS_HOLD_MAX_S)
        RS_in_encounter = false;                           // missed a music change: stop holding
    if (!RS_in_encounter) { rs_toast(count, task); return; }
    if (!RS_held_count) RS_held_since = now;
    RS_held_count += MAX(count, 1);
    RS_held_task = RS_held_count == 1 ? task : nil;        // several tasks: the "N updated" toast
    WLOG(@"research: holding toast until the catch is seen (%d pending)", RS_held_count);
}

static void rs_lb_queue(NSString *text);
static NSDictionary *RS_nests_data = nil;     // v135 nests (the Hub reads it)
static bool RS_pinging = false;
static long RS_ping_seq = -1;
static void rs_ping(void) {
    if (RS_pinging) return;
    RS_pinging = true;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/ping"]];
    rq.timeoutInterval = 4;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            RS_pinging = false;
            if (!rj(j, @"seq")) return;
            long seq = [rj(j, @"seq") longValue];
            if (rj(j, @"level")) RS_level = [rj(j, @"level") intValue];
            // v135: the nests migrated since we last looked -> one toast (queued like the
            // leaderboard ones, so it waits for encounters and menus to close)
            if (rj(j, @"nest_period")) {
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                long np = [rj(j, @"nest_period") longValue], seen = [ud integerForKey:@"windstock.nest.period"];
                if (seen > 0 && np != seen) {
                    rs_lb_queue(@"Nest migration! Parks have new nests. See what's near you in the Hub");
                    WLOG(@"nests: migration %ld -> %ld", seen, np);
                    RS_nests_data = nil;
                }
                if (np != seen) [ud setInteger:np forKey:@"windstock.nest.period"];
            }
            if (RS_ping_seq >= 0 && seq > RS_ping_seq) {
                rs_announce([rj(j, @"count") intValue], rj(j, @"task"));
                rs_fetch(false);                      // badge + open screen
            }
            RS_ping_seq = seq;
            if (rj(j, @"friend_requests")) {                // v186: a new friend request -> a toast
                static int known = -1;
                int n = [rj(j, @"friend_requests") intValue];
                if (known >= 0 && n > known) rs_lb_queue(@"New friend request! Profile menu > Friends");
                known = n;
                FR_requests = n;
            }
            // v190: "X sent you a Gift!", "X accepted your trade!" -- each note once (the newest
            // one seen is kept); a phone that never saw any only gets the last 10 minutes' worth
            NSArray *notes = rj(j, @"friend_notes");
            if ([notes isKindOfClass:[NSArray class]] && notes.count) {
                NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
                double seen = [ud doubleForKey:@"windstock.friend.note"], newest = seen;
                double floor_ms = seen > 0 ? seen : ([NSDate date].timeIntervalSince1970 - 600) * 1000.0;
                for (NSDictionary *n in notes) {
                    double ms = [rj(n, @"ms") doubleValue];
                    if (ms > floor_ms && [rj(n, @"text") isKindOfClass:[NSString class]]) {
                        rs_lb_queue(rj(n, @"text"));
                        NSString *txt = rj(n, @"text");     // v193: a chime for a gift, the fanfare for a trade
                        if ([txt containsString:@"sent you a Gift"]) rs_sfx_modern("se_go_friend_gift_send");
                        else if ([txt containsString:@"complete! You got"]) rs_sfx_modern("se_go_trade_demo");
                        else if ([txt containsString:@"accepted your friend request"]) rs_sfx_modern("se_go_friend_ok");   // v194
                        else if ([txt containsString:@"wants to trade"]) rs_sfx_modern("se_go_trade_machine");
                        WLOG(@"friends: toast \"%@\"", rj(n, @"text"));
                    }
                    newest = MAX(newest, ms);
                }
                if (newest > seen) [ud setDouble:newest forKey:@"windstock.friend.note"];
            }
        });
    }] resume];
}

// ---- v75: the Poke Ball main menu. The game keeps MainMenuGuiController "visible" whether the
// menu is open or not, so watch the taps instead: a tap on the Poke Ball at the bottom centre
// opens the menu, and the menu's close X sits in the same spot. Opening any menu screen (bag,
// Pokedex, storage...) or leaving the map also ends it.
// ---- the Nearby box, which the research buttons belong to.
// v102: the buttons show -- and take taps -- only while Nearby does, and sit on top of it.
// Where it is comes from the Pokemon ICONS inside it (NearbyPokemonPreviewIcon), projected
// through the UI camera: v94-v101 measured the NearbyPokemonPreviewGuiController's own
// rect, which on device came out as 18x38 at the far left or 118x243 mid-screen (logged
// 2026-09-25) -- that transform is not the box.
//   rs_nearby_state():  1 = Nearby is up (out = the icons' bounds, if any icon is),
//                       0 = Nearby is not up (hide the buttons),
//                      -1 = can't tell (types/functions missing): behave as before.
static void rs_nearby_why(const char *why) {
    static const char *last = NULL;
    if (why != last) { last = why; WLOG(@"research: Nearby -- %s", why); }
}
static int rs_nearby_state(UIView *parent, CGRect *out, bool *have_rect) {
    static void *t_gui = NULL, *t_icon = NULL;
    *have_rect = false;
    if (!t_gui) t_gui = mt_type("Niantic.Holoholo.NearbyPokemon.NearbyPokemonPreviewGuiController, Assembly-CSharp");
    if (!t_icon) t_icon = mt_type("Niantic.Holoholo.NearbyPokemon.NearbyPokemonPreviewIcon, Assembly-CSharp");
    if (!looks_like_ptr(t_gui) || !g_qc[QC_COMP_TR] || !g_mt[MT_FIND_ALL]) { rs_nearby_why("can't find the Nearby types"); return -1; }
    void *gui = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_gui, NULL);
    void *go = looks_like_ptr(gui) ? ((qc_inst0)g_qc[QC_COMP_GO])(gui, NULL) : NULL;
    if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) {
        rs_nearby_why("Nearby not shown -- buttons hidden");
        return 0;
    }
    // v105: and the game's own word on it -- GuiController.IsVisible (0.35 0xCE94C, the check
    // the shiny details code uses), so a Nearby that is technically active but hidden behind
    // a menu or mid-transition hides the buttons too
    if (g_shiny_base && *(uint32_t *)(g_shiny_base + 0xCE94C) == 0xa9be4ff4 &&
        !((bool (*)(void *, void *))(g_shiny_base + 0xCE94C))(gui, NULL)) {
        rs_nearby_why("Nearby hidden (IsVisible false) -- buttons hidden");
        return 0;
    }
    if (!looks_like_ptr(t_icon) || !g_spk_anchor_ok) { rs_nearby_why("Nearby shown (no icon positions)"); return 1; }
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t_icon, NULL);
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    CGSize sz = parent.bounds.size;
    CGFloat x0 = 1e9, y0 = 1e9, x1 = -1e9, y1 = -1e9;
    int used = 0;
    for (int64_t i = 0; i < n && i < 32; i++) {
        void *icon = *(void **)((uint8_t *)arr + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(icon)) continue;
        void *igo = ((qc_inst0)g_qc[QC_COMP_GO])(icon, NULL);
        if (!looks_like_ptr(igo) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(igo, NULL)) continue;
        CGPoint p;
        if (!spk_tr_screen(((qc_inst0)g_qc[QC_COMP_TR])(icon, NULL), sz, &p)) continue;
        if (p.x < sz.width * 0.35 || p.y < sz.height * 0.45) continue;   // the box lives bottom-right
        x0 = MIN(x0, p.x); x1 = MAX(x1, p.x); y0 = MIN(y0, p.y); y1 = MAX(y1, p.y);
        used++;
    }
    if (!used) { rs_nearby_why("Nearby shown, no icons to measure -- fixed spot"); return 1; }
    const CGFloat pad = 22;                              // half an icon, plus the box's margin
    // v165: the box's right edge doesn't move with its icons, but the icons' bounds do -- with
    // one Pokemon in it the bounds shrank to that one icon and the buttons slid over to sit on
    // top of it. So the right edge is the widest one measured (2+ icons) for this screen size,
    // and until there's been one, the screen's right margin (the old fixed spot's edge).
    static CGFloat right_edge = 0;
    static CGSize right_for;
    if (!CGSizeEqualToSize(right_for, sz)) { right_for = sz; right_edge = 0; }
    if (used >= 2) right_edge = MAX(right_edge, x1 + pad);
    CGFloat right = right_edge > 0 ? right_edge : sz.width - ws_safe_insets(parent).right - 16;
    x1 = MAX(x1, right - pad);
    CGRect box = CGRectMake(x0 - pad, y0 - pad, x1 - x0 + 2 * pad, y1 - y0 + 2 * pad);
    static CGRect logged;
    if (!CGRectEqualToRect(CGRectIntegral(box), logged)) {
        logged = CGRectIntegral(box);
        WLOG(@"research: Nearby box from %d icon(s): %.0f,%.0f %.0fx%.0f", used,
             box.origin.x, box.origin.y, box.size.width, box.size.height);
    }
    rs_nearby_why("Nearby shown, anchored to its icons");
    *out = box;
    *have_rect = true;
    return 1;
}

// ---- v164: the Poke Ball menu, read from the game instead of guessed from taps.
// The tap watch below (v75) counted ANY tap in a 120 x 140 pt patch around the ball as "the
// menu opened", so a tap next to the ball hid the buttons with no menu up, and they stayed
// gone until a second tap landed there. The buttons are UIKit views on top of the game's
// picture, so they can't be slotted in under the menu's green backdrop
// (MainMenuGui/MapRadialMenu/Blackout) -- but the menu's Animator says exactly when that
// backdrop is up. Its clips (sharedassets0, read 2026-10-04):
//   MapMenuInit (closed)   Blackout alpha 0                       ButtonClose off
//   ActionOpen             Blackout 0 -> 1 over 0.27 s            ButtonClose on from 0 s
//   ActionSelected         Blackout 1                             ButtonClose on
//   ActionClose            Blackout 1 until 0.1 s, 0 by 0.33 s    ButtonClose off at 0.1 s
// So ButtonClose (the X that takes the ball's place) is active exactly while the green is
// on screen. Transform.Find (it finds inactive children too) + activeInHierarchy, both
// calls the tweak already verifies; rs_tick then fades the buttons at the backdrop's own
// pace, so they look covered by it, like the Nearby box under them.
//   1 = the menu is up, 0 = it isn't, -1 = can't tell (the tap watch stays in charge)
static bool RS_ball_known = false;      // the game answered this tick: taps are not consulted
static int rs_ball_menu_state(void) {
    static void *mm_t = NULL;
    if (!g_game_live || !g_qc[QC_STR] || !g_qc[QC_FINDOBJ] || !g_qc[QC_FIND] || !g_qc[QC_COMP_TR] ||
        !g_qc[QC_COMP_GO] || !g_mt[MT_ACTIVE]) return -1;
    if (!mm_t) mm_t = mt_type("Niantic.Holoholo.Map.UI.MainMenuGuiController, Assembly-CSharp");
    if (!looks_like_ptr(mm_t)) return -1;
    void *mm = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, mm_t, NULL);
    if (!looks_like_ptr(mm)) return 0;                              // no menu object, so no menu
    void *tr = ((qc_inst0)g_qc[QC_COMP_TR])(mm, NULL);
    void *path = ((qc_static1)g_qc[QC_STR])(NULL, (void *)"MapRadialMenu/ButtonClose", NULL);
    if (!looks_like_ptr(tr) || !looks_like_ptr(path)) return -1;
    void *x_tr = ((qc_inst1)g_qc[QC_FIND])(tr, path, NULL);
    void *x_go = looks_like_ptr(x_tr) ? ((qc_inst0)g_qc[QC_COMP_GO])(x_tr, NULL) : NULL;
    if (!looks_like_ptr(x_go)) return -1;                           // not the hierarchy we know
    return ((bool (*)(void *, void *))g_mt[MT_ACTIVE])(x_go, NULL) ? 1 : 0;
}

static bool RS_ball_menu = false;
@interface WSResearchBallTap : NSObject <UIGestureRecognizerDelegate>
- (void)tapped:(UITapGestureRecognizer *)g;
@end
@implementation WSResearchBallTap
- (void)tapped:(UITapGestureRecognizer *)g {
    if (RS_ball_known) return;                                // v164: the game says, not the taps
    UIView *v = g.view;
    CGPoint p = [g locationInView:v];
    CGSize sz = v.bounds.size;
    CGFloat bottom = sz.height - ws_safe_insets(v).bottom;
    bool on_ball = fabs(p.x - sz.width / 2) < 60 && p.y > bottom - 140;
    if (!on_ball) return;
    if (RS_ball_menu) { RS_ball_menu = false; WLOG(@"research: Poke Ball menu closed"); }
    else if (RS_shown) { RS_ball_menu = true; WLOG(@"research: Poke Ball menu opened"); }
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    return !(RS_screen && !RS_screen.hidden);                 // not while Research is open
}
@end
static WSResearchBallTap *RS_ball_tap = nil;
static void rs_watch_ball(UIView *parent) {
    if (!RS_ball_tap) RS_ball_tap = [WSResearchBallTap new];
    for (UIGestureRecognizer *g in parent.gestureRecognizers) if (g.delegate == RS_ball_tap) return;
    UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:RS_ball_tap action:@selector(tapped:)];
    tap.cancelsTouchesInView = NO;
    tap.delaysTouchesBegan = NO;
    tap.delaysTouchesEnded = NO;
    tap.delegate = RS_ball_tap;
    [parent addGestureRecognizer:tap];
}
// v164: one call for rs_tick and the GO Plus's own probe -- the game's word on the menu when
// it gives one, the tap watch only when it doesn't.
static void rs_ball_menu_tick(UIView *parent) {
    int st = rs_ball_menu_state();
    static int last = -2;
    if (st != last) {
        last = st;
        WLOG(@"research: Poke Ball menu %s", st == 1 ? "open -- its backdrop covers the buttons" :
             st == 0 ? "closed" : "can't be read (yet) -- watching taps on the ball meanwhile");
    }
    RS_ball_known = st >= 0;
    if (RS_ball_known) RS_ball_menu = st == 1;
    else rs_watch_ball(parent);
}

// ---- the Windstock Hub (was "All Events" until v126): what's running now and what's next
// (server: /research/events), the Radar, and the Leaderboard when signed in to a profile.
static UIView *RS_events = nil;
static UIStackView *RS_events_stack = nil;
static UIScrollView *RS_events_scroll = nil;   // switched off on the Radar tab so
                                               // the map gets the drags, not the page
static WKWebView *RS_map = nil;
static bool RS_map_stale = true;   // v167: next rs_map_view loads afresh (tab entered / Hub opened)
static NSDictionary *RS_events_data = nil;
static int RS_events_mode = 0;                  // 0 = the event list, 1 = the radar, 2 = leaderboard
static void rs_radar_open(void);

static NSString *rs_ends_text(double ms) {
    // ends_ms 0 means an event the server runs until someone turns it off --
    // the manual one set in the World Manager, which has no end time.
    if (ms <= 0) return @"Running now";
    long s = (long)MAX(0, ms / 1000);
    if (s >= 172800) return [NSString stringWithFormat:@"Ends in %ld days and %ld hours", s / 86400, (s % 86400) / 3600];
    if (s >= 86400) return [NSString stringWithFormat:@"Ends in 1 day and %ld hours", (s % 86400) / 3600];
    if (s >= 3600) return [NSString stringWithFormat:@"Ends in %ld hours and %ld min", s / 3600, (s % 3600) / 60];
    return [NSString stringWithFormat:@"Ends in %ld min", s / 60];
}

static NSString *rs_starts_text(double ms) {
    long s = (long)MAX(0, ms / 1000);
    if (s >= 86400) return [NSString stringWithFormat:@"Starts in %ld days", s / 86400];
    if (s >= 3600) return [NSString stringWithFormat:@"Starts in %ld hours", s / 3600];
    if (s >= 120) return [NSString stringWithFormat:@"Starts in %ld min", s / 60];
    return @"Starting soon";
}

static UIView *rs_event_card(NSDictionary *e, bool now) {
    UIView *card = rs_card();
    card.layer.cornerRadius = 18;
    UILabel *title = rs_label(rj(e, @"title"), 18, true, rs_ink());
    double server = [rj(RS_events_data, @"server_ms") doubleValue];
    double drift = ([NSDate date].timeIntervalSince1970 - RS_state_rx) * 1000;
    UILabel *when = rs_label(now ? rs_ends_text([rj(e, @"ends_ms") doubleValue] - server - drift)
                                 : rs_starts_text([rj(e, @"starts_ms") doubleValue] - server - drift),
                             13, true, rs_rgb(0xE06A90));
    NSMutableArray *parts = [NSMutableArray arrayWithObjects:title, when, nil];
    NSArray *bonuses = rj(e, @"bonuses");
    if ([bonuses isKindOfClass:[NSArray class]] && bonuses.count) {
        NSMutableArray *chips = [NSMutableArray array];
        for (NSString *b in bonuses) {
            UIView *chip = [UIView new];
            chip.backgroundColor = rs_rgb(0xEAF6F2);
            chip.layer.cornerRadius = 10;
            UILabel *l = rs_label(b, 12, true, rs_rgb(0x3D7C77));
            [chip addSubview:l];
            rs_pin(l, chip, UIEdgeInsetsMake(6, 10, 6, 10));
            [chips addObject:chip];
        }
        // v146: two chips a row -- Halloween has four and one row ran off the card
        NSMutableArray *rows = [NSMutableArray array];
        for (NSUInteger i = 0; i < chips.count; i += 2) {
            UIStackView *row = rs_hstack([chips subarrayWithRange:NSMakeRange(i, MIN((NSUInteger)2, chips.count - i))], 8);
            row.alignment = UIStackViewAlignmentCenter;
            [rows addObject:row];
        }
        UIStackView *col = rs_vstack(rows, 6);
        col.alignment = UIStackViewAlignmentLeading;
        [parts addObject:col];
    }
    UIStackView *v = rs_vstack(parts, 8);
    UIImageView *icon = [rj(e, @"kind") isEqual:@"research"]
        ? rs_image_tinted(@"/research/art/QuestSymbolMap.png", 44, 44, rs_teal())
        : rs_image(@"/research/art/TodayView_Icon_Event.png", 44, 44);
    UIStackView *row = rs_hstack(@[icon, v], 14);
    row.alignment = UIStackViewAlignmentTop;
    [card addSubview:row];
    rs_pin(row, card, UIEdgeInsetsMake(16, 16, 16, 16));
    return card;
}


static void rs_events_render(void);

// EVENTS | RADAR | LEADERBOARD, drawn like the Research screen's tabs.
static UIStackView *rs_events_tabs(void) {
    NSArray *names = rs_lb_on() ? @[@"EVENTS", @"RADAR", @"LEADERBOARD"] : @[@"EVENTS", @"RADAR"];
    UIStackView *strip = rs_hstack(@[], 0);
    strip.distribution = UIStackViewDistributionFillEqually;
    for (int i = 0; i < (int)names.count; i++) {
        UIView *tab = [UIView new];
        bool on = i == RS_events_mode;
        UILabel *l = rs_label(names[i], 15, true, UIColor.whiteColor);
        NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:names[i]];
        [a addAttribute:NSKernAttributeName value:@(1.2) range:NSMakeRange(0, a.length)];
        [a addAttribute:NSForegroundColorAttributeName
                  value:on ? UIColor.whiteColor : [UIColor colorWithWhite:1 alpha:0.62]
                  range:NSMakeRange(0, a.length)];
        l.attributedText = a;
        l.textAlignment = NSTextAlignmentCenter;
        l.numberOfLines = 1;
        l.adjustsFontSizeToFitWidth = YES;          // LEADERBOARD shrinks to fit a third of the width
        l.minimumScaleFactor = 0.5;
        UIView *pill = [UIView new];
        pill.backgroundColor = on ? rs_teal() : UIColor.clearColor;
        pill.layer.cornerRadius = 17;
        [tab addSubview:pill];
        [pill addSubview:l];
        pill.translatesAutoresizingMaskIntoConstraints = NO;
        l.translatesAutoresizingMaskIntoConstraints = NO;
        [NSLayoutConstraint activateConstraints:@[
            [pill.topAnchor constraintEqualToAnchor:tab.topAnchor constant:6],
            [pill.bottomAnchor constraintEqualToAnchor:tab.bottomAnchor constant:-8],
            [pill.leadingAnchor constraintEqualToAnchor:tab.leadingAnchor constant:6],
            [pill.trailingAnchor constraintEqualToAnchor:tab.trailingAnchor constant:-6],
            [pill.heightAnchor constraintEqualToConstant:34],
            [l.centerXAnchor constraintEqualToAnchor:pill.centerXAnchor],
            [l.widthAnchor constraintLessThanOrEqualToAnchor:pill.widthAnchor constant:-10],
            [l.centerYAnchor constraintEqualToAnchor:pill.centerYAnchor]]];
        int idx = i;
        rs_on_tap(tab, ^{
            if (idx == 1 && RS_events_mode != 1) RS_map_stale = true;
            RS_events_mode = idx;
            if (RS_events_scroll) [RS_events_scroll setContentOffset:CGPointZero animated:NO];
            rs_events_render();
        });
        [strip addArrangedSubview:tab];
    }
    return strip;
}

// The map, served by our own server (/research/map). It knows which trainer
// this is from the request's address, so there is nothing to sign into.
static UIView *rs_map_view(void) {
    if (!RS_map) {
        WKWebViewConfiguration *cfg = [WKWebViewConfiguration new];
        cfg.allowsInlineMediaPlayback = YES;
        RS_map = [[WKWebView alloc] initWithFrame:CGRectZero configuration:cfg];
        RS_map.opaque = NO;
        RS_map.backgroundColor = UIColor.clearColor;
        RS_map.layer.cornerRadius = 18;
        RS_map.layer.masksToBounds = YES;
        // Leaflet does its own panning and zooming; the web view must not.
        RS_map.scrollView.scrollEnabled = NO;
        RS_map.scrollView.bounces = NO;
    }
    // NOT RS_HOST. A WKWebView does its networking in a SEPARATE process, so
    // the launcher's in-app hostname redirect and its NSURLProtocol never see
    // these requests: loading the Niantic hostname here was claimed by the
    // interception and then silently never loaded -- the server logged no hit
    // at all and the tab came up blank. Go straight at the loopback server,
    // the way the launcher's own Game Editor web view does.
    // (A server running on a Mac instead would need its address here.)
    // v152: or the Windstock Online server's own address, when that is where we play.
    NSURL *u = ws_web_rebase([NSURL URLWithString:RS_MAP_URL]);
    // v167: load it once. Every Hub redraw comes through here, and reloading each time
    // threw away whatever you were looking at -- tap a Pokemon, and its card vanished
    // a moment later when the events download landed and redrew the tab. Still a
    // fresh load for a new address (Online vs. the phone's own server).
    static NSURL *loaded = nil;
    if (RS_map_stale || ![loaded isEqual:u] || !RS_map.URL) {
        RS_map_stale = false;
        loaded = u;
        [RS_map loadRequest:[NSURLRequest requestWithURL:u]];
    }
    return RS_map;
}

// ---- the community goal card (v127), top of the hub's EVENTS tab. The goal comes with the
// standing (windstock-leaderboard.json): the website counts everyone's catches or spins
// toward it and says whether this trainer helped. The reward is paid by our own server
// (research.py goal_claim), once per goal.
static bool RS_goal_claiming = false;

static NSString *rs_goal_key(NSDictionary *g, NSString *what) {
    return [NSString stringWithFormat:@"windstock.goal.%@.%@", what, rj(g, @"id") ?: @"?"];
}

static void rs_goal_claim(NSDictionary *g) {
    if (RS_goal_claiming) return;
    RS_goal_claiming = true;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/goal_claim"]];
    rq.HTTPMethod = @"POST";
    rq.timeoutInterval = 8;
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:@{@"id": rj(g, @"id") ?: @"",
                                                            @"rewards": rj(g, @"rewards") ?: @[]}
                                                  options:0 error:nil];
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            RS_goal_claiming = false;
            if ([rj(j, @"ok") boolValue]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:rs_goal_key(g, @"claimed")];
                rs_toast_show(1, nil, [rj(j, @"already") boolValue] ? @"Reward already claimed"
                                                                      : @"Community goal reward claimed!");
                WLOG(@"goal: claimed %@", rj(g, @"id"));
            } else {
                rs_toast_show(1, nil, @"Couldn't claim the reward. Try again.");
                WLOG(@"goal: claim failed %@", rj(j, @"error") ?: e.localizedDescription);
            }
            rs_events_render();
        });
    }] resume];
    rs_events_render();                        // "Claiming..."
}

static NSString *rs_goal_left(double ends_ms) {
    long s = (long)(ends_ms / 1000.0 - [NSDate date].timeIntervalSince1970);
    if (s <= 0) return @"Ended";
    long h = s / 3600, m = (s % 3600) / 60;
    if (h >= 48) return [NSString stringWithFormat:@"%ld days left", h / 24];
    if (h >= 1) return [NSString stringWithFormat:@"%ldh %ldm left", h, m];
    return [NSString stringWithFormat:@"%ldm left", MAX(1L, m)];
}

static UIView *rs_goal_card(NSDictionary *g) {
    bool done = rj(g, @"completedAt") != nil;
    int prog = rs_num(rj(g, @"progress")), target = MAX(1, rs_num(rj(g, @"target")));
    int mine = rs_num(rj(g, @"mine"));
    NSString *metric = [rj(g, @"metric") isEqual:@"spun"] ? @"spun" : @"caught";

    UILabel *kicker = rs_label(done ? @"COMMUNITY GOAL · COMPLETE!" : @"COMMUNITY GOAL", 12, true,
                               done ? rs_green() : rs_teal());
    UILabel *title = rs_label(rj(g, @"title") ?: @"", 20, true, rs_ink());
    WSResearchBar *bar = [WSResearchBar new];
    bar.segments = 0;
    bar.fraction = MIN(1.0, (CGFloat)prog / target);
    rs_size(bar, 0, 12);
    UILabel *nums = rs_label([NSString stringWithFormat:@"%@ / %@ %@", rs_thousands(prog), rs_thousands(target),
                              rj(g, @"metricLabel") ?: metric], 15, true, rs_ink());
    NSString *when = done ? @"Target reached!" : rs_goal_left([rj(g, @"endsAt") doubleValue]);
    int players = rs_num(rj(g, @"players"));
    UILabel *meta = rs_label([NSString stringWithFormat:@"%@ · %d %@ · you: %@", when, players,
                              players == 1 ? @"trainer" : @"trainers", rs_thousands(mine)], 13, false, rs_ink2());
    UILabel *reward = rs_label([NSString stringWithFormat:@"Reward: %@", rj(g, @"rewardText") ?: @""], 14, true, rs_gold());
    NSMutableArray *views = [@[kicker, title, bar, nums, meta, reward] mutableCopy];

    if (done && [rj(g, @"eligible") boolValue]) {
        bool claimed = [[NSUserDefaults standardUserDefaults] boolForKey:rs_goal_key(g, @"claimed")];
        UILabel *btn = rs_label(claimed ? @"Reward claimed ✓" : (RS_goal_claiming ? @"Claiming…" : @"Claim reward"),
                                16, true, UIColor.whiteColor);
        btn.textAlignment = NSTextAlignmentCenter;
        btn.backgroundColor = claimed ? rs_ink2() : rs_green();
        btn.layer.cornerRadius = 20;
        btn.clipsToBounds = YES;
        rs_size(btn, 0, 40);
        if (!claimed) rs_on_tap(btn, ^{ rs_goal_claim(g); });
        [views addObject:btn];
    } else if (done) {
        [views addObject:rs_label(@"The reward goes to trainers who helped. Join in on the next one!", 13, false, rs_ink2())];
    } else if (!mine) {
        [views addObject:rs_label([metric isEqual:@"spun"] ? @"Spin PokéStops to help out!" : @"Catch Pokémon to help out!",
                                  13, true, rs_teal())];
    }
    UIView *c = rs_card();
    UIStackView *v = rs_vstack(views, 6);
    ws_spacing_after(v, 12, title);
    [c addSubview:v];
    rs_pin(v, c, UIEdgeInsetsMake(16, 16, 16, 16));
    return c;
}

// ---- Nests (v135): the nesting parks near you and when they migrate (server: /research/nests,
// nests.py). Shown on the EVENTS tab under the events, fetched with them.
static NSString *rs_migrates_text(double ms) {
    long s = (long)MAX(0, ms / 1000);
    if (s >= 86400) return [NSString stringWithFormat:@"Nests migrate in %ld %@ and %ld hours", s / 86400,
                            s / 86400 == 1 ? @"day" : @"days", (s % 86400) / 3600];
    if (s >= 3600) return [NSString stringWithFormat:@"Nests migrate in %ld hours and %ld min", s / 3600, (s % 3600) / 60];
    return [NSString stringWithFormat:@"Nests migrate in %ld min", MAX(1L, s / 60)];
}

static NSString *rs_dist_text(int m) {
    return m >= 1000 ? [NSString stringWithFormat:@"%.1f km", m / 1000.0]
                     : [NSString stringWithFormat:@"%d m", MAX(10, m / 10 * 10)];
}

static UIView *rs_nests_card(NSDictionary *nd) {
    double server = [rj(nd, @"server_ms") doubleValue];
    double drift = ([NSDate date].timeIntervalSince1970 - RS_state_rx) * 1000;
    NSDictionary *mig = rj(nd, @"migration");
    UILabel *kicker = rs_label(@"NESTS NEAR YOU", 12, true, rs_teal());
    UILabel *when = rs_label(rs_migrates_text([rj(mig, @"next_ms") doubleValue] - server - drift),
                             13, true, rs_rgb(0xE06A90));
    NSMutableArray *views = [@[kicker, when] mutableCopy];
    NSArray *rows = rj(nd, @"nests");
    if (![rows isKindOfClass:[NSArray class]] || !rows.count) {
        NSString *msg = rj(nd, @"message") ?: @"No nesting parks close by this cycle. Try a bigger park, "
                                               @"or check back after the migration.";
        [views addObject:rs_label(msg, 14, false, rs_ink2())];
    } else {
        int shown = 0;
        for (NSDictionary *n in rows) {
            if (shown++ >= 8) break;
            UIImageView *icon = rs_image([NSString stringWithFormat:@"/research/pokemon/%d.png",
                                          rs_num(rj(n, @"species"))], 44, 44);
            UILabel *sp = rs_label(rj(n, @"species_name") ?: @"?", 16, true, rs_ink());
            UILabel *park = rs_label(rj(n, @"name") ?: @"Park", 13, false, rs_ink2());
            park.numberOfLines = 1;
            park.lineBreakMode = NSLineBreakByTruncatingTail;
            UIStackView *text = rs_vstack(@[sp, park], 2);
            UILabel *d = rs_label(rs_dist_text(rs_num(rj(n, @"distance_m"))), 13, true, rs_teal());
            [d setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
            [d setContentCompressionResistancePriority:UILayoutPriorityRequired
                                               forAxis:UILayoutConstraintAxisHorizontal];
            [views addObject:rs_hstack(@[icon, text, d], 12)];
        }
    }
    UIView *c = rs_card();
    UIStackView *v = rs_vstack(views, 8);
    ws_spacing_after(v, 12, when);
    [c addSubview:v];
    rs_pin(v, c, UIEdgeInsetsMake(16, 16, 16, 16));
    return c;
}

static void rs_nests_fetch(void) {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/nests"]];
    rq.timeoutInterval = 8;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![j isKindOfClass:[NSDictionary class]]) return;
            RS_nests_data = j;
            WLOG(@"nests: %lu near", (unsigned long)[rj(j, @"nests") count]);
            if (RS_events && !RS_events.hidden && RS_events_mode == 0) rs_events_render();
        });
    }] resume];
}

// ---- v146: the Halloween banner, top of the EVENTS tab while an event with theme
// "halloween" runs (events.py SEASONAL: Oct 26 - Nov 1). Night-purple card, pumpkin-orange
// title, the four Pokemon the event brings out, and the time left.
static UIView *rs_halloween_banner(NSDictionary *e) {
    UIView *card = rs_card();
    card.layer.cornerRadius = 20;
    card.backgroundColor = rs_rgb(0x2B1640);
    card.layer.borderColor = rs_rgb(0xF08A24).CGColor;
    card.layer.borderWidth = 2;
    card.layer.shadowColor = rs_rgb(0x7A2FB8).CGColor;
    card.layer.shadowOpacity = 0.55;
    card.layer.shadowRadius = 12;
    UILabel *title = rs_label(@"\U0001F383  Halloween  \U0001F47B", 24, true, rs_rgb(0xF6A13A));
    title.textAlignment = NSTextAlignmentCenter;
    UILabel *sub = rs_label(@"Ghosts, bats and bones are out in force. Double candy, double XP "
                            @"and double shiny chance!", 14, true, rs_rgb(0xE9DDF7));
    sub.textAlignment = NSTextAlignmentCenter;
    NSMutableArray *mons = [NSMutableArray array];
    for (NSNumber *n in @[@92, @41, @96, @104]) {             // Gastly, Zubat, Drowzee, Cubone
        UIView *disc = [UIView new];
        disc.backgroundColor = rs_rgb(0x43245F);
        disc.layer.cornerRadius = 30;
        rs_size(disc, 60, 60);
        UIImageView *iv = rs_image([NSString stringWithFormat:@"/research/pokemon/%@.png", n], 50, 50);
        [disc addSubview:iv];
        [NSLayoutConstraint activateConstraints:@[
            [iv.centerXAnchor constraintEqualToAnchor:disc.centerXAnchor],
            [iv.centerYAnchor constraintEqualToAnchor:disc.centerYAnchor]]];
        [mons addObject:disc];
    }
    UIStackView *row = rs_hstack(mons, 10);
    double server = [rj(RS_events_data, @"server_ms") doubleValue];
    double drift = ([NSDate date].timeIntervalSince1970 - RS_state_rx) * 1000;
    UILabel *when = rs_label(rs_ends_text([rj(e, @"ends_ms") doubleValue] - server - drift),
                             13, true, rs_rgb(0xF6A13A));
    when.textAlignment = NSTextAlignmentCenter;
    UIStackView *v = rs_vstack(@[title, sub, row, when], 10);
    v.alignment = UIStackViewAlignmentCenter;
    [card addSubview:v];
    rs_pin(v, card, UIEdgeInsetsMake(18, 16, 18, 16));
    return card;
}

static void rs_events_render(void) {
    if (!RS_events_stack) return;
    for (UIView *v in RS_events_stack.arrangedSubviews) {
        [RS_events_stack removeArrangedSubview:v];
        [v removeFromSuperview];
    }
    if (RS_events_mode == 2 && !rs_lb_on()) RS_events_mode = 0;     // signed out meanwhile
    UILabel *big = rs_label(@"Windstock Hub", 30, true, UIColor.whiteColor);
    big.textAlignment = NSTextAlignmentCenter;
    [RS_events_stack addArrangedSubview:big];
    [RS_events_stack addArrangedSubview:rs_events_tabs()];
    if (RS_events_mode == 1) {
        // The map fills what is left of the screen. The page scrolls nothing of
        // its own, so the outer scroll view has to let go of the gestures.
        if (RS_events_scroll) RS_events_scroll.scrollEnabled = NO;
        UIView *m = rs_map_view();
        CGFloat h = MAX(320, RS_events.bounds.size.height - 210);
        rs_size(m, 0, h);
        [RS_events_stack addArrangedSubview:m];
        return;
    }
    if (RS_events_scroll) RS_events_scroll.scrollEnabled = YES;
    if (RS_events_mode == 2) {
        rs_lb_render(RS_events_stack);
        UIView *pad = [UIView new];
        rs_size(pad, 0, 90);
        [RS_events_stack addArrangedSubview:pad];
        return;
    }
    NSDictionary *goal = rs_lb_on() ? rj(RS_lb, @"goal") : nil;
    if ([goal isKindOfClass:[NSDictionary class]] && rj(goal, @"id"))
        [RS_events_stack addArrangedSubview:rs_goal_card(goal)];
    NSArray *now = rj(RS_events_data, @"now") ?: @[];
    NSArray *soon = rj(RS_events_data, @"soon") ?: @[];
    if (!RS_events_data) {
        UILabel *l = rs_label(@"Loading events…", 16, true, [UIColor colorWithWhite:1 alpha:0.7]);
        l.textAlignment = NSTextAlignmentCenter;
        [RS_events_stack addArrangedSubview:l];
        return;
    }
    if (!now.count && !soon.count) {
        UIView *c = rs_card();
        UILabel *l = rs_label(@"Nothing scheduled right now. Events you set up in the World "
                              @"Manager show up here. The radar above works either way.",
                              15, true, rs_ink2());
        l.textAlignment = NSTextAlignmentCenter;
        [c addSubview:l];
        rs_pin(l, c, UIEdgeInsetsMake(20, 18, 20, 18));
        [RS_events_stack addArrangedSubview:c];
    }
    for (NSDictionary *e in now)
        if ([rj(e, @"theme") isEqual:@"halloween"]) {
            [RS_events_stack addArrangedSubview:rs_halloween_banner(e)];
            break;
        }
    if (now.count) {
        UILabel *h = rs_label(@"Happening Now", 19, true, UIColor.whiteColor);
        [RS_events_stack addArrangedSubview:h];
        for (NSDictionary *e in now) [RS_events_stack addArrangedSubview:rs_event_card(e, true)];
    }
    if (soon.count) {
        UILabel *h = rs_label(@"Coming Up", 19, true, UIColor.whiteColor);
        [RS_events_stack addArrangedSubview:h];
        for (NSDictionary *e in soon) [RS_events_stack addArrangedSubview:rs_event_card(e, false)];
    }
    if ([rj(RS_nests_data, @"enabled") boolValue]) {
        [RS_events_stack addArrangedSubview:rs_label(@"Nests", 19, true, UIColor.whiteColor)];
        [RS_events_stack addArrangedSubview:rs_nests_card(RS_nests_data)];
    }
    UIView *pad = [UIView new];
    rs_size(pad, 0, 90);
    [RS_events_stack addArrangedSubview:pad];
}

static void rs_events_fetch(void) {
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/research/events"]];
    rq.timeoutInterval = 6;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if ([j isKindOfClass:[NSDictionary class]]) {
                RS_events_data = j;
                if (RS_events_mode != 1) rs_events_render();   // v167: the radar has no event cards
            }
        });
    }] resume];
}

static void rs_events_close(void) {
    if (!RS_events || RS_events.hidden) return;
    if (RS_events_mode != 0) {                  // the X on the radar/leaderboard goes back to the events
        RS_events_mode = 0;
        rs_events_render();
        return;
    }
    UIView *screen = RS_events;
    if (!RS_events_quiet) rs_sfx(RS_SFX_CLOSE);
    [UIView animateWithDuration:0.18 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ screen.alpha = 0; }
                     completion:^(BOOL f) { screen.hidden = YES; screen.alpha = 1; }];
}

static bool rs_events_build(UIView *parent) {
    if (!RS_events || RS_events.superview != parent) {
        [RS_events removeFromSuperview];
        RS_events = [[UIView alloc] initWithFrame:parent.bounds];
        RS_events.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAGradientLayer *bg = [CAGradientLayer layer];
        bg.colors = @[(id)[rs_rgb(0x3B2255) colorWithAlphaComponent:0.95].CGColor,
                      (id)[rs_rgb(0x6A3A63) colorWithAlphaComponent:0.95].CGColor];
        bg.frame = CGRectMake(0, 0, 3000, 3000);
        [RS_events.layer addSublayer:bg];
        UIScrollView *scroll = [UIScrollView new];
        scroll.alwaysBounceVertical = YES;
        scroll.showsVerticalScrollIndicator = NO;
        [RS_events addSubview:scroll];
        scroll.translatesAutoresizingMaskIntoConstraints = NO;
        RS_events_scroll = scroll;
        RS_events_stack = rs_vstack(@[], 12);
        [scroll addSubview:RS_events_stack];
        RS_events_stack.translatesAutoresizingMaskIntoConstraints = NO;
        UIImageView *close = rs_image(@"/research/art/btn_close_normal.png", 60, 60);
        [RS_events addSubview:close];
        rs_on_tap(close, ^{ rs_events_close(); });
        rs_on_drag(RS_events, scroll,                                           // v179: back to Research
                   ^NSArray<UIView *> *(int dir) {
                       UIView *r = dir < 0 && RS_events_mode == 0 ? rs_research_prepare() : nil;
                       return r ? @[RS_events, r] : @[RS_events];
                   },
                   ^(int dir, bool finished) { if (RS_screen && RS_events && !RS_events.hidden) RS_screen.hidden = YES; },
                   ^(int dir) { rs_swap_to_research(); });
        UILayoutGuide *safe = ws_safe_guide(RS_events);
        [NSLayoutConstraint activateConstraints:@[
            [scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
            [scroll.bottomAnchor constraintEqualToAnchor:RS_events.bottomAnchor],
            [scroll.leadingAnchor constraintEqualToAnchor:RS_events.leadingAnchor],
            [scroll.trailingAnchor constraintEqualToAnchor:RS_events.trailingAnchor],
            [RS_events_stack.topAnchor constraintEqualToAnchor:scroll.topAnchor constant:16],
            [RS_events_stack.bottomAnchor constraintEqualToAnchor:scroll.bottomAnchor constant:-16],
            [RS_events_stack.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
            [RS_events_stack.widthAnchor constraintEqualToAnchor:scroll.widthAnchor constant:-32],
            [close.centerXAnchor constraintEqualToAnchor:RS_events.centerXAnchor],
            [close.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]]];
        RS_events.hidden = YES;
        [parent addSubview:RS_events];
    }
    return RS_events != nil;
}

static void rs_events_open(void) {
    UIView *parent = mt_unity_view();
    if (!parent || !rs_events_build(parent)) return;
    RS_events.transform = CGAffineTransformIdentity;
    RS_events.hidden = NO;
    [parent bringSubviewToFront:RS_events];
    RS_events.alpha = 0;
    [UIView animateWithDuration:0.18 animations:^{ RS_events.alpha = 1; }];
    rs_sfx(RS_SFX_OPEN);
    if (RS_screen && !RS_screen.hidden) {       // swiped over from Research: no close sound
        RS_screen.hidden = YES;
        RS_screen.transform = CGAffineTransformIdentity;
    }
    RS_events_mode = 0;
    rs_events_render();
    rs_events_fetch();
    rs_nests_fetch();
    WLOG(@"research: Windstock Hub opened");
}

// ---- v179: Research <-> Hub by dragging. prepare = built, rendered and shown off to the side
// (the drag places it); swap = the drag finished, make the new screen the open one.
/** v183: dragging toward a tab beside this one. The page the drag started on becomes a picture
 *  (taken ONCE per drag, v184 -- it only slides away); the real cards are drawn with the tab
 *  being dragged to, to come in beside it. */
static UIView *rs_peek_to(int to) {
    int count = [(rj(RS_state, @"timed") ?: @[]) count] ? 3 : 2;
    if (!RS_screen || !RS_scroll || to < 0 || to >= count) return nil;
    if (RS_peek_from < 0) {
        UIView *snap = [RS_scroll snapshotViewAfterScreenUpdates:NO];
        if (!snap) return nil;
        snap.frame = RS_scroll.frame;
        snap.userInteractionEnabled = NO;
        [RS_screen insertSubview:snap aboveSubview:RS_scroll];
        RS_peek_snap = snap;
        RS_peek_from = RS_tab;
    }
    if (RS_tab != to) {
        CFTimeInterval t0 = CACurrentMediaTime();
        RS_tab = to;
        [RS_scroll setContentOffset:CGPointZero animated:NO];
        rs_render();
        [RS_screen layoutIfNeeded];
        static int logged = 0;
        if (logged++ < 3) WLOG(@"research: drew the tab beside in %.0f ms", (CACurrentMediaTime() - t0) * 1000);
    }
    return RS_peek_snap;
}
static void rs_hub_drag_cancel(void) {          // dragged toward the Hub, let go short
    if (RS_events && !RS_events.hidden && RS_screen && !RS_screen.hidden) RS_events.hidden = YES;
}
static void rs_peek_end(bool keep) {
    if (RS_peek_from < 0) return;
    [RS_peek_snap removeFromSuperview];
    RS_peek_snap = nil;
    RS_stack.transform = CGAffineTransformIdentity;
    bool back = !keep && RS_tab != RS_peek_from;
    if (!keep) RS_tab = RS_peek_from;
    RS_peek_from = -1;
    if (back) rs_render();                        // the old page comes back
    else rs_render_tabs();                        // the pill moves over
}

static UIView *rs_events_prepare(void) {
    UIView *parent = mt_unity_view();
    if (!parent || !rs_events_build(parent)) return nil;
    RS_events_mode = 0;
    rs_events_render();
    [parent bringSubviewToFront:RS_events];
    return RS_events;
}
static UIView *rs_research_prepare(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return nil;
    if (!RS_screen || RS_screen.superview != parent) {
        [RS_screen removeFromSuperview];
        RS_screen = nil;
        rs_build(parent);
    }
    rs_render();
    [parent bringSubviewToFront:RS_screen];
    return RS_screen;
}
static void rs_swap_to_hub(void) {
    RS_screen.hidden = YES;
    RS_screen.transform = CGAffineTransformIdentity;
    RS_events.hidden = NO; RS_events.alpha = 1;
    RS_events.transform = CGAffineTransformIdentity;
    rs_events_fetch();
    rs_nests_fetch();
    WLOG(@"research: dragged over to the Windstock Hub");
}
static void rs_swap_to_research(void) {
    RS_events.hidden = YES;
    RS_events.transform = CGAffineTransformIdentity;
    RS_screen.hidden = NO; RS_screen.alpha = 1;
    RS_screen.transform = CGAffineTransformIdentity;
    rs_fetch(true);
    WLOG(@"research: dragged back to Research");
}

// ---- Radar: the Help Center's 500 m sweep, on a MAP.
// The tab hosts the server's /research/map page (rs_map_view), which does the
// sweeping, the once-a-minute countdown and the drawing itself. The native
// list that used to live here -- rows, timer, cooldown label -- went with it.

// The native radar list lived here. The Radar TAB now shows the server's map
// page instead (rs_map_view), which is the same sweep drawn on a real map.

// ---- "Global position moved up!" (v124). The rank last announced is kept in the game's
// defaults, so a change that happened while the game was closed is announced on return.
// Like research updates, it waits until an encounter is over.
static NSMutableArray<NSString *> *RS_lb_toasts = nil;     // one per tick, oldest first

static void rs_lb_queue(NSString *text) {
    if (!RS_lb_toasts) RS_lb_toasts = [NSMutableArray new];
    [RS_lb_toasts addObject:text];
}

/** v127: "New community goal: ..." once per goal, and "complete!" once when it's reached. */
static void rs_goal_notice(void) {
    NSDictionary *g = rj(RS_lb, @"goal");
    if (![g isKindOfClass:[NSDictionary class]] || !rj(g, @"id")) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    bool done = rj(g, @"completedAt") != nil;
    if (![ud boolForKey:rs_goal_key(g, @"seen")]) {
        [ud setBool:YES forKey:rs_goal_key(g, @"seen")];
        if (!done && [rj(g, @"endsAt") doubleValue] / 1000.0 > [NSDate date].timeIntervalSince1970)
            rs_lb_queue([NSString stringWithFormat:@"New community goal: %@", rj(g, @"title") ?: @""]);
    }
    if (done && ![ud boolForKey:rs_goal_key(g, @"done")]) {
        [ud setBool:YES forKey:rs_goal_key(g, @"done")];
        rs_lb_queue([rj(g, @"eligible") boolValue] ? @"Community goal complete! Claim your reward in the Hub"
                                                  : @"Community goal complete!");
        WLOG(@"goal: %@ complete", rj(g, @"id"));
    }
}

static void rs_lb_tick(bool screen_open) {
    if (rs_lb_load()) {
        int rank = rs_num(rj(RS_lb, @"rank"));
        NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
        int seen = (int)[ud integerForKey:@"windstock.lb.rank"];
        if (rank > 0 && seen > 0 && rank != seen) {
            rs_lb_queue(rank < seen
                ? [NSString stringWithFormat:@"Global position moved up! #%d → #%d", seen, rank]
                : [NSString stringWithFormat:@"Global position moved down. #%d → #%d", seen, rank]);
            WLOG(@"leaderboard: #%d -> #%d", seen, rank);
        }
        if (rank > 0) [ud setInteger:rank forKey:@"windstock.lb.rank"];
        rs_goal_notice();
        if (RS_events && !RS_events.hidden && RS_events_mode != 1 && !RS_goal_claiming) rs_events_render();
    }
    if (RS_lb_toasts.count && !RS_in_encounter && !screen_open) {
        rs_toast_show(1, nil, RS_lb_toasts.firstObject);
        [RS_lb_toasts removeObjectAtIndex:0];
    }
}

__attribute__((unused))   // the event cards' Radar pill is gone; the RADAR tab is how you open it now
static void rs_radar_open(void) {
    RS_events_mode = 1;
    // No sweep from here any more. The Radar tab is the server's map page and
    // it sweeps as soon as it loads; doing one here first would spend the
    // once-a-minute cooldown and the map would open "still recharging".
    rs_events_render();
    WLOG(@"research: radar opened");
}

// ---- the binoculars button, only on the plain map
// v67: the scan over every GuiController (v66) only ever saw the HUD, so menus never hid
// the button. Instead ask Unity for each menu screen by type -- FindObjectOfType, the same
// lookup that reliably detects storage. The common ones are checked every tick; the rest
// round-robin a few per tick. Found = hide at once; show again only after a clean full pass.
static const char *kRsBlockers[] = {
    "Niantic.Holoholo.Map.UI.PokeNavExpandedGuiController",
    "Niantic.Holoholo.Pokestop.PokestopSpinnerInteractionGuiController",
    "Niantic.Holoholo.Gym.ApproachUIController",
    "Niantic.Holoholo.UI.Pokemon.PokemonInventoryGuiController",
    "Niantic.Holoholo.UI.Pokemon.PokemonInfoGuiController",
    "Niantic.Holoholo.UI.Items.ItemInventoryGuiController",
    "Niantic.Holoholo.UI.PlayerProfileGuiController",
    // ---- round-robin from here
    "Niantic.Holoholo.UI.Pokedex.PokedexListGuiController",
    "Niantic.Holoholo.UI.Pokedex.PokedexInfoGuiController",
    "Niantic.Holoholo.UI.SettingsGuiController",
    "Niantic.Holoholo.Storefront.StorefrontGuiController",
    "Niantic.Holoholo.Storefront.BuyItemGuiController",
    "Niantic.Holoholo.Pokestop.PokestopDiskInteractionGuiController",
    "Niantic.Holoholo.Pokestop.PokestopDiskConfirmationGuiController",
    "Niantic.Holoholo.Gym.BattlePrepUIController",
    "Niantic.Holoholo.Gym.PickTeamUIController",
    "Niantic.Holoholo.Battle.GymBattleUI",
    "Niantic.Holoholo.Encounter.EncounterUIController",
    "Niantic.Holoholo.UI.EggHatchGuiController",
    "Niantic.Holoholo.UI.IncubatorSelectorGuiController",
    "Niantic.Holoholo.UI.ModalDialog",
    "Niantic.Holoholo.UI.LevelUpGuiController",
    "Niantic.Holoholo.UI.BadgeAwardGuiController",
    "Niantic.Holoholo.UI.BadgeDetailGuiController",
    "Niantic.Holoholo.UI.ActivityLogGuiController",
    "Niantic.Holoholo.UI.AboutScreenGuiController",
    "Niantic.Holoholo.UI.NicknamePopupGuiController",
    "Niantic.Holoholo.UI.NumericalPickerDialog",
    "Niantic.Holoholo.Encounter.ItemUseConfirmationGuiController",
    "Niantic.Holoholo.UI.Conversations.ConversationLayoutGui",
    "Niantic.Holoholo.Cutscenes.PokemonCutsceneGuiController",
    "Niantic.Holoholo.Items.PlayerBuffSelectionGuiController",
};
#define RS_BLOCKERS (int)(sizeof(kRsBlockers) / sizeof(kRsBlockers[0]))
#define RS_ALWAYS 7
#define RS_PER_TICK 6
static void *g_rs_block_types[RS_BLOCKERS];
// GuiController.get_IsVisible: 0.29 0xBF18C -> 0.35 0xCE94C (get_Canvas 0xBF13C->0xCE8FC and
// get_IsDestroyed 0xBF2AC->0xCEA6C port uniquely; both builds keep the same spacing)
#define RVA_GUI_IS_VISIBLE   0xCE94C
#define FIRST_GUI_IS_VISIBLE 0xa9be4ff4
static void *g_rs_is_visible = NULL;

static bool rs_blocker_open(int i) {
    if (!g_game_live) return false;
    if (!g_rs_block_types[i]) {
        char full[160];
        snprintf(full, sizeof full, "%s, Assembly-CSharp", kRsBlockers[i]);
        g_rs_block_types[i] = mt_type(full);
        if (!looks_like_ptr(g_rs_block_types[i])) { g_rs_block_types[i] = (void *)1; }
    }
    if (g_rs_block_types[i] == (void *)1) return false;             // type not in this build
    void *gc = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, g_rs_block_types[i], NULL);
    // v68: some screens (the main menu...) stay alive while closed -- only a VISIBLE one counts
    bool open = looks_like_ptr(gc) && (!g_rs_is_visible || ((bool (*)(void *, void *))g_rs_is_visible)(gc, NULL));
    static int last_logged = -1;
    if (open && last_logged != i) { last_logged = i; WLOG(@"research: button hidden for %s", kRsBlockers[i]); }
    return open;
}

static bool rs_map_clear(void) {
    if (!g_map_active || !g_game_live) return false;
    // v69: MainMenuGuiController reports IsVisible=YES on the plain map, so it can't hide the
    // button by itself. Log how it changes, to find what the opened menu looks like.
    static void *mm_t = NULL;
    if (!mm_t) mm_t = mt_type("Niantic.Holoholo.Map.UI.MainMenuGuiController, Assembly-CSharp");
    if (looks_like_ptr(mm_t) && g_rs_is_visible) {
        void *mm = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, mm_t, NULL);
        int st = !looks_like_ptr(mm) ? 0 : ((bool (*)(void *, void *))g_rs_is_visible)(mm, NULL) ? 2 : 1;
        static int last = -1;
        if (st != last) { last = st; WLOG(@"research: main menu %s", st == 0 ? "gone" : st == 2 ? "visible" : "hidden"); }
    }
    for (int i = 0; i < RS_ALWAYS; i++)
        if (rs_blocker_open(i)) return false;
    static int cursor = RS_ALWAYS, clean_run = 0;
    static bool was_blocked = true;
    for (int k = 0; k < RS_PER_TICK; k++) {
        int i = cursor;
        cursor = cursor + 1 >= RS_BLOCKERS ? RS_ALWAYS : cursor + 1;
        if (rs_blocker_open(i)) { was_blocked = true; clean_run = 0; return false; }
        clean_run++;
    }
    if (was_blocked && clean_run < RS_BLOCKERS - RS_ALWAYS) return false;   // not a full clean pass yet
    was_blocked = false;
    return true;
}

// ---- v128: reward encounters open natively. The reward Pokemon is still placed at the
// trainer's feet by the server (research.py _place_encounter), which now also sends its
// encounter id. "Catch it!" makes the game fetch map objects right away (below), waits for
// that Pokemon to arrive on the map and then taps it for the player: MapPokemon.OnTap
// is what the game's own tap handler runs -- mapExploreState.PokemonSelected(this) -- so
// the bag-full check, the encounter request and the whole encounter are the game's.
// Plain calls, nothing hooked; both functions are checked by their first instruction.
#define RVA_MAPPOKEMON_ONTAP   0x89308     // MapPokemon.OnTap(sender, e)   (0.29 0x83D6C)
#define FIRST_MAPPOKEMON_ONTAP 0xa9be4ff4
#define RVA_WILDMAP_ENC_ID     0x8E428     // WildMapPokemon.get_EncounterId (0.29 0x8AD80);
#define FIRST_WILDMAP_ENC_ID   0xf9406c00  //   returns 0 when it has no proto (the prefab)
#define OFF_MAPPOKEMON_EXPLORE 0x30        // MapPokemon.mapExploreState: OnTap throws without it
#define RS_CATCH_WAIT          25.0        // seconds to wait for it to show up on the map
static void *g_rs_ontap = NULL, *g_rs_enc_id = NULL;

// The map refresh. The game fetches map objects when MapContentHandler's fetchThrottle
// (a SpaceTimeThrottle) says so: time since lastUpdateS past the max interval, or past the
// min interval after walking far enough. Winding lastUpdateS back makes the very next check
// (the handler runs every 0.3 s) pass, so the game sends its own GetMapObjects -- the same
// request it sends every ~11 s, just now. Offsets are 0.35's, checked against the code that
// uses them: the handler's load of the throttle and Check()'s load of lastUpdateS.
#define RVA_MCH_LOAD_THROTTLE  0x80988     // MapContentHandler: ldr x0, [x19, #0x40]
#define WORD_MCH_LOAD_THROTTLE 0xf9402260
#define RVA_STT_LOAD_LAST      0x119744    // SpaceTimeThrottle.Check: ldp s0, s1, [x19, #0x28]
#define WORD_STT_LOAD_LAST     0x2d450660
#define OFF_MCH_FETCH_THROTTLE 0x40        // MapContentHandler.fetchThrottle (0.29: 0x30)
#define OFF_STT_LAST_UPDATE    0x28        // lastUpdateS, then minIntervalS, maxIntervalS
static bool g_rs_refresh_ok = false;
// v131: the throttle alone did nothing while standing still -- the game only checks it from
// UpdateCells, which the native map library calls back when the visible cells change (that is
// why reward Pokemon used to need "walk a little"). So call the refresh the throttle leads to:
// 0.35 0x80C88 (new in 0.35, no 0.29 name) sets the handler's "fetch pending" byte (+0x70)
// and sends GetMapObjects once the handler isn't paused. The game only calls it with that byte
// clear; so do we. Checked against its own first word, its store to +0x70, and the UpdateCells
// code that tests the byte and calls it.
#define RVA_MCH_REFRESH        0x80C88
#define FIRST_MCH_REFRESH      0xa9bd57f6
#define RVA_MCH_REFRESH_SETS   0x80CE0     // strb w8, [x19, #0x70]
#define WORD_MCH_REFRESH_SETS  0x3901c268
#define RVA_MCH_TEST_PENDING   0x80980     // UpdateCells: ldrb w8, [x19, #0x70]
#define WORD_MCH_TEST_PENDING  0x3941c268
#define RVA_MCH_CALL_REFRESH   0x809A0     // UpdateCells: bl 0x80C88
#define WORD_MCH_CALL_REFRESH  0x940000ba
#define OFF_MCH_FETCH_PENDING  0x70
static void *g_rs_mch_refresh = NULL;

// v162: THE MAP HEARTBEAT. Because of the above, a trainer standing still sent no request at
// all for minutes on end (public server log 2026-10-02: an Incense lit at 19:02, not one
// request in the next six minutes) -- so an Incense or a Lure brought nothing, however often
// the server made its Pokemon, and spawns never changed until you walked. beat = called every
// tick while the plain map shows: refresh when the game hasn't fetched for RS_MAP_BEAT_S.
// Its own fetches (walking) move lastUpdateS, which restarts the wait.
#define RS_MAP_BEAT_S 15.0
static void rs_map_refresh(bool beat = false) {
    if (!g_rs_refresh_ok) return;
    static void *t = NULL;
    if (!t) {
        static const char *names[] = { "Niantic.Holoholo.Map.MapContentHandler, Assembly-CSharp",
                                       "MapContentHandler, Assembly-CSharp" };
        for (unsigned i = 0; i < sizeof names / sizeof *names && !looks_like_ptr(t); i++) t = mt_type(names[i]);
        if (!looks_like_ptr(t)) { t = (void *)1; WLOG(@"research: MapContentHandler type not found -- no map refresh"); }
    }
    if (t == (void *)1) return;
    void *h = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t, NULL);
    void *thr = looks_like_ptr(h) ? *(void **)((uint8_t *)h + OFF_MCH_FETCH_THROTTLE) : NULL;
    if (!looks_like_ptr(thr)) return;
    float *f = (float *)((uint8_t *)thr + OFF_STT_LAST_UPDATE);
    if (!(f[1] >= 0 && f[1] < 600 && f[2] > 0 && f[2] < 600)) {     // not a throttle: leave it alone
        WLOG(@"research: map throttle looks wrong (%.1f/%.1f) -- no map refresh", f[1], f[2]);
        g_rs_refresh_ok = false;
        return;
    }
    static float beat_seen = 0;
    static NSTimeInterval beat_at = 0;
    static NSTimeInterval beat_last_tick = 0;
    static int beats = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (beat) {
        // v208: the gap below means the beat wasn't ticking a moment ago -- the map just
        // became clear (game launch, or coming back from a menu), not a trainer who has
        // been standing on it. That first tick used to take whatever lastUpdateS already
        // held as "just fetched" and wait a full RS_MAP_BEAT_S before trying again, so
        // spawns from a launch-time fetch (if any) sat for 15 s before a real one followed.
        // Skip straight to forcing a refresh instead, so spawns show as soon as the map does;
        // the normal wait still applies to every beat after this one.
        bool fresh = (now - beat_last_tick) > 2.0;
        beat_last_tick = now;
        if (fresh) {
            beat_seen = f[0];
            beat_at = now - RS_MAP_BEAT_S;
        } else if (f[0] != beat_seen) { beat_seen = f[0]; beat_at = now; return; }   // fetched since we looked
        if (now - beat_at < RS_MAP_BEAT_S) return;
    }
    beat_at = now;
    f[0] = -1e6f;
    uint8_t pending = *((uint8_t *)h + OFF_MCH_FETCH_PENDING);
    bool sent = g_rs_mch_refresh && !pending;
    if (sent) ((void (*)(void *, void *))g_rs_mch_refresh)(h, NULL);
    beat_seen = f[0];
    if (beat) {                              // every 15 s: say so once, then only count
        if (beats++ == 0) WLOG(@"research: map heartbeat on (every %.0f s while standing still, %s)",
                               RS_MAP_BEAT_S, sent ? "sent" : pending ? "a fetch is already pending" : "throttle only");
    } else if (sent) {
        WLOG(@"research: map refresh sent");
    } else {
        WLOG(@"research: map refresh requested (%s)", pending ? "a fetch is already pending" : "throttle only");
    }
}
static uint64_t RS_catch_eid = 0;
static NSString *RS_catch_name = nil;
static NSTimeInterval RS_catch_until = 0;

static bool rs_catch_ready(void) { return g_rs_ontap && g_rs_enc_id && g_mt[MT_FIND_ALL]; }

static void rs_catch_start(uint64_t eid, NSString *name) {
    RS_catch_eid = eid;
    RS_catch_name = name;
    RS_catch_until = [NSDate date].timeIntervalSince1970 + RS_CATCH_WAIT;
    WLOG(@"research: catch %@ -- waiting for encounter %llu on the map", name, eid);
    rs_map_refresh();
    rs_toast_show(1, nil, [NSString stringWithFormat:@"%@ is on its way…", name]);
}

static void *rs_find_map_pokemon(uint64_t eid) {
    static void *t = NULL;
    if (!t) {
        static const char *names[] = { "Niantic.Holoholo.Map.WildMapPokemon, Assembly-CSharp",
                                       "WildMapPokemon, Assembly-CSharp" };
        for (unsigned i = 0; i < sizeof names / sizeof *names && !looks_like_ptr(t); i++) t = mt_type(names[i]);
        if (!looks_like_ptr(t)) { t = (void *)1; WLOG(@"research: WildMapPokemon type not found"); }
    }
    if (t == (void *)1) return NULL;
    void *arr = ((qc_static1)g_mt[MT_FIND_ALL])(NULL, t, NULL);
    int64_t n = looks_like_ptr(arr) ? *(int64_t *)((uint8_t *)arr + 0x18) : 0;
    static NSTimeInterval last_census = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    bool census = now - last_census >= 5;
    int live = 0;
    NSMutableString *ids = census ? [NSMutableString string] : nil;
    for (int64_t i = 0; i < n && i < 512; i++) {
        void *mp = *(void **)((uint8_t *)arr + OFF_ARRAY_DATA + i * 8);
        if (!looks_like_ptr(mp)) continue;
        uint64_t id = ((uint64_t (*)(void *, void *))g_rs_enc_id)(mp, NULL);
        if (census && id) { live++; if (live <= 12) [ids appendFormat:@" %llu", id]; }
        if (id != eid) continue;
        if (!looks_like_ptr(*(void **)((uint8_t *)mp + OFF_MAPPOKEMON_EXPLORE))) continue;
        void *go = ((qc_inst0)g_qc[QC_COMP_GO])(mp, NULL);
        if (!looks_like_ptr(go) || !((bool (*)(void *, void *))g_mt[MT_ACTIVE])(go, NULL)) continue;
        return mp;
    }
    if (census) {
        last_census = now;
        WLOG(@"research: looking for %llu -- %d map Pokemon:%@", eid, live, ids);
    }
    return NULL;
}

// ---- v130: our own encounter call. MapExploreState.PokemonSelected (0.35 0x85C08) checks the
// bag, that no other map state is open and that the location is known, and then does two
// things -- this does just those two, straight:
//   state = mapExploreState.SetActiveSubstate<WildPokemonEncounterState>()   (generic virtual)
//   state.SetupEncounter(mapPokemon)
// The generic call goes through il2cpp's generic-virtual resolver with the MethodInfo the game
// keeps in a metadata slot; PokemonSelected's own lazy init fills that slot, so we run the same
// init (same token, same guard byte) first if the game hasn't yet. Every address is checked
// against the instructions in PokemonSelected that use it; any mismatch -> OnTap as before.
#define RVA_PSEL               0x85C08     // MapExploreState.PokemonSelected
#define FIRST_PSEL             0xa9bc5ff8
static const struct { uint32_t rva, word; } kRsOwnCheck[] = {
    { 0x85C24, 0xd000f4d5 },   // adrp x21, guard page
    { 0x85C28, 0x39615ea8 },   // ldrb w8, [x21, #0x857]        guard byte
    { 0x85C30, 0xb000c9e8 },   // adrp x8, token page
    { 0x85C38, 0xb9432900 },   // ldr w0, [x8, #0x328]          metadata token
    { 0x85C3C, 0x944ff9c0 },   // bl il2cpp method init
    { 0x85F4C, 0xd000eec8 },   // adrp x8, slot page
    { 0x85F54, 0xf940c500 },   // ldr x0, [x8, #0x188]          SetActiveSubstate<...> MethodInfo
    { 0x85F5C, 0x94501bc8 },   // bl generic-virtual resolver
    { 0x85F74, 0x9406ec91 },   // bl SetupEncounter
};
#define RVA_PSEL_GUARD         0x1F1F857
#define RVA_PSEL_TOKEN         0x19C2328
#define RVA_PSEL_GM_SLOT       0x1E5F188
#define RVA_IL2CPP_INIT_METHOD 0x148433C
#define RVA_GV_RESOLVE         0x148CE7C
#define RVA_SETUP_ENCOUNTER    0x2411B8    // WildPokemonEncounterState.SetupEncounter(MapPokemon)
static uintptr_t g_rs_own_base = 0;        // set when every check above passed

typedef struct { void *obj; void *mi; } RsGvCall;   // the resolver returns (this, MethodInfo*)

static bool rs_own_encounter(void *mp) {
    if (!g_rs_own_base) return false;
    uintptr_t b = g_rs_own_base;
    void *mes = *(void **)((uint8_t *)mp + OFF_MAPPOKEMON_EXPLORE);       // the MapExploreState
    if (!looks_like_ptr(mes)) return false;
    uint8_t *guard = (uint8_t *)(b + RVA_PSEL_GUARD);
    if (!(*guard & 1)) {
        ((void (*)(uint32_t))(b + RVA_IL2CPP_INIT_METHOD))(*(uint32_t *)(b + RVA_PSEL_TOKEN));
        *guard = 1;
        WLOG(@"research: PokemonSelected metadata initialised by us");
    }
    void *gm = *(void **)(b + RVA_PSEL_GM_SLOT);
    if (!looks_like_ptr(gm)) { WLOG(@"research: own encounter -- no SetActiveSubstate MethodInfo"); return false; }
    RsGvCall r = ((RsGvCall (*)(void *, void *))(b + RVA_GV_RESOLVE))(gm, mes);
    if (!looks_like_ptr(r.obj) || !looks_like_ptr(r.mi) || !looks_like_ptr(*(void **)r.mi)) {
        WLOG(@"research: own encounter -- SetActiveSubstate didn't resolve");
        return false;
    }
    void *state = ((void *(*)(void *, void *))*(void **)r.mi)(r.obj, r.mi);
    if (!looks_like_ptr(state)) { WLOG(@"research: own encounter -- no encounter state"); return false; }
    ((void (*)(void *, void *, void *))(b + RVA_SETUP_ENCOUNTER))(state, mp, NULL);
    return true;
}

/** Is the game's encounter screen up? (EncounterUIController, the same blocker-list lookup
 *  that hides the buttons -- not the music, which can miss a change.) */
static bool rs_encounter_open(void) {
    static int idx = -2;
    if (idx == -2) {
        idx = -1;
        for (int i = 0; i < RS_BLOCKERS; i++)
            if (strstr(kRsBlockers[i], "EncounterUIController")) { idx = i; break; }
    }
    return idx >= 0 && rs_blocker_open(idx);
}

static void rs_catch_give_up(const char *why) {
    WLOG(@"research: encounter %llu -- %s; left on the map", RS_catch_eid, why);
    rs_toast_show(1, nil, [NSString stringWithFormat:@"%@ is waiting at your feet — tap it on the map", RS_catch_name]);
    RS_catch_eid = 0;
}

/** free: the plain map is showing and nothing of ours or the game's is in the way.
 *  v129: the Pokemon has to have been on the map ~1 s before it's tapped (its model is still
 *  loading when it first appears, and a tap then does nothing), and after a tap we watch for
 *  the encounter screen; no screen within 3 s -> tap again, up to 3 times. */
static void rs_catch_tick(bool free) {
    if (!RS_catch_eid) return;
    static NSTimeInterval last = 0, last_refresh = 0, seen_at = 0, tapped_at = 0;
    static int taps = 0;
    static uint64_t for_eid = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (for_eid != RS_catch_eid) { for_eid = RS_catch_eid; seen_at = tapped_at = 0; taps = 0; last_refresh = now; }
    if (tapped_at) {
        // The encounter screen, or the map going away under us (the approach camera,
        // Nearby hiding) -- either way the game took the tap.
        if (rs_encounter_open() || !free) {
            WLOG(@"research: encounter %llu started (tap %d%s)", RS_catch_eid, taps,
                 rs_encounter_open() ? "" : ", map left");
            RS_catch_eid = 0;
            return;
        }
        if (now - tapped_at < 3) return;
        tapped_at = 0;
        if (taps >= 3) { rs_catch_give_up("the game didn't open the encounter"); return; }
    }
    if (now > RS_catch_until) { rs_catch_give_up("never showed up on the map"); return; }
    if (!free || now - last < 0.5) return;
    last = now;
    if (now - last_refresh >= 4) {           // again, in case a fetch was already in flight
        rs_map_refresh();
        last_refresh = now;
    }
    void *mp = rs_find_map_pokemon(RS_catch_eid);
    if (!mp) { seen_at = 0; return; }
    if (!seen_at) {
        seen_at = now;
        WLOG(@"research: encounter %llu is on the map", RS_catch_eid);
    }
    if (now - seen_at < 1.0) return;         // let its model finish loading
    taps++;
    tapped_at = now;
    if (rs_own_encounter(mp)) {
        WLOG(@"research: started %@ (encounter %llu) with our own call, try %d", RS_catch_name, RS_catch_eid, taps);
        return;
    }
    WLOG(@"research: tapping %@ (encounter %llu) for the player, try %d", RS_catch_name, RS_catch_eid, taps);
    ((void (*)(void *, void *, void *, void *))g_rs_ontap)(mp, NULL, NULL, NULL);
}

// ---- v177: the map buttons, as Unity UI. sharedassets0 carries
//   NearbyPokemonPreviewGui/ClickTarget/WSResearchButton (+ /Dot) and .../WSHubButton,
// all inactive (work/tools/research_buttons.py, run by patch_badges). Taps reach us through
// Button.OnPointerClick -- their onClick lists are empty.
#define RVA_BUTTON_ONPOINTERCLICK   0x852B38   // UnityEngine.UI.Button.OnPointerClick (0.29 0x832158)
#define FIRST_BUTTON_ONPOINTERCLICK 0xb40000a1 // cbz x1, ...
#define OFF_POINTEREVENT_BUTTON     0x12C      // PointerEventData.button (0 = left), as the original reads it
static void (*o_button_click)(void *, void *, void *) = NULL;

static void hk_button_click(void *self, void *ev, void *mi) {
    o_button_click(self, ev, mi);
    if (!looks_like_ptr(self) || !looks_like_ptr(ev) || !g_get_name || !g_qc[QC_COMP_GO]) return;
    if (*(int32_t *)((uint8_t *)ev + OFF_POINTEREVENT_BUTTON) != 0) return;
    if (g71_on_click(self)) return;          // 0.71's gym screen buttons (GymScreen071.inc.mm)
    void *go = ((qc_inst0)g_qc[QC_COMP_GO])(self, NULL);
    void *name = looks_like_ptr(go) ? g_get_name(go, NULL) : NULL;
    if (!looks_like_ptr(name)) return;
    if (il2cpp_string_equals(name, "WSFriendsBtn")) {   // v187: profile menu > Friends (profile_friends.py)
        dispatch_async(dispatch_get_main_queue(), ^{ WLOG(@"friends: profile menu entry tapped"); fr_open(); });
        return;
    }
    int which = il2cpp_string_equals(name, "WSResearchButton") ? 1 : il2cpp_string_equals(name, "WSHubButton") ? 2 : 0;
    if (!which) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        bool open = (RS_screen && !RS_screen.hidden) || (RS_events && !RS_events.hidden);
        if (open || RS_level < RS_UNLOCK_LEVEL) return;
        WLOG(@"research: %s button tapped", which == 1 ? "Research" : "Hub");
        if (which == 1) rs_open(); else rs_events_open();
    });
}

/** child of the Nearby box by path, or NULL */
static void *rs_unity_child(void *box_tr, const char *path) {
    void *s = ((qc_static1)g_qc[QC_STR])(NULL, (void *)path, NULL);
    void *tr = looks_like_ptr(s) ? ((qc_inst1)g_qc[QC_FIND])(box_tr, s, NULL) : NULL;
    return looks_like_ptr(tr) ? tr : NULL;
}

static void rs_unity_set(void *tr, bool on, void **last_go, int *last_on) {
    void *go = tr ? ((qc_inst0)g_qc[QC_COMP_GO])(tr, NULL) : NULL;
    if (!looks_like_ptr(go)) return;
    if (go == *last_go && *last_on == (int)on) return;      // the box was rebuilt -> set again
    ((void (*)(void *, bool, void *))g_qc[QC_SETACTIVE])(go, on, NULL);
    *last_go = go;
    *last_on = on;
}

static void rs_unity_buttons(UIView *parent, bool unlocked) {
    static void *t_gui = NULL;
    static void *go_r = NULL, *go_h = NULL, *go_d = NULL;
    static int on_r = -1, on_h = -1, on_d = -1;
    static bool missing_logged = false, found_logged = false;
    if (!t_gui) t_gui = mt_type("Niantic.Holoholo.NearbyPokemon.NearbyPokemonPreviewGuiController, Assembly-CSharp");
    if (!looks_like_ptr(t_gui) || !g_qc[QC_FIND] || !g_qc[QC_SETACTIVE]) return;
    void *gui = ((qc_static1)g_qc[QC_FINDOBJ])(NULL, t_gui, NULL);
    void *box = looks_like_ptr(gui) ? ((qc_inst0)g_qc[QC_COMP_TR])(gui, NULL) : NULL;
    if (!looks_like_ptr(box)) { RS_btn_top = -1; return; }
    void *r = rs_unity_child(box, "ClickTarget/WSResearchButton");
    void *h = rs_unity_child(box, "ClickTarget/WSHubButton");
    void *d = rs_unity_child(box, "ClickTarget/WSResearchButton/Dot");
    if (!r || !h) {
        if (!missing_logged) { missing_logged = true; WLOG(@"research: no Unity buttons on Nearby -- game data not patched (patch_badges)"); }
        RS_btn_top = -1;
        return;
    }
    if (!found_logged) { found_logged = true; WLOG(@"research: Unity buttons found on Nearby"); }
    rs_unity_set(r, unlocked, &go_r, &on_r);
    rs_unity_set(h, unlocked, &go_h, &on_h);
    rs_unity_set(d, unlocked && [rj(RS_state, @"claimable") boolValue], &go_d, &on_d);
    CGPoint p;
    RS_btn_top = unlocked && spk_tr_screen(h, parent.bounds.size, &p) ? p.y - 24 : -1;
}

#include "Friends.inc.mm"

static void rs_tick(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    CGRect nb;
    bool nb_rect = false;
    int nearby = rs_nearby_state(parent, &nb, &nb_rect);
    bool screen_open = (RS_screen && !RS_screen.hidden) || (RS_events && !RS_events.hidden);
    rs_ball_menu_tick(parent);                                          // v164: sets RS_ball_menu
    bool clear = rs_map_clear();
    static bool was_clear = true;
    if (!RS_ball_known) {                                               // the tap watch's guesses need ending
        if (RS_ball_menu && !g_map_active) RS_ball_menu = false;        // went somewhere else
        if (RS_ball_menu && !clear && was_clear) RS_ball_menu = false;  // picked a menu screen
    }
    was_clear = clear;
    bool unlocked = RS_level >= RS_UNLOCK_LEVEL;
    static bool was_unlocked = false;
    if (unlocked != was_unlocked) {
        was_unlocked = unlocked;
        WLOG(@"research: level %d -- buttons %@", RS_level, unlocked ? @"unlocked" : @"locked (need 5)");
    }
    if (!unlocked && RS_screen && !RS_screen.hidden) rs_close();   // locked mid-session: put it away
    if (!unlocked && RS_events && !RS_events.hidden) rs_events_close();
    // v177: the buttons are Unity UI on the Nearby box now (research_buttons.py), so the game
    // shows, hides, moves and layers them with Nearby -- the Poke Ball menu, profile and shop
    // cover them like they cover Nearby. All the tweak does is switch them on at level 5 and
    // the dot on when something can be claimed. "show" is still worked out the old way for
    // the reward-catch, map refresh and badge polling below.
    if (nearby == 0 && !RS_ball_known) RS_ball_menu = false;
    bool show = !screen_open && unlocked && nearby != 0 && clear && !RS_ball_menu;
    rs_catch_tick(!screen_open && nearby != 0 && clear && !RS_ball_menu);
    if (!RS_catch_eid && !screen_open && nearby != 0 && clear && !RS_ball_menu) rs_map_refresh(true);   // v162
    if (RS_shown != show) {
        RS_shown = show;
        if (show) rs_fetch(false);
    }
    rs_unity_buttons(parent, unlocked);
    // v73: gentler polling -- the toast check every 2 s (it still runs on the catch screen,
    // where the game shows it), not while the Research screen itself is open
    static NSTimeInterval last_ping = 0;
    NSTimeInterval pnow = [NSDate date].timeIntervalSince1970;
    if (!screen_open && pnow - last_ping >= 2.0) {
        last_ping = pnow;
        rs_ping();
    }
    // keep the numbers live: every 3 s with the screen open, every 30 s on the map (badge)
    static NSTimeInterval last_fetch = 0, last_countdown = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if ((screen_open && now - last_fetch > 5) || (show && now - last_fetch > 90)) {
        last_fetch = now;
        rs_fetch(false);
    }
    static NSTimeInterval last_lb = 0;
    if (now - last_lb >= 5) {                                            // v124: leaderboard
        last_lb = now;
        rs_lb_tick(screen_open);
    }
    if (screen_open && RS_tab == 2 && now - last_countdown > 20) {      // timed countdown
        last_countdown = now;
        rs_render();
    }
    fr_tick(parent);                                                     // v186: ME | FRIENDS
}

static bool install_research(uintptr_t base, uintptr_t dstart, size_t dsize) {
    if (!g_mt_ready || !g_qc[QC_COMP_GO]) return false;
    // v177: the map buttons are Unity Buttons; without their taps there's no way in
    if (*(uint32_t *)(base + RVA_BUTTON_ONPOINTERCLICK) != FIRST_BUTTON_ONPOINTERCLICK) {
        WLOG(@"research: Button.OnPointerClick doesn't match -- OFF");
        return false;
    }
    o_button_click = (void (*)(void *, void *, void *))(base + RVA_BUTTON_ONPOINTERCLICK);
    if (!redirect_method_pointer(dstart, dsize, base + RVA_BUTTON_ONPOINTERCLICK,
                                 (uintptr_t)&hk_button_click, "Button.OnPointerClick")) return false;
    if (*(uint32_t *)(base + RVA_PLAY_UI_SFX) == FIRST_PLAY_UI_SFX) g_rs_ui_sfx = (void *)(base + RVA_PLAY_UI_SFX);
    else WLOG(@"research: PlayUISFX doesn't match -- no sounds");
    if (*(uint32_t *)(base + RVA_GUI_IS_VISIBLE) == FIRST_GUI_IS_VISIBLE)
        g_rs_is_visible = (void *)(base + RVA_GUI_IS_VISIBLE);
    else
        WLOG(@"research: GuiController.IsVisible doesn't match -- menus hide the button while they exist");
    if (*(uint32_t *)(base + RVA_MAPPOKEMON_ONTAP) == FIRST_MAPPOKEMON_ONTAP &&
        *(uint32_t *)(base + RVA_WILDMAP_ENC_ID) == FIRST_WILDMAP_ENC_ID) {
        g_rs_ontap = (void *)(base + RVA_MAPPOKEMON_ONTAP);
        g_rs_enc_id = (void *)(base + RVA_WILDMAP_ENC_ID);
    } else {
        WLOG(@"research: MapPokemon.OnTap doesn't match -- reward Pokemon wait on the map instead");
    }
    bool own = *(uint32_t *)(base + RVA_PSEL) == FIRST_PSEL;
    for (unsigned i = 0; own && i < sizeof kRsOwnCheck / sizeof *kRsOwnCheck; i++)
        if (*(uint32_t *)(base + kRsOwnCheck[i].rva) != kRsOwnCheck[i].word) {
            WLOG(@"research: own encounter call off -- 0x%x doesn't match", kRsOwnCheck[i].rva);
            own = false;
        }
    if (own) g_rs_own_base = base;
    g_rs_refresh_ok = *(uint32_t *)(base + RVA_MCH_LOAD_THROTTLE) == WORD_MCH_LOAD_THROTTLE &&
                      *(uint32_t *)(base + RVA_STT_LOAD_LAST) == WORD_STT_LOAD_LAST;
    if (!g_rs_refresh_ok) WLOG(@"research: map throttle code doesn't match -- no map refresh");
    if (*(uint32_t *)(base + RVA_MCH_REFRESH) == FIRST_MCH_REFRESH &&
        *(uint32_t *)(base + RVA_MCH_REFRESH_SETS) == WORD_MCH_REFRESH_SETS &&
        *(uint32_t *)(base + RVA_MCH_TEST_PENDING) == WORD_MCH_TEST_PENDING &&
        *(uint32_t *)(base + RVA_MCH_CALL_REFRESH) == WORD_MCH_CALL_REFRESH)
        g_rs_mch_refresh = (void *)(base + RVA_MCH_REFRESH);
    else
        WLOG(@"research: map refresh call doesn't match -- throttle only");
    rs_load_fonts();
    WLOG(@"research: armed (Unity buttons on Nearby)");
    return true;
}
#endif
