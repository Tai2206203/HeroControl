#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
#import "ThemeResources.h"
#include "../BackendSDK/EspVisualStyle.h"

static NSDictionary *HCHeroCatalog(void) {
    static NSDictionary *entries;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"HeroIcons/catalog.json"];
        NSData *data=[NSData dataWithContentsOfFile:path];
        NSDictionary *catalog=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        NSMutableDictionary *result=[NSMutableDictionary dictionary];
        for (NSDictionary *hero in catalog[@"heroes"]) result[[hero[@"id"] stringValue]]=hero;
        entries=result;
    });
    return entries;
}
static NSCache *HCHeroImageCache(void) {
    static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{ cache=[NSCache new];cache.countLimit=24;cache.totalCostLimit=2*1024*1024; });
    return cache;
}
static void HCPurgeHeroImages(void) { [HCHeroImageCache() removeAllObjects]; }
static UIImage *HCHeroIcon(int32_t heroID) {
    NSString *key=[NSString stringWithFormat:@"%d",heroID];
    UIImage *image=[HCHeroImageCache() objectForKey:key];
    if(image) return image;
    if(!HCHeroCatalog()[key]) return nil;
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[NSString stringWithFormat:@"HeroIcons/%d.img",heroID]];
    CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);
    if(source) {
        NSDictionary *options=@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
            (__bridge id)kCGImageSourceThumbnailMaxPixelSize:@128,(__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES,
            (__bridge id)kCGImageSourceShouldCacheImmediately:@YES};
        // Decode one static frame, including GIF sources; never retain animation frames.
        CGImageRef frame=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
        if(frame) { image=[UIImage imageWithCGImage:frame];NSUInteger cost=CGImageGetBytesPerRow(frame)*CGImageGetHeight(frame);
            [HCHeroImageCache() setObject:image forKey:key cost:cost];CGImageRelease(frame); }
        CFRelease(source);
    }
    return image;
}
static NSCache *HCThemeCache(void) {
    static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{ cache=[NSCache new];cache.countLimit=10;cache.totalCostLimit=16*1024*1024; });
    return cache;
}
static NSArray<NSString *> *HCMenuArtFiles(void) {
    return @[@"violet-sss.png",@"lauriel-sss.jpg",@"airi-sss.jpg",@"telannas-fee-sss.jpg",@"telannas-dimension-sss.jpg",@"telannas-newyear-sss.jpg",@"butterfly-phoenix-sss.jpg",@"liliana-magic-sss.jpg"];
}
static NSString *HCMenuArt(NSInteger group) {
    NSArray *files=HCMenuArtFiles();
    NSUInteger index=group>=0 ? (NSUInteger)group%files.count : 0;
    return files[index];
}
// Drawing only reads the cache. Decode photos on a serial worker, once per name.
static UIImage *HCThemeImage(NSString *name) {
    NSCache *cache=HCThemeCache();
    UIImage *cached=[cache objectForKey:name];if(cached) return cached;
    static NSMutableSet *pending;static NSMutableDictionary *retryAfter;static dispatch_queue_t worker;static dispatch_once_t once;
    dispatch_once(&once,^{pending=[NSMutableSet set];retryAfter=[NSMutableDictionary dictionary];worker=dispatch_queue_create("local.herocontrol.theme",DISPATCH_QUEUE_SERIAL);});
    @synchronized(pending) { if([pending containsObject:name] || [retryAfter[name] doubleValue]>NSProcessInfo.processInfo.systemUptime) return nil;[pending addObject:name]; }
    dispatch_async(worker,^{ @autoreleasepool {
        NSString *path=HCThemeResourcePath(name);
        NSURL *url=path ? [NSURL fileURLWithPath:path] : nil;
        CGImageSourceRef source=url ? CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL) : NULL;
        if(source) {
            NSDictionary *options=@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                (__bridge id)kCGImageSourceThumbnailMaxPixelSize:([name isEqual:@"app-background.jpg"] ? @256 : @640),
                (__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES,(__bridge id)kCGImageSourceShouldCacheImmediately:@YES};
            CGImageRef frame=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
            if(frame) { [cache setObject:[UIImage imageWithCGImage:frame] forKey:name cost:CGImageGetBytesPerRow(frame)*CGImageGetHeight(frame)];CGImageRelease(frame); }
            CFRelease(source);
        }
        BOOL loaded=[cache objectForKey:name]!=nil;
        @synchronized(pending) { [pending removeObject:name];
            if(loaded) [retryAfter removeObjectForKey:name];else retryAfter[name]=@(NSProcessInfo.processInfo.systemUptime+5);
        }
        if(loaded) dispatch_async(dispatch_get_main_queue(),^{[NSNotificationCenter.defaultCenter postNotificationName:@"HCThemeDidLoad" object:name];});
    }});
    return nil;
}
static void HCDrawImageFill(UIImage *image,CGRect rect,CGFloat alpha,CGFloat zoom) {
    if(!image || image.size.width<=0 || image.size.height<=0) return;
    CGFloat scale=MAX(rect.size.width/image.size.width,rect.size.height/image.size.height)*zoom;
    CGSize size=CGSizeMake(image.size.width*scale,image.size.height*scale);
    CGContextRef context=UIGraphicsGetCurrentContext();CGContextSaveGState(context);CGContextClipToRect(context,rect);
    [image drawInRect:CGRectMake(CGRectGetMidX(rect)-size.width/2,CGRectGetMidY(rect)-size.height/2,size.width,size.height) blendMode:kCGBlendModeNormal alpha:alpha];
    CGContextRestoreGState(context);
}
// Paint the whole card opaquely; only a localized shade sits above the photo.
static void HCDrawSkinCard(CGRect rect,NSString *name) {
    CGContextRef context=UIGraphicsGetCurrentContext();CGContextSaveGState(context);
    [[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:12] addClip];
    [[UIColor colorWithRed:0.14 green:0.12 blue:0.24 alpha:1] setFill];UIRectFill(rect);
    HCDrawImageFill(HCThemeImage(name),rect,1,1);
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    NSArray *colors=@[(__bridge id)[UIColor colorWithWhite:0 alpha:0.08].CGColor,
        (__bridge id)[UIColor colorWithWhite:0 alpha:0.68].CGColor];
    CGGradientRef shade=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,NULL);
    CGContextDrawLinearGradient(context,shade,rect.origin,CGPointMake(rect.origin.x,CGRectGetMaxY(rect)),0);
    CGGradientRelease(shade);CGColorSpaceRelease(space);CGContextRestoreGState(context);
}
static void HCDrawHeroIcon(int32_t heroID,CGRect rect) {
    UIImage *image=HCHeroIcon(heroID);
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);
    UIBezierPath *circle=[UIBezierPath bezierPathWithOvalInRect:rect];[circle addClip];
    [[UIColor colorWithWhite:0.12 alpha:0.95] setFill];UIRectFill(rect);
    if (image) {
        CGFloat scale=MAX(rect.size.width/image.size.width,rect.size.height/image.size.height);
        CGSize size=CGSizeMake(image.size.width*scale,image.size.height*scale);
        [image drawInRect:CGRectMake(CGRectGetMidX(rect)-size.width/2,CGRectGetMidY(rect)-size.height/2,size.width,size.height)];
    } else {
        NSString *text=[NSString stringWithFormat:@"%d",heroID];
        [text drawInRect:CGRectInset(rect,3,rect.size.height/3) withAttributes:@{
            NSFontAttributeName:[UIFont boldSystemFontOfSize:9],NSForegroundColorAttributeName:UIColor.whiteColor}];
    }
    CGContextRestoreGState(context);
    [[UIColor colorWithWhite:0.7 alpha:0.4] setStroke];circle.lineWidth=0.6;[circle stroke];
}

