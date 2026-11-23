// Standalone HUD bootstrap/window-hosting approach adapted from TrollSpeed
// (c) 2023 Lessica, MIT. See ThirdParty/TrollSpeed-LICENSE.txt and NOTICE.txt.
// This process owns its window and only edits Hero Control's settings file.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "OverlayCommon.h"
#import "HCFeatures.h"
#include <dlfcn.h>
#include <notify.h>
#include <sys/file.h>
#include <sys/resource.h>
#include <fcntl.h>
#include <math.h>
#include <signal.h>
#include <mach/mach.h>
#include <string.h>
#include <stdlib.h>

@interface UIApplication (HCPrivate)
- (void)_accessibilityInit;
- (void)__completeAndRunAsPlugin;
@end
@interface UIWindow (HCPrivate)
- (unsigned int)_contextId;
@end
// Scope private selectors to their actual receiver contracts. Declaring them
// on NSObject makes calls through `id` ambiguous with unrelated SDK APIs such
// as NSTextAttachment.location and CIRAWFilter.orientation under ARC.
@protocol HCAXEventPath <NSObject>
- (NSInteger)pathIdentity;
@end
@protocol HCAXEventHand <NSObject>
- (NSArray<id<HCAXEventPath>> *)paths;
@end
@protocol HCAXEventRepresentation <NSObject>
+ (instancetype)representationWithHIDEvent:(CFTypeRef)event hidStreamIdentifier:(NSString *)identifier;
- (CGPoint)location;
- (BOOL)isTouchDown;
- (BOOL)isMove;
- (BOOL)isCancel;
- (BOOL)isLift;
- (BOOL)isInRangeLift;
- (id<HCAXEventHand>)handInfo;
@end
@protocol HCOrientationUpdate <NSObject>
- (long long)orientation;
@end
@protocol HCOrientationObserving <NSObject>
- (void)setHandler:(void (^)(id<HCOrientationUpdate> update))handler;
- (long long)activeInterfaceOrientation;
@end
@protocol HCWindowHosting <NSObject>
- (void)registerWindowWithContextID:(unsigned int)context atLevel:(double)level;
@end

static NSString *HCDirectory, *HCProfile, *HCExecutable;
static NSString *HCSession;
static int HCLock = -1;
static BOOL HCStopping;
static NSString *HCPhase = @"starting", *HCMessage = @"Đang tạo cửa sổ nút nổi.";
static NSUInteger HCTouchCount;
static NSInteger HCOrientation = UIInterfaceOrientationPortrait;
static BOOL HCLocked;
static BOOL HCMenuOpen;
static NSString *HCSettingsError;

static void HCState(void) {
    NSDictionary *state = @{@"schemaVersion": @1, @"phase": HCPhase, @"message": HCMessage,
        @"pid": @(getpid()), @"euid": @(geteuid()), @"heartbeat": @(NSProcessInfo.processInfo.systemUptime),
        @"session": HCSession, @"menuOpen": @(HCMenuOpen), @"orientation": @(HCOrientation),
        @"touchEvents": @(HCTouchCount), @"hiddenForLock": @(HCLocked),
        @"settingsOnly": @YES, @"settingsError": HCSettingsError ?: @"", @"appVersion": @"0.4.1"};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:NULL];
    NSString *path = [HCDirectory stringByAppendingPathComponent:@"state.json"];
    [data writeToFile:path options:NSDataWritingAtomic error:NULL];
    chmod(path.fileSystemRepresentation, 0644);
    chown(path.fileSystemRepresentation, 501, 501);
}
static void HCStop(NSString *message, BOOL failed) {
    HCStopping = YES;
    HCPhase = failed ? @"failed" : @"stopped"; HCMessage = message;
    HCState();
    exit(failed ? 70 : 0);
}

