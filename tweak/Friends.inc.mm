// ----------------------------------------------------------------- Friends (v186-v193)
// The newer game's friend list, which 0.35 doesn't have. v187: it opens from the trainer
// profile's own menu (the three-bar button: Friends / Journal / Customize -- the entry is game
// data, work/tools/profile_friends.py). The menu is drawn over the Unity view in the newer
// game's look (a white page in a green frame; v188: no tabs or title across the top):
//   list     -- Add Friend + Requests buttons, a row per friend (avatar, ring hearts, last seen)
//   add      -- my Trainer Code with its QR code, Copy / Share, and a box to enter a code
//   requests -- incoming (Accept / Decline) and sent (Cancel)
//   friend   -- a friend's page: friendship, SEND/OPEN GIFT, TRADE, Remove (v189)
//   trade    -- v190: a trade room like the newer game's: each trainer picks ONLY their own
//               Pokemon (the other side shows what the friend chose), a chat box to agree,
//               both confirm and the server makes the swap. Every page slides in as a new
//               screen with a back header; back slides it away again.
// The X goes back to the list from a sub page, and back to the profile from the list;
// dragging right from the list does the same. The server is friends.py.
#import <CoreImage/CoreImage.h>

#define FR_EDGE 10              // the green frame's width at the sides

static UIView *FR_screen = nil;            // the Friends menu
static UIScrollView *FR_scroll = nil;
static UIStackView *FR_stack = nil;
static NSDictionary *FR_state = nil;
static int FR_page = 0;                    // 0 list, 1 add, 2 requests, 3 friend, 4 trade room, 5 pick (v191)
static NSString *FR_friend = nil;          // the friend page's id
static NSString *FR_note = nil;            // the last message / error, shown on top
static bool FR_note_bad = false;
static NSTimeInterval FR_note_t = 0;
static bool FR_busy = false;
static bool FR_remove_armed = false;
static UITextField *FR_code_field = nil;
static NSString *FR_code_typed = @"";
static NSArray *FR_gift_items = nil;       // v189: what the gift just opened held (the friend page shows it)
static NSString *FR_gift_from = nil;
static NSDictionary *FR_box = nil;         // my Pokemon to pick from (/friends/box)
static NSString *FR_trade = nil;           // v190: the trade room open on page 4
static NSDictionary *FR_room = nil;        //       and what it last looked like
static NSData *FR_room_raw = nil;
static UITextField *FR_chat_field = nil;
static NSString *FR_chat_draft = @"";
static bool FR_render_pending = false;     // a re-render waiting for the chat box to lose focus
static void fr_back(void);
static UIView *FR_snap = nil;              // v192: the outgoing page while a slide runs

static void fr_render(void);
static void fr_chat_reveal(bool animated);
static void fr_close(void);
static void fr_open(void);


static UIColor *fr_pink(void) { return rs_rgb(0xF2668B); }

// v194: the MODERN game's own Friends / trade sounds (0.111 sharedassets1, the same set as the
// user's friend-gift-*.mp3), in sounds/windstock_sfx_<clip>.*, played by rs_sfx_modern.
#define FR_SFX_GIFT_SEND   "se_go_friend_gift_send"
#define FR_SFX_GIFT_OPEN   "se_go_friend_gift_open"
#define FR_SFX_GIFT_SELECT "se_go_friend_gift_select"     // tapping SEND / OPEN GIFT
#define FR_SFX_LETTER      "se_go_friend_send_letter"     // a friend request sent
#define FR_SFX_OK          "se_go_friend_ok"              // a request accepted
#define FR_SFX_LEVEL_UP    "se_go_friend_level_up"        // friendship reached a new level
#define FR_SFX_LEVEL_PLUS  "se_go_friend_level_plus"      // a friendship day counted
#define FR_SFX_TRADE_BTN   "se_go_trade_any_button"       // TRADE, choosing / picking a Pokemon
#define FR_SFX_TRADE_OK    "se_go_trade_confirm_button"   // CONFIRM TRADE
#define FR_SFX_TRADE_THEM  "se_go_trade_machine"          // the friend picked / confirmed
#define FR_SFX_TRADE       "se_go_trade_demo"             // the swap (rises, hits at ~1.45 s)
// ...and the trade room's music (Tweak.mm ws_extra_music): windstock_music_<name>.m4a
#define FR_MUSIC_ROOM      @"124_trade_standby"
#define FR_MUSIC_TRADE     @"125_trade"
static void fr_music_sync(void);
static NSString *FR_music_done = nil;      // the trade whose 125_trade theme is playing

/** v194: friendship went up since the last look -> level-up chime (or the small one for a day). */
static void fr_note_friendship(NSDictionary *j) {
    static NSMutableDictionary *was = nil;             // friend id -> @[level, days]
    bool first = was == nil;
    if (first) was = [NSMutableDictionary dictionary];
    const char *sfx = NULL;
    NSString *who = nil;
    for (NSDictionary *f in rj(j, @"friends") ?: @[]) {
        NSString *fid = rj(f, @"id");
        if (![fid isKindOfClass:[NSString class]]) continue;
        int lvl = [rj(f, @"friendship") intValue], days = [rj(f, @"days") intValue];
        NSArray *old = was[fid];
        if (old && lvl > [old[0] intValue]) { sfx = FR_SFX_LEVEL_UP; who = [NSString stringWithFormat:@"You and %@ are now %@s!", rj(f, @"name") ?: @"your friend", rj(f, @"friendship_name") ?: @"better friend"]; }
        else if (old && days > [old[1] intValue] && !sfx) sfx = FR_SFX_LEVEL_PLUS;
        was[fid] = @[@(lvl), @(days)];
    }
    if (first || !sfx) return;
    // after the gift / trade show's own sound
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        rs_sfx_modern(sfx);
        if (who) { FR_note = who; FR_note_bad = false; FR_note_t = [NSDate date].timeIntervalSince1970; if (FR_screen && !FR_screen.hidden) fr_render(); }
    });
}

// ---- networking
static void fr_take(id j) {
    if (![j isKindOfClass:[NSDictionary class]] || !rj(j, @"me")) return;
    FR_state = j;
    fr_note_friendship(j);
    FR_requests = (int)[(rj(j, @"incoming") ?: @[]) count] + (int)[(rj(j, @"trades") ?: @[]) count];
    NSString *msg = rj(j, @"message"), *err = rj(j, @"error");
    if (msg || err) {
        FR_note = msg ?: err;
        FR_note_bad = err != nil;
        FR_note_t = [NSDate date].timeIntervalSince1970;
    }
}

static void fr_fetch(void) {
    if (FR_busy) return;
    FR_busy = true;
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:RS_HOST @"/friends/state"]];
    rq.timeoutInterval = 6;
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            FR_busy = false;
            if (!rj(j, @"me")) { static int w = 0; if (w++ < 3) WLOG(@"friends: state failed %@", e.localizedDescription ?: @""); }
            fr_take(j);
            if (FR_screen && !FR_screen.hidden) fr_render();
        });
    }] resume];
}

static void fr_post(NSString *action, NSDictionary *body, void (^done)(NSDictionary *j)) {
    NSString *url = [NSString stringWithFormat:@"%@/friends/%@", RS_HOST, action];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    rq.HTTPMethod = @"POST";
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body ?: @{} options:0 error:nil];
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    rq.timeoutInterval = 8;
    WLOG(@"friends: %@", action);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!rj(j, @"me")) {
                FR_note = @"Couldn't reach the server."; FR_note_bad = true;
                FR_note_t = [NSDate date].timeIntervalSince1970;
            } else {
                fr_take(j);
            }
            if (done) done(j);
            if (FR_screen && !FR_screen.hidden) fr_render();
        });
    }] resume];
}

// ---- pieces
static NSString *fr_code_text(NSString *c) {          // 1234 5678 9012
    if (c.length != 12) return c ?: @"";
    return [NSString stringWithFormat:@"%@ %@ %@", [c substringToIndex:4],
            [c substringWithRange:NSMakeRange(4, 4)], [c substringFromIndex:8]];
}

static NSString *fr_team_name(int t) {
    return t == 1 ? @"Mystic" : t == 2 ? @"Valor" : t == 3 ? @"Instinct" : @"No team";
}

static NSString *fr_ago(double ms) {
    if (ms <= 0) return @"A while ago";
    double s = [NSDate date].timeIntervalSince1970 - ms / 1000.0;
    if (s < 3600) return [NSString stringWithFormat:@"%d min ago", MAX(1, (int)(s / 60))];
    if (s < 86400) return [NSString stringWithFormat:@"%d h ago", (int)(s / 3600)];
    return [NSString stringWithFormat:@"%d d ago", (int)(s / 86400)];
}

/** A trainer in a pastel circle, head and shoulders, like the newer game's friend list. */
static UIColor *fr_pastel(int team) {
    switch (team) {
        case 1: return rs_rgb(0xCBEAF7);     // Mystic
        case 2: return rs_rgb(0xF8D3DA);     // Valor
        case 3: return rs_rgb(0xFFF1B5);     // Instinct
        default: return rs_rgb(0xE3ECEC);
    }
}

/** f = a friend/request row: "team" colours the circle, "avatar" is their real look
    (/friends/trainer/<look>.png, rendered from the 0.35 trainer); old servers send none. */
static UIView *fr_avatar(NSDictionary *f, CGFloat size) {
    int team = [rj(f, @"team") intValue];
    NSString *pic = rj(f, @"avatar");
    if (![pic isKindOfClass:[NSString class]] || !pic.length) pic = @"/friends/art/ic_defaultMaleAvatar.png";
    UIView *ring = [UIView new];
    rs_size(ring, size, size);
    ring.backgroundColor = fr_pastel(team);
    ring.layer.cornerRadius = size / 2;
    ring.clipsToBounds = YES;
    UIImageView *face = rs_image(pic, size * 0.98, size * 0.98);
    [ring addSubview:face];
    [NSLayoutConstraint activateConstraints:@[
        [face.centerXAnchor constraintEqualToAnchor:ring.centerXAnchor],
        [face.bottomAnchor constraintEqualToAnchor:ring.bottomAnchor constant:size * 0.04]]];
    return ring;
}

