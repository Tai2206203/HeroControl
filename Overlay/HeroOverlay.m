// Standalone HUD bootstrap/window-hosting approach adapted from TrollSpeed
// (c) 2023 Lessica, MIT. See ThirdParty/TrollSpeed-LICENSE.txt and NOTICE.txt.
// This process owns its window; game access is isolated in CameraEngine.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "OverlayCommon.h"
#import "HCFeatures.h"
#include "OverlayLock.h"
#include "CapturePolicy.h"
#include "../BackendSDK/EspPresentation.h"
#import "CameraEngine.h"
#import "HeroAssets.h"
#include "../BackendSDK/MinimapProjection.h"
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
static NSDictionary *HCReportsStatus;
static NSUInteger HCEspDraws;
static double HCEspDrawWindow, HCEspDrawFPS;
static BOOL HCCaptureProtected, HCSecureHostAvailable, HCCaptureActive, HCCaptureLayerConfigured;
static UIView *HCOverlayRootView;
static UITextField *HCOverlaySecureField;
static NSInteger HCConfiguredCaptureMode=-1;
static UIView *HCCachedSecureHost;
static void HCRefreshCaptureHost(UIView *canvas,UIView *espView) {
    if(!HCOverlayRootView) return;
    BOOL sizeChanged=!CGRectEqualToRect(HCOverlaySecureField.frame,HCOverlayRootView.bounds);
    BOOL configure=HCConfiguredCaptureMode!=HCCaptureProtected;
    if(sizeChanged) HCOverlaySecureField.frame=HCOverlayRootView.bounds;
    if(configure && HCCaptureProtected) {
        HCOverlaySecureField.secureTextEntry=NO;HCOverlaySecureField.secureTextEntry=YES;
    }
    if(sizeChanged || configure) {
        [HCOverlaySecureField layoutIfNeeded];HCCachedSecureHost=HCSecureCanvas(HCOverlaySecureField);
    }
    UIView *secure=HCCachedSecureHost;
    HCSecureHostAvailable=secure!=nil;
    UIView *parent=HCCaptureProtected ? secure : HCOverlayRootView;
    if(secure && (sizeChanged || configure)) secure.frame=HCOverlayRootView.bounds;
    if(parent && canvas.superview!=parent) [parent addSubview:canvas];
    if(configure) {
        BOOL menuConfigured=HCConfigureCaptureLayer(canvas.layer,secure.layer,HCCaptureProtected);
        BOOL espConfigured=HCConfigureCaptureLayer(espView.layer,secure.layer,HCCaptureProtected);
        HCCaptureLayerConfigured=HCCaptureProtected && menuConfigured && espConfigured;
        HCConfiguredCaptureMode=HCCaptureProtected;
    }
    canvas.hidden=HCShouldHideOverlay(HCLocked,HCCaptureProtected,HCCaptureActive,secure!=nil);
}
static NSString *HCStartupStage = @"entry";

static void HCState(void) {
    NSDictionary *state = @{@"schemaVersion": @1, @"phase": HCPhase, @"message": HCMessage,
        @"pid": @(getpid()), @"euid": @(geteuid()), @"heartbeat": @(NSProcessInfo.processInfo.systemUptime),
        @"session": HCSession, @"menuOpen": @(HCMenuOpen), @"orientation": @(HCOrientation),
        @"touchEvents": @(HCTouchCount), @"hiddenForLock": @(HCLocked),
        @"hidEvents": @(HCHIDCount), @"axTouchEvents": @(HCAXCount), @"pointerFallbacks": @(HCPointerFallbackCount),
        @"inputBackend": HCInputBackend,
        @"hiddenForCapture": @(HCCaptureProtected && (!HCSecureHostAvailable || HCCaptureActive)), @"captureLayerConfigured": @(HCCaptureLayerConfigured), @"captureScope": @"menu_and_esp", @"captureProtected": @(HCCaptureProtected), @"secureHostAvailable": @(HCSecureHostAvailable), @"screenCaptured": @(HCCaptureActive),
        @"iconCount": @(HCHeroCatalog().count), @"settingsOnly": @NO, @"camera": HCCameraStatus ?: @{@"code": @"camera_disabled", @"message": @"Camera xa đang tắt."},
        @"esp": HCEspStatus ?: @{@"code": @"esp_disabled", @"message": @"ESP đang tắt."},
        @"espLastSample": HCEspLastSample ?: (id)NSNull.null,
        @"displayLimitHz": @(UIScreen.mainScreen.maximumFramesPerSecond), @"overlayDrawFPS": @(HCEspDrawFPS),
        @"reports": HCReportsStatus ?: @{@"code": @"reports_disabled", @"message": @"Đọc thư tố cáo đang tắt.", @"records": @[], @"querySupported": @NO},
        @"settingsError": HCSettingsError ?: @"", @"appVersion": @"0.11.2", @"generation": @HC_RUNTIME_GENERATION, @"stage": HCStartupStage};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:NULL];
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

@interface HCOverlayCanvas : UIView <HCEspPainting>
@property(nonatomic) CGPoint bubble;
@property(nonatomic) NSInteger group;
@property(nonatomic, strong) NSMutableDictionary *settings;
@property(nonatomic, strong) NSDictionary *baseSettings;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *targets;
@property(nonatomic, copy) NSString *activeTarget;
@property(nonatomic) NSInteger pointer;
@property(nonatomic) CGPoint startPoint;
@property(nonatomic) CGPoint startBubble;
@property(nonatomic) BOOL dragged;
- (void)reloadSettings;
- (void)drawEsp;
- (void)refreshEspSurface;
- (void)cancelInteraction;
@property(nonatomic,strong) HCEspDrawingView *espView;
- (void)toggleMenu;
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer;
@end

