// Standalone HUD bootstrap/window-hosting approach adapted from TrollSpeed
// (c) 2023 Lessica, MIT. See ThirdParty/TrollSpeed-LICENSE.txt and NOTICE.txt.
// This process owns its window; game access is isolated in CameraEngine.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "OverlayCommon.h"
#import "HCFeatures.h"
#include "OverlayLock.h"
#import "CameraEngine.h"
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
#include <errno.h>
#include <stdio.h>

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
static NSUInteger HCHIDCount, HCAXCount, HCPointerFallbackCount;
static NSString *HCInputBackend = @"not_started";
static CFTypeRef HCEventMonitor;
static NSInteger HCOrientation = UIInterfaceOrientationPortrait;
static BOOL HCLocked;
static BOOL HCMenuOpen;
static NSString *HCSettingsError;
static HCCameraEngine *HCCamera;
static NSDictionary *HCCameraStatus;
static NSDictionary *HCEspStatus;
static NSDictionary *HCEspLastSample;
static NSUInteger HCEspDraws;
static double HCEspDrawWindow, HCEspDrawFPS;
static NSString *HCStartupStage = @"entry";

static void HCState(void) {
    NSDictionary *state = @{@"schemaVersion": @1, @"phase": HCPhase, @"message": HCMessage,
        @"pid": @(getpid()), @"euid": @(geteuid()), @"heartbeat": @(NSProcessInfo.processInfo.systemUptime),
        @"session": HCSession, @"menuOpen": @(HCMenuOpen), @"orientation": @(HCOrientation),
        @"touchEvents": @(HCTouchCount), @"hiddenForLock": @(HCLocked),
        @"hidEvents": @(HCHIDCount), @"axTouchEvents": @(HCAXCount), @"pointerFallbacks": @(HCPointerFallbackCount),
        @"inputBackend": HCInputBackend,
        @"settingsOnly": @NO, @"camera": HCCameraStatus ?: @{@"code": @"camera_disabled", @"message": @"Camera xa đang tắt."},
        @"esp": HCEspStatus ?: @{@"code": @"esp_disabled", @"message": @"ESP đang tắt."},
        @"espLastSample": HCEspLastSample ?: (id)NSNull.null,
        @"displayLimitHz": @(UIScreen.mainScreen.maximumFramesPerSecond), @"overlayDrawFPS": @(HCEspDrawFPS),
        @"reports": @{@"code": @"unsupported", @"message": @"Chưa có nguồn dữ liệu tố cáo."},
        @"settingsError": HCSettingsError ?: @"", @"appVersion": @"0.8.0", @"stage": HCStartupStage};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:NSJSONWritingPrettyPrinted error:NULL];
    NSString *path = [HCDirectory stringByAppendingPathComponent:@"state.json"];
    NSError *writeError = nil;
    if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError])
        fprintf(stderr, "HC_OVERLAY state_write_failed stage=%s error=%s\n", HCStartupStage.UTF8String, writeError.localizedDescription.UTF8String);
    chmod(path.fileSystemRepresentation, 0644);
    chown(path.fileSystemRepresentation, 501, 501);
}
static void HCStage(NSString *stage) {
    HCStartupStage = stage;
    fprintf(stderr, "HC_OVERLAY stage=%s uid=%u euid=%u\n", stage.UTF8String, (unsigned)getuid(), (unsigned)geteuid());
    HCState();
}
static void HCStop(NSString *message, BOOL failed) {
    HCStopping = YES;
    if (HCCamera) HCCameraStatus = [HCCamera stop];
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
- (void)drawEsp;
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
            if ([flag isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)flag) != CFBooleanGetTypeID() &&
                ([flag doubleValue] == 0 || [flag doubleValue] == 1)) {
                settings[@"flags"][feature[@"key"]] = [flag doubleValue] == 1 ? @YES : @NO;
            } else if (!flag || CFGetTypeID((__bridge CFTypeRef)flag) != CFBooleanGetTypeID()) valid = NO;
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
    if ([self.settings[@"flags"][@"__ifxEnemyEspEnabledV1"] boolValue]) {
        double now = NSProcessInfo.processInfo.systemUptime;
        if (!HCEspDrawWindow) HCEspDrawWindow = now;
        HCEspDraws++;
        if (now - HCEspDrawWindow >= 1) { HCEspDrawFPS = HCEspDraws / (now - HCEspDrawWindow); HCEspDraws = 0; HCEspDrawWindow = now; }
    } else { HCEspDrawFPS = 0; HCEspDraws = 0; HCEspDrawWindow = 0; }
    [self drawEsp];
    if (HCMenuOpen) {
        CGRect p = [self panelRect];
        [[UIColor colorWithRed:0.045 green:0.06 blue:0.09 alpha:0.97] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:p cornerRadius:18] fill];
        HCText(@"HERO CONTROL", CGRectMake(p.origin.x + 14, p.origin.y + 14, p.size.width - 70, 24), 17, HCAccent(), YES);
        CGRect close = CGRectMake(CGRectGetMaxX(p) - 44, p.origin.y + 6, 38, 36);
        HCText(@"×", CGRectInset(close, 8, 0), 28, UIColor.whiteColor, NO); [self target:@"close" rect:close];
        HCText(HCSettingsError ?: @"Camera + ESP: xem kết quả kiểm chứng\nTố cáo: chưa hỗ trợ.", CGRectMake(p.origin.x + 14, p.origin.y + 43, p.size.width - 28, 34), 11,
            HCSettingsError ? UIColor.systemOrangeColor : UIColor.lightGrayColor, NO);
        NSArray *tabs = @[@"ESP", @"Camera", @"Reports"];
        NSArray *groups = @[@0, @1, @4];
        CGFloat tabWidth = (p.size.width - 20) / 3;
        for (NSInteger i = 0; i < 3; i++) {
            NSInteger group = [groups[i] integerValue];
            CGRect r = CGRectMake(p.origin.x + 10 + i * tabWidth, p.origin.y + 80, tabWidth, 32);
            if (group == self.group) { [HCAccent() setFill]; [[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:6] fill]; }
            HCText(tabs[i], CGRectInset(r, 4, 8), 11, group == self.group ? UIColor.blackColor : UIColor.whiteColor, YES);
            [self target:[NSString stringWithFormat:@"tab:%ld", (long)group] rect:r];
        }
        CGFloat y = p.origin.y + 122;
        if (self.group == 1) {
            double scale = [self.settings[@"cameraScale"] doubleValue];
            HCText([NSString stringWithFormat:@"Camera: %.2f×", scale], CGRectMake(p.origin.x + 14, y, p.size.width - 28, 24), 16, UIColor.whiteColor, YES);
            CGRect enable = CGRectMake(p.origin.x + 14, y + 27, p.size.width - 28, 28);
            BOOL enabled = [self.settings[@"cameraEnabled"] boolValue];
            HCText(@"Bật camera xa", CGRectInset(enable, 0, 4), 14, UIColor.whiteColor, YES);
            HCText(enabled ? @"ON" : @"OFF", CGRectMake(CGRectGetMaxX(enable) - 35, enable.origin.y + 4, 35, 22), 14,
                enabled ? HCAccent() : UIColor.lightGrayColor, YES);
            [self target:@"cameraEnabled" rect:enable];
            CGRect slider = CGRectMake(p.origin.x + 20, y + 62, p.size.width - 40, 36);
            [[UIColor colorWithWhite:0.22 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(slider.origin.x, slider.origin.y + 15, slider.size.width, 6) cornerRadius:3] fill];
            CGFloat x = slider.origin.x + HCClamp((scale - 1) / 1.3, 0, 1) * slider.size.width;
            [HCAccent() setFill]; [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(x - 9, slider.origin.y + 9, 18, 18)] fill];
            [self target:@"camera" rect:slider];
            HCText(HCCameraStatus[@"message"] ?: @"Bật camera xa rồi vào trận tập để thử.", CGRectMake(p.origin.x + 14, y + 107, p.size.width - 28, 70), 12, UIColor.lightGrayColor, NO);
        } else if (self.group == 4) {
            HCText(@"Chưa có dữ liệu tố cáo. Không thể xác nhận chức năng này hoạt động.", CGRectMake(p.origin.x + 14, y, p.size.width - 28, 80), 14, UIColor.systemOrangeColor, NO);
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
            HCText([NSString stringWithFormat:@"ESP: %@ • %@/%@ mục tiêu chiếu được", HCEspStatus[@"code"] ?: @"chưa chạy", HCEspStatus[@"projectedCount"] ?: @0, HCEspStatus[@"targetCount"] ?: @0], CGRectMake(p.origin.x + 14, y + 3, p.size.width - 28, 36), 10, UIColor.lightGrayColor, NO);
        }
        CGRect stop = CGRectMake(p.origin.x + 10, CGRectGetMaxY(p) - 34, p.size.width - 20, 28);
        HCText(@"TẮT NÚT NỔI", CGRectInset(stop, 6, 6), 12, UIColor.systemOrangeColor, YES); [self target:@"stop" rect:stop];
    }
    CGRect bubble = [self bubbleRect];
    [HCAccent() setFill]; [[UIBezierPath bezierPathWithOvalInRect:bubble] fill];
    HCText(HCMenuOpen ? @"×" : @"HC", CGRectMake(bubble.origin.x + (HCMenuOpen ? 17 : 11), bubble.origin.y + 12, 38, 30),
        HCMenuOpen ? 24 : 20, UIColor.blackColor, YES);
}
- (void)drawEsp {
    NSDictionary *flags = self.settings[@"flags"];
    if (HCLocked || ![flags[@"__ifxEnemyEspEnabledV1"] boolValue]) return;
    if (!HCEspStatus[@"sampleUptime"] || NSProcessInfo.processInfo.systemUptime - [HCEspStatus[@"sampleUptime"] doubleValue] > 0.5) return;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIColor *color = HCAccent();
    for (NSDictionary *target in HCEspStatus[@"targets"]) {
        if (![target[@"onScreen"] boolValue]) continue;
        CGFloat x = [target[@"x"] doubleValue] * w, top = [target[@"headY"] doubleValue] * h;
        CGFloat bottom = [target[@"feetY"] doubleValue] * h, height = bottom - top;
        if (!isfinite(height) || height < 4 || height > h) continue;
        CGRect box = CGRectMake(x - height * 0.24, top, height * 0.48, height);
        [color setStroke];
        if ([flags[@"DoroCheat.Reference.R1.Box"] boolValue]) {
            UIBezierPath *path = [UIBezierPath bezierPathWithRect:box]; path.lineWidth = 1.5; [path stroke];
        }
        if ([flags[@"DoroCheat.Reference.R1.HP"] boolValue] && [target[@"hpKnown"] boolValue]) {
            CGFloat ratio = HCClamp([target[@"hp"] doubleValue] / MAX(1, [target[@"maxHP"] doubleValue]), 0, 1);
            [UIColor.blackColor setFill]; UIRectFill(CGRectMake(box.origin.x, top - 7, box.size.width, 4));
            [color setFill]; UIRectFill(CGRectMake(box.origin.x, top - 7, box.size.width * ratio, 4));
        }
        if ([flags[@"DoroCheat.Reference.R1.Icon"] boolValue])
            HCText([NSString stringWithFormat:@"#%@", target[@"heroID"]], CGRectMake(x - 34, top - 24, 68, 18), 11, color, YES);
        if ([flags[@"DoroCheat.Reference.R1.HP"] boolValue] && ![target[@"hpKnown"] boolValue])
            HCText([target[@"hpCurrentKnown"] boolValue] ? [NSString stringWithFormat:@"HP %@", target[@"hp"]] : @"HP ?", CGRectMake(x - 35, top - 20, 70, 18), 10, color, NO);
        if ([flags[@"DoroCheat.Reference.R1.Check"] boolValue]) {
            NSMutableArray *texts = [NSMutableArray array];
            for (NSNumber *cd in target[@"cooldowns"]) [texts addObject:cd.intValue < 0 ? @"?" : cd.stringValue];
            HCText([texts componentsJoinedByString:@" / "], CGRectMake(x - 45, bottom + 3, 90, 18), 11, color, YES);
        }
    }
    if ([flags[@"DoroCheat.Reference.R1.Map"] boolValue] && [HCEspStatus[@"hasHostPosition"] boolValue]) {
        CGRect radar = CGRectMake(w - 114, 44, 100, 100);
        [[UIColor colorWithWhite:0 alpha:0.5] setFill]; UIRectFill(radar);
        HCText(@"RADAR ±60m", CGRectMake(radar.origin.x, 27, 105, 16), 10, color, YES);
        [UIColor.whiteColor setFill]; UIRectFill(CGRectMake(CGRectGetMidX(radar)-2, CGRectGetMidY(radar)-2, 4, 4));
        for (NSDictionary *target in HCEspStatus[@"targets"]) {
            double dx = [target[@"worldX"] doubleValue] - [HCEspStatus[@"hostX"] doubleValue];
            double dz = [target[@"worldZ"] doubleValue] - [HCEspStatus[@"hostZ"] doubleValue];
            if (fabs(dx) > 60 || fabs(dz) > 60) continue;
            [color setFill];
            [[UIBezierPath bezierPathWithOvalInRect:CGRectMake(CGRectGetMidX(radar)+dx/1.2-3, CGRectGetMidY(radar)-dz/1.2-3, 6, 6)] fill];
        }
    }
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
        else if ([target isEqual:@"cameraEnabled"]) {
            [self reloadSettings];
            if (self.settings) {
                self.settings[@"cameraEnabled"] = [self.settings[@"cameraEnabled"] boolValue] ? @NO : @YES;
                [self saveSettings];
            }
        }
        else if ([target hasPrefix:@"flag:"]) {
            [self reloadSettings];
            NSString *key = [target substringFromIndex:5];
            if (self.settings) { self.settings[@"flags"][key] = [self.settings[@"flags"][key] boolValue] ? @NO : @YES; [self saveSettings]; }
        }
        HCState();
    }
}
@end