@interface HCOverlayCanvas : UIView
@property(nonatomic) CGPoint bubble;
@property(nonatomic) NSInteger group;
@property(nonatomic, strong) NSMutableDictionary *settings;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *targets;
@property(nonatomic, copy) NSString *activeTarget;
@property(nonatomic) NSInteger pointer;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGPoint startBubble;
@property(nonatomic) BOOL dragged;
- (void)reloadSettings;
- (void)toggleMenu;
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer;
@end

static UIColor *HCAccent(void) { return [UIColor colorWithRed:0.39 green:0.88 blue:0.78 alpha:1]; }
static void HCText(NSString *text, CGRect rect, CGFloat size, UIColor *color, BOOL bold) {
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size],
        NSForegroundColorAttributeName: color}];
}
static CGFloat HCClamp(CGFloat value, CGFloat lower, CGFloat upper) { return MAX(lower, MIN(value, MAX(lower, upper))); }

@implementation HCOverlayCanvas
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO; self.multipleTouchEnabled = NO;
        _bubble = CGPointMake(38, 115); _pointer = -1;
        _targets = [NSMutableArray array];
        [self reloadSettings];
    }
    return self;
}
- (void)reloadSettings {
    NSData *data = [NSData dataWithContentsOfFile:HCProfile];
    id root = data.length <= 131072 ? [NSJSONSerialization JSONObjectWithData:data ?: NSData.data options:NSJSONReadingMutableContainers error:NULL] : nil;
    id settings = [root isKindOfClass:NSDictionary.class] && [root[@"schemaVersion"] isEqual:@1] ? root[@"settings"] : nil;
    if ([settings isKindOfClass:NSDictionary.class] && [settings[@"flags"] isKindOfClass:NSDictionary.class] &&
        [settings[@"cameraScale"] isKindOfClass:NSNumber.class] && [settings[@"selectedSkins"] isKindOfClass:NSDictionary.class]) {
        BOOL valid = isfinite([settings[@"cameraScale"] doubleValue]) && [settings[@"cameraScale"] doubleValue] >= 1 &&
            [settings[@"cameraScale"] doubleValue] <= 2.3;
        for (NSDictionary *feature in HCFeatures()) {
            id flag = settings[@"flags"][feature[@"key"]];
            if (!flag || CFGetTypeID((__bridge CFTypeRef)flag) != CFBooleanGetTypeID()) valid = NO;
        }
        if (!valid) {
            HCSettingsError = @"Cấu hình sai kiểu dữ liệu. Mở Hero Control để kiểm tra.";
            self.settings = nil; [self setNeedsDisplay]; return;
        }
        self.settings = [settings mutableCopy];
        self.settings[@"flags"] = [settings[@"flags"] mutableCopy];
        HCSettingsError = nil;
    } else {
        HCSettingsError = @"Không đọc được cấu hình. Mở lại Hero Control để kiểm tra.";
        // Do not replace a corrupt profile with invented defaults.
        self.settings = nil;
    }
    [self setNeedsDisplay];
}
- (void)saveSettings {
    if (!self.settings || !HCOverlayPathsValid(HCDirectory, HCProfile)) {
        HCSettingsError = @"Không lưu được: đường dẫn/cấu hình không hợp lệ."; return;
    }
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"settings": self.settings}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:HCProfile options:NSDataWritingAtomic error:&error]) {
        HCSettingsError = error.localizedDescription ?: @"Không ghi được cấu hình.";
    } else {
        chmod(HCProfile.fileSystemRepresentation, 0644);
        chown(HCProfile.fileSystemRepresentation, 501, 501);
        HCSettingsError = nil;
    }
    HCState(); [self setNeedsDisplay];
}
- (CGRect)bubbleRect { return CGRectMake(self.bubble.x - 26, self.bubble.y - 26, 52, 52); }
- (CGRect)panelRect {
    CGFloat width = MIN(320, self.bounds.size.width - 72), height = MIN(364, self.bounds.size.height - 32);
    return CGRectMake(HCClamp(self.bubble.x + 32, 36, self.bounds.size.width - width - 36),
        HCClamp(self.bubble.y + 30, 16, self.bounds.size.height - height - 16), width, height);
}
- (void)layoutSubviews {
    [super layoutSubviews];
    self.bubble = CGPointMake(HCClamp(self.bubble.x, 30, self.bounds.size.width - 30),
        HCClamp(self.bubble.y, 60, self.bounds.size.height - 38));
    [self setNeedsDisplay];
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return !HCLocked && (CGRectContainsPoint([self bubbleRect], point) || (HCMenuOpen && CGRectContainsPoint([self panelRect], point)));
}
- (void)target:(NSString *)key rect:(CGRect)rect { [self.targets addObject:@{@"key": key, @"rect": [NSValue valueWithCGRect:rect]}]; }
- (NSString *)targetAt:(CGPoint)point {
    if (CGRectContainsPoint([self bubbleRect], point)) return @"bubble";
    if (!HCMenuOpen) return nil;
    for (NSDictionary *target in self.targets.reverseObjectEnumerator)
        if (CGRectContainsPoint([target[@"rect"] CGRectValue], point)) return target[@"key"];
    return nil;
}
- (void)drawRect:(CGRect)rect {
    [self.targets removeAllObjects];
    if (HCMenuOpen) {
        CGRect p = [self panelRect];
        [[UIColor colorWithRed:0.045 green:0.06 blue:0.09 alpha:0.97] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:p cornerRadius:18] fill];
        HCText(@"HERO CONTROL", CGRectMake(p.origin.x + 14, p.origin.y + 14, p.size.width - 70, 24), 17, HCAccent(), YES);
        CGRect close = CGRectMake(CGRectGetMaxX(p) - 44, p.origin.y + 6, 38, 36);
        HCText(@"×", CGRectInset(close, 8, 0), 28, UIColor.whiteColor, NO); [self target:@"close" rect:close];
        HCText(HCSettingsError ?: @"Chỉ lưu cấu hình • Chưa có xử lý game", CGRectMake(p.origin.x + 14, p.origin.y + 43, p.size.width - 28, 34), 11,
            HCSettingsError ? UIColor.systemOrangeColor : UIColor.lightGrayColor, NO);
        NSArray *tabs = @[@"ESP", @"Camera", @"Style", @"Skins", @"Reports"];
        CGFloat tabWidth = (p.size.width - 20) / 5;
        for (NSInteger i = 0; i < 5; i++) {
            CGRect r = CGRectMake(p.origin.x + 10 + i * tabWidth, p.origin.y + 80, tabWidth, 32);
            if (i == self.group) { [HCAccent() setFill]; [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6] fill]; }
            HCText(tabs[i], CGRectInset(r, 4, 8), 11, i == self.group ? UIColor.blackColor : UIColor.whiteColor, YES);
            [self target:[NSString stringWithFormat:@"tab:%ld", (long)i] rect:r];
        }
        CGFloat y = p.origin.y + 122;
        if (self.group == 1) {
            double scale = [self.settings[@"cameraScale"] doubleValue];
            HCText([NSString stringWithFormat:@"Camera: %.2f×", scale], CGRectMake(p.origin.x + 14, y, p.size.width - 28, 24), 16, UIColor.whiteColor, YES);
            CGRect slider = CGRectMake(p.origin.x + 20, y + 38, p.size.width - 40, 36);
            [[UIColor colorWithWhite:0.22 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(slider.origin.x, slider.origin.y + 15, slider.size.width, 6) cornerRadius:3] fill];
            CGFloat x = slider.origin.x + HCClamp((scale - 1) / 1.3, 0, 1) * slider.size.width;
            [HCAccent() setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x - 9, slider.origin.y + 9, 18, 18)] fill];
            [self target:@"camera" rect:slider];
            HCText(@"Kéo để chọn 1.00–2.30×; chưa áp dụng vào game.", CGRectMake(p.origin.x + 14, y + 85, p.size.width - 28, 45), 12, UIColor.lightGrayColor, NO);
        } else {
            NSArray *features = [HCFeatures() filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"group == %ld", (long)self.group]];
            CGFloat rowHeight = MIN(28, (p.size.height - 160) / MAX((NSUInteger)1, features.count));
            for (NSDictionary *feature in features) {
                CGRect row = CGRectMake(p.origin.x + 12, y, p.size.width - 24, rowHeight);
                BOOL enabled = [self.settings[@"flags"][feature[@"key"]] boolValue];
                HCText(feature[@"title"], CGRectMake(row.origin.x + 2, y + 5, row.size.width - 52, rowHeight), 13, UIColor.whiteColor, NO);
                CGRect pill = CGRectMake(CGRectGetMaxX(row) - 40, y + 5, 36, 18);
                [(enabled ? HCAccent() : [UIColor colorWithWhite:0.3 alpha:1]) setFill];
                [[UIBezierPath bezierPathWithRoundedRect:pill cornerRadius:9] fill];
                [UIColor.whiteColor setFill];
                [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(pill.origin.x + (enabled ? 20 : 2), pill.origin.y + 2, 14, 14)] fill];
                [self target:[@"flag:" stringByAppendingString:feature[@"key"]] rect:row];
                y += rowHeight;
            }
            if (self.group == 3)
                HCText(@"Danh sách tướng/skin cần backend game.", CGRectMake(p.origin.x + 14, y + 8, p.size.width - 28, 40), 12, UIColor.lightGrayColor, NO);
        }
        CGRect stop = CGRectMake(p.origin.x + 10, CGRectGetMaxY(p) - 34, p.size.width - 20, 28);
        HCText(@"TẮT NÚT NỔI", CGRectInset(stop, 6, 6), 12, UIColor.systemOrangeColor, YES); [self target:@"stop" rect:stop];
    }
    CGRect bubble = [self bubbleRect];
    [HCAccent() setFill]; [[UIBezierPath bezierPathWithOvalInRect:bubble] fill];
    HCText(HCMenuOpen ? @"×" : @"HC", CGRectMake(bubble.origin.x + (HCMenuOpen ? 17 : 11), bubble.origin.y + 12, 38, 30),
        HCMenuOpen ? 24 : 20, UIColor.blackColor, YES);
}
- (void)toggleMenu {
    HCMenuOpen = !HCMenuOpen;
    self.activeTarget = nil; self.pointer = -1;
    if (HCMenuOpen) [self reloadSettings];
    [self setNeedsDisplay]; HCState();
}
- (void)cameraAt:(CGPoint)point {
    if (!self.settings) return;
    CGRect p = [self panelRect];
    self.settings[@"cameraScale"] = @(1 + HCClamp((point.x - p.origin.x - 20) / (p.size.width - 40), 0, 1) * 1.3);
    [self setNeedsDisplay];
}
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer {
    if (HCLocked) return;
    if (phase == UITouchPhaseBegan) {
        if (self.pointer >= 0) return;
        NSString *target = [self targetAt:point];
        if (!target) return;
        self.pointer = pointer; self.activeTarget = target;
        self.startPoint = point; self.startBubble = self.bubble; self.dragged = NO;
        if ([target isEqual:@"camera"]) { [self reloadSettings]; [self cameraAt:point]; }
    } else if (pointer != self.pointer) return;
    HCTouchCount++;
    if (phase == UITouchPhaseMoved) {
        if ([self.activeTarget isEqual:@"bubble"]) {
            CGFloat dx = point.x - self.startPoint.x, dy = point.y - self.startPoint.y;
            if (hypot(dx, dy) > 7) self.dragged = YES;
            if (self.dragged) {
                self.bubble = CGPointMake(HCClamp(self.startBubble.x + dx, 30, self.bounds.size.width - 30),
                    HCClamp(self.startBubble.y + dy, 60, self.bounds.size.height - 38));
                [self setNeedsDisplay];
            }
        } else if ([self.activeTarget isEqual:@"camera"]) [self cameraAt:point];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        NSString *target = self.activeTarget;
        self.activeTarget = nil; self.pointer = -1;
        if (phase == UITouchPhaseCancelled) { [self reloadSettings]; return; }
        if ([target isEqual:@"camera"]) { [self cameraAt:point]; [self saveSettings]; return; }
        if (self.dragged || ![[self targetAt:point] isEqual:target]) return;
        if ([target isEqual:@"bubble"] || [target isEqual:@"close"]) [self toggleMenu];
        else if ([target isEqual:@"stop"]) HCStop(@"Đã tắt nút nổi. Mở Hero Control để bật lại.", NO);
        else if ([target hasPrefix:@"tab:"]) { self.group = [[target substringFromIndex:4] integerValue]; [self setNeedsDisplay]; }
        else if ([target hasPrefix:@"flag:"]) {
            [self reloadSettings];
            NSString *key = [target substringFromIndex:5];
            if (self.settings) { self.settings[@"flags"][key] = @(![self.settings[@"flags"][key] boolValue]); [self saveSettings]; }
        }
        HCState();
    }
}
@end