/** The friendship hearts, each in a ring: orange up to the level reached, grey after. */
static UIColor *fr_orange(void) { return rs_rgb(0xF27C38); }
static UIView *fr_hearts(int level, CGFloat size) {
    NSMutableArray *hs = [NSMutableArray array];
    for (int i = 0; i < 4; i++) {
        bool on = i < level;
        UIView *c = [UIView new];
        rs_size(c, size, size);
        c.layer.cornerRadius = size / 2;
        c.layer.borderWidth = MAX(1.5, size * 0.11);
        c.layer.borderColor = (on ? fr_orange() : rs_rgb(0xD5DDDE)).CGColor;
        c.backgroundColor = UIColor.whiteColor;
        UIImageView *h = rs_image_tinted(on ? @"/friends/art/HealingHeart.png" : @"/friends/art/HealingHeartOutline.png",
                                         size * 0.56, size * 0.52, on ? fr_orange() : rs_rgb(0xD5DDDE));
        [c addSubview:h];
        [NSLayoutConstraint activateConstraints:@[[h.centerXAnchor constraintEqualToAnchor:c.centerXAnchor],
                                                  [h.centerYAnchor constraintEqualToAnchor:c.centerYAnchor constant:size * 0.03]]];
        [hs addObject:c];
    }
    return rs_hstack(hs, size * 0.12);
}

static UIView *fr_line(void) {                 // the thin rule between rows
    UIView *l = [UIView new];
    l.backgroundColor = rs_rgb(0xDCE3E4);
    rs_size(l, 0, 1);
    return l;
}

static UIImage *fr_qr(NSString *text, CGFloat side) {
    CIFilter *f = [CIFilter filterWithName:@"CIQRCodeGenerator"];
    [f setValue:[text dataUsingEncoding:NSUTF8StringEncoding] forKey:@"inputMessage"];
    [f setValue:@"H" forKey:@"inputCorrectionLevel"];   // H: still reads with the ball over the middle
    CIImage *img = f.outputImage;
    if (!img) return nil;
    CGFloat k = side * UIScreen.mainScreen.scale / img.extent.size.width;
    img = [img imageByApplyingTransform:CGAffineTransformMakeScale(k, k)];
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:img fromRect:img.extent];
    if (!cg) return nil;
    UIImage *out = [UIImage imageWithCGImage:cg scale:UIScreen.mainScreen.scale orientation:UIImageOrientationUp];
    CGImageRelease(cg);
    return out;
}

/** A white pill with an icon and a word (COPY, SHARE, the list's two big buttons). */
static const char *FR_btn_sfx = NULL;      // v194: the next fr_icon_button's tap sound (NULL = the menu one)
static UIView *fr_icon_button(NSString *icon, NSString *title, CGFloat h, int badge, void (^tap)(void)) {
    const char *sfx = FR_btn_sfx;
    FR_btn_sfx = NULL;
    UIView *b = rs_card();
    rs_size(b, 0, h);
    b.layer.cornerRadius = h / 2 > 22 ? 18 : h / 2;
    // the official icons are white (made for coloured buttons): drawn teal on the white pill
    bool white = [icon hasSuffix:@"ic_share.png"] || [icon hasSuffix:@"ico_add_friends.png"]
                 || [icon hasSuffix:@"pogo_trade_icon.png"];
    UIImageView *iv = white ? rs_image_tinted(icon, h * 0.5, h * 0.5, rs_teal()) : rs_image(icon, h * 0.5, h * 0.5);
    UILabel *l = rs_label(title, h > 50 ? 15 : 14, true, rs_ink());
    l.numberOfLines = 1;
    l.adjustsFontSizeToFitWidth = YES;
    l.minimumScaleFactor = 0.7;
    UIStackView *row = rs_hstack(@[iv, l], 8);
    [b addSubview:row];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
        [row.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
        [row.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [row.leadingAnchor constraintGreaterThanOrEqualToAnchor:b.leadingAnchor constant:10]]];
    if (badge > 0) {
        UILabel *n = rs_label([NSString stringWithFormat:@"%d", badge], 12, true, UIColor.whiteColor);
        n.textAlignment = NSTextAlignmentCenter;
        n.backgroundColor = rs_rgb(0xFF4B4B);
        n.layer.cornerRadius = 10;
        n.clipsToBounds = YES;
        rs_size(n, badge > 9 ? 28 : 20, 20);
        [b addSubview:n];
        [NSLayoutConstraint activateConstraints:@[
            [n.topAnchor constraintEqualToAnchor:b.topAnchor constant:-4],
            [n.trailingAnchor constraintEqualToAnchor:b.trailingAnchor constant:4]]];
    }
    if (tap) rs_on_tap(b, ^{ if (sfx) rs_sfx_modern(sfx); else rs_sfx(RS_SFX_OPEN); tap(); });
    return b;
}

static UIView *fr_small_button(NSString *title, UIColor *fill, UIColor *ink, void (^tap)(void)) {
    UILabel *l = rs_label(title, 14, true, ink);
    l.textAlignment = NSTextAlignmentCenter;
    l.backgroundColor = fill;
    l.layer.cornerRadius = 17;
    l.clipsToBounds = YES;
    rs_size(l, 92, 34);
    if (tap) rs_on_tap(l, tap);
    return l;
}

static UIView *fr_note_card(void) {
    UIView *c = rs_card();
    c.backgroundColor = FR_note_bad ? rs_rgb(0xFFF1F1) : rs_rgb(0xEFFBF5);
    UILabel *l = rs_label(FR_note, 15, true, FR_note_bad ? rs_rgb(0xC2414B) : rs_rgb(0x2F8F6B));
    l.textAlignment = NSTextAlignmentCenter;
    [c addSubview:l];
    rs_pin(l, c, UIEdgeInsetsMake(12, 14, 12, 14));
    return c;
}

static UIView *fr_empty(NSString *text) {
    UIView *c = rs_card();
    c.backgroundColor = rs_rgb(0xF3F7F7);
    UILabel *l = rs_label(text, 15, true, rs_ink2());
    l.textAlignment = NSTextAlignmentCenter;
    [c addSubview:l];
    rs_pin(l, c, UIEdgeInsetsMake(22, 16, 22, 16));
    return c;
}

static UIView *fr_section_title(NSString *s) {
    UILabel *l = (UILabel *)rs_section_title(s);
    NSMutableAttributedString *a = [l.attributedText mutableCopy];
    [a addAttribute:NSForegroundColorAttributeName value:rs_ink2() range:NSMakeRange(0, a.length)];
    l.attributedText = a;
    return l;
}

static int fr_depth(int p) { return p == 0 ? 0 : p <= 3 ? 1 : p == 4 ? 2 : 3; }

/** Change page. v190: deeper pages slide in from the right as a new screen, going back
 *  slides the old one off to the right; the page underneath trails a little, like UIKit's. */
static void fr_go_anim(int page, bool animate) {
    int from = FR_page;
    FR_page = page;
    FR_remove_armed = false;
    [FR_code_field resignFirstResponder];
    [FR_chat_field resignFirstResponder];
    int dir = fr_depth(page) > fr_depth(from) ? 1 : fr_depth(page) < fr_depth(from) ? -1 : 0;
    // v192: a slide still running is finished at once -- two at a time left pages drawn over each other
    if (FR_snap) { [FR_snap removeFromSuperview]; FR_snap = nil; }
    [FR_scroll.layer removeAllAnimations];
    FR_scroll.transform = CGAffineTransformIdentity;
    FR_scroll.alpha = 1;
    UIView *snap = nil;
    if (animate && dir && FR_screen && !FR_screen.hidden) {
        // an opaque picture of the old page: the scroll view itself is see-through
        snap = [[UIView alloc] initWithFrame:FR_scroll.frame];
        snap.backgroundColor = UIColor.whiteColor;
        snap.clipsToBounds = YES;
        UIView *pic = [FR_scroll snapshotViewAfterScreenUpdates:NO];
        if (pic) { pic.frame = snap.bounds; [snap addSubview:pic]; }
        [FR_screen insertSubview:snap aboveSubview:FR_scroll];
        FR_snap = snap;
    }
    [FR_scroll setContentOffset:CGPointZero animated:NO];
    fr_render();
    if (!snap) return;
    CGFloat w = FR_scroll.bounds.size.width;
    if (dir > 0) {                                  // in from the right, over the old page
        FR_scroll.transform = CGAffineTransformMakeTranslation(w, 0);
        [FR_screen bringSubviewToFront:FR_scroll];
    } else {                                        // the old page leaves to the right
        FR_scroll.transform = CGAffineTransformMakeTranslation(-w * 0.3, 0);
        FR_scroll.alpha = 0.6;
    }
    for (UIView *v in FR_screen.subviews)           // the close button stays on top
        if (v != FR_scroll && v != snap && [v isKindOfClass:[UIImageView class]]) [FR_screen bringSubviewToFront:v];
    [UIView animateWithDuration:0.3 delay:0 usingSpringWithDamping:0.92 initialSpringVelocity:0.2
                        options:0 animations:^{
        FR_scroll.transform = CGAffineTransformIdentity;
        FR_scroll.alpha = 1;
        snap.transform = CGAffineTransformMakeTranslation(dir > 0 ? -w * 0.3 : w, 0);
        snap.alpha = dir > 0 ? 0.6 : 1;
    } completion:^(BOOL f) {
        [snap removeFromSuperview];
        if (FR_snap == snap) FR_snap = nil;
    }];
}

static void fr_go(int page) { fr_go_anim(page, true); }

/** One screen back: pick -> room -> friend -> list -> the profile. */
static void fr_back(void) {
    rs_sfx(RS_SFX_CLOSE);
    if (FR_page == 5) fr_go(4);
    else if (FR_page == 4) fr_go(FR_friend ? 3 : 2);
    else if (FR_page != 0) fr_go(0);
    else fr_close();
}

/** The back chevron and the page's title, at the top of every page but the list. */
static UIView *fr_header_row(NSString *title) {
    UIImageView *chev = rs_image_tinted(@"/friends/art/ic_chevron_right.png", 14, 24, rs_rgb(0x3D5866));
    chev.transform = CGAffineTransformMakeRotation(M_PI);
    UILabel *t = rs_label(title, 22, true, rs_rgb(0x2E4A5A));
    t.numberOfLines = 1;
    t.adjustsFontSizeToFitWidth = YES;
    t.minimumScaleFactor = 0.7;
    UIStackView *row = rs_hstack(@[chev, t], 14);
    UIView *box = [UIView new];
    [box addSubview:row];
    rs_pin(row, box, UIEdgeInsetsMake(4, 4, 8, 0));
    rs_on_tap(box, ^{ fr_back(); });
    return box;
}

// ---- v193: gift and trade animations, with their sounds

/** A picture positioned by frame (rs_image lays out with constraints), from the art cache. */
static UIImageView *fr_free_image(NSString *path, CGFloat size) {
    UIImageView *iv = rs_image(path, 0, 0);               // starts the download if it isn't cached
    iv.translatesAutoresizingMaskIntoConstraints = YES;
    iv.contentMode = UIViewContentModeScaleAspectFit;
    iv.clipsToBounds = NO;
    iv.frame = CGRectMake(0, 0, size, size);
    return iv;
}