static UIColor *HCAccent(void) { return [UIColor colorWithRed:0.39 green:0.88 blue:0.78 alpha:1]; }
static void HCText(NSString *text, CGRect rect, CGFloat size, UIColor *color, BOOL bold) {
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: bold ? [UIFont boldSystemFontOfSize:size] : [UIFont systemFontOfSize:size],
        NSForegroundColorAttributeName: color}];
}
static CGFloat HCClamp(CGFloat value, CGFloat lower, CGFloat upper) { return MAX(lower, MIN(value, MAX(lower, upper))); }

static NSDictionary *HCOverlayReadProfileForMerge(void) {
    NSData *data=[NSData dataWithContentsOfFile:HCProfile];
    if (!data || data.length>131072) return nil;
    id root=[NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    if (![root isKindOfClass:NSDictionary.class] || ![root[@"schemaVersion"] isEqual:@1]) return nil;
    id settings=root[@"settings"];
    if (![settings isKindOfClass:NSDictionary.class] || ![settings[@"flags"] isKindOfClass:NSDictionary.class] ||
        ![settings[@"cameraScale"] isKindOfClass:NSNumber.class] || ![settings[@"selectedSkins"] isKindOfClass:NSDictionary.class]) return nil;
    double scale=[settings[@"cameraScale"] doubleValue];
    if (!isfinite(scale) || scale<1 || scale>2.3) return nil;
    for (NSDictionary *feature in HCFeatures()) {
        id value=settings[@"flags"][feature[@"key"]];
        if (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)!=CFBooleanGetTypeID()) return nil;
    }
    return settings;
}