@interface HCOverlayWindow : UIWindow @end
@implementation HCOverlayWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
- (BOOL)_ignoresHitTest { return HCLocked; }
- (BOOL)_isSecure { return YES; }
- (BOOL)_shouldCreateContextAsSecure { return YES; }
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return hit == self ? nil : hit;
}
@end
@interface HCOverlayApplication : UIApplication @end
@implementation HCOverlayApplication @end
@interface HCOverlayController : UIViewController @end
@implementation HCOverlayController
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskPortrait; }
- (BOOL)prefersStatusBarHidden { return YES; }
@end

static HCOverlayCanvas *HCCanvas;
static HCOverlayWindow *HCWindow;
static id<HCWindowHosting> HCHost;
static id<HCOrientationObserving> HCOrientationObserver;

static void HCRotate(NSInteger orientation) {
    if (orientation < 1 || orientation > 4) return;
    HCCanvas.activeTarget = nil; HCCanvas.pointer = -1;
    HCOrientation = orientation;
    CGRect screen = HCWindow.bounds;
    CGSize portrait = CGSizeMake(MIN(screen.size.width, screen.size.height), MAX(screen.size.width, screen.size.height));
    BOOL landscape = UIInterfaceOrientationIsLandscape(orientation);
    HCCanvas.transform = CGAffineTransformIdentity;
    HCCanvas.bounds = CGRectMake(0, 0, landscape ? portrait.height : portrait.width, landscape ? portrait.width : portrait.height);
    HCCanvas.center = CGPointMake(CGRectGetMidX(screen), CGRectGetMidY(screen));
    CGFloat angle = orientation == UIInterfaceOrientationLandscapeLeft ? -M_PI_2 :
        orientation == UIInterfaceOrientationLandscapeRight ? M_PI_2 : orientation == UIInterfaceOrientationPortraitUpsideDown ? M_PI : 0;
    HCCanvas.transform = CGAffineTransformMakeRotation(angle);
    [HCCanvas setNeedsLayout]; HCState();
}

