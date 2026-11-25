#include "../Protection/ProtectedStrings.h"
#include "InputCapture.h"
#import "ReportAnalysis.h"
#include "ReportScroll.h"
// Standalone HUD bootstrap/window-hosting approach adapted from TrollSpeed
// (c) 2023 Lessica, MIT. See ThirdParty/TrollSpeed-LICENSE.txt and NOTICE.txt.
// This process owns its window; game access is isolated in CameraEngine.
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/runtime.h>
#import "OverlayCommon.h"
#import "HCFeatures.h"
#import "SettingsStore.h"
#include "OverlayLock.h"
#include "CapturePolicy.h"
#include "DrawerMotion.h"
#import "ReportNotice.h"
#include "../BackendSDK/EspPresentation.h"
#include "../BackendSDK/CameraControl.h"
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
        @"settingsError": HCSettingsError ?: @"", @"appVersion": @"0.17.2", @"generation": @HC_RUNTIME_GENERATION, @"stage": HCStartupStage};
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
@property(nonatomic) NSTimeInterval cameraLastSave;
@property(nonatomic) BOOL pendingSettingsSave;
@property(nonatomic,copy) NSString *settingsNotice;
- (void)reloadSettings;
- (void)drawEsp;
- (void)refreshEspSurface;
- (void)cancelInteraction;
@property(nonatomic,strong) HCEspDrawingView *espView;
- (void)toggleMenu;
- (void)welcome;
- (void)receiveReports:(NSDictionary *)report;
- (void)discardReportLayout;
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer;
@end