@implementation HCOverlayCanvas {
    BOOL _editingMinimap;
    CGRect _startMapRect;
    double _menuOpenedAt, _nextMenuRedraw;
    HCEspScreenState _screenStates[HC_ESP_MAX_TARGETS];
    NSInteger _screenPID;
    CGSize _screenSize;
    NSString *_screenCamera;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = UIColor.clearColor;
        self.opaque = NO; self.multipleTouchEnabled = NO;
        _bubble = CGPointMake(38, 115); _pointer = -1; _group=5;
        _targets = [NSMutableArray array];
        [self reloadSettings];
        _espView=[[HCEspDrawingView alloc] initWithFrame:self.bounds];
        [self addSubview:_espView];
        _espView.painter=self;_espView.opaque=NO;_espView.backgroundColor=UIColor.clearColor;_espView.userInteractionEnabled=NO;
        [self refreshEspSurface];
    }
    return self;
}
- (void)refreshEspSurface {
    HCCaptureProtected=![self.settings[@"espCaptureProtected"] isEqual:@NO];
    HCCaptureActive=UIScreen.mainScreen.isCaptured;
    self.espView.frame=self.bounds;
    BOOL wasHidden=self.hidden;
    HCRefreshCaptureHost(self,self.espView);
    if(self.hidden && !wasHidden) [self cancelInteraction];
    self.espView.hidden=HCLocked;
    if(self.hidden) { HCEspDrawFPS=0;HCEspDraws=0;HCEspDrawWindow=0; }
    [self.espView setNeedsDisplay];
    double now=NSProcessInfo.processInfo.systemUptime;
    if(!self.hidden && (HCMenuOpen || _editingMinimap) && now>=_nextMenuRedraw) {
        _nextMenuRedraw=now+0.05;[self setNeedsDisplay];
    }
}
- (void)cancelInteraction {
    BOOL editing=self.activeTarget!=nil;
    self.activeTarget=nil;self.pointer=-1;self.dragged=NO;
    if(editing) [self reloadSettings];
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
        self.baseSettings = [settings copy];
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
    NSString *lockPath=[HCProfile stringByAppendingString:@".edit-lock"];
    int editLock=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    struct stat lockInfo={0};
    if (editLock<0 || fstat(editLock,&lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid!=501 || flock(editLock,LOCK_EX|LOCK_NB)) {
        if (editLock>=0) close(editLock);
        HCSettingsError=@"Chưa lấy được khóa chỉnh cấu hình. Thử lại trong Hero Control.";return;
    }
    // Merge only the fields changed by this gesture. An app edit completed
    // during a slider drag must survive the HUD's eventual atomic replacement.
    NSDictionary *latest=HCOverlayReadProfileForMerge();
    if (!latest) {
        flock(editLock,LOCK_UN);close(editLock);
        HCSettingsError=@"Cấu hình hiện tại không hợp lệ; không ghi đè.";return;
    }
    NSMutableDictionary *merged=[latest mutableCopy];
    NSMutableDictionary *mergedFlags=[latest[@"flags"] mutableCopy];
    for (NSString *key in self.settings[@"flags"]) {
        id value=self.settings[@"flags"][key];
        if (![value isEqual:self.baseSettings[@"flags"][key]]) mergedFlags[key]=value;
    }
    merged[@"flags"]=mergedFlags;
    for (NSString *key in self.settings) {
        if ([key isEqual:@"flags"]) continue;
        if (![self.settings[key] isEqual:self.baseSettings[key]]) merged[key]=self.settings[key];
    }
    self.settings=merged;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"settings": self.settings, @"revision": NSUUID.UUID.UUIDString}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:HCProfile options:NSDataWritingAtomic error:&error]) {
        HCSettingsError = error.localizedDescription ?: @"Không ghi được cấu hình.";
    } else {
        chmod(HCProfile.fileSystemRepresentation, 0644);
        chown(HCProfile.fileSystemRepresentation, 501, 501);
        HCSettingsError = nil;
    }
    flock(editLock,LOCK_UN);close(editLock);
    HCState(); [self setNeedsDisplay];
}
- (CGRect)bubbleRect { return CGRectMake(self.bubble.x - 26, self.bubble.y - 26, 52, 52); }
- (CGRect)panelRect {
    BOOL landscape=self.bounds.size.width>self.bounds.size.height;
    CGFloat width=landscape ? MIN(640,self.bounds.size.width*0.76) : MIN(360,self.bounds.size.width-32);
    CGFloat height=landscape ? MIN(330,self.bounds.size.height*0.80) : MIN(440,self.bounds.size.height*0.72);
    return CGRectMake((self.bounds.size.width-width)/2,(self.bounds.size.height-height)/2,width,height);
}
- (CGRect)contentRect {
    CGRect p=[self panelRect];return CGRectMake(p.origin.x+66,p.origin.y+62,p.size.width-82,p.size.height-104);
}
- (void)tile:(CGRect)rect title:(NSString *)title subtitle:(NSString *)subtitle image:(int32_t)hero action:(NSString *)action {
    HCFillGradient(rect,[UIColor colorWithRed:0.16 green:0.20 blue:0.25 alpha:0.98],[UIColor colorWithRed:0.08 green:0.11 blue:0.15 alpha:0.98]);
    NSString *glyph=hero==130 || hero==156 ? @"viewfinder" : hero==118 ? @"square.stack.3d.up.fill" : hero==537 ? @"camera.fill" : @"envelope.fill";
    UIImage *symbol=[[UIImage systemImageNamed:glyph] imageWithTintColor:[HCAccent() colorWithAlphaComponent:0.22] renderingMode:UIImageRenderingModeAlwaysOriginal];
    [symbol drawInRect:CGRectMake(CGRectGetMaxX(rect)-43,rect.origin.y+10,28,28)];
    [[HCAccent() colorWithAlphaComponent:0.18] setStroke];
    UIBezierPath *path=[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:14];path.lineWidth=0.8;[path stroke];
    CGFloat font=rect.size.width<130 ? 13 : 17;
    HCText(title,CGRectMake(rect.origin.x+10,CGRectGetMaxY(rect)-47,rect.size.width-18,22),font,UIColor.whiteColor,YES);
    HCText(subtitle,CGRectMake(rect.origin.x+10,CGRectGetMaxY(rect)-23,rect.size.width-18,18),8,UIColor.lightGrayColor,NO);
    [self target:action rect:rect];
}
- (CGRect)minimapRect {
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    CGFloat size=HCClamp([self.settings[@"minimapSize"] doubleValue] ?: 150,80,MIN(240,MIN(w,h)));
    double x=self.settings[@"minimapX"] ? [self.settings[@"minimapX"] doubleValue] : 0.015;
    double y=self.settings[@"minimapY"] ? [self.settings[@"minimapY"] doubleValue] : 0.02;
    return CGRectMake(HCClamp(w*x,0,w-size),HCClamp(h*y,0,h-size),size,size);
}
- (CGRect)minimapDoneRect {
    CGRect map=[self minimapRect];
    return CGRectMake(CGRectGetMaxX(map)-56,MAX(0,map.origin.y-27),56,24);
}
- (CGRect)minimapIconButton:(BOOL)increase {
    CGRect map=[self minimapRect],done=[self minimapDoneRect];
    CGFloat y=map.size.width>=120 ? done.origin.y : HCClamp(CGRectGetMaxY(map)+4,0,self.bounds.size.height-24);
    return CGRectMake(map.origin.x+(increase ? 29 : 0),y,26,24);
}
- (CGRect)minimapResizeRect {
    CGRect map=[self minimapRect];
    return CGRectMake(CGRectGetMaxX(map)-22,CGRectGetMaxY(map)-22,28,28);
}
- (void)minimapAt:(CGPoint)point {
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    double dx=point.x-self.startPoint.x,dy=point.y-self.startPoint.y;
    if([self.activeTarget isEqual:@"minimap-move"]) {
        self.settings[@"minimapX"]=@(HCMinimapDragPosition(_startMapRect.origin.x,dx,w,_startMapRect.size.width));
        self.settings[@"minimapY"]=@(HCMinimapDragPosition(_startMapRect.origin.y,dy,h,_startMapRect.size.height));
    } else {
        double limit=MIN(240,MIN(w-_startMapRect.origin.x,h-_startMapRect.origin.y));
        self.settings[@"minimapSize"]=@(HCClamp(_startMapRect.size.width+(dx+dy)/2,80,limit));
    }
    [self refreshEspSurface];[self setNeedsDisplay];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    [self refreshEspSurface];
    self.bubble = CGPointMake(HCClamp(self.bubble.x, 30, self.bounds.size.width - 30),
        HCClamp(self.bubble.y, 60, self.bounds.size.height - 38));
    [self setNeedsDisplay];
}
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    return !self.hidden && !HCLocked && (CGRectContainsPoint([self bubbleRect], point) || (HCMenuOpen && CGRectContainsPoint([self panelRect], point)) ||
        (_editingMinimap && (CGRectContainsPoint([self minimapRect],point) || CGRectContainsPoint([self minimapDoneRect],point) || CGRectContainsPoint([self minimapResizeRect],point) || CGRectContainsPoint([self minimapIconButton:NO],point) || CGRectContainsPoint([self minimapIconButton:YES],point))));
}
- (void)target:(NSString *)key rect:(CGRect)rect { [self.targets addObject:@{@"key": key, @"rect": [NSValue valueWithCGRect:rect]}]; }
- (NSString *)targetAt:(CGPoint)point {
    if (CGRectContainsPoint([self bubbleRect], point)) return @"bubble";
    if (_editingMinimap) {
        if(CGRectContainsPoint([self minimapIconButton:NO],point)) return @"minimap-icon-smaller";
        if(CGRectContainsPoint([self minimapIconButton:YES],point)) return @"minimap-icon-larger";
        if(CGRectContainsPoint([self minimapDoneRect],point)) return @"minimap-done";
        if(CGRectContainsPoint([self minimapResizeRect],point)) return @"minimap-resize";
        if(CGRectContainsPoint([self minimapRect],point)) return @"minimap-move";
    }
    if (!HCMenuOpen) return nil;
    for (NSDictionary *target in self.targets.reverseObjectEnumerator)
        if (CGRectContainsPoint([target[@"rect"] CGRectValue], point)) return target[@"key"];
    return nil;
}
- (void)drawRect:(CGRect)rect {
    [self.targets removeAllObjects];
    if (HCMenuOpen) {
        CGRect p=[self panelRect];
        CGContextRef ctx=UIGraphicsGetCurrentContext();
        UIBezierPath *outline=[UIBezierPath bezierPathWithRoundedRect:p cornerRadius:26];
        CGContextSaveGState(ctx);
        double fade=_menuOpenedAt>0 ? HCClamp((NSProcessInfo.processInfo.systemUptime-_menuOpenedAt)/0.18,0,1) : 1;
        CGContextSetAlpha(ctx,fade);
        HCFillGradient(p,[UIColor colorWithRed:0.10 green:0.13 blue:0.18 alpha:0.98],[UIColor colorWithRed:0.035 green:0.05 blue:0.075 alpha:0.98]);
        CGContextSaveGState(ctx);[outline addClip];
        NSArray *covers=@[@"nakroth-loi-quang.png",@"nakroth-thu-nguyen.jpg",@"nakroth-quy-thuong.jpg"];
        double cycle=NSProcessInfo.processInfo.systemUptime/14.0;
        NSUInteger cover=(NSUInteger)floor(cycle)%covers.count;
        CGFloat blend=HCClamp((cycle-floor(cycle)-0.88)/0.12,0,1);
        CGFloat zoom=1.025+0.015*sin(NSProcessInfo.processInfo.systemUptime*0.12);
        HCDrawImageFill(HCThemeImage(covers[cover]),p,0.38*(1-blend),zoom);
        if(blend>0) HCDrawImageFill(HCThemeImage(covers[(cover+1)%covers.count]),p,0.38*blend,zoom);
        CGContextRestoreGState(ctx);
        CGFloat pulse=0.18+0.08*sin(NSProcessInfo.processInfo.systemUptime*1.7);
        [[HCAccent() colorWithAlphaComponent:pulse] setStroke];
        UIBezierPath *accent=[UIBezierPath bezierPath];[accent moveToPoint:CGPointMake(p.origin.x+66,p.origin.y+50)];
        [accent addLineToPoint:CGPointMake(CGRectGetMaxX(p)-22,p.origin.y+50)];accent.lineWidth=1;[accent stroke];
        [[UIColor colorWithWhite:0.65 alpha:0.25] setStroke];outline.lineWidth=1;[outline stroke];
        CGRect side=CGRectMake(p.origin.x+10,p.origin.y+10,44,p.size.height-20);
        [[UIColor colorWithWhite:0.18 alpha:0.98] setFill];[[UIBezierPath bezierPathWithRoundedRect:side cornerRadius:25] fill];
        NSArray *symbols=@[@"house.fill",@"viewfinder",@"camera.fill",@"paintbrush.fill",@"square.stack.3d.up.fill",@"envelope.fill"];
        NSArray *groups=@[@5,@0,@1,@2,@3,@4];
        CGFloat step=MIN(46,(side.size.height-12)/6);
        for(NSInteger i=0;i<6;i++) {
            CGRect r=CGRectMake(side.origin.x+3,side.origin.y+6+i*step,38,step-3);
            BOOL selected=self.group==[groups[i] integerValue];
            if(selected) { [[UIColor colorWithWhite:0.9 alpha:0.12] setFill];[[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12] fill]; }
            UIImage *symbol=[[UIImage systemImageNamed:symbols[i]] imageWithTintColor:selected ? UIColor.whiteColor : UIColor.grayColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            [symbol drawInRect:CGRectMake(CGRectGetMidX(r)-11,CGRectGetMidY(r)-11,22,22)];
            [self target:[NSString stringWithFormat:@"tab:%@",groups[i]] rect:r];
        }
        HCText(@"HERO CONTROL",CGRectMake(p.origin.x+66,p.origin.y+14,p.size.width-130,20),15,UIColor.whiteColor,YES);
        HCText(@"BẢNG ĐIỀU KHIỂN",CGRectMake(p.origin.x+66,p.origin.y+34,p.size.width-130,14),10,UIColor.lightGrayColor,YES);
        CGRect close=CGRectMake(CGRectGetMaxX(p)-47,p.origin.y+9,34,32);
        HCText(@"×",CGRectInset(close,10,0),30,UIColor.whiteColor,NO);[self target:@"close" rect:close];
        CGRect c=[self contentRect];
        if(self.group==5) {
            BOOL wide=c.size.width>460;
            CGFloat leftWidth=wide ? c.size.width*0.54 : c.size.width;
            CGRect banner=CGRectMake(c.origin.x,c.origin.y,leftWidth,MIN(88,c.size.height*0.38));
            [self tile:banner title:@"SẴN SÀNG" subtitle:@"TỰ ĐỘNG LƯU CẤU HÌNH" image:130 action:@"tab:0"];
            CGFloat rowY=CGRectGetMaxY(banner)+12;
            NSArray *quick=@[@{@"title":@"HIỂN THỊ KẺ ĐỊCH",@"key":@"__ifxEnemyEspEnabledV1"},@{@"title":@"ESP ICON",@"key":@"DoroCheat.Reference.R1.Icon"},@{@"title":@"ESP MINIMAP",@"key":@"DoroCheat.Reference.R1.Map"}];
            for(NSInteger i=0;i<3;i++) {
                NSDictionary *q=quick[i];CGRect r=CGRectMake(c.origin.x,rowY+i*34,leftWidth,29);
                [[UIColor colorWithWhite:0.23 alpha:0.97] setFill];[[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12] fill];
                BOOL on=[self.settings[@"flags"][q[@"key"]] boolValue];
                HCText(q[@"title"],CGRectMake(r.origin.x+12,r.origin.y+8,r.size.width-65,18),11,UIColor.whiteColor,YES);
                HCText(on ? @"ON" : @"OFF",CGRectMake(CGRectGetMaxX(r)-44,r.origin.y+8,40,18),11,on ? HCAccent() : UIColor.grayColor,YES);
                [self target:[@"flag:" stringByAppendingString:q[@"key"]] rect:r];
            }
            if(wide) {
                CGFloat x=c.origin.x+leftWidth+14,tw=(c.size.width-leftWidth-24)/2,th=(c.size.height-12)/2;
                [self tile:CGRectMake(x,c.origin.y,tw,th) title:@"ESP" subtitle:@"ẢNH TƯỚNG / ID" image:156 action:@"tab:0"];
                [self tile:CGRectMake(x+tw+10,c.origin.y,tw,th) title:@"SKINS" subtitle:@"CHỌN TRANG PHỤC" image:118 action:@"tab:3"];
                [self tile:CGRectMake(x,c.origin.y+th+12,tw,th) title:@"CAMERA" subtitle:@"GÓC NHÌN" image:537 action:@"tab:1"];
                [self tile:CGRectMake(x+tw+10,c.origin.y+th+12,tw,th) title:@"REPORTS" subtitle:@"LỊCH SỬ TỐ CÁO" image:193 action:@"tab:4"];
            }
        } else if(self.group==1) {
            double scale=[self.settings[@"cameraScale"] doubleValue];
            HCText([NSString stringWithFormat:@"CAMERA  %.2f×",scale],CGRectMake(c.origin.x,c.origin.y,c.size.width,30),22,UIColor.whiteColor,YES);
            CGRect enable=CGRectMake(c.origin.x,c.origin.y+40,c.size.width,36);
            HCText([self.settings[@"cameraEnabled"] boolValue] ? @"CAMERA XA     ON" : @"CAMERA XA     OFF",enable,16,HCAccent(),YES);[self target:@"cameraEnabled" rect:enable];
            CGRect slider=CGRectMake(c.origin.x,c.origin.y+100,c.size.width,34);
            [[UIColor colorWithWhite:0.3 alpha:1] setFill];UIRectFill(CGRectMake(slider.origin.x,slider.origin.y+15,slider.size.width,4));
            CGFloat knob=slider.origin.x+(scale-1)/1.3*slider.size.width;
            [HCAccent() setFill];[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob-9,slider.origin.y+8,18,18)] fill];[self target:@"camera" rect:slider];
            HCText(HCCameraStatus[@"message"] ?: @"Bật camera và kiểm tra trong trận.",CGRectMake(c.origin.x,c.origin.y+155,c.size.width,75),12,UIColor.lightGrayColor,NO);
        } else if(self.group==4) {
            CGRect row=CGRectMake(c.origin.x,c.origin.y,c.size.width,40);
            HCText([self.settings[@"flags"][@"reports.enabled"] boolValue] ? @"TRUY VẤN TỐ CÁO: ON" : @"TRUY VẤN TỐ CÁO: OFF",row,16,HCAccent(),YES);
            [self target:@"flag:reports.enabled" rect:row];
            HCText(HCReportsStatus[@"message"] ?: @"Cài adapter để truy vấn lịch sử máy chủ.",CGRectMake(c.origin.x,c.origin.y+60,c.size.width,120),14,UIColor.whiteColor,NO);
        } else {
            NSMutableArray *features=[NSMutableArray array];
            for(NSDictionary *feature in HCFeatures()) if([feature[@"group"] integerValue]==self.group) [features addObject:feature];
            NSInteger columns=c.size.width>440 ? 2 : 1;
            CGFloat gap=10,rowHeight=MIN(46,(c.size.height-(self.group==0 ? 40 : 12))/MAX(1,ceil((double)features.count/columns)));
            CGFloat cellWidth=(c.size.width-gap*(columns-1))/columns;
            for(NSUInteger i=0;i<features.count;i++) {
                NSDictionary *feature=features[i];
                CGRect row=CGRectMake(c.origin.x+(i%columns)*(cellWidth+gap),c.origin.y+(i/columns)*rowHeight,cellWidth,rowHeight-6);
                [[UIColor colorWithWhite:0.23 alpha:0.95] setFill];[[UIBezierPath bezierPathWithRoundedRect:row cornerRadius:10] fill];
                BOOL on=[self.settings[@"flags"][feature[@"key"]] boolValue];
                HCText(feature[@"title"],CGRectMake(row.origin.x+10,row.origin.y+9,row.size.width-54,row.size.height),12,UIColor.whiteColor,NO);
                HCText(on ? @"ON" : @"OFF",CGRectMake(CGRectGetMaxX(row)-38,row.origin.y+9,34,22),10,on ? HCAccent() : UIColor.grayColor,YES);
                [self target:[@"flag:" stringByAppendingString:feature[@"key"]] rect:row];
            }
        }
        if(self.group==0) {
            CGRect adjust=CGRectMake(c.origin.x,CGRectGetMaxY(c)-29,c.size.width,26);
            HCText(@"↔  CHỈNH KHUNG MINIMAP",CGRectInset(adjust,4,4),11,HCAccent(),YES);
            [self target:@"minimap-edit" rect:adjust];
        }
        CGRect privacy=CGRectMake(p.origin.x+66,CGRectGetMaxY(p)-31,MIN(240,p.size.width-178),22);
        [[UIColor colorWithWhite:0.2 alpha:0.8] setFill];[[UIBezierPath bezierPathWithRoundedRect:privacy cornerRadius:7] fill];
        HCText(HCCaptureProtected ? @"TỰ ẨN QUAY/CHỤP: ON" : @"TỰ ẨN QUAY/CHỤP: OFF",CGRectInset(privacy,7,5),9,HCCaptureProtected ? HCAccent() : UIColor.lightGrayColor,YES);
        [self target:@"capture" rect:privacy];
        CGRect stop=CGRectMake(CGRectGetMaxX(p)-104,CGRectGetMaxY(p)-33,94,25);
        HCText(@"TẮT NÚT NỔI",CGRectInset(stop,4,3),10,UIColor.systemOrangeColor,YES);[self target:@"stop" rect:stop];
        CGContextRestoreGState(ctx);
    }
    if(_editingMinimap) {
        CGRect map=[self minimapRect];
        [[HCAccent() colorWithAlphaComponent:0.13] setFill];UIRectFill(map);
        UIBezierPath *edge=[UIBezierPath bezierPathWithRect:map];CGFloat dash[]={5,4};[edge setLineDash:dash count:2 phase:0];
        [HCAccent() setStroke];edge.lineWidth=1.5;[edge stroke];
        HCText(@"KÉO KHUNG ĐỂ DI CHUYỂN",CGRectMake(map.origin.x+7,CGRectGetMidY(map)-9,map.size.width-12,28),9,UIColor.whiteColor,YES);
        for(int i=0;i<2;i++) {
            CGRect button=[self minimapIconButton:i==1];
            [[UIColor colorWithWhite:0.15 alpha:0.95] setFill];[[UIBezierPath bezierPathWithRoundedRect:button cornerRadius:5] fill];
            HCText(i==0 ? @"−" : @"+",CGRectInset(button,7,3),15,UIColor.whiteColor,YES);
        }
        CGRect done=[self minimapDoneRect];[HCAccent() setFill];[[UIBezierPath bezierPathWithRoundedRect:done cornerRadius:6] fill];
        HCText(@"XONG",CGRectInset(done,9,5),10,UIColor.blackColor,YES);
        CGRect resize=[self minimapResizeRect];[HCAccent() setFill];[[UIBezierPath bezierPathWithRoundedRect:resize cornerRadius:6] fill];
        HCText(@"↘",CGRectInset(resize,5,3),18,UIColor.blackColor,YES);
    }
    CGRect bubble = [self bubbleRect];
    CGContextRef bubbleContext=UIGraphicsGetCurrentContext();CGContextSaveGState(bubbleContext);
    [[UIBezierPath bezierPathWithOvalInRect:bubble] addClip];
    HCDrawImageFill(HCThemeImage(@"app-background.jpg"),bubble,1,1);
    CGContextRestoreGState(bubbleContext);
    [HCAccent() setStroke];UIBezierPath *edge=[UIBezierPath bezierPathWithOvalInRect:bubble];edge.lineWidth=1.5;[edge stroke];
    if(HCMenuOpen) HCText(@"×",CGRectMake(bubble.origin.x+18,bubble.origin.y+12,25,30),24,UIColor.whiteColor,YES);
}
- (void)drawEsp {
    if ([self.settings[@"flags"][@"__ifxEnemyEspEnabledV1"] boolValue] ) {
        double now = NSProcessInfo.processInfo.systemUptime;
        if (!HCEspDrawWindow) HCEspDrawWindow = now;
        HCEspDraws++;
        if (now - HCEspDrawWindow >= 1) { HCEspDrawFPS = HCEspDraws / (now - HCEspDrawWindow); HCEspDraws = 0; HCEspDrawWindow = now; }
    } else { HCEspDrawFPS = 0; HCEspDraws = 0; HCEspDrawWindow = 0; }
    NSDictionary *flags = self.settings[@"flags"];

    if (HCLocked || ![flags[@"__ifxEnemyEspEnabledV1"] boolValue]) return;
    double now=NSProcessInfo.processInfo.systemUptime;
    double age=now-[HCEspStatus[@"sampleUptime"] doubleValue];
    if (!HCEspStatus[@"sampleUptime"] || age<0 || age>HC_ESP_HOLD_SECONDS) return;
    NSInteger pid=[HCEspStatus[@"pid"] integerValue];
    NSString *camera=HCEspStatus[@"nativeCamera"];
    if (pid!=_screenPID || !CGSizeEqualToSize(_screenSize,self.bounds.size) || ![_screenCamera isEqual:camera]) {
        memset(_screenStates,0,sizeof(_screenStates));_screenPID=pid;_screenSize=self.bounds.size;_screenCamera=[camera copy];
    }
    CGContextRef context=UIGraphicsGetCurrentContext();
    if (HCMenuOpen) {
        UIBezierPath *clip=[UIBezierPath bezierPathWithRect:self.bounds];
        [clip appendPath:[UIBezierPath bezierPathWithRect:[self panelRect]]];
        clip.usesEvenOddFillRule=YES;[clip addClip];
    }
    (void)context;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    UIColor *color = HCAccent();
    CGRect map=[self minimapRect];
    CGFloat mapSize=map.size.width;
    double extent=[self.settings[@"minimapWorldExtent"] doubleValue] ?: 60;
    BOOL rotated=[self.settings[@"minimapRotated"] boolValue];
    if ([flags[@"DoroCheat.Reference.R1.Map"] boolValue]) {
        [[UIColor colorWithWhite:0.12 alpha:0.18] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:map cornerRadius:4] fill];
        [[HCAccent() colorWithAlphaComponent:0.6] setStroke];
        [[UIBezierPath bezierPathWithRect:map] stroke];
    }
    for (NSDictionary *target in HCEspStatus[@"targets"]) {
        int32_t mapID=[target[@"heroID"] intValue];
        if ([flags[@"DoroCheat.Reference.R1.Map"] boolValue] && target[@"worldX"] && target[@"worldZ"]) {
            double u=0,v=0;
            if (HCMinimapProject([target[@"worldX"] doubleValue],[target[@"worldZ"] doubleValue],extent,rotated,&u,&v)) {
                CGFloat iconSize=HCClamp([self.settings[@"minimapIconSize"] doubleValue] ?: 20,8,40);
                CGFloat margin=iconSize/2+3;
                CGRect icon=CGRectMake(map.origin.x+margin+u*(mapSize-2*margin)-iconSize/2,
                    map.origin.y+margin+v*(mapSize-2*margin)-iconSize/2,iconSize,iconSize);
                HCDrawHeroIcon(mapID,icon);
                HCDrawHealthRing(target,CGRectInset(icon,-1.5,-1.5),YES,1.2);
            }
        }
        if (![target[@"onScreen"] boolValue]) continue;
        uint32_t objectID=[target[@"objectID"] unsignedIntValue];int32_t heroID=[target[@"heroID"] intValue];
        HCEspScreenState *slot=NULL;
        for(int i=0;i<HC_ESP_MAX_TARGETS;i++) if(_screenStates[i].valid && _screenStates[i].objectID==objectID && _screenStates[i].heroID==heroID) { slot=&_screenStates[i];break; }
        if(!slot) {
            slot=&_screenStates[0];
            for(int i=0;i<HC_ESP_MAX_TARGETS;i++) {
                if(!_screenStates[i].valid) { slot=&_screenStates[i];break; }
                if(_screenStates[i].time<slot->time) slot=&_screenStates[i];
            }
        }
        if(!HCEspSmooth(slot,objectID,heroID,now,[target[@"x"] floatValue],[target[@"headY"] floatValue],[target[@"feetY"] floatValue])) continue;
        CGFloat x=slot->x*w,top=slot->headY*h,bottom=slot->feetY*h,height=bottom-top;
        if (!isfinite(height) || height < 4 || height > h) continue;
        CGFloat widthScale=HCClamp([self.settings[@"espBoxWidthScale"] doubleValue] ?: 1,0.5,3);
        CGFloat heightScale=HCClamp([self.settings[@"espBoxHeightScale"] doubleValue] ?: 1,0.5,3);
        CGFloat boxWidth=height*0.48*widthScale,boxHeight=height*heightScale;
        CGRect box = CGRectMake(x-boxWidth/2,(top+bottom)/2-boxHeight/2,boxWidth,boxHeight);
        BOOL hpEnabled=[flags[@"DoroCheat.Reference.R1.HP"] boolValue];
        double diameter=HCHeroBadgeSized(box.size.width,box.size.height,HCClamp([self.settings[@"espIconSize"] doubleValue] ?: 32,12,64));
        if (diameter>0 && ([flags[@"DoroCheat.Reference.R1.Icon"] boolValue] || hpEnabled)) {
            CGRect outer=CGRectMake(CGRectGetMidX(box)-diameter/2,CGRectGetMidY(box)-diameter/2,diameter,diameter);
            HCDrawHeroIcon(heroID,CGRectInset(outer,3.2,3.2));
            if(hpEnabled) HCDrawHealthRing(target,CGRectInset(outer,1.1,1.1),NO,2.2);
        }
        if ([flags[@"HeroControl.ESP.HeroID"] boolValue] && heroID>0) {
            NSString *label=[NSString stringWithFormat:@"ID: %d",heroID];
            CGRect badge=CGRectMake(x-45,MAX(0,CGRectGetMinY(box)-24),90,20);
            [[UIColor.blackColor colorWithAlphaComponent:0.8] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:badge cornerRadius:4] fill];
            HCText(label,CGRectInset(badge,4,1),13,UIColor.whiteColor,YES);
        }
        [color setStroke];
        if ([flags[@"DoroCheat.Reference.R1.Box"] boolValue]) {
            UIBezierPath *path = [UIBezierPath bezierPathWithRect:box]; path.lineWidth = 1.5; [path stroke];
        }
        if ([flags[@"DoroCheat.Reference.R1.Check"] boolValue]) {
            NSMutableArray *texts = [NSMutableArray array];
            for (NSNumber *cd in target[@"cooldowns"]) [texts addObject:cd.intValue < 0 ? @"?" : cd.stringValue];
            NSString *text = texts.count == 3 ? [NSString stringWithFormat:@"S1:%@  S2:%@  S3:%@", texts[0], texts[1], texts[2]] : @"Chưa đọc CD";
            HCText(text, CGRectMake(x - 75, CGRectGetMaxY(box) + 3, 150, 18), 10, color, YES);
        }
    }
}
- (void)toggleMenu {
    HCMenuOpen = !HCMenuOpen;
    self.activeTarget = nil; self.pointer = -1;
    if (HCMenuOpen) { _editingMinimap=NO;_menuOpenedAt=NSProcessInfo.processInfo.systemUptime;[self reloadSettings]; }
    [self setNeedsDisplay]; HCState();
}
- (void)cameraAt:(CGPoint)point {
    if (!self.settings) return;
    CGRect c = [self contentRect];
    self.settings[@"cameraScale"] = @(1 + HCClamp((point.x - c.origin.x) / c.size.width, 0, 1) * 1.3);
    [self setNeedsDisplay];
}
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer {
    if (HCLocked || self.hidden) return;
    if (phase == UITouchPhaseBegan) {
        if (self.pointer >= 0) return;
        NSString *target = [self targetAt:point];
        if (!target) return;
        self.pointer = pointer; self.activeTarget = target;
        self.startPoint = point; self.startBubble = self.bubble; self.dragged = NO;
        if ([target isEqual:@"camera"]) { [self reloadSettings]; [self cameraAt:point]; }
        if ([target isEqual:@"minimap-move"] || [target isEqual:@"minimap-resize"]) { [self reloadSettings];_startMapRect=[self minimapRect]; }
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
        else if ([self.activeTarget isEqual:@"minimap-move"] || [self.activeTarget isEqual:@"minimap-resize"]) [self minimapAt:point];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        NSString *target = self.activeTarget;
        BOOL mapGesture=[target isEqual:@"minimap-move"] || [target isEqual:@"minimap-resize"];
        if(phase==UITouchPhaseEnded && mapGesture) [self minimapAt:point];
        self.activeTarget = nil; self.pointer = -1;
        if (phase == UITouchPhaseCancelled) { [self reloadSettings]; return; }
        if (mapGesture) { [self saveSettings];return; }
        if ([target isEqual:@"camera"]) { [self cameraAt:point]; [self saveSettings]; return; }
        if (self.dragged || ![[self targetAt:point] isEqual:target]) return;
        if ([target isEqual:@"bubble"] || [target isEqual:@"close"]) [self toggleMenu];
        else if ([target isEqual:@"minimap-edit"]) {
            _editingMinimap=YES;HCMenuOpen=NO;[self setNeedsDisplay];
        }
        else if ([target isEqual:@"minimap-icon-smaller"] || [target isEqual:@"minimap-icon-larger"]) {
            [self reloadSettings];
            CGFloat size=[self.settings[@"minimapIconSize"] doubleValue] ?: 20;
            self.settings[@"minimapIconSize"]=@(HCClamp(size+([target isEqual:@"minimap-icon-larger"] ? 2 : -2),8,40));
            [self saveSettings];[self refreshEspSurface];
        }
        else if ([target isEqual:@"minimap-done"]) { _editingMinimap=NO;[self setNeedsDisplay]; }
        else if ([target isEqual:@"stop"]) HCStop(@"Đã tắt nút nổi. Mở Hero Control để bật lại.", NO);
        else if ([target hasPrefix:@"tab:"]) { self.group = [[target substringFromIndex:4] integerValue]; [self setNeedsDisplay]; }
        else if ([target isEqual:@"capture"]) {
            [self reloadSettings];
            if(self.settings) { self.settings[@"espCaptureProtected"]=[self.settings[@"espCaptureProtected"] isEqual:@NO] ? @YES : @NO;[self saveSettings];[self refreshEspSurface]; }
        }
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
- (BOOL)_isSecure { return HCCaptureProtected; }
- (BOOL)_shouldCreateContextAsSecure { return HCCaptureProtected; }
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
    HCLocked = locked; [HCCanvas refreshEspSurface];
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
    if (!HCLocked) [HCCanvas refreshEspSurface];
}
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    HCStage(@"delegate_launch");
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        @autoreleasepool {
            for(NSString *name in @[@"app-background.jpg",@"nakroth-loi-quang.png",@"nakroth-thu-nguyen.jpg",@"nakroth-quy-thuong.jpg"]) (void)HCThemeImage(name);
        }
    });
    HCOverlayController *controller = [HCOverlayController new];
    HCCanvas = [[HCOverlayCanvas alloc] initWithFrame:UIScreen.mainScreen.bounds];
    HCOverlayRootView=[[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    HCOverlayRootView.backgroundColor=UIColor.clearColor;
    HCOverlaySecureField=[[UITextField alloc] initWithFrame:HCOverlayRootView.bounds];
    HCOverlaySecureField.backgroundColor=UIColor.clearColor;HCOverlaySecureField.textColor=UIColor.clearColor;
    HCOverlaySecureField.userInteractionEnabled=NO;HCOverlaySecureField.text=@" ";
    // Trigger UIKit to configure the canvas after the secure state changes.
    HCOverlaySecureField.secureTextEntry=NO;HCOverlaySecureField.secureTextEntry=YES;
    [HCOverlayRootView addSubview:HCOverlaySecureField];
    [HCOverlayRootView addSubview:HCCanvas];
    controller.view = HCOverlayRootView;
    [HCCanvas refreshEspSurface];
    HCWindow = [[HCOverlayWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.window = HCWindow;
    HCWindow.backgroundColor = UIColor.clearColor;
    HCWindow.rootViewController = controller;
    HCWindow.windowLevel = 10000010.0;
    [HCWindow makeKeyAndVisible];
    HCConfiguredCaptureMode=-1;[HCCanvas refreshEspSurface];
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
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        (void)notification;[HCCanvas refreshEspSurface];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        (void)notification;[HCCanvas cancelInteraction];
    }];
    HCUpdateLock(); HCState();
    HCCamera = [[HCCameraEngine alloc] initWithProfile:HCProfile report:^(NSDictionary *report) {
        HCCameraStatus = report;
        [HCCanvas setNeedsDisplay];
    } espReport:^(NSDictionary *report) {
        HCEspStatus = report;
        // Preserve the last actor sample for export after switching away from
        // the game. It is historical evidence, never a frame to draw now.
        if ([report[@"listCount"] integerValue] > 0) HCEspLastSample = report;
    } reportsReport:^(NSDictionary *report) {
        HCReportsStatus = report;
        if (HCMenuOpen && HCCanvas.group == 4) [HCCanvas setNeedsDisplay];
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