@interface HCOverlayWindow : UIWindow @end
@implementation HCOverlayWindow
+ (BOOL)_isSystemWindow { return YES; }
- (BOOL)_isWindowServerHostingManaged { return NO; }
// Window hosting otherwise captures the full display context before UIKit's
// view hitTest gets a chance to return nil. Our controls use the AX monitor,
// not UIKit-delivered touches, so let the underlying application receive input.
- (BOOL)_ignoresHitTest { return YES; }
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
    if (locked) { HCEspDrawFPS = 0; HCEspDraws = 0; HCEspDrawWindow = 0; }
    [HCCanvas setNeedsDisplay]; HCState();
}

@interface HCOverlayDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow *window;
@property(nonatomic, strong) NSTimer *timer;
@property(nonatomic, strong) CADisplayLink *displayLink;
@end
@implementation HCOverlayDelegate
- (void)displayTick:(CADisplayLink *)link {
    NSInteger desired = MIN(UIScreen.mainScreen.maximumFramesPerSecond, MAX(60, [HCEspStatus[@"requestedReadHz"] integerValue]));
    if (link.preferredFrameRateRange.preferred != desired)
        link.preferredFrameRateRange = CAFrameRateRangeMake(MIN(60, desired), desired, desired);
    if (!HCLocked && [HCCanvas.settings[@"flags"][@"__ifxEnemyEspEnabledV1"] boolValue]) [HCCanvas setNeedsDisplay];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    HCStage(@"delegate_launch");
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
    HCStage(@"register_window");
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
    HCStartupStage = @"ready";
    HCPhase = @"visible"; HCMessage = @"Đã đăng ký nút nổi Hero Control. Chạm để mở/thu menu; kéo để di chuyển.";
    HCUpdateLock(); HCState();
    HCCamera = [[HCCameraEngine alloc] initWithProfile:HCProfile report:^(NSDictionary *report) {
        HCCameraStatus = report;
        [HCCanvas setNeedsDisplay];
    } espReport:^(NSDictionary *report) {
        HCEspStatus = report;
        // Preserve the last actor sample for export after switching away from
        // the game. It is historical evidence, never a frame to draw now.
        if ([report[@"listCount"] integerValue] > 0) HCEspLastSample = report;
    }];
    [HCCamera start];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(displayTick:)];
    NSInteger maximum = UIScreen.mainScreen.maximumFramesPerSecond;
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(MIN(60, maximum), maximum, maximum);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    self.timer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        (void)timer;
        if (access(HCExecutable.fileSystemRepresentation, X_OK) || !HCOverlayPathsValid(HCDirectory, HCProfile))
            HCStop(@"Gói ứng dụng/cấu hình không còn tồn tại; overlay tự dừng.", NO);
        // The profile is shared with the app. Do not replace an in-progress drag.
        if (!HCCanvas.activeTarget) [HCCanvas reloadSettings];
        HCState();
    }];
    alarm(0);
    return YES;
}
@end