static void HCUpdateLock(void) {
    mach_port_t (*portFunction)(void) = dlsym(RTLD_DEFAULT, "SBSSpringBoardServerPort");
    void (*statusFunction)(mach_port_t, BOOL *, BOOL *) = dlsym(RTLD_DEFAULT, "SBGetScreenLockStatus");
    if (!portFunction || !statusFunction) return;
    mach_port_t port = portFunction();
    if (!port) return;
    BOOL locked = NO, passcode = NO;
    statusFunction(port, &locked, &passcode);
    HCLocked = locked; HCCanvas.hidden = locked;
    HCCanvas.activeTarget = nil; HCCanvas.pointer = -1;
    if (locked) HCMenuOpen = NO;
    [HCCanvas setNeedsDisplay]; HCState();
}

@interface HCOverlayDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSTimer *timer;
@end
@implementation HCOverlayDelegate
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    HCOverlayController *controller = [HCOverlayController new];
    HCCanvas = [[HCOverlayCanvas alloc] initWithFrame:UIScreen.mainScreen.bounds];
    controller.view = HCCanvas;
    HCWindow = [[HCOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window = HCWindow;
    HCWindow.backgroundColor = UIColor.clearColor;
    HCWindow.rootViewController = controller;
    HCWindow.windowLevel = 10000010.0;
    [HCWindow makeKeyAndVisible];
    HCHost = [NSClassFromString(@"SBSAccessibilityWindowHostingController") new];
    if (!HCHost || ![HCHost respondsToSelector:@selector(registerWindowWithContextID:atLevel:)] || ![HCWindow _contextId])
        HCStop(@"Không có API đăng ký cửa sổ overlay trên môi trường này.", YES);
    [HCHost registerWindowWithContextID:[HCWindow _contextId] atLevel:HCWindow.windowLevel];
    HCOrientationObserver = [NSClassFromString(@"FBSOrientationObserver") new];
    if (![HCOrientationObserver respondsToSelector:@selector(setHandler:)])
        HCStop(@"Không có API theo dõi hướng màn hình cho menu nổi.", YES);
    if ([HCOrientationObserver respondsToSelector:@selector(setHandler:)]) {
        [HCOrientationObserver setHandler:^(id<HCOrientationUpdate> update) {
            NSInteger orientation = [update orientation];
            dispatch_async(dispatch_get_main_queue(), ^{ HCRotate(orientation); });
        }];
        if ([HCOrientationObserver respondsToSelector:@selector(activeInterfaceOrientation)])
            HCRotate([HCOrientationObserver activeInterfaceOrientation]);
    }
    int stopToken, toggleToken, lockToken, springboardToken;
    notify_register_dispatch(HCOverlayNotification(HCDirectory, @"stop").UTF8String, &stopToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCStop(@"Đã tắt nút nổi.", NO); });
    notify_register_dispatch(HCOverlayNotification(HCDirectory, @"toggle").UTF8String, &toggleToken, dispatch_get_main_queue(), ^(int token) { (void)token; [HCCanvas toggleMenu]; });
    notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCUpdateLock(); });
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &springboardToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCStop(@"SpringBoard đã khởi động lại. Mở Hero Control để bật nút nổi.", NO); });
    HCPhase = @"visible"; HCMessage = @"Đã đăng ký nút nổi Hero Control. Chạm để mở/thu menu; kéo để di chuyển.";
    HCUpdateLock(); HCState();
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (access(HCExecutable.fileSystemRepresentation, X_OK) || !HCOverlayPathsValid(HCDirectory, HCProfile))
            HCStop(@"Gói ứng dụng/cấu hình không còn tồn tại; overlay tự dừng.", NO);
        // The profile is shared with the app. Do not replace an in-progress drag.
        if (!HCCanvas.activeTarget && HCMenuOpen) [HCCanvas reloadSettings];
        HCState();
    }];
    return YES;
}
@end

