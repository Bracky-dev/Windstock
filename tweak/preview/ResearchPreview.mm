// ResearchPreview -- the tweak's Research screens, running in the iOS Simulator.
//
// It compiles the REAL screen code (../Research.inc.mm, the same file that goes into the
// tweak) with the game's own machinery stubbed out below, so you can edit the screens in
// Xcode and press Run instead of building a tweak and copying it to a phone.
//
//   1. start the data server:  python3 preview_server.py
//   2. press Run in Xcode (any iPhone simulator)
//
// The map is a green rectangle with the two buttons on it; tap them for the Research and
// All Events screens. Everything else -- the game hooks, the map detection -- is stubbed:
// what you are looking at is the layout, the colours and the wording.
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <objc/message.h>

// ---- stubs for what the tweak normally borrows from the game ------------------
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
enum { QC_FINDOBJ, QC_COMP_GO, QC_COUNT };
enum { MT_COUNT };
static void *g_qc[QC_COUNT];
static void *g_mt[MT_COUNT];
static bool g_map_active = true;
static bool g_game_live = true;
static bool g_mt_ready = true;
static UIWindow *G_window = nil;
static UIView *mt_unity_view(void) { return G_window.rootViewController.view; }

// the server the harness talks to (a plain-HTTP shim in front of research.py)
#define RS_HOST_OVERRIDE @"http://127.0.0.1:8799"

#include "../Research.inc.mm"

// ---- the app -----------------------------------------------------------------
@interface WSRoot : UIViewController @end
@implementation WSRoot
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor colorWithRed:0.31 green:0.62 blue:0.45 alpha:1];
    UILabel *l = [UILabel new];
    l.text = @"pretend map";
    l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
    l.font = [UIFont systemFontOfSize:22 weight:UIFontWeightBold];
    l.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:l];
    [NSLayoutConstraint activateConstraints:@[
        [l.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [l.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor]]];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        rs_load_fonts();
        rs_tick();                      // builds the binoculars button
        RS_button.hidden = NO; RS_button.alpha = 1;
        RS_cal_button.hidden = NO; RS_cal_button.alpha = 1;
        RS_shown = true;
    });
}
@end

// iOS 27 insists on scene lifecycle, so the harness adopts it.
@interface WSScene : UIResponder <UIWindowSceneDelegate>
@property (nonatomic, strong) UIWindow *window;
@end
@implementation WSScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session
      options:(UISceneConnectionOptions *)options {
    UIWindowScene *ws = (UIWindowScene *)scene;
    self.window = [[UIWindow alloc] initWithWindowScene:ws];
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
    UISceneConfiguration *c = [UISceneConfiguration configurationWithName:@"ws"
                                                             sessionRole:session.role];
    c.delegateClass = [WSScene class];
    return c;
}
@end

int main(int argc, char *argv[]) {
    @autoreleasepool {
        return UIApplicationMain(argc, argv, nil, NSStringFromClass([WSDelegate class]));
    }
}

// Test hooks the harness drives from outside (simctl can't call in, so a timer does it).
__attribute__((constructor)) static void schedule_shots(void) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ rs_open(); });
}