/** Little stars bursting out of a point and fading. */
static void fr_sparkles(UIView *in, CGPoint at, int n, CGFloat reach) {
    NSArray *colors = @[rs_rgb(0xFFD54A), rs_rgb(0x8EE6C2), UIColor.whiteColor, rs_rgb(0xF6A6C8)];
    for (int i = 0; i < n; i++) {
        UILabel *s = [UILabel new];
        s.text = i % 3 ? @"✦" : @"✧";
        s.font = [UIFont systemFontOfSize:14 + (i % 4) * 4 weight:UIFontWeightBold];
        s.textColor = colors[i % colors.count];
        [s sizeToFit];
        s.center = at;
        [in addSubview:s];
        CGFloat ang = (2 * M_PI * i) / n + (i % 2) * 0.3;
        CGFloat r = reach * (0.6 + 0.4 * ((i * 37) % 10) / 10.0);
        [UIView animateWithDuration:0.7 delay:0.02 * (i % 5) options:UIViewAnimationOptionCurveEaseOut animations:^{
            s.center = CGPointMake(at.x + cos(ang) * r, at.y + sin(ang) * r);
            s.transform = CGAffineTransformMakeRotation(ang);
            s.alpha = 0;
        } completion:^(BOOL d) { [s removeFromSuperview]; }];
    }
}

/** The gift leaves: it pops up off the SEND GIFT button and flies away up the screen. */
static void fr_anim_gift_send(UIView *from) {
    if (!FR_screen || !from.window) { rs_sfx_modern(FR_SFX_GIFT_SEND); return; }
    CGPoint at = [from.superview convertPoint:from.center toView:FR_screen];
    UIImageView *g = fr_free_image(@"/friends/art/ic_gift.png", 64);
    g.center = at;
    g.transform = CGAffineTransformMakeScale(0.4, 0.4);
    [FR_screen addSubview:g];
    rs_sfx_modern(FR_SFX_GIFT_SEND);
    fr_sparkles(FR_screen, at, 10, 70);
    [UIView animateKeyframesWithDuration:1.0 delay:0 options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.25 animations:^{
            g.transform = CGAffineTransformMakeScale(1.5, 1.5);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.25 relativeDuration:0.75 animations:^{
            g.center = CGPointMake(at.x + 40, -60);
            g.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(0.7, 0.7), CGAffineTransformMakeRotation(0.5));
            g.alpha = 0.2;
        }];
    } completion:^(BOOL d) { [g removeFromSuperview]; }];
}

/** A dimmed layer over everything for the open / trade shows; a tap (once it's done) closes it. */
static UIView *fr_show_layer(void) {
    UIView *layer = [[UIView alloc] initWithFrame:FR_screen.bounds];
    layer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    layer.backgroundColor = [UIColor colorWithWhite:0 alpha:0];
    [FR_screen addSubview:layer];
    [UIView animateWithDuration:0.2 animations:^{ layer.backgroundColor = [UIColor colorWithWhite:0.05 alpha:0.62]; }];
    return layer;
}

static void fr_show_end(UIView *layer, NSTimeInterval after) {
    __block bool gone = false;
    void (^close)(void) = ^{
        if (gone) return;
        gone = true;
        [UIView animateWithDuration:0.25 animations:^{ layer.alpha = 0; } completion:^(BOOL d) { [layer removeFromSuperview]; }];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        rs_on_tap(layer, close);                        // not before the show has really started
    });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(after * NSEC_PER_SEC)), dispatch_get_main_queue(), close);
}

/** Opening a gift: it shakes, bursts, and what was inside pops out. */
static void fr_anim_gift_open(NSArray *items, NSString *from) {
    if (!FR_screen || FR_screen.hidden) { rs_sfx_modern(FR_SFX_GIFT_OPEN); return; }
    UIView *layer = fr_show_layer();
    CGSize sz = layer.bounds.size;
    CGPoint mid = CGPointMake(sz.width / 2, sz.height * 0.42);
    UIImageView *g = fr_free_image(@"/friends/art/ic_gift.png", 150);
    g.center = mid;
    g.transform = CGAffineTransformMakeScale(0.2, 0.2);
    [layer addSubview:g];
    UILabel *title = rs_label([NSString stringWithFormat:@"%@'s gift", from ?: @"Your friend"], 22, true, UIColor.whiteColor);
    title.textAlignment = NSTextAlignmentCenter;
    title.translatesAutoresizingMaskIntoConstraints = YES;
    title.frame = CGRectMake(20, mid.y - 150, sz.width - 40, 30);
    title.alpha = 0;
    [layer addSubview:title];
    [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0 animations:^{
        g.transform = CGAffineTransformIdentity;
        title.alpha = 1;
    } completion:nil];
    CAKeyframeAnimation *shake = [CAKeyframeAnimation animationWithKeyPath:@"transform.rotation.z"];
    shake.values = @[@0, @-0.12, @0.12, @-0.18, @0.18, @-0.25, @0.25, @0];
    shake.duration = 0.75;
    shake.beginTime = CACurrentMediaTime() + 0.35;
    [g.layer addAnimation:shake forKey:@"shake"];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        rs_sfx_modern(FR_SFX_GIFT_OPEN);
        fr_sparkles(layer, mid, 18, 140);
        [UIView animateWithDuration:0.25 animations:^{
            g.transform = CGAffineTransformMakeScale(1.7, 1.7);
            g.alpha = 0;
        }];
        NSMutableArray *bubbles = [NSMutableArray array];
        for (NSDictionary *rw in items) [bubbles addObject:rs_reward_bubble(rw, 72, true)];
        UIStackView *row = rs_hstack(bubbles, 14);
        UIView *box = [UIView new];
        [box addSubview:row];
        rs_pin(row, box, UIEdgeInsetsZero);
        box.translatesAutoresizingMaskIntoConstraints = NO;
        [layer addSubview:box];
        [NSLayoutConstraint activateConstraints:@[[box.centerXAnchor constraintEqualToAnchor:layer.centerXAnchor],
                                                  [box.centerYAnchor constraintEqualToAnchor:layer.topAnchor constant:mid.y]]];
        box.transform = CGAffineTransformMakeScale(0.1, 0.1);
        box.alpha = 0;
        [UIView animateWithDuration:0.5 delay:0.08 usingSpringWithDamping:0.55 initialSpringVelocity:0.9 options:0 animations:^{
            box.transform = CGAffineTransformIdentity;
            box.alpha = 1;
        } completion:nil];
        UILabel *tap = rs_label(@"Tap to continue", 14, false, [UIColor colorWithWhite:1 alpha:0.75]);
        tap.textAlignment = NSTextAlignmentCenter;
        tap.translatesAutoresizingMaskIntoConstraints = YES;
        tap.frame = CGRectMake(20, mid.y + 110, sz.width - 40, 24);
        [layer addSubview:tap];
    });
    fr_show_end(layer, 5.0);
}

/** A trade going through: the two Pokemon swap places in a flash, then the new one shows. */
static void fr_anim_trade(NSDictionary *gave, NSDictionary *got) {
    if (!FR_screen || FR_screen.hidden) { rs_sfx_modern(FR_SFX_TRADE); return; }
    UIView *layer = fr_show_layer();
    CGSize sz = layer.bounds.size;
    CGFloat y = sz.height * 0.42;
    CGPoint L = CGPointMake(sz.width * 0.22, y), R = CGPointMake(sz.width * 0.78, y), M = CGPointMake(sz.width / 2, y);
    UIImageView *a = fr_free_image([NSString stringWithFormat:@"/research/pokemon/%d.png", [rj(gave, @"id") intValue]], 120);
    UIImageView *b = fr_free_image([NSString stringWithFormat:@"/research/pokemon/%d.png", [rj(got, @"id") intValue]], 120);
    a.center = L; b.center = R;
    a.alpha = b.alpha = 0;
    [layer addSubview:a]; [layer addSubview:b];
    rs_sfx_modern(FR_SFX_TRADE);
    FR_music_done = FR_trade ?: @"?";                     // v194: the trade theme takes over
    fr_music_sync();
    const NSTimeInterval lag = 0.5;                       // v194: the flash lands on trade_demo's hit
    [UIView animateWithDuration:0.25 delay:lag * 0.6 options:0 animations:^{ a.alpha = b.alpha = 1; } completion:nil];
    [UIView animateKeyframesWithDuration:0.9 delay:0.25 + lag options:UIViewKeyframeAnimationOptionCalculationModeCubic animations:^{
        [UIView addKeyframeWithRelativeStartTime:0 relativeDuration:0.5 animations:^{       // up and in, crossing
            a.center = CGPointMake(M.x, y - 70); b.center = CGPointMake(M.x, y + 70);
            a.transform = b.transform = CGAffineTransformMakeScale(0.7, 0.7);
        }];
        [UIView addKeyframeWithRelativeStartTime:0.5 relativeDuration:0.5 animations:^{     // and out the other side
            a.center = R; b.center = L;
            a.transform = b.transform = CGAffineTransformIdentity;
        }];
    } completion:nil];
    UIView *flash = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 60, 60)];
    flash.backgroundColor = UIColor.whiteColor;
    flash.layer.cornerRadius = 30;
    flash.center = M;
    flash.alpha = 0;
    [layer addSubview:flash];
    [UIView animateWithDuration:0.35 delay:0.62 + lag options:UIViewAnimationOptionCurveEaseOut animations:^{
        flash.transform = CGAffineTransformMakeScale(6, 6);
        flash.alpha = 0.85;
    } completion:^(BOOL d) {
        [UIView animateWithDuration:0.3 animations:^{ flash.alpha = 0; } completion:^(BOOL d2) { [flash removeFromSuperview]; }];
    }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1.3 + lag) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        fr_sparkles(layer, L, 16, 120);
        [UIView animateWithDuration:0.3 animations:^{ a.alpha = 0; }];
        [UIView animateWithDuration:0.5 delay:0 usingSpringWithDamping:0.55 initialSpringVelocity:0.8 options:0 animations:^{
            b.center = M;
            b.transform = CGAffineTransformMakeScale(1.45, 1.45);
        } completion:nil];
        UILabel *t = rs_label([NSString stringWithFormat:@"You got %@!", rj(got, @"name") ?: @"a Pokémon"], 24, true, UIColor.whiteColor);
        t.textAlignment = NSTextAlignmentCenter;
        t.translatesAutoresizingMaskIntoConstraints = YES;
        t.frame = CGRectMake(20, y + 110, sz.width - 40, 34);
        t.transform = CGAffineTransformMakeScale(0.3, 0.3);
        t.alpha = 0;
        [layer addSubview:t];
        [UIView animateWithDuration:0.4 delay:0.15 usingSpringWithDamping:0.6 initialSpringVelocity:0.8 options:0 animations:^{
            t.transform = CGAffineTransformIdentity;
            t.alpha = 1;
        } completion:nil];
    });
    fr_show_end(layer, 5.0);
}