static void HCHIDCallback(void *target, void *refcon, CFTypeRef service, CFTypeRef event) {
    (void)target; (void)refcon; (void)service;
    // Monitor only: no global touch injection. Dispatch our own canvas actions
    // only for a finger that begins inside the bubble/panel; ignore other apps.
    @autoreleasepool {
        @try {
            HCHIDCount++;
            Class<HCAXEventRepresentation> representation = (Class<HCAXEventRepresentation>)NSClassFromString(@"AXEventRepresentation");
            id<HCAXEventRepresentation> rep = [representation representationWithHIDEvent:event hidStreamIdentifier:@"UIApplicationEvents"];
            if (!rep) return;
            UITouchPhase phase;
            if ([rep isTouchDown]) phase = UITouchPhaseBegan;
            else if ([rep isMove]) phase = UITouchPhaseMoved;
            else if ([rep isCancel]) phase = UITouchPhaseCancelled;
            else if ([rep isLift] || [rep isInRangeLift]) phase = UITouchPhaseEnded;
            else return;
            HCAXCount++;
            CGPoint point = [rep location];
            id<HCAXEventPath> path = [[[rep handInfo] paths] firstObject];
            NSInteger pointer = path ? [path pathIdentity] : -1;
            // Raw monitor streams can omit the path identity for a single
            // finger. Do not silently discard the entire gesture as before.
            if (pointer < 1) { pointer = 1; HCPointerFallbackCount++; }
            // The system monitor may supply normalized digitizer coordinates;
            // AX's UIApplication stream supplies points. Support both forms.
            if (point.x >= 0 && point.y >= 0 && point.x <= 1 && point.y <= 1) {
                CGSize screen = UIScreen.mainScreen.bounds.size;
                point = CGPointMake(point.x * screen.width, point.y * screen.height);
            }
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    CGPoint local = [HCCanvas convertPoint:point fromView:HCWindow];
                    [HCCanvas receivePoint:local phase:phase pointer:pointer];
                } @catch (NSException *error) { HCSettingsError = error.reason; HCState(); }
            });
        } @catch (NSException *error) { fprintf(stderr, "HC_OVERLAY HID: %s\n", error.reason.UTF8String); }
    }
}