static UIColor *HCAccent(void) { return [UIColor colorWithRed:0.39 green:0.88 blue:0.78 alpha:1]; }
static UIColor *HCMenuAccent(void) { return [UIColor colorWithRed:0.02 green:0.43 blue:0.36 alpha:1]; }
static NSArray *HCCalibrationFields(void) {
    static NSArray *fields;static dispatch_once_t once;dispatch_once(&once,^{ fields=@[
        @{@"key":@"espCombinedScale",@"title":@"Cỡ box + icon",@"min":@0.5,@"max":@4,@"step":@0.05,@"default":@1},
        @{@"key":@"minimapX",@"title":@"Khung ngang",@"min":@0,@"max":@1,@"step":@0.005,@"default":@0.015},
        @{@"key":@"minimapY",@"title":@"Khung dọc",@"min":@0,@"max":@1,@"step":@0.005,@"default":@0.02},
        @{@"key":@"minimapSize",@"title":@"Cỡ khung",@"min":@80,@"max":@240,@"step":@1,@"default":@150},
        @{@"key":@"minimapIconSize",@"title":@"Cỡ icon map",@"min":@8,@"max":@40,@"step":@1,@"default":@20},
        @{@"key":@"minimapWorldExtent",@"title":@"Phạm vi thế giới",@"min":@30,@"max":@200,@"step":@1,@"default":@60},
        @{@"key":@"minimapCenterX",@"title":@"Tâm thế giới X",@"min":@-200,@"max":@200,@"step":@1,@"default":@0},
        @{@"key":@"minimapCenterZ",@"title":@"Tâm thế giới Z",@"min":@-200,@"max":@200,@"step":@1,@"default":@0},
        @{@"key":@"minimapAngle",@"title":@"Góc bản đồ",@"min":@-180,@"max":@180,@"step":@1,@"default":@0},
        @{@"key":@"espBoxWidthScale",@"title":@"Rộng box",@"min":@0.5,@"max":@3,@"step":@0.05,@"default":@1},
        @{@"key":@"espBoxHeightScale",@"title":@"Cao box",@"min":@0.5,@"max":@3,@"step":@0.05,@"default":@1},
        @{@"key":@"espIconSize",@"title":@"Cỡ icon ESP",@"min":@12,@"max":@64,@"step":@1,@"default":@32},
        @{@"key":@"espReadHz",@"title":@"Nhịp đọc ESP",@"min":@60,@"max":@120,@"step":@60,@"default":@60},
]; });return fields;
}
static NSArray *HCFilteredReports(NSDictionary *status,NSString *period) {
    NSArray *records=[status[@"records"] isKindOfClass:NSArray.class] ? status[@"records"] : @[];
    if([period isEqual:@"all"] || !period) return records;
    NSCalendar *calendar=[[NSCalendar alloc] initWithCalendarIdentifier:NSCalendarIdentifierISO8601];
    calendar.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:25200];
    NSDate *now=[status[@"serverTime"] doubleValue]>0 ? [NSDate dateWithTimeIntervalSince1970:[status[@"serverTime"] doubleValue]] : NSDate.date;
    NSDate *periodStart=nil;NSTimeInterval periodDuration=0;
    NSCalendarUnit unit=[period isEqual:@"week"] ? NSCalendarUnitWeekOfYear : NSCalendarUnitMonth;
    if(![calendar rangeOfUnit:unit startDate:&periodStart interval:&periodDuration forDate:now] || !periodStart) return @[];
    NSDateFormatter *formatter=[NSDateFormatter new];formatter.locale=[NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat=@"yyyy-MM-dd HH:mm:ss XXXXX";
    NSISO8601DateFormatter *iso=[NSISO8601DateFormatter new];
    NSMutableArray *result=[NSMutableArray array];
    for(NSDictionary *record in records) {
        if(![record isKindOfClass:NSDictionary.class]) continue;
        NSDate *date=[record[@"eventTime"] doubleValue]>0 ? [NSDate dateWithTimeIntervalSince1970:[record[@"eventTime"] doubleValue]] :
            ([formatter dateFromString:record[@"time"] ?: @""] ?: [iso dateFromString:record[@"time"] ?: @""]);
        if(date && [date compare:periodStart]!=NSOrderedAscending && [date compare:now]!=NSOrderedDescending) [result addObject:record];
    }
    return result;
}
static void HCText(NSString *text, CGRect rect, CGFloat size, UIColor *color, BOOL bold) {
    (void)bold;
    [text drawInRect:rect withAttributes:@{NSFontAttributeName: [UIFont boldSystemFontOfSize:size],
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
    NSInteger _calibrationPage;
    NSArray<NSDictionary *> *_reportLayout;
    NSDictionary *_reportLayoutStatus,*_reportObservedStatus;
    NSString *_reportLayoutPeriod;
    double _reportLayoutWidth,_reportContentHeight,_reportScroll,_reportDragStart;
    double _reportVelocity,_reportLastY,_reportLastTouch,_reportTick;
    CGRect _reportViewport;
    BOOL _editingMinimap;
    CGRect _startMapRect;
    double _nextMenuRedraw, _emptyEspSince, _welcomeUntil;
    double _menuProgress,_menuMotionFrom,_menuMotionTo,_menuMotionStarted;
    double _reportNoticeStarted, _lastPointerEvent;
    BOOL _reportNoticeWasVisible, _welcomeWasVisible, _reportNoticeBusy;
    NSDictionary *_pendingNoticeReport;
    dispatch_queue_t _noticeQueue;
    NSString *_reportNoticeReason;
    NSUInteger _reportNoticeCount;
    HCReportNoticeTracker *_reportNoticeTracker;
    BOOL _imagesPurged;
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
        _noticeQueue=dispatch_queue_create("local.herocontrol.notices",DISPATCH_QUEUE_SERIAL);
        _reportNoticeTracker=[[HCReportNoticeTracker alloc] initWithPath:[HCDirectory stringByAppendingPathComponent:@"report-notice-seen.json"]];
        [self reloadSettings];
        _espView=[[HCEspDrawingView alloc] initWithFrame:self.bounds];
        [self addSubview:_espView];
        _espView.painter=self;_espView.clearsContextBeforeDrawing=YES;_espView.layer.shouldRasterize=NO;_espView.opaque=NO;_espView.backgroundColor=UIColor.clearColor;_espView.userInteractionEnabled=NO;
        [self refreshEspSurface];
    }
    return self;
}
- (void)updateMenuMotion:(double)now {
    _menuProgress=HCMotionProgress(_menuMotionFrom,_menuMotionTo,now-_menuMotionStarted,0.28);
    double target=HCMenuOpen ? 1 : 0;
    if(target!=_menuMotionTo) {
        _menuMotionFrom=_menuProgress;_menuMotionTo=target;_menuMotionStarted=now;
    }
}
- (HCDrawerGeometry)drawer:(CGRect)destination progress:(double)progress {
    CGRect bubble=[self bubbleRect];
    return HCDrawerFromAnchor((HCMotionRect){bubble.origin.x,bubble.origin.y,bubble.size.width,bubble.size.height},
        (HCMotionRect){destination.origin.x,destination.origin.y,destination.size.width,destination.size.height},progress);
}
- (CGRect)reportNoticeRect {
    CGRect bubble=[self bubbleRect];CGFloat width=MIN(344,self.bounds.size.width-32),height=96;
    CGFloat x=CGRectGetMidX(bubble)<self.bounds.size.width/2 ? CGRectGetMaxX(bubble)+10 : bubble.origin.x-width-10;
    x=MAX(16,MIN(self.bounds.size.width-width-16,x));
    CGFloat y=MAX(MAX(20,self.safeAreaInsets.top),MIN(self.bounds.size.height-height-20,CGRectGetMidY(bubble)-height/2));
    return CGRectMake(x,y,width,height);
}
- (BOOL)menuInteractive { return HCMenuOpen && _menuProgress>=0.999; }
- (void)receiveReports:(NSDictionary *)report {
    HCReportsStatus=report;
    if(_reportNoticeBusy) { _pendingNoticeReport=report;return; }
    _reportNoticeBusy=YES;
    BOOL enabled=[self.settings[@"flags"][@"reports.enabled"] boolValue] && ![report[@"code"] isEqual:@"reports_disabled"];
    dispatch_async(_noticeQueue,^{ @autoreleasepool {
        NSArray *arrivals=[self->_reportNoticeTracker observe:report enabled:enabled now:NSDate.date.timeIntervalSince1970];
        dispatch_async(dispatch_get_main_queue(),^{
            if(arrivals.count && [self.settings[@"flags"][@"reports.enabled"] boolValue] && [HCReportsStatus[@"accountID"] isEqual:report[@"accountID"]]) {
                NSDictionary *latest=arrivals.lastObject;
                NSString *reason=[latest[@"reason"] isKindOfClass:NSString.class] ? latest[@"reason"] : @"Máy chủ chưa cung cấp lý do chi tiết";
                self->_reportNoticeReason=[reason substringToIndex:MIN((NSUInteger)240,reason.length)];
                self->_reportNoticeCount=arrivals.count;self->_reportNoticeStarted=NSProcessInfo.processInfo.systemUptime;
            }
            if(arrivals.count || (HCMenuOpen && self.group==4)) [self setNeedsDisplay];
            self->_reportNoticeBusy=NO;
            NSDictionary *pending=self->_pendingNoticeReport;self->_pendingNoticeReport=nil;
            if(pending) [self receiveReports:pending];
        });
    }});
}
- (void)refreshEspSurface {
    HCCaptureProtected=![self.settings[@"espCaptureProtected"] isEqual:@NO];
    HCCaptureActive=UIScreen.mainScreen.isCaptured;
    self.espView.frame=self.bounds;
    BOOL wasHidden=self.hidden;
    HCRefreshCaptureHost(self,self.espView);
    if(self.hidden && !wasHidden) {
        [self cancelInteraction];HCPurgeHeroImages();HCEspLastSample=nil;
        memset(_screenStates,0,sizeof(_screenStates));_imagesPurged=YES;
    }
    self.espView.hidden=HCLocked;
    if(self.hidden) { HCEspDrawFPS=0;HCEspDraws=0;HCEspDrawWindow=0; }
    [self.espView setNeedsDisplay];
    double now=NSProcessInfo.processInfo.systemUptime;
    if(self.pointer>=0 && now-_lastPointerEvent>6) [self cancelInteraction];
    BOOL reportMoving=NO;
    if(HCMenuOpen && self.group==4 && self.pointer<0 && fabs(_reportVelocity)>0) {
        HCReportScrollStep step=HCReportScrollAdvance(_reportScroll,_reportVelocity,now-_reportTick,_reportContentHeight,_reportViewport.size.height);
        reportMoving=step.offset!=_reportScroll;_reportScroll=step.offset;_reportVelocity=step.velocity;_reportTick=now;
    } else if(!HCMenuOpen || self.group!=4) _reportVelocity=0;
    BOOL reportStopped=reportMoving && _reportVelocity==0;
    double previous=_menuProgress;[self updateMenuMotion:now];
    BOOL notice=_reportNoticeStarted>0 && now-_reportNoticeStarted<4;
    BOOL welcome=now<_welcomeUntil;
    BOOL repaint=reportMoving || previous!=_menuProgress || fabs(_menuProgress-_menuMotionTo)>0.0001 || (notice && HCReportNoticeProgress(now-_reportNoticeStarted)<1) || (_reportNoticeWasVisible && !notice) || (_welcomeWasVisible && !welcome);
    BOOL clearWelcome=_welcomeWasVisible && !welcome;
    _welcomeWasVisible=welcome;
    BOOL clearNotice=_reportNoticeWasVisible && !notice;
    BOOL clearMenu=previous>0 && _menuProgress==0;
    BOOL finishedMotion=previous!=_menuProgress && _menuProgress==_menuMotionTo;
    if(clearMenu) [self discardReportLayout];
    _reportNoticeWasVisible=notice;
    if(_reportNoticeStarted>0 && now-_reportNoticeStarted>=4) {
        _reportNoticeStarted=0;_reportNoticeReason=nil;_reportNoticeCount=0;
    }
    BOOL moving=reportMoving || fabs(_menuProgress-_menuMotionTo)>0.0001 || (notice && HCReportNoticeProgress(now-_reportNoticeStarted)<1);
    if(!self.hidden && repaint && (clearNotice || clearMenu || clearWelcome || finishedMotion || reportStopped || now>=_nextMenuRedraw)) {
        _reportNoticeWasVisible=notice;
        _nextMenuRedraw=now+(moving ? 1.0/60 : 0.05);[self setNeedsDisplay];
    }
}
- (void)cancelInteraction {
    _reportVelocity=0;
    BOOL editing=self.activeTarget!=nil;
    self.activeTarget=nil;self.pointer=-1;self.dragged=NO;
    if(editing) [self reloadSettings];
}
- (void)reloadSettings {
    if(self.pendingSettingsSave) { [self saveSettings];if(self.pendingSettingsSave) return; }
    NSDictionary *previousSettings=self.settings;
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
            HCSettingsError = @"Cấu hình sai kiểu dữ liệu. Mở DORO-CHEAT để kiểm tra.";
            self.settings = nil; [self setNeedsDisplay]; return;
        }
        self.settings = [settings mutableCopy];
        self.settings[@"flags"] = [settings[@"flags"] mutableCopy];
        self.baseSettings = [settings copy];
        HCSettingsError = nil;
    } else {
        HCSettingsError = @"Không đọc được cấu hình. Mở lại DORO-CHEAT để kiểm tra.";
        // Do not replace a corrupt profile with invented defaults.
        self.settings = nil;
    }
    if(![previousSettings isEqual:self.settings]) [self setNeedsDisplay];
}
- (void)saveSettings {
    self.pendingSettingsSave=YES;
    if (!self.settings || !HCOverlayPathsValid(HCDirectory, HCProfile)) {
        HCSettingsError = @"Không lưu được: đường dẫn/cấu hình không hợp lệ.";self.pendingSettingsSave=NO; return;
    }
    NSString *lockPath=[HCProfile stringByAppendingString:@".edit-lock"];
    int editLock=open(lockPath.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    struct stat lockInfo={0};
    if (editLock<0 || fstat(editLock,&lockInfo) || !S_ISREG(lockInfo.st_mode) || lockInfo.st_uid!=501 || flock(editLock,LOCK_EX|LOCK_NB)) {
        if (editLock>=0) close(editLock);
        HCSettingsError=@"Chưa lấy được khóa chỉnh cấu hình. Thử lại trong DORO-CHEAT.";return;
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
    [mergedFlags removeObjectsForKeys:@[@"DoroCheat.Style.Banner",@"DoroCheat.Style.Buttons",@"DoroCheat.Style.Skin",@"DoroCheat.Style.BeforeMatch",@"DoroCheat.Style.LiveChange"]];
    merged[@"selectedSkins"]=@{};
    self.settings=merged;
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"schemaVersion": @1, @"settings": self.settings, @"revision": NSUUID.UUID.UUIDString}
        options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&error];
    if (!data || ![data writeToFile:HCProfile options:NSDataWritingAtomic error:&error]) {
        HCSettingsError = error.localizedDescription ?: @"Không ghi được cấu hình.";
    } else {
        chmod(HCProfile.fileSystemRepresentation, 0644);
        chown(HCProfile.fileSystemRepresentation, 501, 501);
        HCSettingsError = nil;self.pendingSettingsSave=NO;
        NSMutableDictionary *baseline=[self.settings mutableCopy];
        baseline[@"flags"]=[self.settings[@"flags"] copy];self.baseSettings=baseline;
    }
    flock(editLock,LOCK_UN);close(editLock);
    HCState(); [self setNeedsDisplay];
}
- (CGRect)bubbleRect { return CGRectMake(self.bubble.x - 26, self.bubble.y - 26, 52, 52); }
- (CGRect)panelRect {
    BOOL landscape=self.bounds.size.width>self.bounds.size.height;
    CGFloat width=landscape ? MIN(680,self.bounds.size.width*0.80) : MIN(376,self.bounds.size.width-32);
    CGFloat height=landscape ? MIN(350,self.bounds.size.height*0.84) : MIN(460,self.bounds.size.height*0.74);
    return CGRectMake((self.bounds.size.width-width)/2,(self.bounds.size.height-height)/2,width,height);
}
- (CGRect)contentRect {
    CGRect p=[self panelRect];BOOL function=self.group>=1 && self.group<=3;
    CGFloat reserve=function && p.size.width>500 ? 194 : 0;
    CGFloat banner=function && p.size.width<=500 && p.size.height>=400 ? 100 : 0;
    return CGRectMake(p.origin.x+66,p.origin.y+62+banner,p.size.width-82-reserve,p.size.height-104-banner);
}
- (void)discardReportLayout {
    _reportLayout=nil;_reportLayoutStatus=nil;_reportObservedStatus=nil;
}
- (void)prepareReportLayout:(CGFloat)width {
    NSString *period=self.settings[@"reportsPeriod"] ?: @"all";
    if(_reportLayout && width==_reportLayoutWidth && [_reportLayoutPeriod isEqual:period] &&
        (self.activeTarget && [self.activeTarget isEqual:@"reports-scroll"])) return;
    BOOL sameLayout=_reportLayout && width==_reportLayoutWidth && [_reportLayoutPeriod isEqual:period];
    if(sameLayout && _reportObservedStatus==HCReportsStatus) return;
    _reportObservedStatus=HCReportsStatus;
    NSMutableDictionary *visible=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"message",@"queryStatus",@"candidateCount",@"sentRequestCount",@"receivedResponseCount",@"accountID",@"recordsTruncated",@"records"])
        if(HCReportsStatus[key]) visible[key]=HCReportsStatus[key];
    if(![period isEqual:@"all"]) {
        double stamp=[HCReportsStatus[@"serverTime"] doubleValue] ?: NSDate.date.timeIntervalSince1970;
        visible[@"filterDay"]=@((long long)((stamp+25200)/86400));
    }
    if(sameLayout && [_reportLayoutStatus isEqual:visible]) return;
    _reportLayoutStatus=visible;_reportLayoutPeriod=period;_reportLayoutWidth=width;
    NSArray *blocks=HCReportAnalysisBlocks(HCReportsStatus,HCFilteredReports(HCReportsStatus,period));
    NSMutableArray *layout=[NSMutableArray arrayWithCapacity:blocks.count];CGFloat y=8;
    NSDictionary *attributes=@{NSFontAttributeName:[UIFont boldSystemFontOfSize:11]};
    for(NSDictionary *block in blocks) {
        CGRect text=[block[@"text"] boundingRectWithSize:CGSizeMake(MAX(40,width-32),CGFLOAT_MAX)
            options:NSStringDrawingUsesLineFragmentOrigin|NSStringDrawingUsesFontLeading attributes:attributes context:nil];
        CGFloat height=ceil(text.size.height)+42;
        NSMutableDictionary *row=[block mutableCopy];row[@"y"]=@(y);row[@"height"]=@(height);
        [layout addObject:row];y+=height+8;
    }
    _reportLayout=layout;_reportContentHeight=y;
    _reportScroll=HCReportScrollClamp(_reportScroll,y,_reportViewport.size.height);
}
- (void)drawReportTable:(CGRect)c {
    BOOL enabled=[self.settings[@"flags"][@"reports.enabled"] boolValue];
    CGRect toggle=CGRectMake(c.origin.x,c.origin.y,c.size.width-86,24);
    HCText(enabled ? @"CHECK TỐ CÁO • ON" : @"CHECK TỐ CÁO • OFF",toggle,11,HCMenuAccent(),YES);
    [self target:@"flag:reports.enabled" rect:toggle];
    CGRect retry=CGRectMake(CGRectGetMaxX(c)-78,c.origin.y,78,24);
    HCText(@"↻ LÀM MỚI",retry,10,HCMenuAccent(),YES);[self target:@"reports-refresh" rect:retry];
    NSArray *periods=@[@"all",@"week",@"month"],*titles=@[@"TẤT CẢ",@"TUẦN NÀY",@"THÁNG NÀY"];
    NSString *period=self.settings[@"reportsPeriod"] ?: @"all";
    for(NSInteger i=0;i<3;i++) {
        CGRect filter=CGRectMake(c.origin.x+i*c.size.width/3,c.origin.y+27,c.size.width/3-3,24);
        [([period isEqual:periods[i]] ? [UIColor colorWithRed:0.84 green:0.95 blue:0.92 alpha:1] : [UIColor colorWithWhite:0.94 alpha:1]) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:filter cornerRadius:6] fill];
        HCText(titles[i],CGRectInset(filter,5,6),9,UIColor.blackColor,YES);[self target:[@"period:" stringByAppendingString:periods[i]] rect:filter];
    }
    _reportViewport=CGRectMake(c.origin.x,c.origin.y+58,c.size.width,MAX(40,c.size.height-58));
    [self prepareReportLayout:_reportViewport.size.width];
    _reportScroll=HCReportScrollClamp(_reportScroll,_reportContentHeight,_reportViewport.size.height);
    CGContextRef context=UIGraphicsGetCurrentContext();CGContextSaveGState(context);
    [[UIBezierPath bezierPathWithRoundedRect:_reportViewport cornerRadius:9] addClip];
    [[UIColor colorWithWhite:0.93 alpha:1] setFill];UIRectFill(_reportViewport);
    // Binary search skips offscreen rows; no subviews or images per receipt.
    NSUInteger low=0,high=_reportLayout.count;
    while(low<high) { NSUInteger mid=low+(high-low)/2;NSDictionary *row=_reportLayout[mid];
        if([row[@"y"] doubleValue]+[row[@"height"] doubleValue]<_reportScroll) low=mid+1;else high=mid; }
    for(NSUInteger i=low;i<_reportLayout.count;i++) {
        NSDictionary *row=_reportLayout[i];CGFloat y=[row[@"y"] doubleValue]-_reportScroll;
        if(y>_reportViewport.size.height) break;
        CGRect card=CGRectMake(_reportViewport.origin.x+5,_reportViewport.origin.y+y,_reportViewport.size.width-10,[row[@"height"] doubleValue]);
        [([row[@"detail"] boolValue] ? UIColor.whiteColor : [UIColor colorWithRed:0.94 green:0.98 blue:0.97 alpha:1]) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:card cornerRadius:7] fill];
        HCText(row[@"title"],CGRectMake(card.origin.x+10,card.origin.y+8,card.size.width-22,17),10,HCMenuAccent(),YES);
        HCText(row[@"text"],CGRectMake(card.origin.x+10,card.origin.y+28,card.size.width-22,card.size.height-34),11,UIColor.blackColor,YES);
    }
    if(_reportContentHeight>_reportViewport.size.height) {
        CGFloat h=MAX(20,_reportViewport.size.height*_reportViewport.size.height/_reportContentHeight);
        CGFloat y=_reportViewport.origin.y+(_reportViewport.size.height-h)*_reportScroll/(_reportContentHeight-_reportViewport.size.height);
        [[HCMenuAccent() colorWithAlphaComponent:0.7] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(CGRectGetMaxX(_reportViewport)-4,y,3,h) cornerRadius:1.5] fill];
    }
    CGContextRestoreGState(context);[self target:@"reports-scroll" rect:_reportViewport];
}
- (void)tile:(CGRect)rect title:(NSString *)title subtitle:(NSString *)subtitle image:(int32_t)hero action:(NSString *)action {
    NSString *cover=hero==130 ? @"violet-sss.png" : hero==156 ? @"butterfly-phoenix-sss.jpg" : hero==537 ? @"liliana-magic-sss.jpg" : hero==118 ? @"telannas-newyear-sss.jpg" : @"telannas-dimension-sss.jpg";
    HCDrawSkinCard(rect,cover);
    NSString *glyph=hero==130 || hero==156 ? @"viewfinder" : hero==118 ? @"slider.horizontal.3" : hero==537 ? @"camera.fill" : @"envelope.fill";
    UIImage *symbol=[[UIImage systemImageNamed:glyph] imageWithTintColor:[HCMenuAccent() colorWithAlphaComponent:0.22] renderingMode:UIImageRenderingModeAlwaysOriginal];
    [symbol drawInRect:CGRectMake(CGRectGetMaxX(rect)-43,rect.origin.y+10,28,28)];
    [[HCMenuAccent() colorWithAlphaComponent:0.18] setStroke];
    UIBezierPath *path=[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:14];path.lineWidth=0.8;[path stroke];
    CGFloat font=rect.size.width<130 ? 13 : 17;
    HCText(title,CGRectMake(rect.origin.x+10,CGRectGetMaxY(rect)-47,rect.size.width-18,22),font,UIColor.whiteColor,YES);
    HCText(subtitle,CGRectMake(rect.origin.x+10,CGRectGetMaxY(rect)-23,rect.size.width-18,18),8,UIColor.whiteColor,NO);
    [self target:action rect:rect];
}
- (NSString *)minimapKey:(NSString *)key {
    if(self.bounds.size.height>self.bounds.size.width) {
        if([key isEqual:@"minimapX"]) return @"minimapPortraitX";
        if([key isEqual:@"minimapY"]) return @"minimapPortraitY";
        if([key isEqual:@"minimapSize"]) return @"minimapPortraitSize";
    }
    return key;
}
- (void)ensureMinimapLayout {
    if(self.bounds.size.height<=self.bounds.size.width) return;
    NSDictionary *defaults=@{@"minimapX":@0.015,@"minimapY":@0.02,@"minimapSize":@150};
    for(NSString *key in defaults) {
        NSString *portrait=[self minimapKey:key];
        if(!self.settings[portrait]) self.settings[portrait]=self.settings[key] ?: defaults[key];
    }
}
- (NSNumber *)minimapValue:(NSString *)key {
    return self.settings[[self minimapKey:key]] ?: self.settings[key];
}
- (CGRect)calibrationTrack:(NSUInteger)index {
    CGRect c=[self contentRect];CGFloat rowHeight=(c.size.height-68)/5;
    return CGRectMake(c.origin.x+c.size.width*0.48,c.origin.y+31+(index%5)*rowHeight,c.size.width*0.5,rowHeight-3);
}
- (void)calibrationAt:(CGPoint)point {
    NSString *key=[self.activeTarget substringFromIndex:7];
    NSArray *fields=HCCalibrationFields();
    for(NSUInteger i=0;i<fields.count;i++) if([[self minimapKey:fields[i][@"key"]] isEqual:key]) {
        NSDictionary *field=fields[i];CGRect track=[self calibrationTrack:i];
        double minimum=[field[@"min"] doubleValue],maximum=[field[@"max"] doubleValue],step=[field[@"step"] doubleValue];
        double fraction=HCClamp((point.x-track.origin.x)/track.size.width,0,1);
        double value=HCClamp(minimum+round((fraction*(maximum-minimum))/step)*step,minimum,maximum);
        if([key hasPrefix:@"minimapPortrait"]) [self ensureMinimapLayout];
        self.settings[key]=[key isEqual:@"espReadHz"] ? @(lround(value)) : @(value);
        if([key hasPrefix:@"minimap"] && ![key isEqual:@"minimapIconSize"]) self.settings[@"minimapAutoAlign"]=@NO;
        [self refreshEspSurface];[self setNeedsDisplay];break;
    }
}
- (CGRect)minimapRect {
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    CGFloat size=HCClamp([[self minimapValue:@"minimapSize"] doubleValue] ?: 150,80,MIN(240,MIN(w,h)));
    double x=[self minimapValue:@"minimapX"] ? [[self minimapValue:@"minimapX"] doubleValue] : 0.015;
    double y=[self minimapValue:@"minimapY"] ? [[self minimapValue:@"minimapY"] doubleValue] : 0.02;
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
    [self ensureMinimapLayout];
    CGFloat w=self.bounds.size.width,h=self.bounds.size.height;
    double dx=point.x-self.startPoint.x,dy=point.y-self.startPoint.y;
    if([self.activeTarget isEqual:@"minimap-move"]) {
        self.settings[[self minimapKey:@"minimapX"]]=@(HCMinimapDragPosition(_startMapRect.origin.x,dx,w,_startMapRect.size.width));
        self.settings[[self minimapKey:@"minimapY"]]=@(HCMinimapDragPosition(_startMapRect.origin.y,dy,h,_startMapRect.size.height));
    } else {
        double limit=MIN(240,MIN(w-_startMapRect.origin.x,h-_startMapRect.origin.y));
        self.settings[[self minimapKey:@"minimapSize"]]=@(HCClamp(_startMapRect.size.width+(dx+dy)/2,80,limit));
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
    return !self.hidden && !HCLocked && (CGRectContainsPoint([self bubbleRect], point) || ([self menuInteractive] && CGRectContainsPoint([self panelRect], point)) ||
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
    if (![self menuInteractive]) return nil;
    for (NSDictionary *target in self.targets.reverseObjectEnumerator)
        if (CGRectContainsPoint([target[@"rect"] CGRectValue], point)) return target[@"key"];
    return nil;
}
- (void)drawRect:(CGRect)rect {
    [self.targets removeAllObjects];
    CGContextClearRect(UIGraphicsGetCurrentContext(),self.bounds);
    if (_menuProgress>0) {
        CGRect p=[self panelRect];
        CGContextRef ctx=UIGraphicsGetCurrentContext();
        UIBezierPath *outline=[UIBezierPath bezierPathWithRoundedRect:p cornerRadius:26];
        CGContextSaveGState(ctx);
        HCDrawerGeometry motion=[self drawer:p progress:_menuProgress];
        CGRect reveal=CGRectMake(motion.reveal.x,motion.reveal.y,motion.reveal.width,motion.reveal.height);
        [[UIBezierPath bezierPathWithRoundedRect:reveal cornerRadius:26] addClip];
        CGContextTranslateCTM(ctx,motion.dx,motion.dy);
        [UIColor.whiteColor setFill];[outline fill];
        CGContextSaveGState(ctx);[outline addClip];
        // Opaque panel; photos live in dedicated tiles and portraits.
        [[UIColor colorWithWhite:1 alpha:1] setFill];
        UIRectFill(CGRectMake(p.origin.x,p.origin.y,p.size.width,55));
        CGContextRestoreGState(ctx);
        CGFloat pulse=0.22;
        [[HCMenuAccent() colorWithAlphaComponent:pulse] setStroke];
        UIBezierPath *accent=[UIBezierPath bezierPath];[accent moveToPoint:CGPointMake(p.origin.x+66,p.origin.y+50)];
        [accent addLineToPoint:CGPointMake(CGRectGetMaxX(p)-22,p.origin.y+50)];accent.lineWidth=1;[accent stroke];
        [[UIColor colorWithWhite:0.65 alpha:0.25] setStroke];outline.lineWidth=1;[outline stroke];
        CGRect side=CGRectMake(p.origin.x+10,p.origin.y+10,44,p.size.height-20);
        [[UIColor colorWithWhite:0.95 alpha:1] setFill];[[UIBezierPath bezierPathWithRoundedRect:side cornerRadius:25] fill];
        NSArray *symbols=@[@"house.fill",@"viewfinder",@"camera.fill",@"gearshape.fill",@"slider.horizontal.3",@"envelope.fill"];
        NSArray *groups=@[@5,@0,@1,@2,@3,@4];
        CGFloat step=MIN(46,(side.size.height-12)/6);
        for(NSInteger i=0;i<6;i++) {
            CGRect r=CGRectMake(side.origin.x+3,side.origin.y+6+i*step,38,step-3);
            BOOL selected=self.group==[groups[i] integerValue];
            if(selected) { [[UIColor colorWithWhite:0.82 alpha:0.6] setFill];[[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:12] fill]; }
            CGContextSaveGState(ctx);[[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:11] addClip];
            HCDrawImageFill(HCThemeImage(HCMenuArt([groups[i] integerValue])),r,1,1);
            [[UIColor.blackColor colorWithAlphaComponent:selected ? 0.22 : 0.46] setFill];UIRectFill(r);
            CGContextRestoreGState(ctx);
            if(selected) { [HCAccent() setStroke];UIBezierPath *tabEdge=[UIBezierPath bezierPathWithRoundedRect:r cornerRadius:11];tabEdge.lineWidth=2;[tabEdge stroke]; }
            UIImage *symbol=[[UIImage systemImageNamed:symbols[i]] imageWithTintColor:UIColor.whiteColor renderingMode:UIImageRenderingModeAlwaysOriginal];
            [symbol drawInRect:CGRectMake(CGRectGetMidX(r)-11,CGRectGetMidY(r)-11,22,22)];
            [self target:[NSString stringWithFormat:@"tab:%@",groups[i]] rect:r];
        }
        HCText(@"DORO-CHEAT",CGRectMake(p.origin.x+66,p.origin.y+14,p.size.width-130,20),15,UIColor.blackColor,YES);
        HCText(@"BẢNG ĐIỀU KHIỂN",CGRectMake(p.origin.x+66,p.origin.y+34,p.size.width-130,14),10,UIColor.darkGrayColor,YES);
        CGRect close=CGRectMake(CGRectGetMaxX(p)-47,p.origin.y+9,34,32);
        HCText(@"×",CGRectInset(close,10,0),30,UIColor.blackColor,NO);[self target:@"close" rect:close];
        CGRect c=[self contentRect];
        if(self.group!=5) {
            [[UIColor colorWithWhite:1 alpha:1] setFill];
            [[UIBezierPath bezierPathWithRoundedRect:CGRectInset(c,-7,-5) cornerRadius:14] fill];
            if(self.group>=1 && self.group<=3 && p.size.width>500) {
                CGRect portrait=CGRectMake(CGRectGetMaxX(p)-184,p.origin.y+54,166,p.size.height-88);
                CGContextSaveGState(ctx);[[UIBezierPath bezierPathWithRoundedRect:portrait cornerRadius:16] addClip];
                HCDrawImageFill(HCThemeImage(HCMenuArt(self.group)),portrait,1,1);CGContextRestoreGState(ctx);
            } else if(self.group>=1 && self.group<=3 && p.size.height>=400) {
                CGRect banner=CGRectMake(p.origin.x+66,p.origin.y+62,p.size.width-82,90);
                CGContextSaveGState(ctx);[[UIBezierPath bezierPathWithRoundedRect:banner cornerRadius:16] addClip];
                HCDrawImageFill(HCThemeImage(HCMenuArt(self.group)),banner,1,1);CGContextRestoreGState(ctx);
            }
        }
        if(self.group==5) {
            BOOL wide=c.size.width>460;
            CGFloat leftWidth=wide ? c.size.width*0.50 : c.size.width;
            CGRect banner=CGRectMake(c.origin.x,c.origin.y,leftWidth,wide ? MIN(88,c.size.height*0.38) : 56);
            [self tile:banner title:@"SẴN SÀNG" subtitle:@"TỰ ĐỘNG LƯU CẤU HÌNH" image:130 action:@"tab:0"];
            CGFloat rowY=CGRectGetMaxY(banner)+12;
            NSArray *quick=@[@{@"title":@"HIỂN THỊ KẺ ĐỊCH",@"key":@"__ifxEnemyEspEnabledV1"},@{@"title":@"ESP ICON",@"key":@"DoroCheat.Reference.R1.Icon"},@{@"title":@"ESP MINIMAP",@"key":@"DoroCheat.Reference.R1.Map"}];
            for(NSInteger i=0;i<3;i++) {
                NSDictionary *q=quick[i];CGRect r=CGRectMake(c.origin.x,rowY+i*(wide ? 34 : 30),leftWidth,wide ? 29 : 25);
                HCDrawSkinCard(r,HCMenuArt(i));
                BOOL on=[self.settings[@"flags"][q[@"key"]] boolValue];
                HCText(q[@"title"],CGRectMake(r.origin.x+12,r.origin.y+8,r.size.width-65,18),11,UIColor.whiteColor,YES);
                HCText(on ? @"ON" : @"OFF",CGRectMake(CGRectGetMaxX(r)-44,r.origin.y+8,40,18),11,on ? HCAccent() : UIColor.whiteColor,YES);
                [self target:[@"flag:" stringByAppendingString:q[@"key"]] rect:r];
            }
            if(wide) {
                CGFloat x=c.origin.x+leftWidth+14,tw=(c.size.width-leftWidth-24)/2,th=(c.size.height-12)/2;
                [self tile:CGRectMake(x,c.origin.y,tw,th) title:@"ESP" subtitle:@"ẢNH TƯỚNG / ID" image:156 action:@"tab:0"];
                [self tile:CGRectMake(x+tw+10,c.origin.y,tw,th) title:@"CĂN CHỈNH" subtitle:@"BOX / ICON / MINIMAP" image:118 action:@"tab:3"];
                [self tile:CGRectMake(x,c.origin.y+th+12,tw,th) title:@"CAMERA" subtitle:@"GÓC NHÌN" image:537 action:@"tab:1"];
                [self tile:CGRectMake(x+tw+10,c.origin.y+th+12,tw,th) title:@"REPORTS" subtitle:@"LỊCH SỬ TỐ CÁO" image:193 action:@"tab:4"];
            } else {
                CGFloat y=rowY+100,tw=(c.size.width-10)/2,th=MAX(48,(CGRectGetMaxY(c)-y-10)/2);
                [self tile:CGRectMake(c.origin.x,y,tw,th) title:@"ESP" subtitle:@"ẢNH TƯỚNG / ID" image:156 action:@"tab:0"];
                [self tile:CGRectMake(c.origin.x+tw+10,y,tw,th) title:@"CĂN CHỈNH" subtitle:@"BOX / ICON / MINIMAP" image:118 action:@"tab:3"];
                [self tile:CGRectMake(c.origin.x,y+th+10,tw,th) title:@"CAMERA" subtitle:@"GÓC NHÌN" image:537 action:@"tab:1"];
                [self tile:CGRectMake(c.origin.x+tw+10,y+th+10,tw,th) title:@"REPORTS" subtitle:@"BẢNG PHÂN TÍCH" image:193 action:@"tab:4"];
            }
        } else if(self.group==1) {
            double distance=HCCameraDistance([self.settings[@"cameraScale"] doubleValue]);
            HCText([NSString stringWithFormat:@"CAM XA  %.2f / 2",distance],CGRectMake(c.origin.x,c.origin.y,c.size.width,30),22,UIColor.blackColor,YES);
            CGRect enable=CGRectMake(c.origin.x,c.origin.y+36,c.size.width,28);
            HCText([self.settings[@"cameraEnabled"] boolValue] ? @"CAMERA XA     ON" : @"CAMERA XA     OFF",enable,16,HCMenuAccent(),YES);[self target:@"cameraEnabled" rect:enable];
            CGRect slider=CGRectMake(c.origin.x,c.origin.y+80,c.size.width,28);
            [[UIColor colorWithWhite:0.8 alpha:1] setFill];UIRectFill(CGRectMake(slider.origin.x,CGRectGetMidY(slider)-2,slider.size.width,4));
            CGFloat knob=slider.origin.x+distance/2*slider.size.width;
            [HCMenuAccent() setFill];[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob-9,CGRectGetMidY(slider)-9,18,18)] fill];[self target:@"camera" rect:slider];
            CGRect minus=CGRectMake(c.origin.x,c.origin.y+115,50,22),plus=CGRectMake(CGRectGetMaxX(c)-50,c.origin.y+115,50,22);
            HCText(@"− 0.05",minus,12,HCMenuAccent(),YES);HCText(@"+ 0.05",plus,12,HCMenuAccent(),YES);
            [self target:@"camera-minus" rect:minus];[self target:@"camera-plus" rect:plus];
            double combined=[self.settings[@"espCombinedScale"] doubleValue] ?: 1;
            HCText([NSString stringWithFormat:@"CỠ BOX + ICON   %.2f×",combined],CGRectMake(c.origin.x,c.origin.y+147,c.size.width,18),11,HCMenuAccent(),YES);
            CGRect espSlider=CGRectMake(c.origin.x,c.origin.y+172,c.size.width,24);
            [[UIColor colorWithWhite:0.8 alpha:1] setFill];UIRectFill(CGRectMake(espSlider.origin.x,CGRectGetMidY(espSlider)-2,espSlider.size.width,4));
            CGFloat espKnob=espSlider.origin.x+(HCClamp(combined,0.5,4)-0.5)/3.5*espSlider.size.width;
            [HCMenuAccent() setFill];[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(espKnob-7,CGRectGetMidY(espSlider)-7,14,14)] fill];
            [self target:@"esp-combined" rect:espSlider];
        } else if(self.group==2) {
            HCText(@"CẤU HÌNH CỦA BẠN",CGRectMake(c.origin.x,c.origin.y,c.size.width,28),16,HCMenuAccent(),YES);
            HCText(@"Thay đổi được tự lưu. LƯU tạo một bản riêng; TẢI khôi phục bản đó, gồm cả khung minimap ngang/dọc.",CGRectMake(c.origin.x,c.origin.y+35,c.size.width,44),11,UIColor.darkGrayColor,NO);
            CGRect save=CGRectMake(c.origin.x,c.origin.y+88,c.size.width*0.46,35),load=CGRectMake(c.origin.x+c.size.width*0.52,c.origin.y+88,c.size.width*0.48,35);
            HCText(@"LƯU SETTING",save,13,HCMenuAccent(),YES);[self target:@"settings-save" rect:save];
            HCText(@"TẢI SETTING",load,13,HCMenuAccent(),YES);[self target:@"settings-load" rect:load];
            HCText(HCSettingsError ?: self.settingsNotice ?: @"Tải chỉ thay đổi cấu hình khi bản lưu hợp lệ.",CGRectMake(c.origin.x,c.origin.y+139,c.size.width,48),11,HCSettingsError ? UIColor.systemRedColor : UIColor.darkGrayColor,NO);
        } else if(self.group==3) {
            NSArray *fields=HCCalibrationFields();NSUInteger pages=(fields.count+4)/5;
            _calibrationPage=MAX(0,MIN((NSInteger)pages-1,_calibrationPage));
            CGRect toggle=CGRectMake(c.origin.x,c.origin.y,c.size.width-76,25);
            HCText(self.bounds.size.width>self.bounds.size.height ? @"KHUNG NGANG • THỦ CÔNG" : @"KHUNG DỌC • THỦ CÔNG",toggle,11,HCMenuAccent(),YES);
            CGRect prev=CGRectMake(CGRectGetMaxX(c)-68,c.origin.y,30,25),next=CGRectMake(CGRectGetMaxX(c)-32,c.origin.y,30,25);
            HCText(@"‹",prev,20,UIColor.blackColor,YES);HCText(@"›",next,20,UIColor.blackColor,YES);
            [self target:@"cal-prev" rect:prev];[self target:@"cal-next" rect:next];
            NSUInteger pageStart=(NSUInteger)_calibrationPage*5;
            NSUInteger pageEnd=MIN(fields.count,pageStart+5);
            for(NSUInteger i=pageStart;i<pageEnd;i++) {
                NSDictionary *field=fields[i];CGRect track=[self calibrationTrack:i];
                double value=[self minimapValue:field[@"key"]] ? [[self minimapValue:field[@"key"]] doubleValue] : [field[@"default"] doubleValue];
                HCText(field[@"title"],CGRectMake(c.origin.x,track.origin.y,c.size.width*0.46,13),10,UIColor.blackColor,YES);
                HCText([NSString stringWithFormat:@"%.2f",value],CGRectMake(c.origin.x,track.origin.y+13,c.size.width*0.46,13),9,HCMenuAccent(),NO);
                [[UIColor colorWithWhite:0.4 alpha:0.8] setFill];UIRectFill(CGRectMake(track.origin.x,CGRectGetMidY(track)-2,track.size.width,4));
                double fraction=(value-[field[@"min"] doubleValue])/([field[@"max"] doubleValue]-[field[@"min"] doubleValue]);
                CGFloat knob=track.origin.x+HCClamp(fraction,0,1)*track.size.width;
                [HCMenuAccent() setFill];[[UIBezierPath bezierPathWithOvalInRect:CGRectMake(knob-5,CGRectGetMidY(track)-5,10,10)] fill];
                [self target:[@"adjust:" stringByAppendingString:[self minimapKey:field[@"key"]]] rect:track];
            }
            CGRect edit=CGRectMake(c.origin.x,CGRectGetMaxY(c)-28,c.size.width*0.55,24);
            HCText(@"KÉO KHUNG MAP",edit,10,HCMenuAccent(),YES);[self target:@"minimap-edit" rect:edit];
            CGRect rotate=CGRectMake(c.origin.x+c.size.width*0.56,CGRectGetMaxY(c)-28,c.size.width*0.44,24);
            HCText([self.settings[@"minimapRotated"] boolValue] ? @"XOAY 180°: ON" : @"XOAY 180°: OFF",rotate,9,UIColor.blackColor,NO);[self target:@"minimap-rotate" rect:rotate];
        } else if(self.group==4) {
            [self drawReportTable:c];
        } else {
            NSMutableArray *features=[NSMutableArray array];
            for(NSDictionary *feature in HCFeatures()) if([feature[@"group"] integerValue]==self.group) [features addObject:feature];
            NSInteger columns=c.size.width>440 ? 2 : 1;
            CGFloat gap=10,rowHeight=MIN(46,(c.size.height-(self.group==0 ? 40 : 12))/MAX(1,ceil((double)features.count/columns)));
            CGFloat cellWidth=(c.size.width-gap*(columns-1))/columns;
            for(NSUInteger i=0;i<features.count;i++) {
                NSDictionary *feature=features[i];
                CGRect row=CGRectMake(c.origin.x+(i%columns)*(cellWidth+gap),c.origin.y+(i/columns)*rowHeight,cellWidth,rowHeight-6);
                HCDrawSkinCard(row,HCMenuArt(i));

                BOOL on=[self.settings[@"flags"][feature[@"key"]] boolValue];
                HCText(feature[@"title"],CGRectMake(row.origin.x+10,row.origin.y+9,row.size.width-54,row.size.height),12,UIColor.whiteColor,NO);
                HCText(on ? @"ON" : @"OFF",CGRectMake(CGRectGetMaxX(row)-38,row.origin.y+9,34,22),10,on ? HCAccent() : UIColor.whiteColor,YES);
                [self target:[@"flag:" stringByAppendingString:feature[@"key"]] rect:row];
            }
        }
        if(self.group==0) {
            CGRect adjust=CGRectMake(c.origin.x,CGRectGetMaxY(c)-29,c.size.width,26);
            HCText(@"↔  CHỈNH KHUNG MINIMAP",CGRectInset(adjust,4,4),11,HCMenuAccent(),YES);
            [self target:@"minimap-edit" rect:adjust];
        }
        CGRect privacy=CGRectMake(p.origin.x+66,CGRectGetMaxY(p)-31,MIN(240,p.size.width-178),22);
        [[UIColor colorWithWhite:0.94 alpha:1] setFill];[[UIBezierPath bezierPathWithRoundedRect:privacy cornerRadius:7] fill];
        HCText(HCCaptureProtected ? @"TỰ ẨN QUAY/CHỤP: ON" : @"TỰ ẨN QUAY/CHỤP: OFF",CGRectInset(privacy,7,5),9,HCCaptureProtected ? HCMenuAccent() : UIColor.darkGrayColor,YES);
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
    double noticeProgress=_reportNoticeStarted>0 ? HCReportNoticeProgress(NSProcessInfo.processInfo.systemUptime-_reportNoticeStarted) : 0;
    _reportNoticeWasVisible=noticeProgress>0;
    if(noticeProgress>0) {
        CGRect banner=[self reportNoticeRect];
        HCDrawerGeometry notice=[self drawer:banner progress:noticeProgress];
        CGRect reveal=CGRectMake(notice.reveal.x,notice.reveal.y,notice.reveal.width,notice.reveal.height);
        CGContextRef context=UIGraphicsGetCurrentContext();CGContextSaveGState(context);
        [[UIBezierPath bezierPathWithRoundedRect:reveal cornerRadius:18] addClip];
        CGContextTranslateCTM(context,notice.dx,notice.dy);
        [UIColor.whiteColor setFill];[[UIBezierPath bezierPathWithRoundedRect:banner cornerRadius:18] fill];
        HCDrawImageFill(HCThemeImage(@"diaochan-celestial.jpg"),banner,0.12,1);
        [[UIColor colorWithWhite:1 alpha:0.70] setFill];UIRectFill(banner);
        [HCMenuAccent() setFill];UIRectFill(CGRectMake(banner.origin.x,banner.origin.y,4,banner.size.height));
        HCText(@"DORO-CHEAT • PHÁT HIỆN TỐ CÁO",CGRectMake(banner.origin.x+14,banner.origin.y+10,banner.size.width-28,20),11,HCMenuAccent(),YES);
        HCText(_reportNoticeReason ?: @"Đã nhận bản ghi tố cáo mới.",CGRectMake(banner.origin.x+14,banner.origin.y+35,banner.size.width-28,34),12,UIColor.blackColor,YES);
        HCText([NSString stringWithFormat:@"%lu bản ghi mới • tự đóng sau 4 giây",(unsigned long)_reportNoticeCount],CGRectMake(banner.origin.x+14,banner.origin.y+75,banner.size.width-28,14),9,UIColor.darkGrayColor,NO);
        CGContextRestoreGState(context);
    }
    if(noticeProgress<=0 && _welcomeUntil>NSProcessInfo.processInfo.systemUptime) {
        CGFloat width=MIN(356,self.bounds.size.width-32);
        CGRect toast=CGRectMake((self.bounds.size.width-width)/2,MAX(44,self.safeAreaInsets.top+10),width,66);
        [[UIColor colorWithRed:0.055 green:0.075 blue:0.11 alpha:0.95] setFill];
        [[UIBezierPath bezierPathWithRoundedRect:toast cornerRadius:18] fill];
        HCText(@"DORO-CHEAT",CGRectMake(toast.origin.x+16,toast.origin.y+12,width-32,20),16,HCAccent(),YES);
        HCText(@"chúc bạn chơi game vui vẻ",CGRectMake(toast.origin.x+16,toast.origin.y+36,width-32,20),13,UIColor.whiteColor,YES);
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

    if (HCLocked || ![flags[@"__ifxEnemyEspEnabledV1"] boolValue]) {
        memset(_screenStates,0,sizeof(_screenStates));
        if(!_imagesPurged) { HCPurgeHeroImages();_imagesPurged=YES; }
        return;
    }
    double now=NSProcessInfo.processInfo.systemUptime;
    double age=now-[HCEspStatus[@"sampleUptime"] doubleValue];
    if (!HCEspStatus[@"sampleUptime"] || age<0 || age>HC_ESP_HOLD_SECONDS || ![HCEspStatus[@"targets"] count]) {
        memset(_screenStates,0,sizeof(_screenStates));
        if(!_emptyEspSince) _emptyEspSince=now;
        if(!_imagesPurged && now-_emptyEspSince>1) { HCPurgeHeroImages();_imagesPurged=YES; }
        return;
    }
    _emptyEspSince=0;_imagesPurged=NO;
    for(int i=0;i<HC_ESP_MAX_TARGETS;i++) if(_screenStates[i].valid && now-_screenStates[i].time>HC_ESP_HOLD_SECONDS)
        memset(&_screenStates[i],0,sizeof(_screenStates[i]));
    NSInteger pid=[HCEspStatus[@"pid"] integerValue];
    NSString *camera=HCEspStatus[@"nativeCamera"];
    if (pid!=_screenPID || !CGSizeEqualToSize(_screenSize,self.bounds.size) || ![_screenCamera isEqual:camera]) {
        memset(_screenStates,0,sizeof(_screenStates));_screenPID=pid;_screenSize=self.bounds.size;_screenCamera=[camera copy];
    }
    CGContextRef context=UIGraphicsGetCurrentContext();
    NSMutableArray<NSValue *> *masks=[NSMutableArray array];
    if(_menuProgress>0) {
        HCDrawerGeometry menu=[self drawer:[self panelRect] progress:_menuProgress];
        [masks addObject:[NSValue valueWithCGRect:CGRectMake(menu.reveal.x,menu.reveal.y,menu.reveal.width,menu.reveal.height)]];
    }
    double noticeProgress=_reportNoticeStarted>0 ? HCReportNoticeProgress(now-_reportNoticeStarted) : 0;
    if(noticeProgress>0) {
        HCDrawerGeometry notice=[self drawer:[self reportNoticeRect] progress:noticeProgress];
        [masks addObject:[NSValue valueWithCGRect:CGRectMake(notice.reveal.x,notice.reveal.y,notice.reveal.width,notice.reveal.height)]];
    }
    // Intersect exclusions independently, so overlapping menu/notice regions
    // never reveal ESP through an even-odd overlap.
    for(NSValue *mask in masks) {
        UIBezierPath *clip=[UIBezierPath bezierPathWithRect:self.bounds];
        [clip appendPath:[UIBezierPath bezierPathWithRect:mask.CGRectValue]];
        clip.usesEvenOddFillRule=YES;[clip addClip];
    }
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
            BOOL projected=HCMinimapManualProject([target[@"worldX"] doubleValue],[target[@"worldZ"] doubleValue],
                [self.settings[@"minimapCenterX"] doubleValue],[self.settings[@"minimapCenterZ"] doubleValue],extent,
                [self.settings[@"minimapAngle"] doubleValue],rotated,&u,&v);
            if (projected) {
                CGFloat iconSize=HCClamp([self.settings[@"minimapIconSize"] doubleValue] ?: 20,8,40);
                // Icon size never changes the map transform or icon center.
                CGFloat px=map.origin.x+u*mapSize;
                CGFloat py=map.origin.y+v*mapSize;
                CGRect icon=CGRectMake(px-iconSize/2,py-iconSize/2,iconSize,iconSize);
                // Keep partial edge icons inside the exact calibration frame.
                CGContextSaveGState(context);CGContextClipToRect(context,map);
                HCDrawHeroIcon(mapID,icon);
                HCDrawHealthRing(target,CGRectInset(icon,-1.5,-1.5),YES,1.2);
                CGContextRestoreGState(context);
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
        CGFloat combined=HCClamp([self.settings[@"espCombinedScale"] doubleValue] ?: 1,0.5,4);
        HCEspDimensions dimensions=HCEspCombinedDimensions(height*0.48*widthScale,height*heightScale,
            HCClamp([self.settings[@"espIconSize"] doubleValue] ?: 32,12,64),combined);
        CGFloat boxWidth=dimensions.width,boxHeight=dimensions.height;
        CGRect box = CGRectMake(x-boxWidth/2,(top+bottom)/2-boxHeight/2,boxWidth,boxHeight);
        BOOL hpEnabled=[flags[@"DoroCheat.Reference.R1.HP"] boolValue];
        double diameter=HCHeroBadgeSized(box.size.width,box.size.height,dimensions.icon);
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
- (void)welcome {
    HCMenuOpen=NO;_menuProgress=_menuMotionFrom=_menuMotionTo=0;_editingMinimap=NO;[self cancelInteraction];
    _welcomeUntil=NSProcessInfo.processInfo.systemUptime+3.5;[self setNeedsDisplay];HCState();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.6*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ [self setNeedsDisplay]; });
}
- (void)toggleMenu {
    [self updateMenuMotion:NSProcessInfo.processInfo.systemUptime];
    HCMenuOpen = !HCMenuOpen;
    [self updateMenuMotion:NSProcessInfo.processInfo.systemUptime];
    self.activeTarget = nil; self.pointer = -1;
    if (HCMenuOpen) { _editingMinimap=NO;[self reloadSettings]; }
    [self setNeedsDisplay]; HCState();
}
- (void)cameraAt:(CGPoint)point {
    if (!self.settings) return;
    CGRect c = [self contentRect];
    self.settings[@"cameraScale"] = @(HCCameraScaleFromDistance(HCClamp((point.x-c.origin.x)/c.size.width,0,1)*2));
    NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
    if(now-self.cameraLastSave>=0.12) { self.cameraLastSave=now;[self saveSettings]; }
    [self setNeedsDisplay];
}
- (void)espCombinedAt:(CGPoint)point {
    CGRect c=[self contentRect];
    self.settings[@"espCombinedScale"]=@(0.5+3.5*HCClamp((point.x-c.origin.x)/c.size.width,0,1));
    [self refreshEspSurface];[self setNeedsDisplay];
}
- (void)receivePoint:(CGPoint)point phase:(UITouchPhase)phase pointer:(NSInteger)pointer {
    if (HCLocked || self.hidden) return;
    double now=NSProcessInfo.processInfo.systemUptime;
    HCInputDecision decision=HCInputDecide(self.pointer,pointer,phase==UITouchPhaseBegan,
        phase==UITouchPhaseEnded || phase==UITouchPhaseCancelled,now-_lastPointerEvent,
        hypot(point.x-self.startPoint.x,point.y-self.startPoint.y));
    if(decision==HCInputIgnore) return;
    if(decision==HCInputCancel || decision==HCInputRestart) [self cancelInteraction];
    if(decision==HCInputCancel) return;
    if (phase == UITouchPhaseBegan) {
        NSString *target = [self targetAt:point];
        if (!target) return;
        self.pointer = pointer; self.activeTarget = target;
        self.startPoint = point; self.startBubble = self.bubble; self.dragged = NO;
        if([target isEqual:@"reports-scroll"]) {
            _reportDragStart=_reportScroll;_reportVelocity=0;_reportLastY=point.y;_reportLastTouch=now;
        }
        if ([target isEqual:@"camera"]) { [self reloadSettings]; [self cameraAt:point]; }
        if ([target isEqual:@"esp-combined"]) { [self reloadSettings];[self espCombinedAt:point]; }
        if ([target hasPrefix:@"adjust:"]) { [self reloadSettings];[self calibrationAt:point]; }
        if ([target isEqual:@"minimap-move"] || [target isEqual:@"minimap-resize"]) { [self reloadSettings];_startMapRect=[self minimapRect]; }
    }
    _lastPointerEvent=NSProcessInfo.processInfo.systemUptime;
    HCTouchCount++;
    if (phase == UITouchPhaseMoved) {
        if([self.activeTarget isEqual:@"reports-scroll"]) {
            double dy=point.y-self.startPoint.y,dt=now-_reportLastTouch;
            _reportScroll=HCReportScrollClamp(_reportDragStart-dy,_reportContentHeight,_reportViewport.size.height);
            if(dt>0 && dt<0.15) _reportVelocity=HCClamp(0.3*_reportVelocity+0.7*(_reportLastY-point.y)/dt,-2200,2200);
            _reportLastY=point.y;_reportLastTouch=now;self.dragged=YES;[self setNeedsDisplay];
        } else if ([self.activeTarget isEqual:@"bubble"]) {
            CGFloat dx = point.x - self.startPoint.x, dy = point.y - self.startPoint.y;
            if (hypot(dx, dy) > 7) self.dragged = YES;
            if (self.dragged) {
                self.bubble = CGPointMake(HCClamp(self.startBubble.x + dx, 30, self.bounds.size.width - 30),
                    HCClamp(self.startBubble.y + dy, 60, self.bounds.size.height - 38));
                [self setNeedsDisplay];
            }
        } else if ([self.activeTarget isEqual:@"camera"]) [self cameraAt:point];
        else if ([self.activeTarget isEqual:@"esp-combined"]) [self espCombinedAt:point];
        else if ([self.activeTarget hasPrefix:@"adjust:"]) [self calibrationAt:point];
        else if ([self.activeTarget isEqual:@"minimap-move"] || [self.activeTarget isEqual:@"minimap-resize"]) [self minimapAt:point];
    } else if (phase == UITouchPhaseEnded || phase == UITouchPhaseCancelled) {
        NSString *target = self.activeTarget;
        BOOL mapGesture=[target isEqual:@"minimap-move"] || [target isEqual:@"minimap-resize"];
        if(phase==UITouchPhaseEnded && mapGesture) [self minimapAt:point];
        if(phase==UITouchPhaseEnded && [target hasPrefix:@"adjust:"]) [self calibrationAt:point];
        self.activeTarget = nil; self.pointer = -1;
        if([target isEqual:@"reports-scroll"]) {
            if(phase==UITouchPhaseCancelled || now-_reportLastTouch>0.12) _reportVelocity=0;
            _reportTick=now;[self setNeedsDisplay];return;
        }
        if (phase == UITouchPhaseCancelled) { [self reloadSettings]; return; }
        if (mapGesture || [target hasPrefix:@"adjust:"]) { [self saveSettings];return; }
        if ([target isEqual:@"camera"]) { [self cameraAt:point]; [self saveSettings]; return; }
        if ([target isEqual:@"esp-combined"]) { [self espCombinedAt:point];[self saveSettings];return; }
        if (self.dragged || ![[self targetAt:point] isEqual:target]) return;
        if ([target isEqual:@"bubble"] || [target isEqual:@"close"]) [self toggleMenu];
        else if ([target isEqual:@"settings-save"] || [target isEqual:@"settings-load"]) {
            BOOL saving=[target isEqual:@"settings-save"];
            if(saving && self.pendingSettingsSave) [self saveSettings];
            if(!saving || !self.pendingSettingsSave) {
                NSDictionary *result=HCSettingsSnapshot(HCProfile,saving);
                self.settingsNotice=result[@"message"];
                if([result[@"ok"] isEqual:@YES]) { self.pendingSettingsSave=NO;[self reloadSettings];[self refreshEspSurface]; }
                [self setNeedsDisplay];
            }
        }
        else if ([target isEqual:@"cal-prev"] || [target isEqual:@"cal-next"]) {
            _calibrationPage+= [target isEqual:@"cal-next"] ? 1 : -1;[self setNeedsDisplay];
        }
        else if ([target isEqual:@"minimap-auto"] || [target isEqual:@"minimap-rotate"]) {
            [self reloadSettings];
            if([target isEqual:@"minimap-auto"]) self.settings[@"minimapAutoAlign"]=@NO;
            else { self.settings[@"minimapRotated"]=[self.settings[@"minimapRotated"] boolValue] ? @NO : @YES;self.settings[@"minimapAutoAlign"]=@NO; }
            [self saveSettings];[self refreshEspSurface];
        }
        else if ([target isEqual:@"minimap-edit"]) {
            [self reloadSettings];self.settings[@"minimapAutoAlign"]=@NO;[self saveSettings];
            _editingMinimap=YES;HCMenuOpen=NO;[self setNeedsDisplay];
        }
        else if ([target isEqual:@"minimap-icon-smaller"] || [target isEqual:@"minimap-icon-larger"]) {
            [self reloadSettings];
            CGFloat size=[self.settings[@"minimapIconSize"] doubleValue] ?: 20;
            self.settings[@"minimapIconSize"]=@(HCClamp(size+([target isEqual:@"minimap-icon-larger"] ? 2 : -2),8,40));
            [self saveSettings];[self refreshEspSurface];
        }
        else if ([target isEqual:@"minimap-done"]) { _editingMinimap=NO;[self setNeedsDisplay]; }
        else if ([target isEqual:@"stop"]) HCStop(@"Đã tắt nút nổi. Mở DORO-CHEAT để bật lại.", NO);
        else if ([target hasPrefix:@"tab:"]) { self.group = [[target substringFromIndex:4] integerValue];_reportVelocity=0;if(self.group!=4) [self discardReportLayout]; [self.targets removeAllObjects];[self setNeedsDisplay]; }
        else if ([target hasPrefix:@"period:"]) {
            [self reloadSettings];self.settings[@"reportsPeriod"]=[target substringFromIndex:7];_reportScroll=0;_reportVelocity=0;[self saveSettings];
        }
        else if ([target isEqual:@"reports-refresh"]) {
            [self reloadSettings];self.settings[@"reportsRefreshID"]=NSUUID.UUID.UUIDString;self.settings[@"flags"][@"reports.enabled"]=@YES;self.settings[@"gameRuntimeEnabled"]=@YES;[self saveSettings];
        }
        else if ([target isEqual:@"capture"]) {
            [self reloadSettings];
            if(self.settings) { self.settings[@"espCaptureProtected"]=[self.settings[@"espCaptureProtected"] isEqual:@NO] ? @YES : @NO;[self saveSettings];[self refreshEspSurface]; }
        }
        else if ([target isEqual:@"camera-minus"] || [target isEqual:@"camera-plus"]) {
            [self reloadSettings];
            if(self.settings) {
                self.settings[@"cameraScale"]=@(HCCameraScaleFromDistance(HCCameraDistance([self.settings[@"cameraScale"] doubleValue])+([target isEqual:@"camera-plus"] ? 0.05 : -0.05)));
                [self saveSettings];
            }
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
            if (self.settings) {
                BOOL on=![self.settings[@"flags"][key] boolValue];self.settings[@"flags"][key]=@(on);
                if(on && [key isEqual:@"reports.enabled"]) {
                    self.settings[@"gameRuntimeEnabled"]=@YES;self.settings[@"reportsRefreshID"]=NSUUID.UUID.UUIDString;
                }
                [self saveSettings];
            }
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
    mach_port_t (*portFunction)(void) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSSBSSpringBoardServerPort));
    void (*statusFunction)(mach_port_t, BOOL *, BOOL *) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSSBGetScreenLockStatus));
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
            for(NSString *name in [HCMenuArtFiles() arrayByAddingObject:@"app-background.jpg"]) (void)HCThemeImage(name);
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
    HCHost = [NSClassFromString(HCProtectedString(HCSHostingClass)) new];
    if (!HCHost || ![HCHost respondsToSelector:@selector(registerWindowWithContextID:atLevel:)] || ![HCWindow _contextId])
        HCStop(@"Không có API đăng ký cửa sổ overlay trên môi trường này.", YES);
    HCStage(@"register_window");
    [HCHost registerWindowWithContextID:[HCWindow _contextId] atLevel:HCWindow.windowLevel];
    HCOrientationObserver = [NSClassFromString(HCProtectedString(HCSOrientationClass)) new];
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
    int stopToken, toggleToken, lockToken, springboardToken, welcomeToken;
    notify_register_dispatch(HCOverlayNotification(HCDirectory, @"stop").UTF8String, &stopToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCStop(@"Đã tắt nút nổi.", NO); });
    notify_register_dispatch(HCOverlayNotification(HCDirectory,@"welcome").UTF8String,&welcomeToken,dispatch_get_main_queue(),^(int token){ (void)token;[HCCanvas welcome]; });
    notify_register_dispatch(HCOverlayNotification(HCDirectory, @"toggle").UTF8String, &toggleToken, dispatch_get_main_queue(), ^(int token) { (void)token; [HCCanvas toggleMenu]; });
    notify_register_dispatch("com.apple.springboard.lockstate", &lockToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCUpdateLock(); });
    notify_register_dispatch("SBSpringBoardDidLaunchNotification", &springboardToken, dispatch_get_main_queue(), ^(int token) { (void)token; HCStop(@"SpringBoard đã khởi động lại. Mở DORO-CHEAT để bật nút nổi.", NO); });
    HCStartupStage = @"ready";
    HCPhase = @"visible"; HCMessage = @"Đã đăng ký nút nổi DORO-CHEAT. Chạm để mở/thu menu; kéo để di chuyển.";
    [NSNotificationCenter.defaultCenter addObserverForName:UIScreenCapturedDidChangeNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        (void)notification;[HCCanvas refreshEspSurface];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationUserDidTakeScreenshotNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        (void)notification;[HCCanvas cancelInteraction];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        (void)notification;[HCCanvas discardReportLayout];HCPurgeHeroImages();[HCThemeCache() removeAllObjects];HCEspLastSample=nil;[HCCanvas.espView setNeedsDisplay];
    }];
    [NSNotificationCenter.defaultCenter addObserverForName:@"HCThemeDidLoad" object:nil queue:NSOperationQueue.mainQueue usingBlock:^(NSNotification *notification) {
        if(HCMenuOpen || [notification.object isEqual:@"app-background.jpg"]) [HCCanvas setNeedsDisplay];
    }];
    HCUpdateLock(); HCState();
    HCCamera = [[HCCameraEngine alloc] initWithProfile:HCProfile report:^(NSDictionary *report) {
        HCCameraStatus = report;
    } espReport:^(NSDictionary *report) {
        HCEspStatus = report;
        // Preserve the last actor sample for export after switching away from
        // the game. It is historical evidence, never a frame to draw now.
        if ([report[@"listCount"] integerValue] > 0) {
            NSMutableDictionary *metadata=[report mutableCopy];[metadata removeObjectForKey:@"targets"];HCEspLastSample=metadata;
        } else if(![report[@"targets"] count]) HCEspLastSample=nil;
    } reportsReport:^(NSDictionary *report) {
        [HCCanvas receiveReports:report];
    }];
    [HCCamera start];[HCCanvas welcome];
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
            Class<HCAXEventRepresentation> representation = (Class<HCAXEventRepresentation>)NSClassFromString(HCProtectedString(HCSAXClass));
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
            if (pointer < 1) { pointer = 0; HCPointerFallbackCount++; }
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
    void *library = dlopen(HCProtectedCString(HCSIOKitPath), RTLD_NOW | RTLD_GLOBAL);
    if (!library) return NO;
    CFTypeRef (*create)(CFAllocatorRef, int, CFDictionaryRef) = dlsym(library, HCProtectedCString(HCSIOHIDEventSystemClientCreateWithType));
    void (*registerCallback)(CFTypeRef, void (*)(void *, void *, CFTypeRef, CFTypeRef), void *, void *) =
        dlsym(library, HCProtectedCString(HCSIOHIDEventSystemClientRegisterEventCallback));
    void (*schedule)(CFTypeRef, CFRunLoopRef, CFStringRef) = dlsym(library, HCProtectedCString(HCSIOHIDEventSystemClientScheduleWithRunLoop));
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
            void (*gsInitialize)(void) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSGSInitialize));
            void (*displayStart)(void) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSBKSDisplayServicesStart));
            void (*appInitialize)(void) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSUIApplicationInitialize));
            void (*instantiate)(Class) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSUIApplicationInstantiateSingleton));
            void *(*registerHID)(void (*)(void *, void *, CFTypeRef, CFTypeRef)) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSBKSHIDEventRegisterEventCallback));
            void (*eventInitialize)(Boolean) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSGSEventInitialize));
            void (*pushMode)(CFStringRef) = dlsym(RTLD_DEFAULT, HCProtectedCString(HCSGSEventPushRunLoopMode));
            if (!gsInitialize || !displayStart || !appInitialize || !instantiate || !registerHID || !eventInitialize || !pushMode ||
                !NSClassFromString(HCProtectedString(HCSAXClass))) HCStop(@"Thiếu API khởi tạo hoặc nhận chạm của overlay.", YES);
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