// ---- the list
static UIView *fr_friend_card(NSDictionary *f) {
    UIView *c = [UIView new];
    c.backgroundColor = UIColor.whiteColor;
    UIView *av = fr_avatar(f, 72);
    UIView *hearts = fr_hearts([rj(f, @"friendship") intValue], 18);
    UIStackView *left = rs_vstack(@[av, hearts], 6);
    left.alignment = UIStackViewAlignmentCenter;
    rs_size(left, 92, 0);                           // a fixed column, so every row lines up
    UILabel *name = rs_label(rj(f, @"name") ?: @"?", 19, true, rs_rgb(0x2E4A5A));
    name.numberOfLines = 1;
    bool online = [rj(f, @"online") boolValue];
    UILabel *when = rs_label(online ? @"Online" : fr_ago([rj(f, @"seen_ms") doubleValue]), 15, false,
                             online ? rs_green() : rs_rgb(0x9AABB0));
    when.numberOfLines = 1;
    when.textAlignment = NSTextAlignmentRight;
    [when setContentCompressionResistancePriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [when setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];
    [name setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *top = rs_hstack(@[name, when], 8);
    top.alignment = UIStackViewAlignmentFirstBaseline;
    UIView *sub;
    if ([rj(f, @"gift") boolValue]) {               // v189: "<name> sent you a Gift!", like the newer game
        UIImageView *g = rs_image(@"/friends/art/ic_gift.png", 34, 40);
        UILabel *l = rs_label([NSString stringWithFormat:@"%@ sent you a Gift!", rj(f, @"name") ?: @"?"], 16, false, rs_rgb(0x5F7A82));
        sub = rs_hstack(@[g, l], 10);
    } else {
        sub = rs_label([NSString stringWithFormat:@"%@ · Lv. %d", rj(f, @"friendship_name") ?: @"Friend",
                        [rj(f, @"level") intValue]], 16, false, rs_rgb(0x5F7A82));
    }
    UIStackView *right = rs_vstack(@[top, sub], 10);
    [right setContentHuggingPriority:UILayoutPriorityDefaultLow forAxis:UILayoutConstraintAxisHorizontal];
    UIStackView *row = rs_hstack(@[left, right], 14);
    row.alignment = UIStackViewAlignmentCenter;
    UIStackView *v = rs_vstack(@[row, fr_line()], 14);
    [c addSubview:v];
    rs_pin(v, c, UIEdgeInsetsMake(4, 0, 0, 0));
    NSString *fid = rj(f, @"id");
    rs_on_tap(c, ^{ FR_friend = fid; rs_sfx(RS_SFX_OPEN); fr_go(3); });
    return c;
}

static void fr_render_list(void) {
    NSArray *friends = rj(FR_state, @"friends") ?: @[];
    UIView *add = fr_icon_button(@"/friends/art/ico_add_friends.png", @"ADD FRIEND", 56, 0, ^{ fr_go(1); });
    UIView *req = fr_icon_button(@"/friends/art/ico_friend_request.png", @"REQUESTS", 56, FR_requests, ^{ fr_go(2); });
    UIStackView *buttons = rs_hstack(@[add, req], 12);
    buttons.distribution = UIStackViewDistributionFillEqually;
    buttons.alignment = UIStackViewAlignmentFill;
    [FR_stack addArrangedSubview:buttons];
    [FR_stack addArrangedSubview:fr_line()];
    if (!friends.count)
        [FR_stack addArrangedSubview:fr_empty(@"No friends yet. Tap ADD FRIEND and share your Trainer Code!")];
    for (NSDictionary *f in friends) [FR_stack addArrangedSubview:fr_friend_card(f)];
}

// ---- add a friend
@interface WSFriendsField : NSObject <UITextFieldDelegate> @end
@implementation WSFriendsField
- (BOOL)textField:(UITextField *)tf shouldChangeCharactersInRange:(NSRange)r replacementString:(NSString *)s {
    NSString *t = [tf.text stringByReplacingCharactersInRange:r withString:s];
    NSString *digits = [[t componentsSeparatedByCharactersInSet:NSCharacterSet.decimalDigitCharacterSet.invertedSet]
                        componentsJoinedByString:@""];
    if (digits.length > 12) return NO;
    FR_code_typed = digits;
    tf.text = fr_code_text(digits).length == 14 ? fr_code_text(digits) : digits;
    return NO;
}
- (BOOL)textFieldShouldReturn:(UITextField *)tf { [tf resignFirstResponder]; return YES; }
@end
static WSFriendsField *FR_field_delegate = nil;

static void fr_send_code(void) {
    [FR_code_field resignFirstResponder];
    if (FR_code_typed.length != 12) {
        FR_note = @"A Trainer Code has 12 digits."; FR_note_bad = true;
        FR_note_t = [NSDate date].timeIntervalSince1970;
        fr_render();
        return;
    }
    fr_post(@"add", @{@"code": FR_code_typed}, ^(NSDictionary *j) {
        if (rj(j, @"message")) { FR_code_typed = @""; rs_sfx_modern(FR_SFX_LETTER); }
    });
}

static void fr_share(NSString *code) {
    UIView *parent = mt_unity_view();
    UIViewController *vc = parent.window.rootViewController;
    while (vc.presentedViewController) vc = vc.presentedViewController;
    if (!vc) return;
    NSString *text = [NSString stringWithFormat:@"Add me as a friend in Windstock! My Trainer Code: %@", fr_code_text(code)];
    UIActivityViewController *a = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
    a.popoverPresentationController.sourceView = parent;
    a.popoverPresentationController.sourceRect = CGRectMake(parent.bounds.size.width / 2, parent.bounds.size.height / 2, 1, 1);
    [vc presentViewController:a animated:YES completion:nil];
}

static void fr_render_add(void) {
    NSString *code = rj(rj(FR_state, @"me"), @"code") ?: @"";
    [FR_stack addArrangedSubview:fr_section_title(@"My Trainer Code")];
    UIView *card = rs_card();
    UIImageView *qr = [[UIImageView alloc] initWithImage:fr_qr([@"windstock-friend:" stringByAppendingString:code], 170)];
    qr.contentMode = UIViewContentModeScaleAspectFit;
    rs_size(qr, 170, 170);
    UIImageView *ball = rs_image(@"/friends/art/QR_Pokeball.png", 34, 34);   // like the game's code
    ball.backgroundColor = UIColor.whiteColor;
    ball.layer.cornerRadius = 17;
    [qr addSubview:ball];
    [NSLayoutConstraint activateConstraints:@[[ball.centerXAnchor constraintEqualToAnchor:qr.centerXAnchor],
                                              [ball.centerYAnchor constraintEqualToAnchor:qr.centerYAnchor]]];
    UILabel *num = rs_label(fr_code_text(code), 26, true, rs_ink());
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc] initWithString:num.text];
    [a addAttribute:NSKernAttributeName value:@(1.5) range:NSMakeRange(0, a.length)];
    num.attributedText = a;
    num.textAlignment = NSTextAlignmentCenter;
    UIView *copy = fr_icon_button(@"/friends/art/ic_copy_button.png", @"COPY", 42, 0, ^{
        UIPasteboard.generalPasteboard.string = code;
        FR_note = @"Trainer Code copied."; FR_note_bad = false;
        FR_note_t = [NSDate date].timeIntervalSince1970;
        fr_render();
    });
    UIView *share = fr_icon_button(@"/friends/art/ic_share.png", @"SHARE", 42, 0, ^{ fr_share(code); });
    UIStackView *two = rs_hstack(@[copy, share], 12);
    two.distribution = UIStackViewDistributionFillEqually;
    two.alignment = UIStackViewAlignmentFill;
    UIStackView *v = rs_vstack(@[qr, num, two], 14);
    v.alignment = UIStackViewAlignmentCenter;
    [two.widthAnchor constraintEqualToAnchor:v.widthAnchor].active = YES;
    [card addSubview:v];
    rs_pin(v, card, UIEdgeInsetsMake(20, 16, 18, 16));
    [FR_stack addArrangedSubview:card];

    [FR_stack addArrangedSubview:fr_section_title(@"Add a friend")];
    UIView *card2 = rs_card();
    UITextField *tf = [UITextField new];
    if (!FR_field_delegate) FR_field_delegate = [WSFriendsField new];
    tf.delegate = FR_field_delegate;
    tf.keyboardType = UIKeyboardTypeNumberPad;
    tf.textAlignment = NSTextAlignmentCenter;
    tf.font = rs_font(22, true);
    tf.textColor = rs_ink();
    tf.attributedPlaceholder = [[NSAttributedString alloc] initWithString:@"Enter Trainer Code"
        attributes:@{NSForegroundColorAttributeName: rs_ink2(), NSFontAttributeName: rs_font(18, true)}];
    tf.text = FR_code_typed.length == 12 ? fr_code_text(FR_code_typed) : FR_code_typed;
    tf.backgroundColor = rs_rgb(0xF0F5F5);
    tf.layer.cornerRadius = 14;
    rs_size(tf, 0, 52);
    UIToolbar *bar = [[UIToolbar alloc] initWithFrame:CGRectMake(0, 0, 320, 44)];   // number pads have no return key
    bar.items = @[[[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemFlexibleSpace target:nil action:nil],
                  [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                target:tf action:@selector(resignFirstResponder)]];
    tf.inputAccessoryView = bar;
    FR_code_field = tf;
    UIView *send = rs_green_button(@"SEND FRIEND REQUEST", true, ^{ fr_send_code(); });
    UILabel *hint = rs_label(@"Ask your friend for their 12-digit code: it's on their Add Friend page.", 13, false, rs_ink2());
    hint.textAlignment = NSTextAlignmentCenter;
    UIStackView *v2 = rs_vstack(@[tf, send, hint], 12);
    [card2 addSubview:v2];
    rs_pin(v2, card2, UIEdgeInsetsMake(16, 16, 16, 16));
    [FR_stack addArrangedSubview:card2];
}

// ---- requests
static UIView *fr_request_card(NSDictionary *r, bool incoming) {
    UIView *c = rs_card();
    UIView *av = fr_avatar(r, 48);
    UILabel *name = rs_label(rj(r, @"name") ?: @"?", 16, true, rs_ink());
    name.numberOfLines = 1;
    UILabel *sub = rs_label([NSString stringWithFormat:@"Lv. %d · %@", [rj(r, @"level") intValue],
                             fr_team_name([rj(r, @"team") intValue])], 12, true, rs_ink2());
    UIStackView *mid = rs_vstack(@[name, sub], 3);
    NSString *rid = rj(r, @"id");
    NSArray *buttons;
    if (incoming) {
        UIView *yes = fr_small_button(@"ACCEPT", rs_green(), UIColor.whiteColor, ^{
            fr_post(@"accept", @{@"id": rid}, ^(NSDictionary *j) { if (rj(j, @"message")) rs_sfx_modern(FR_SFX_OK); });
        });
        UIView *no = fr_small_button(@"DECLINE", rs_rgb(0xE9EFEF), rs_ink2(), ^{ fr_post(@"decline", @{@"id": rid}, nil); });
        UIStackView *bs = rs_vstack(@[yes, no], 6);
        buttons = @[bs];
    } else {
        buttons = @[fr_small_button(@"CANCEL", rs_rgb(0xE9EFEF), rs_ink2(), ^{ fr_post(@"cancel", @{@"id": rid}, nil); })];
    }
    UIStackView *row = rs_hstack([@[av, mid] arrayByAddingObjectsFromArray:buttons], 12);
    [c addSubview:row];
    rs_pin(row, c, UIEdgeInsetsMake(12, 12, 12, 12));
    return c;
}

static UIView *fr_mon_line(NSDictionary *m, NSString *caption) {
    UIImageView *icon = rs_image([NSString stringWithFormat:@"/research/pokemon/%d.png", [rj(m, @"id") intValue]], 52, 52);
    NSString *nm = [rj(m, @"nickname") length] ? rj(m, @"nickname") : (rj(m, @"name") ?: @"?");
    if ([rj(m, @"shiny") boolValue]) nm = [nm stringByAppendingString:@" ✨"];
    UILabel *cap = rs_label(caption, 12, true, rs_ink2());
    UILabel *n = rs_label(nm, 16, true, rs_ink());
    n.numberOfLines = 1;
    UILabel *cp = rs_label([NSString stringWithFormat:@"CP %d", [rj(m, @"cp") intValue]], 13, false, rs_ink2());
    UIStackView *t = rs_vstack(cap.text.length ? @[cap, n, cp] : @[n, cp], 2);
    return rs_hstack(@[icon, t], 10);
}

static UIView *fr_room_card(NSDictionary *t) {
    UIView *c = rs_card();
    NSString *who = rj(t, @"friend_name") ?: @"?";
    UIImageView *icon = rs_image_tinted(@"/friends/art/pogo_trade_icon.png", 40, 40, rs_teal());   // white art: teal on the card
    UILabel *l1 = rs_label([NSString stringWithFormat:@"Trade with %@", who], 16, true, rs_ink());
    UILabel *l2 = rs_label([rj(t, @"their_pick") boolValue] ? [NSString stringWithFormat:@"%@ has chosen a Pokémon", who]
                                                             : @"Open -- pick your Pokémon", 13, false, rs_ink2());
    UIStackView *mid = rs_vstack(@[l1, l2], 2);
    NSString *rid = rj(t, @"trade"), *fid = rj(t, @"friend");
    UIView *go = fr_small_button(@"OPEN", rs_green(), UIColor.whiteColor, ^{
        FR_trade = rid; FR_friend = fid; FR_room = nil; FR_room_raw = nil; fr_go(4);
    });
    UIStackView *row = rs_hstack(@[icon, mid, go], 12);
    [c addSubview:row];
    rs_pin(row, c, UIEdgeInsetsMake(12, 12, 12, 12));
    return c;
}

static void fr_render_requests(void) {
    NSArray *in = rj(FR_state, @"incoming") ?: @[], *out = rj(FR_state, @"outgoing") ?: @[];
    NSArray *rooms = rj(FR_state, @"trades") ?: @[];
    if (rooms.count) {                              // v190: open trade rooms first
        [FR_stack addArrangedSubview:fr_section_title(@"Trades")];
        for (NSDictionary *t in rooms) [FR_stack addArrangedSubview:fr_room_card(t)];
    }
    [FR_stack addArrangedSubview:fr_section_title(@"Friend requests")];
    if (!in.count) [FR_stack addArrangedSubview:fr_empty(@"No friend requests right now.")];
    for (NSDictionary *r in in) [FR_stack addArrangedSubview:fr_request_card(r, true)];
    if (out.count) {
        [FR_stack addArrangedSubview:fr_section_title(@"Sent")];
        for (NSDictionary *r in out) [FR_stack addArrangedSubview:fr_request_card(r, false)];
    }
}

// ---- one friend
static void fr_render_friend(void) {
    NSDictionary *f = nil;
    for (NSDictionary *x in rj(FR_state, @"friends") ?: @[])
        if ([rj(x, @"id") isEqual:FR_friend]) f = x;
    if (!f) { FR_page = 0; fr_render_list(); return; }
    int lvl = [rj(f, @"friendship") intValue], days = [rj(f, @"days") intValue];
    id next = rj(f, @"next_days");
    NSArray *names = rj(FR_state, @"levels") ?: @[@"Friend", @"Good Friend", @"Great Friend", @"Ultra Friend", @"Best Friend"];

    UIView *card = rs_card();
    UIView *av = fr_avatar(f, 110);
    UILabel *name = rs_label(rj(f, @"name") ?: @"?", 24, true, rs_ink());
    name.textAlignment = NSTextAlignmentCenter;
    bool online = [rj(f, @"online") boolValue];
    UILabel *sub = rs_label([NSString stringWithFormat:@"Lv. %d · %@ · %@", [rj(f, @"level") intValue],
                             fr_team_name([rj(f, @"team") intValue]),
                             online ? @"Online" : fr_ago([rj(f, @"seen_ms") doubleValue])], 14, true, rs_ink2());
    sub.textAlignment = NSTextAlignmentCenter;
    UIView *hearts = fr_hearts(lvl, 30);
    UILabel *kind = rs_label(rj(f, @"friendship_name") ?: @"Friend", 18, true, fr_pink());
    kind.textAlignment = NSTextAlignmentCenter;
    UIStackView *v = rs_vstack(@[av, name, sub, hearts, kind], 10);
    v.alignment = UIStackViewAlignmentCenter;
    ws_spacing_after(v, 16, sub);
    if ([next isKindOfClass:[NSNumber class]]) {
        int need = [next intValue], prev = 0;
        int steps[] = {0, 1, 7, 30, 90};
        if (lvl >= 0 && lvl < 5) prev = steps[lvl];
        WSResearchBar *bar = [WSResearchBar new];
        bar.fraction = need > prev ? (CGFloat)(days - prev) / (need - prev) : 0;
        rs_size(bar, 0, 12);
        NSString *nextName = lvl + 1 < (int)names.count ? names[lvl + 1] : @"";
        int left = MAX(0, need - days);
        UILabel *togo = rs_label([NSString stringWithFormat:@"%d more %@ to %@", left, left == 1 ? @"day" : @"days", nextName],
                                 13, true, rs_ink2());
        togo.textAlignment = NSTextAlignmentCenter;
        UIStackView *prog = rs_vstack(@[bar, togo], 6);
        [v addArrangedSubview:prog];
        [prog.widthAnchor constraintEqualToAnchor:v.widthAnchor].active = YES;
    }
    UILabel *how = rs_label([rj(f, @"today") boolValue]
                            ? @"You interacted today: friendship +1 ✓"
                            : @"Open a gift or trade once a day to grow your friendship.", 13, false, rs_ink2());
    how.textAlignment = NSTextAlignmentCenter;
    [v addArrangedSubview:how];
    [card addSubview:v];
    rs_pin(v, card, UIEdgeInsetsMake(22, 18, 20, 18));
    [FR_stack addArrangedSubview:card];

    // v189: gifts and trades
    NSString *fid0 = rj(f, @"id");
    UIView *gift;
    if ([rj(f, @"gift") boolValue]) {
        FR_btn_sfx = FR_SFX_GIFT_SELECT;
        gift = fr_icon_button(@"/friends/art/ic_gift.png", @"OPEN GIFT", 56, 0, ^{
            NSString *from = rj(f, @"name");
            fr_post(@"open", @{@"id": fid0}, ^(NSDictionary *j) {
                NSArray *items = rj(j, @"items");
                if ([items isKindOfClass:[NSArray class]] && items.count) {
                    FR_gift_items = items;
                    FR_gift_from = from;
                    fr_anim_gift_open(items, from);       // v193: shake, burst, the items pop out
                }
            });
        });
    } else if ([rj(f, @"gift_sent") boolValue]) {
        gift = fr_icon_button(@"/friends/art/ic_gift.png", @"GIFT SENT ✓", 56, 0, nil);
        gift.alpha = 0.55;
    } else {
        __block UIView *gift_btn = nil;
        FR_btn_sfx = FR_SFX_GIFT_SELECT;
        gift = fr_icon_button(@"/friends/art/ic_gift.png", @"SEND GIFT", 56, 0, ^{
            CGPoint from = CGPointZero;
            UIView *btn = gift_btn;                        // where the gift flies from (read before the redraw)
            UIView *ghost = nil;
            if (btn.window) {
                from = [btn.superview convertPoint:btn.center toView:FR_screen];
                ghost = [[UIView alloc] initWithFrame:CGRectMake(from.x, from.y, 1, 1)];
                [FR_screen addSubview:ghost];
            }
            fr_post(@"gift", @{@"id": fid0}, ^(NSDictionary *j) {
                if (rj(j, @"message")) fr_anim_gift_send(ghost);   // v193: off it flies
                [ghost removeFromSuperview];
            });
        });
        gift_btn = gift;
    }
    FR_btn_sfx = FR_SFX_TRADE_BTN;
    UIView *trade = fr_icon_button(@"/friends/art/pogo_trade_icon.png", @"TRADE", 56, 0, ^{
        fr_post(@"trade_start", @{@"id": fid0}, ^(NSDictionary *j) {
            if (![rj(j, @"trade") isKindOfClass:[NSString class]]) return;
            FR_trade = rj(j, @"trade"); FR_room = nil; FR_room_raw = nil;
            fr_go(4);
        });
    });
    UIStackView *acts = rs_hstack(@[gift, trade], 12);
    acts.distribution = UIStackViewDistributionFillEqually;
    acts.alignment = UIStackViewAlignmentFill;
    [FR_stack addArrangedSubview:acts];
    if (FR_gift_items.count && [FR_gift_from isEqual:rj(f, @"name")]) {
        UIView *gc = rs_card();
        NSMutableArray *bubbles = [NSMutableArray array];
        for (NSDictionary *rw in FR_gift_items) [bubbles addObject:rs_reward_bubble(rw, 64, false)];
        UIStackView *bs = rs_hstack(bubbles, 12);
        UILabel *gl = rs_label([NSString stringWithFormat:@"%@'s gift had:", FR_gift_from], 14, true, rs_ink());
        UIStackView *gv = rs_vstack(@[gl, bs], 10);
        gv.alignment = UIStackViewAlignmentCenter;
        [gc addSubview:gv];
        rs_pin(gv, gc, UIEdgeInsetsMake(14, 14, 14, 14));
        [FR_stack addArrangedSubview:gc];
    }

    NSDateFormatter *df = [NSDateFormatter new];
    df.dateStyle = NSDateFormatterMediumStyle;
    NSString *since = [df stringFromDate:[NSDate dateWithTimeIntervalSince1970:[rj(f, @"since") doubleValue] / 1000.0]];
    UIView *info = rs_card();
    UIStackView *rows = rs_vstack(@[], 10);
    for (NSArray *kv in @[@[@"Friends since", since],
                          @[@"Friendship days", [NSString stringWithFormat:@"%d", days]]]) {
        UILabel *k = rs_label(kv[0], 14, false, rs_ink2());
        UILabel *val = rs_label(kv[1], 14, true, rs_ink());
        val.textAlignment = NSTextAlignmentRight;
        [rows addArrangedSubview:rs_hstack(@[k, val], 8)];
    }
    [info addSubview:rows];
    rs_pin(rows, info, UIEdgeInsetsMake(14, 16, 14, 16));
    [FR_stack addArrangedSubview:info];

    NSString *fid = rj(f, @"id");
    UILabel *rm = rs_label(FR_remove_armed ? @"TAP AGAIN TO REMOVE" : @"REMOVE FRIEND", 15, true,
                           FR_remove_armed ? UIColor.whiteColor : rs_rgb(0xD0505A));
    rm.textAlignment = NSTextAlignmentCenter;
    rm.backgroundColor = FR_remove_armed ? rs_rgb(0xD0505A) : rs_rgb(0xFBEDEE);
    rm.layer.cornerRadius = 22;
    rm.clipsToBounds = YES;
    rs_size(rm, 0, 44);
    rs_on_tap(rm, ^{
        if (!FR_remove_armed) { FR_remove_armed = true; fr_render(); return; }
        fr_post(@"remove", @{@"id": fid}, ^(NSDictionary *j) { FR_page = 0; FR_remove_armed = false; });
    });
    [FR_stack addArrangedSubview:rm];
}

// ---- v190: the trade room (4) and picking my Pokemon for it (5)
static NSDictionary *fr_friend_now(void) {
    for (NSDictionary *x in rj(FR_state, @"friends") ?: @[])
        if ([rj(x, @"id") isEqual:FR_friend]) return x;
    return nil;
}

static void fr_room_apply(NSData *d) {
    id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
    if (![j isKindOfClass:[NSDictionary class]]) return;
    if (rj(j, @"message") || rj(j, @"error")) {
        FR_note = rj(j, @"message") ?: rj(j, @"error");
        FR_note_bad = rj(j, @"error") != nil;
        FR_note_t = [NSDate date].timeIntervalSince1970;
    }
    if (!rj(j, @"trade") && rj(j, @"error")) { FR_room = @{@"state": @"cancelled", @"why": rj(j, @"error")}; }
    else {
        NSMutableDictionary *m = [j mutableCopy];
        [m removeObjectForKey:@"message"]; [m removeObjectForKey:@"error"];
        // v194: the friend's side changed (a Pokemon picked, confirmed) -> the trade machine's clunk
        NSDictionary *prev = FR_room;
        if ([rj(prev, @"trade") isEqual:rj(m, @"trade")] && [rj(m, @"state") isEqual:@"open"]) {
            id pt = rj(rj(prev, @"theirs"), @"uid"), nt = rj(rj(m, @"theirs"), @"uid");
            bool picked = nt && !(pt && [[NSString stringWithFormat:@"%@", pt] isEqual:[NSString stringWithFormat:@"%@", nt]]);
            bool confirmed = [rj(m, @"their_ok") boolValue] && ![rj(prev, @"their_ok") boolValue];
            if (picked || confirmed) rs_sfx_modern(FR_SFX_TRADE_THEM);
        }
        NSData *raw = [NSJSONSerialization dataWithJSONObject:m options:0 error:nil];
        bool same = FR_room_raw && [FR_room_raw isEqualToData:raw] && !rj(j, @"message") && !rj(j, @"error");
        FR_room = m; FR_room_raw = raw;
        if (same) return;                               // nothing new: leave the screen alone
        static NSString *shown = nil;                  // v193: the swap animation, once per trade
        if ([rj(m, @"state") isEqual:@"done"] && ![shown isEqual:rj(m, @"trade")]) {
            shown = rj(m, @"trade");
            NSDictionary *gave = rj(rj(m, @"result"), @"gave"), *got = rj(rj(m, @"result"), @"got");
            if (gave && got) fr_anim_trade(gave, got);
            else rs_sfx_modern(FR_SFX_TRADE);
        }
    }
    if (FR_page != 4 || !FR_screen || FR_screen.hidden) return;
    if (FR_chat_field.isFirstResponder && FR_chat_field.markedTextRange) { FR_render_pending = true; return; }   // mid-word (IME)
    fr_render();
}

static void fr_room_fetch(void) {
    if (!FR_trade) return;
    NSString *url = [NSString stringWithFormat:@"%@/friends/trade?t=%@", RS_HOST, FR_trade];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{ fr_room_apply(d); });
    }] resume];
}

