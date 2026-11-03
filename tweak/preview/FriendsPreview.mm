// FriendsPreview -- the profile's ME | FRIENDS switcher and the Friends menu (Friends.inc.mm) in
// the iOS Simulator. Compiles the real Research.inc.mm + Friends.inc.mm with the game stubbed:
//   python3 friends_preview_server.py &      (fake /friends/state + the real art)
//   ./build_friends_preview.sh               (builds, installs and launches on a booted simulator)
// FR_PREVIEW_PAGE picks the page to open (-1 = just the switcher over a pretend profile).
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#include <stdint.h>
#include <string.h>
#include "../Compat.inc.h"

static void wlog(NSString *fmt, ...) {
    va_list ap; va_start(ap, fmt);
    NSLogv([@"[windstock] " stringByAppendingString:fmt], ap);
    va_end(ap);
}
#define WLOG(...) wlog(__VA_ARGS__)
static id rj(id obj, NSString *key) {
    if (![obj isKindOfClass:[NSDictionary class]]) return nil;
    id v = obj[key];
    return (v == [NSNull null]) ? nil : v;
}
static bool looks_like_ptr(void *p) { return p != NULL; }
static void *mt_type(const char *name) { (void)name; return NULL; }
typedef void *(*qc_static1)(void *, void *, void *);
typedef void *(*qc_inst0)(void *, void *);
typedef void *(*qc_inst1)(void *, void *, void *);
enum { QC_STR, QC_GETTYPE, QC_FINDOBJ, QC_COMP_TR, QC_FIND, QC_COMP_GO, QC_INSTANTIATE,
       QC_GO_TR, QC_SETPARENT, QC_LASTSIB, QC_SETACTIVE, QC_COUNT };
enum { MT_FIND_ALL, MT_GETCOMPONENT, MT_ACTIVE, MT_COUNT };
#define OFF_ARRAY_DATA 0x20
#define PREF_SFX_ENABLED @"sfx"
static void *g_qc[QC_COUNT];
static void *g_mt[MT_COUNT];
static void *(*g_get_name)(void *obj, void *method) = NULL;
static bool il2cpp_string_equals(void *s, const char *a) { return false; }
static bool game_pref_enabled(NSString *k) { return false; }
static NSURL *pack_clip_url(const char *n) { return nil; }
static bool redirect_method_pointer(uintptr_t a, size_t b, uintptr_t c, uintptr_t d, const char *e) { return false; }
static uintptr_t g_shiny_base = 0;
static bool g_spk_anchor_ok = false;
static bool spk_tr_screen(void *tr, CGSize view, CGPoint *out) { return false; }
static NSURL *ws_web_rebase(NSURL *u) { return u; }
static bool g_map_active = true, g_game_live = true, g_mt_ready = true;
static UIWindow *G_window = nil;
static UIView *mt_unity_view(void) { return G_window.rootViewController.view; }

#define RS_HOST_OVERRIDE @"http://127.0.0.1:8799"
#define FR_PREVIEW_PROFILE true
#ifndef FR_PREVIEW_PAGE
#define FR_PREVIEW_PAGE 0
#endif
#include "../Research.inc.mm"

@interface WSRoot : UIViewController @end
@implementation WSRoot
- (void)viewDidLoad {
    [super viewDidLoad];
    // a pretend 0.35 profile: its gradient, a name at the top and a trainer in the middle
    CAGradientLayer *g = [CAGradientLayer layer];
    g.colors = @[(id)[UIColor colorWithRed:0.55 green:0.85 blue:0.80 alpha:1].CGColor,
                 (id)[UIColor colorWithRed:0.93 green:0.97 blue:0.95 alpha:1].CGColor];
    g.frame = CGRectMake(0, 0, 3000, 3000);
    [self.view.layer addSublayer:g];
    UILabel *l = [UILabel new];
    l.text = @"pretend profile";
    l.textColor = [UIColor colorWithWhite:0 alpha:0.35];
    l.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        rs_load_fonts();
        [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *t) { fr_tick(self.view); }];
    });
    if (FR_PREVIEW_PAGE >= 0)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            fr_open();
            if (FR_PREVIEW_PAGE >= 3) FR_friend = @"bob";
            if (FR_PREVIEW_PAGE >= 4) FR_trade = @"t1";
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(),
                           ^{ fr_go(FR_PREVIEW_PAGE); });
        });
}
@end

@interface WSScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation WSScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [WSRoot new];
    [self.window makeKeyAndVisible];
    G_window = self.window;
}
@end
@interface WSDelegate : UIResponder <UIApplicationDelegate> @end
@implementation WSDelegate
- (UISceneConfiguration *)application:(UIApplication *)app
    configurationForConnectingSceneSession:(UISceneSession *)session
                                   options:(UISceneConnectionOptions *)options {
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"ws" sessionRole:session.role];
    c.delegateClass = [WSScene class];
    return c;
}
@end
int main(int argc, char *argv[]) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass([WSDelegate class])); }
}