static BOOL HCStartInputMonitor(void) {
    // Independent of UIApplication's routed event stream, which receives no
    // touches when the hosting window advertises _ignoresHitTest=YES.
    // Client type Monitor=1 follows WebKit's IOKit SPI declarations. We only
    // register an event callback; no filtering, cancellation or injection.
    void *library = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_GLOBAL);
    if (!library) return NO;
    CFTypeRef (*create)(CFAllocatorRef, int, CFDictionaryRef) = dlsym(library, "IOHIDEventSystemClientCreateWithType");
    void (*registerCallback)(CFTypeRef, void (*)(void *, void *, CFTypeRef, CFTypeRef), void *, void *) =
        dlsym(library, "IOHIDEventSystemClientRegisterEventCallback");
    void (*schedule)(CFTypeRef, CFRunLoopRef, CFStringRef) = dlsym(library, "IOHIDEventSystemClientScheduleWithRunLoop");
    if (!create || !registerCallback || !schedule) return NO;
    HCEventMonitor = create(kCFAllocatorDefault, 1, NULL);
    if (!HCEventMonitor) return NO;
    registerCallback(HCEventMonitor, HCHIDCallback, NULL, NULL);
    schedule(HCEventMonitor, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    HCInputBackend = @"iohid_system_monitor";
    fprintf(stderr, "HC_OVERLAY input_monitor_registered\n");
    return YES;
}