static void fr_room_post(NSString *action, NSDictionary *extra) {
    NSMutableDictionary *body = [extra ?: @{} mutableCopy];
    body[@"trade"] = FR_trade ?: @"";
    NSString *url = [NSString stringWithFormat:@"%@/friends/%@", RS_HOST, action];
    NSMutableURLRequest *rq = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
    rq.HTTPMethod = @"POST";
    rq.HTTPBody = [NSJSONSerialization dataWithJSONObject:body options:0 error:nil];
    [rq setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    rq.timeoutInterval = 8;
    WLOG(@"friends: %@", action);
    [[[NSURLSession sharedSession] dataTaskWithRequest:rq completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!d) { FR_note = @"Couldn't reach the server."; FR_note_bad = true; FR_note_t = [NSDate date].timeIntervalSince1970; }
            FR_room_raw = nil;                          // always redraw after our own move
            fr_room_apply(d);
            if ([action isEqual:@"trade_pick"] && FR_page == 5) fr_go(4);
        });
    }] resume];
}

static void fr_fetch_box(void) {
    NSString *url = [NSString stringWithFormat:@"%@/friends/box", RS_HOST];
    [[[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:url] completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
        id j = d ? [NSJSONSerialization JSONObjectWithData:d options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            FR_box = [j isKindOfClass:[NSDictionary class]] ? j : @{@"ok": @NO, @"error": @"Couldn't reach the server."};
            if (FR_screen && !FR_screen.hidden && FR_page == 5) fr_render();
        });
    }] resume];
}