static void HCDrawHealthRing(NSDictionary *target,CGRect ring,BOOL redOnly,CGFloat width) {
    HCHeroHealth health=HCHeroHealthValue([target[@"hp"] doubleValue],[target[@"maxHP"] doubleValue],[target[@"hpKnown"] boolValue]);
    UIBezierPath *track=[UIBezierPath bezierPathWithOvalInRect:ring];
    [[UIColor colorWithWhite:0.12 alpha:0.85] setStroke];track.lineWidth=width;[track stroke];
    if(!health.known) {
        [(redOnly ? [UIColor colorWithRed:1 green:0.16 blue:0.22 alpha:0.35] : [UIColor colorWithWhite:0.65 alpha:0.45]) setStroke];
        track.lineWidth=width;[track stroke];
        [@"?" drawInRect:CGRectMake(CGRectGetMaxX(ring)-6,CGRectGetMaxY(ring)-9,9,11) withAttributes:@{
            NSFontAttributeName:[UIFont boldSystemFontOfSize:9],NSForegroundColorAttributeName:UIColor.whiteColor,
            NSStrokeColorAttributeName:UIColor.blackColor,NSStrokeWidthAttributeName:@-3}];return;
    }
    if(health.ratio<=0) return;
    UIColor *color=redOnly ? [UIColor colorWithRed:1 green:0.16 blue:0.22 alpha:1] :
        [UIColor colorWithRed:health.red green:health.green blue:health.blue alpha:1];
    UIBezierPath *arc=[UIBezierPath bezierPathWithArcCenter:CGPointMake(CGRectGetMidX(ring),CGRectGetMidY(ring))
        radius:ring.size.width/2 startAngle:-M_PI_2 endAngle:-M_PI_2+M_PI*2*health.ratio clockwise:YES];
    [color setStroke];arc.lineWidth=width;arc.lineCapStyle=kCGLineCapRound;[arc stroke];
}
@protocol HCEspPainting <NSObject>
- (void)drawEsp;
@end
@interface HCEspDrawingView : UIView
@property(nonatomic,weak) id<HCEspPainting> painter;
@end
@implementation HCEspDrawingView
- (void)drawRect:(CGRect)rect {
    (void)rect;
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextClearRect(context,self.bounds);
    [self.painter drawEsp];
}
@end

