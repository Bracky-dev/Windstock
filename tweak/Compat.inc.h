// Compat.inc.h -- the few UIKit/Foundation calls newer than iOS 9, with a fallback.
//
// The launcher build targets iOS 15, where every one of these simply calls the real
// API. The game-only IPA (ios-launcher/tools/make_game_ipa.sh) builds this same source
// for iOS 9, where the newer API is missing at runtime and the fallback runs instead.
// Build with -Wunguarded-availability to find any new call that needs a wrapper here.
#pragma once
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

// ---- block timers (iOS 10): a trampoline target keeps the block
@interface WSTweakBlockTarget : NSObject
@property (nonatomic, copy) void (^timerBlock)(NSTimer *);
@property (nonatomic, copy) void (^actionBlock)(id);
- (void)fireTimer:(NSTimer *)t;
- (void)fireAction:(id)sender;
@end
@implementation WSTweakBlockTarget
- (void)fireTimer:(NSTimer *)t { if (self.timerBlock) self.timerBlock(t); }
- (void)fireAction:(id)sender { if (self.actionBlock) self.actionBlock(sender); }
@end

static NSTimer *ws_timer(NSTimeInterval interval, BOOL repeats, void (^block)(NSTimer *)) {
    if (@available(iOS 10.0, *))
        return [NSTimer scheduledTimerWithTimeInterval:interval repeats:repeats block:block];
    WSTweakBlockTarget *t = [WSTweakBlockTarget new];
    t.timerBlock = block;
    return [NSTimer scheduledTimerWithTimeInterval:interval target:t selector:@selector(fireTimer:)
                                          userInfo:nil repeats:repeats];
}

// ---- control actions (UIAction is iOS 13/14): target-action, the target kept alive
// by the control itself
static char kWSTweakActions;
static void ws_on_event(UIControl *c, UIControlEvents events, void (^block)(void)) {
    if (!c || !block) return;
    WSTweakBlockTarget *t = [WSTweakBlockTarget new];
    t.actionBlock = ^(id sender) { block(); };
    NSMutableArray *keep = objc_getAssociatedObject(c, &kWSTweakActions);
    if (!keep) {
        keep = [NSMutableArray array];
        objc_setAssociatedObject(c, &kWSTweakActions, keep, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    [keep addObject:t];
    [c addTarget:t action:@selector(fireAction:) forControlEvents:events];
}

// ---- drawing into an image (UIGraphicsImageRenderer is iOS 10)
static UIImage *ws_draw_image(CGSize size, void (^draw)(CGContextRef ctx)) {
    if (@available(iOS 10.0, *)) {
        UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:size];
        return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) { draw(ctx.CGContext); }];
    }
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    draw(UIGraphicsGetCurrentContext());
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

// ---- safe area (iOS 11). Before it there is no notch; the status bar is the only inset,
// and the game hides it.
static UIEdgeInsets ws_safe_insets(UIView *v) {
    if (@available(iOS 11.0, *)) return v.safeAreaInsets;
    return UIEdgeInsetsZero;
}

static UILayoutGuide *ws_safe_guide(UIView *v) {
    if (@available(iOS 11.0, *)) return v.safeAreaLayoutGuide;
    // iOS 9/10: a guide pinned to the view's own edges
    static char kGuide;
    UILayoutGuide *g = objc_getAssociatedObject(v, &kGuide);
    if (!g) {
        g = [UILayoutGuide new];
        [v addLayoutGuide:g];
        [NSLayoutConstraint activateConstraints:@[
            [g.topAnchor constraintEqualToAnchor:v.topAnchor],
            [g.bottomAnchor constraintEqualToAnchor:v.bottomAnchor],
            [g.leadingAnchor constraintEqualToAnchor:v.leadingAnchor],
            [g.trailingAnchor constraintEqualToAnchor:v.trailingAnchor],
        ]];
        objc_setAssociatedObject(v, &kGuide, g, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return g;
}

// ---- audio fades (iOS 10): without one the volume just steps
static void ws_fade(AVAudioPlayer *p, float volume, NSTimeInterval seconds) {
    if (@available(iOS 10.0, *)) [p setVolume:volume fadeDuration:seconds];
    else p.volume = volume;
}

// ---- haptics (iOS 10): nothing to feel on older phones
static void ws_haptic_select(void) {
    if (@available(iOS 10.0, *)) [[UISelectionFeedbackGenerator new] selectionChanged];
}
static void ws_haptic_error(void) {
    if (@available(iOS 10.0, *))
        [[UINotificationFeedbackGenerator new] notificationOccurred:UINotificationFeedbackTypeError];
}
static void ws_haptic_impact(void) {
    if (@available(iOS 10.0, *))
        [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
}

// ---- small layout/typography bits
static void ws_round_corners(CALayer *l, NSUInteger corners) {
    if (@available(iOS 11.0, *)) l.maskedCorners = (CACornerMask)corners;
}
static void ws_spacing_after(UIStackView *s, CGFloat gap, UIView *after) {
    if (@available(iOS 11.0, *)) [s setCustomSpacing:gap afterView:after];
}
static UIFont *ws_rounded(UIFont *f, CGFloat size) {
    if (@available(iOS 13.0, *)) {
        UIFontDescriptor *d = [f.fontDescriptor fontDescriptorWithDesign:UIFontDescriptorSystemDesignRounded];
        if (d) return [UIFont fontWithDescriptor:d size:size];
    }
    return f;
}
static UIFont *ws_mono(CGFloat size, UIFontWeight weight) {
    if (@available(iOS 13.0, *)) return [UIFont monospacedSystemFontOfSize:size weight:weight];
    return [UIFont monospacedDigitSystemFontOfSize:size weight:weight];
}
static NSJSONWritingOptions ws_json_sorted(void) {
    if (@available(iOS 11.0, *)) return NSJSONWritingSortedKeys;
    return 0;
}