/** One side of the trade: the Pokemon (big), or a prompt. */
static UIView *fr_trade_side(NSString *who, NSDictionary *m, bool mine, bool ok) {
    UIView *c = rs_card();
    c.backgroundColor = mine ? rs_rgb(0xF2FBF7) : rs_rgb(0xF4F7F8);
    UILabel *w = rs_label(who.uppercaseString, 12, true, rs_ink2());
    w.textAlignment = NSTextAlignmentCenter;
    NSMutableArray *parts = [NSMutableArray arrayWithObject:w];
    if (m) {
        [parts addObject:rs_image([NSString stringWithFormat:@"/research/pokemon/%d.png", [rj(m, @"id") intValue]], 84, 84)];
        NSString *nm = [rj(m, @"nickname") length] ? rj(m, @"nickname") : (rj(m, @"name") ?: @"?");
        if ([rj(m, @"shiny") boolValue]) nm = [nm stringByAppendingString:@" ✨"];
        UILabel *n = rs_label(nm, 16, true, rs_ink());
        n.textAlignment = NSTextAlignmentCenter;
        n.numberOfLines = 1;
        n.adjustsFontSizeToFitWidth = YES;
        UILabel *cp = rs_label([NSString stringWithFormat:@"CP %d", [rj(m, @"cp") intValue]], 13, false, rs_ink2());
        cp.textAlignment = NSTextAlignmentCenter;
        [parts addObjectsFromArray:@[n, cp]];
    } else {
        UILabel *q = rs_label(mine ? @"＋" : @"…", 40, true, mine ? rs_green() : rs_ink2());
        q.textAlignment = NSTextAlignmentCenter;
        rs_size(q, 0, 84);
        UILabel *t = rs_label(mine ? @"Choose your Pokémon" : @"Choosing…", 14, true, mine ? rs_green() : rs_ink2());
        t.textAlignment = NSTextAlignmentCenter;
        [parts addObjectsFromArray:@[q, t]];
    }
    UILabel *st = rs_label(ok ? @"✓ Confirmed" : @" ", 12, true, rs_green());
    st.textAlignment = NSTextAlignmentCenter;
    [parts addObject:st];
    UIStackView *v = rs_vstack(parts, 6);
    v.alignment = UIStackViewAlignmentFill;
    [c addSubview:v];
    rs_pin(v, c, UIEdgeInsetsMake(12, 8, 10, 8));
    if (mine) rs_on_tap(c, ^{ rs_sfx_modern(FR_SFX_TRADE_BTN); FR_box = nil; fr_go(5); });
    return c;
}

static UIView *fr_chat_bubble(NSDictionary *m) {
    bool me = [rj(m, @"me") boolValue];
    NSString *text = rj(m, @"text") ?: @"";
    UILabel *l = rs_label(text, 15, false, me ? UIColor.whiteColor : rs_ink());
    UIView *b = [UIView new];
    b.backgroundColor = me ? rs_rgb(0x2E93A8) : rs_rgb(0xEEF3F3);
    b.layer.cornerRadius = 14;
    [b addSubview:l];
    rs_pin(l, b, UIEdgeInsetsMake(8, 12, 8, 12));
    UIView *spacer = [UIView new];
    [spacer setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];
    [b.widthAnchor constraintLessThanOrEqualToConstant:250].active = YES;
    return rs_hstack(me ? @[spacer, b] : @[b, spacer], 0);
}