// UIKit does not document a general screenshot exclusion API. The secure text
// canvas is a best-effort host, not a promise across iOS/jailbreak versions.
static UIView *HCSecureCanvas(UIView *view) {
    for (UIView *child in view.subviews) {
        if ([NSStringFromClass(child.class) containsString:@"CanvasView"]) return child;
        UIView *found=HCSecureCanvas(child);if (found) return found;
    }
    return nil;
}

// Copy the secure text canvas's own compositor mask rather than hard-coding
// undocumented mask bits. Readback only verifies configuration, not a screenshot.
static BOOL HCConfigureCaptureLayer(CALayer *layer,CALayer *secureLayer,BOOL enabled) {
    static char previousMaskKey;
    @try {
        NSNumber *previous=objc_getAssociatedObject(layer,&previousMaskKey);
        if(!enabled) {
            if(previous) { [layer setValue:previous forKey:@"disableUpdateMask"];objc_setAssociatedObject(layer,&previousMaskKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC); }
            return YES;
        }
        id secureMask=[secureLayer valueForKey:@"disableUpdateMask"];
        id current=[layer valueForKey:@"disableUpdateMask"];
        if(![secureMask isKindOfClass:NSNumber.class] || ![current isKindOfClass:NSNumber.class] || [secureMask unsignedIntValue]==0) return NO;
        if(!previous) objc_setAssociatedObject(layer,&previousMaskKey,current,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        NSNumber *wanted=@([current unsignedIntValue] | [secureMask unsignedIntValue]);
        [layer setValue:wanted forKey:@"disableUpdateMask"];
        return [[layer valueForKey:@"disableUpdateMask"] isEqual:wanted];
    } @catch(NSException *exception) { (void)exception;return NO; }
}