static void HCHIDCallback(void *target, void *refcon, CFTypeRef service, CFTypeRef event) {
    (void)target; (void)refcon; (void)service;
    // Monitor only: no global touch injection. Dispatch our own canvas actions
    // only for a finger that begins inside the bubble/panel; ignore other apps.
    @autoreleasepool {
        @try {
            Class<HCAXEventRepresentation> representation = (Class<HCAXEventRepresentation>)NSClassFromString(@"AXEventRepresentation");
            id<HCAXEventRepresentation> rep = [representation representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];
            if (!rep) return;
            UITouchPhase phase;
            if ([rep isTouchDown]) phase = UITouchPhaseBegan;
            else if ([rep isMove]) phase = UITouchPhaseMoved;
            else if ([rep isCancel]) phase = UITouchPhaseCancelled;
            else if ([rep isLift] || [rep isInRangeLift]) phase = UITouchPhaseEnded;
            else return;
            CGPoint point = [rep location];
            id<HCAXEventPath> path = [[[rep handInfo] paths] firstObject];
            NSInteger pointer = path ? [path pathIdentity] : -1;
            if (pointer < 1) return;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CGPoint local = [HCCanvas convertPoint:point fromView:HCWindow];
                    [HCCanvas receivePoint:local phase:phase pointer:pointer];
                } @catch (NSException *error) { HCSettingsError = error.reason; HCState(); }
            });
        } @catch (NSException *error) { fprintf(stderr, "HC_OVERLAY HID: %s\n", error.reason.UTF8String); }
    }
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc != 4 || strcmp(argv[1], "--run")) return 64;
        HCDirectory = [NSString stringWithUTF8String:argv[2]];
        HCProfile = [NSString stringWithUTF8String:argv[3]];
        HCExecutable = [NSString stringWithUTF8String:argv[0]];
        HCSession = NSUUID.UUID.UUIDString;
        if (geteuid() != 0 || !HCOverlayPathsValid(HCDirectory, HCProfile)) return 77;
        // One process per app container. No PID-file kill, even after a crash.
        NSString *lockPath = [HCDirectory stringByAppendingPathComponent:@"overlay.lock"];
        HCLock = open(lockPath.fileSystemRepresentation, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
        if (HCLock < 0 || flock(HCLock, LOCK_EX | LOCK_NB)) return 73;
        fchown(HCLock, 501, 501);
        struct rlimit logLimit = {262144, 262144}; setrlimit(RLIMIT_FSIZE, &logLimit);
        HCState();
        @try {
            for (NSString *framework in @[@"GraphicsServices", @"BackBoardServices", @"SpringBoardServices", @"FrontBoardServices", @"AccessibilityUtilities"])
                dlopen([[NSString stringWithFormat:@"/System/Library/PrivateFrameworks/%@.framework/%@", framework, framework] fileSystemRepresentation], RTLD_NOW | RTLD_GLOBAL);
            void (*gsInitialize)(void) = dlsym(RTLD_DEFAULT, "GSInitialize");
            void (*displayStart)(void) = dlsym(RTLD_DEFAULT, "BKSDisplayServicesStart");
            void (*appInitialize)(void) = dlsym(RTLD_DEFAULT, "UIApplicationInitialize");
            void (*instantiate)(Class) = dlsym(RTLD_DEFAULT, "UIApplicationInstantiateSingleton");
            void *(*registerHID)(void (*)(void *, void *, CFTypeRef, CFTypeRef)) = dlsym(RTLD_DEFAULT, "BKSHIDEventRegisterEventCallback");
            void (*eventInitialize)(Boolean) = dlsym(RTLD_DEFAULT, "GSEventInitialize");
            void (*pushMode)(CFStringRef) = dlsym(RTLD_DEFAULT, "GSEventPushRunLoopMode");
            if (!gsInitialize || !displayStart || !appInitialize || !instantiate || !registerHID || !eventInitialize || !pushMode ||
                !NSClassFromString(@"AXEventRepresentation")) HCStop(@"Thiếu API khởi tạo hoặc nhận chạm của overlay.", YES);
            [UIScreen class]; CFRunLoopGetCurrent();
            gsInitialize(); displayStart(); appInitialize(); instantiate(HCOverlayApplication.class);
            static HCOverlayDelegate *delegate;
            delegate = [HCOverlayDelegate new];
            UIApplication *app = UIApplication.sharedApplication;
            app.delegate = delegate;
            [app _accessibilityInit];
            [NSRunLoop currentRunLoop];
            registerHID(HCHIDCallback);
            eventInitialize(false); pushMode(kCFRunLoopDefaultMode);
            [app __completeAndRunAsPlugin];
            CFRunLoopRun();
        } @catch (NSException *error) { HCStop([@"Overlay: " stringByAppendingString:error.reason ?: @"unknown exception"], YES); }
        if (!HCStopping) HCStop(@"Vòng lặp overlay đã dừng.", NO);
        return 0;
    }
}