@interface WSFriendsChat : NSObject <UITextFieldDelegate> @end
static void fr_chat_send(void);
@implementation WSFriendsChat
- (BOOL)textFieldShouldReturn:(UITextField *)tf { fr_chat_send(); return NO; }
- (void)textFieldDidEndEditing:(UITextField *)tf {
    FR_chat_draft = tf.text ?: @"";
    if (FR_render_pending) { FR_render_pending = false; dispatch_async(dispatch_get_main_queue(), ^{ fr_render(); }); }
}
- (void)changed:(UITextField *)tf { FR_chat_draft = tf.text ?: @""; }
- (void)sendTapped:(UIButton *)b { fr_chat_send(); }
- (void)textFieldDidBeginEditing:(UITextField *)tf { fr_chat_reveal(true); }
- (void)keyboard:(NSNotification *)n {
    if (!FR_screen || FR_screen.hidden) return;
    CGRect kb = [n.userInfo[UIKeyboardFrameEndUserInfoKey] CGRectValue];
    CGRect sc = [FR_scroll convertRect:FR_scroll.bounds toView:nil];
    CGFloat over = MAX(0, CGRectGetMaxY(sc) - kb.origin.y);
    if ([n.name isEqual:UIKeyboardWillHideNotification]) over = 0;
    UIEdgeInsets in = FR_scroll.contentInset;
    in.bottom = over > 0 ? over - 90 + 12 : 0;   // the 90pt pad under the page sits behind the keyboard anyway
    if (in.bottom < 0) in.bottom = 0;
    FR_scroll.contentInset = in;
    FR_scroll.scrollIndicatorInsets = in;
    if (over > 0 && FR_chat_field.isFirstResponder) fr_chat_reveal(true);
}
@end
static WSFriendsChat *FR_chat_delegate = nil;

/** v195: scroll so the chat's input row (text box + SEND) sits just above the keyboard. */
static void fr_chat_reveal(bool animated) {
    UIView *row = FR_chat_field.superview;
    if (!row || !FR_scroll) return;
    [FR_scroll layoutIfNeeded];
    CGRect r = [row convertRect:CGRectInset(row.bounds, 0, -12) toView:FR_scroll];
    [FR_scroll scrollRectToVisible:r animated:animated];
}

static void fr_chat_send(void) {
    NSString *t = [FR_chat_field.text ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length) return;
    FR_chat_field.text = @"";
    FR_chat_draft = @"";
    fr_room_post(@"trade_chat", @{@"text": t});
}

/** REPORT: why, then the server keeps the report with this trade's whole chat (trade_chats.py). */
static void fr_report_trade(NSString *who) {
    NSString *t = FR_trade ?: @"";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:[NSString stringWithFormat:@"Report %@?", who]
        message:@"The Windstock team gets this trade's chat with your report."
        preferredStyle:UIAlertControllerStyleAlert];
    NSArray *reasons = @[@[@"Harassment or bullying", @"harassment"], @[@"Scam or unfair trade", @"scam"],
                         @[@"Inappropriate messages", @"inappropriate"], @[@"Something else", @"other"]];
    for (NSArray *r in reasons)
        [a addAction:[UIAlertAction actionWithTitle:r[0] style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            fr_post(@"trade_report", @{@"trade": t, @"reason": r[1]}, nil);
        }]];
    [a addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [mt_top_controller() presentViewController:a animated:YES completion:nil];
}

/** The bottom of the room: REPORT, and CANCEL TRADE while it's open. */
static UIView *fr_room_foot(NSString *who, bool open) {
    UILabel *rpt = rs_label(@"REPORT", 14, true, rs_rgb(0x9AABB0));
    rpt.textAlignment = NSTextAlignmentCenter;
    rs_size(rpt, 0, 36);
    rs_on_tap(rpt, ^{ fr_report_trade(who); });
    NSMutableArray *parts = [NSMutableArray arrayWithObject:rpt];
    if (open) {
        UILabel *cancel = rs_label(@"CANCEL TRADE", 14, true, rs_rgb(0xD0505A));
        cancel.textAlignment = NSTextAlignmentCenter;
        rs_size(cancel, 0, 36);
        rs_on_tap(cancel, ^{ fr_room_post(@"trade_cancel", nil); });
        [parts addObject:cancel];
    }
    UIStackView *row = rs_hstack(parts, 0);
    row.distribution = UIStackViewDistributionFillEqually;
    return row;
}

static void fr_render_room(void) {
    NSDictionary *r = FR_room;
    NSString *who = rj(r, @"friend_name") ?: rj(fr_friend_now(), @"name") ?: @"your friend";
    [FR_stack addArrangedSubview:fr_header_row([NSString stringWithFormat:@"Trade with %@", who])];
    if (!r) {
        [FR_stack addArrangedSubview:fr_empty(@"Opening the trade…")];
        fr_room_fetch();
        return;
    }
    NSString *state = rj(r, @"state");
    if ([state isEqual:@"done"]) {
        NSDictionary *got = rj(rj(r, @"result"), @"got") ?: rj(r, @"theirs");
        UIView *c = rs_card();
        UIStackView *v = rs_vstack(@[rs_label(@"Trade complete!", 22, true, rs_ink())], 10);
        v.alignment = UIStackViewAlignmentCenter;
        if (got) {
            [v addArrangedSubview:rs_image([NSString stringWithFormat:@"/research/pokemon/%d.png", [rj(got, @"id") intValue]], 120, 120)];
            [v addArrangedSubview:rs_label([NSString stringWithFormat:@"You got %@!", rj(got, @"name")], 17, true, rs_green())];
        }
        [v addArrangedSubview:rs_label(@"It's in your Pokémon storage now.", 13, false, rs_ink2())];
        [c addSubview:v];
        rs_pin(v, c, UIEdgeInsetsMake(22, 16, 22, 16));
        [FR_stack addArrangedSubview:c];
        [FR_stack addArrangedSubview:rs_green_button(@"DONE", true, ^{ fr_back(); })];
        [FR_stack addArrangedSubview:fr_room_foot(who, false)];
        return;
    }
    if (![state isEqual:@"open"]) {
        [FR_stack addArrangedSubview:fr_empty(rj(r, @"why") ?: @"This trade is over.")];
        [FR_stack addArrangedSubview:rs_green_button(@"BACK", true, ^{ fr_back(); })];
        [FR_stack addArrangedSubview:fr_room_foot(who, false)];
        return;
    }
    bool my_ok = [rj(r, @"my_ok") boolValue], their_ok = [rj(r, @"their_ok") boolValue];
    NSDictionary *mine = rj(r, @"mine"), *theirs = rj(r, @"theirs");
    UIView *left = fr_trade_side(@"You", mine, true, my_ok);
    UIView *right = fr_trade_side(who, theirs, false, their_ok);
    UIImageView *swap = rs_image(@"/friends/art/btn_trade_swap.png", 30, 30);
    UIStackView *sides = rs_hstack(@[left, swap, right], 6);
    sides.alignment = UIStackViewAlignmentCenter;
    [left.widthAnchor constraintEqualToAnchor:right.widthAnchor].active = YES;
    [FR_stack addArrangedSubview:sides];
    if (rj(r, @"problem")) {
        UILabel *p = rs_label(rj(r, @"problem"), 13, true, rs_rgb(0xC2414B));
        p.textAlignment = NSTextAlignmentCenter;
        [FR_stack addArrangedSubview:p];
    } else if (rj(r, @"cost")) {
        UILabel *cost = rs_label([NSString stringWithFormat:@"Each of you pays %@ Stardust", rs_thousands([rj(r, @"cost") intValue])],
                                 13, false, rs_ink2());
        cost.textAlignment = NSTextAlignmentCenter;
        [FR_stack addArrangedSubview:cost];
    }
    bool ready = mine && theirs && !rj(r, @"problem");
    NSString *label = !mine ? @"CHOOSE YOUR POKÉMON" : !theirs ? [NSString stringWithFormat:@"WAITING FOR %@", who.uppercaseString]
                    : my_ok ? [NSString stringWithFormat:@"WAITING FOR %@ TO CONFIRM", who.uppercaseString] : @"CONFIRM TRADE";
    [FR_stack addArrangedSubview:rs_green_button(label, !mine || (ready && !my_ok), ^{
        if (!mine) { rs_sfx_modern(FR_SFX_TRADE_BTN); FR_box = nil; fr_go(5); }
        else { rs_sfx_modern(FR_SFX_TRADE_OK); fr_room_post(@"trade_ok", nil); }
    })];

    // the chat box
    UIView *chat = rs_card();
    NSMutableArray *rows = [NSMutableArray arrayWithObject:rs_label(@"CHAT", 12, true, rs_ink2())];
    NSArray *msgs = rj(r, @"chat") ?: @[];
    if (!msgs.count) [rows addObject:rs_label(@"Say hi and agree on the trade here.", 13, false, rs_ink2())];
    for (NSDictionary *m in [msgs subarrayWithRange:NSMakeRange(msgs.count > 30 ? msgs.count - 30 : 0, MIN(msgs.count, 30))])
        [rows addObject:fr_chat_bubble(m)];
    UITextField *tf = [UITextField new];
    if (!FR_chat_delegate) {
        FR_chat_delegate = [WSFriendsChat new];
        for (NSString *k in @[UIKeyboardWillChangeFrameNotification, UIKeyboardWillHideNotification])
            [NSNotificationCenter.defaultCenter addObserver:FR_chat_delegate selector:@selector(keyboard:) name:k object:nil];
    }
    tf.delegate = FR_chat_delegate;
    [tf addTarget:FR_chat_delegate action:@selector(changed:) forControlEvents:UIControlEventEditingChanged];
    tf.placeholder = @"Say something…";
    tf.text = FR_chat_draft;
    tf.font = rs_font(15, false);
    tf.textColor = rs_ink();
    tf.returnKeyType = UIReturnKeySend;
    tf.backgroundColor = rs_rgb(0xF0F5F5);
    tf.layer.cornerRadius = 18;
    tf.leftView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 14, 10)];
    tf.leftViewMode = UITextFieldViewModeAlways;
    rs_size(tf, 0, 40);
    FR_chat_field = tf;
    UIButton *send = [UIButton buttonWithType:UIButtonTypeCustom];   // v195: a real button, not a tapped label
    [send setTitle:@"SEND" forState:UIControlStateNormal];
    [send setTitleColor:UIColor.whiteColor forState:UIControlStateNormal];
    [send setTitleColor:[UIColor colorWithWhite:1 alpha:0.6] forState:UIControlStateHighlighted];
    send.titleLabel.font = rs_font(14, true);
    send.backgroundColor = rs_rgb(0x2E93A8);
    send.layer.cornerRadius = 20;
    send.exclusiveTouch = YES;
    rs_size(send, 84, 40);
    [send addTarget:FR_chat_delegate action:@selector(sendTapped:) forControlEvents:UIControlEventTouchUpInside];
    UIStackView *input = rs_hstack(@[tf, send], 8);
    [rows addObject:input];
    UIStackView *cv = rs_vstack(rows, 8);
    [chat addSubview:cv];
    rs_pin(cv, chat, UIEdgeInsetsMake(12, 12, 12, 12));
    [FR_stack addArrangedSubview:chat];

    [FR_stack addArrangedSubview:fr_room_foot(who, true)];
}