static void HCStartupTimeout(int signalNumber) {
    (void)signalNumber;
    const char message[] = "HC_OVERLAY startup_watchdog_timeout\n";
    write(STDERR_FILENO, message, sizeof(message) - 1);
    _exit(124);
}

int main(int argc, char **argv) {
    setvbuf(stderr, NULL, _IONBF, 0);
    fprintf(stderr, "HC_OVERLAY entry argc=%d uid=%u euid=%u\n", argc, (unsigned)getuid(), (unsigned)geteuid());
    @autoreleasepool {
        if (argc != 6 || strcmp(argv[1], "--run") || strcmp(argv[4], "--lock-fd") || strcmp(argv[5], "3")) {
            fprintf(stderr, "HC_OVERLAY invalid_arguments\n"); return 64;
        }
        signal(SIGALRM, HCStartupTimeout);
        alarm(20);
        HCDirectory = [NSString stringWithUTF8String:argv[2]];
        HCProfile = [NSString stringWithUTF8String:argv[3]];
        HCExecutable = [NSString stringWithUTF8String:argv[0]];
        HCSession = NSUUID.UUID.UUIDString;
        if (geteuid() != 0) { fprintf(stderr, "HC_OVERLAY root_identity_missing\n"); return 77; }
        if (!HCOverlayPathsValid(HCDirectory, HCProfile)) {
            fprintf(stderr, "HC_OVERLAY paths_rejected directory=%s profile=%s\n", HCDirectory.fileSystemRepresentation, HCProfile.fileSystemRepresentation);
            for (NSString *path in @[HCDirectory, HCProfile.stringByDeletingLastPathComponent, HCProfile]) {
                struct stat info = {0}; int result = lstat(path.fileSystemRepresentation, &info); int failure = result ? errno : 0;
                fprintf(stderr, "HC_OVERLAY path=%s stat=%d errno=%d owner=%u mode=%o resolved=%s\n", path.fileSystemRepresentation,
                    result, failure, (unsigned)info.st_uid, (unsigned)info.st_mode, path.stringByResolvingSymlinksInPath.fileSystemRepresentation);
            }
            return 77;
        }
        // The app has already opened and locked this file as mobile. Validate
        // the inherited descriptor, without creating/opening/locking it as root.
        NSString *lockPath = [HCDirectory stringByAppendingPathComponent:[NSString stringWithUTF8String:HC_OVERLAY_LOCK_NAME]];
        HCLock = HC_OVERLAY_LOCK_FD;
        int lockError = HCOverlayValidateLockFD(HCLock, lockPath.fileSystemRepresentation, 501);
        if (lockError) { fprintf(stderr, "HC_OVERLAY inherited_lock_invalid errno=%d\n", lockError); return 73; }
        if (fcntl(HCLock, F_SETFD, FD_CLOEXEC)) { fprintf(stderr, "HC_OVERLAY lock_cloexec_failed errno=%d\n", errno); return 73; }
        fprintf(stderr, "HC_OVERLAY inherited_lock_verified fd=%d\n", HCLock);
        struct rlimit logLimit = {262144, 262144}; setrlimit(RLIMIT_FSIZE, &logLimit);
        HCStage(@"paths_verified");
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
            HCStage(@"frameworks_loaded");
            [UIScreen class]; CFRunLoopGetCurrent();
            HCStage(@"gs_initialize"); gsInitialize();
            HCStage(@"display_start"); displayStart();
            HCStage(@"application_initialize"); appInitialize();
            HCStage(@"application_singleton"); instantiate(HCOverlayApplication.class);
            static HCOverlayDelegate *delegate;
            delegate = [HCOverlayDelegate new];
            UIApplication *app = UIApplication.sharedApplication;
            app.delegate = delegate;
            HCStage(@"accessibility_initialize"); [app _accessibilityInit];
            [NSRunLoop currentRunLoop];
            HCStage(@"register_hid");
            if (!HCStartInputMonitor()) {
                HCInputBackend = @"backboard_routed_fallback";
                fprintf(stderr, "HC_OVERLAY global_monitor_unavailable_using_routed_fallback\n");
                registerHID(HCHIDCallback);
            }
            eventInitialize(false); pushMode(kCFRunLoopDefaultMode);
            HCStage(@"run_plugin"); [app __completeAndRunAsPlugin];
            CFRunLoopRun();
        } @catch (NSException *error) { HCStop([@"Overlay: " stringByAppendingString:error.reason ?: @"unknown exception"], YES); }
        if (!HCStopping) HCStop(@"Vòng lặp overlay đã dừng.", NO);
        return 0;
    }
}