static void fr_render_pick(void) {
    [FR_stack addArrangedSubview:fr_header_row(@"Choose your Pokémon")];
    if (!FR_box) {
        FR_box = @{};
        fr_fetch_box();
    }
    if (!rj(FR_box, @"ok") && !rj(FR_box, @"error")) { [FR_stack addArrangedSubview:fr_empty(@"Loading your Pokémon…")]; return; }
    if (rj(FR_box, @"error")) { [FR_stack addArrangedSubview:fr_empty(rj(FR_box, @"error"))]; return; }
    NSArray *mons = rj(FR_box, @"pokemon") ?: @[];
    UILabel *dust = rs_label([NSString stringWithFormat:@"Stardust %@ · trades today %d/%d",
                              rs_thousands([rj(FR_box, @"stardust") intValue]), [rj(FR_box, @"trades_today") intValue],
                              [rj(FR_box, @"daily_limit") intValue]], 13, false, rs_ink2());
    [FR_stack addArrangedSubview:dust];
    if (!mons.count) [FR_stack addArrangedSubview:fr_empty(@"You have no Pokémon to trade.")];
    for (NSDictionary *m in mons) {
        UIView *c = rs_card();
        UIView *line = fr_mon_line(m, @"");
        NSString *why = rj(m, @"blocked");
        UIStackView *v = rs_vstack(why ? @[line, rs_label(why, 12, false, rs_rgb(0xC2414B))] : @[line], 4);
        [c addSubview:v];
        rs_pin(v, c, UIEdgeInsetsMake(10, 12, 10, 12));
        if (why) c.alpha = 0.5;
        else {
            NSString *uid = [NSString stringWithFormat:@"%@", rj(m, @"uid")];
            rs_on_tap(c, ^{ rs_sfx_modern(FR_SFX_TRADE_BTN); fr_room_post(@"trade_pick", @{@"uid": uid}); });
        }
        [FR_stack addArrangedSubview:c];
    }
}

// ---- the menu
static void fr_render(void) {
    if (!FR_screen) return;
    // v195: a redraw while typing in the chat no longer waits for the keyboard to close -- the
    // new page is built first, the new chat box takes the focus, and only then the old one goes
    NSArray *old = FR_stack.arrangedSubviews;
    UITextField *old_chat = FR_chat_field.isFirstResponder ? FR_chat_field : nil;
    if (FR_note && [NSDate date].timeIntervalSince1970 - FR_note_t < 6)
        [FR_stack addArrangedSubview:fr_note_card()];
    if (!FR_state) {
        UILabel *l = rs_label(@"Loading friends…", 16, true, rs_ink2());
        l.textAlignment = NSTextAlignmentCenter;
        [FR_stack addArrangedSubview:l];
    } else if (FR_page == 1) { [FR_stack addArrangedSubview:fr_header_row(@"Add a friend")]; fr_render_add(); }
    else if (FR_page == 2) { [FR_stack addArrangedSubview:fr_header_row(@"Requests")]; fr_render_requests(); }
    else if (FR_page == 3) { [FR_stack addArrangedSubview:fr_header_row(rj(fr_friend_now(), @"name") ?: @"Friend")]; fr_render_friend(); }
    else if (FR_page == 4) fr_render_room();
    else if (FR_page == 5) fr_render_pick();
    else fr_render_list();
    UIView *pad = [UIView new];
    rs_size(pad, 0, 90);                    // room above the close button
    [FR_stack addArrangedSubview:pad];
    if (old_chat && FR_page == 4 && FR_chat_field && FR_chat_field != old_chat) {
        FR_chat_field.text = old_chat.text;
        [FR_chat_field becomeFirstResponder];
    }
    for (UIView *v in old) { [FR_stack removeArrangedSubview:v]; [v removeFromSuperview]; }
    if (FR_chat_field.isFirstResponder) fr_chat_reveal(false);
    fr_music_sync();
}

/** v194: the trade room (and its Pokemon picker) has the modern game's trade music; the swap
 *  plays 125_trade once. Anywhere else the game's own music (or night/pack track) is back. */
static void fr_music_sync(void) {
    bool here = FR_screen && !FR_screen.hidden && (FR_page == 4 || FR_page == 5) && FR_trade;
    if (!here) { FR_music_done = nil; ws_extra_music(nil, true); return; }
    if ([FR_music_done isEqual:FR_trade]) ws_extra_music(FR_MUSIC_TRADE, false);
    else ws_extra_music(FR_MUSIC_ROOM, true);
}

static void fr_build(UIView *parent) {
    FR_screen = [[UIView alloc] initWithFrame:parent.bounds];
    FR_screen.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // the newer game's friend list: a white page in a green frame
    CAGradientLayer *frame = [CAGradientLayer layer];
    frame.colors = @[(id)rs_rgb(0xC6E7A5).CGColor, (id)rs_rgb(0x9FDAA6).CGColor, (id)rs_rgb(0x7FCBA4).CGColor];
    frame.startPoint = CGPointMake(0, 0); frame.endPoint = CGPointMake(1, 1);
    frame.frame = CGRectMake(0, 0, 3000, 3000);
    [FR_screen.layer addSublayer:frame];
    UIView *page = [UIView new];
    page.backgroundColor = UIColor.whiteColor;
    [FR_screen addSubview:page];
    rs_pin(page, FR_screen, UIEdgeInsetsMake(0, FR_EDGE, 0, FR_EDGE));

    FR_scroll = [UIScrollView new];
    FR_scroll.backgroundColor = UIColor.whiteColor;     // v192: opaque, so a sliding page hides the one under it
    FR_screen.clipsToBounds = YES;
    FR_scroll.alwaysBounceVertical = YES;
    FR_scroll.showsVerticalScrollIndicator = NO;
    FR_scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
    [FR_screen addSubview:FR_scroll];
    FR_scroll.translatesAutoresizingMaskIntoConstraints = NO;
    FR_stack = rs_vstack(@[], 12);
    [FR_scroll addSubview:FR_stack];
    FR_stack.translatesAutoresizingMaskIntoConstraints = NO;

    UIImageView *close = rs_image(@"/research/art/btn_close_normal.png", 60, 60);
    close.layer.shadowColor = UIColor.blackColor.CGColor;
    close.layer.shadowOpacity = 0.18; close.layer.shadowRadius = 5; close.layer.shadowOffset = CGSizeMake(0, 2);
    [FR_screen addSubview:close];
    rs_on_tap(close, ^{ fr_back(); });
    // drag right: a sub page goes back to the list, the list back to ME (the profile shows through)
    UIView *gap = [UIView new];
    gap.frame = FR_screen.bounds;
    gap.userInteractionEnabled = NO;
    [FR_screen addSubview:gap];
    rs_on_drag(FR_screen, FR_scroll,
        ^NSArray<UIView *> *(int dir) {
            if (FR_snap) { [FR_snap removeFromSuperview]; FR_snap = nil; }
            [FR_scroll.layer removeAllAnimations];
            FR_scroll.transform = CGAffineTransformIdentity;
            if (dir > 0) return @[(UIView *)FR_stack];                     // nothing that way
            return FR_page ? @[(UIView *)FR_stack, gap] : @[FR_screen, gap];
        },
        nil,
        ^(int dir) {
            if (FR_page) {                          // the drag already slid this page away
                FR_stack.transform = CGAffineTransformIdentity;
                int to = FR_page == 5 ? 4 : FR_page == 4 ? (FR_friend ? 3 : 2) : 0;
                fr_go_anim(to, false);
                return;
            }
            [FR_code_field resignFirstResponder];
            FR_screen.hidden = YES;
            rs_sfx(RS_SFX_CLOSE);
        });

    UILayoutGuide *safe = ws_safe_guide(FR_screen);
    [NSLayoutConstraint activateConstraints:@[
        [FR_scroll.topAnchor constraintEqualToAnchor:safe.topAnchor],
        [FR_scroll.bottomAnchor constraintEqualToAnchor:FR_screen.bottomAnchor],
        [FR_scroll.leadingAnchor constraintEqualToAnchor:FR_screen.leadingAnchor constant:FR_EDGE],
        [FR_scroll.trailingAnchor constraintEqualToAnchor:FR_screen.trailingAnchor constant:-FR_EDGE],
        [FR_stack.topAnchor constraintEqualToAnchor:FR_scroll.topAnchor constant:16],
        [FR_stack.bottomAnchor constraintEqualToAnchor:FR_scroll.bottomAnchor constant:-16],
        [FR_stack.centerXAnchor constraintEqualToAnchor:FR_scroll.centerXAnchor],
        [FR_stack.widthAnchor constraintEqualToAnchor:FR_scroll.widthAnchor constant:-32 + 2 * FR_EDGE],
        [close.centerXAnchor constraintEqualToAnchor:FR_screen.centerXAnchor],
        [close.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-12]]];
    FR_screen.hidden = YES;
    [parent addSubview:FR_screen];
}

static void fr_open(void) {
    UIView *parent = mt_unity_view();
    if (!parent) return;
    if (!FR_screen || FR_screen.superview != parent) {
        [FR_screen removeFromSuperview];
        FR_screen = nil;
        fr_build(parent);
    }
    if (!FR_screen.hidden) return;
    FR_page = 0;
    FR_screen.hidden = NO;
    [parent bringSubviewToFront:FR_screen];
    // the menu comes in from the right, the way the newer game turns to the FRIENDS tab
    FR_screen.transform = CGAffineTransformMakeTranslation(parent.bounds.size.width, 0);
    [UIView animateWithDuration:0.26 delay:0 options:UIViewAnimationOptionCurveEaseOut
                     animations:^{ FR_screen.transform = CGAffineTransformIdentity; } completion:nil];
    rs_sfx(RS_SFX_OPEN);
    fr_render();
    fr_fetch();
    WLOG(@"friends: opened");
}

static void fr_close(void) {
    if (!FR_screen || FR_screen.hidden) return;
    [FR_code_field resignFirstResponder];
    UIView *screen = FR_screen;
    rs_sfx(RS_SFX_CLOSE);
    FR_music_done = nil;
    ws_extra_music(nil, true);
    [UIView animateWithDuration:0.22 delay:0 options:UIViewAnimationOptionCurveEaseIn
                     animations:^{ screen.transform = CGAffineTransformMakeTranslation(screen.bounds.size.width, 0); }
                     completion:^(BOOL f) { screen.hidden = YES; screen.transform = CGAffineTransformIdentity; }];
}

// ---- called from rs_tick
static void fr_tick(UIView *parent) {
    // v187: no bar over the profile any more -- Friends opens from the profile's menu
    // (WSFriendsBtn, hk_button_click). Only keep an open menu live and on top.
    if (!FR_screen || FR_screen.hidden) return;
    static NSTimeInterval last = 0;
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    [parent bringSubviewToFront:FR_screen];
    if (now - last > 8) { last = now; fr_fetch(); }       // requests arrive live
    static NSTimeInterval last_room = 0;                  // v190: the trade room, every 2 s
    if (FR_page == 4 && FR_trade && now - last_room > 2) { last_room = now; fr_room_fetch(); }
}
