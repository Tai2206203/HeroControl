#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <ImageIO/ImageIO.h>
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
static UIImage *HCHeroIcon(int32_t heroID) {
    static NSCache *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache=[NSCache new];cache.countLimit=64; });
    NSString *key=[NSString stringWithFormat:@"%d",heroID];
    UIImage *image=[cache objectForKey:key];
    if (image) return image;
    NSDictionary *entry=HCHeroCatalog()[key];
    if (!entry) return nil;
    // Filenames are fixed from the integer ID, never paths supplied by game memory.
    NSString *path=[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
        [NSString stringWithFormat:@"HeroIcons/%d.img",heroID]];
    image=[UIImage imageWithContentsOfFile:path];
    if (image) [cache setObject:image forKey:key];
    return image;
}
static UIImage *HCThemeImage(NSString *name) {
    static NSCache *cache;static dispatch_once_t once;
    dispatch_once(&once,^{ cache=[NSCache new];cache.countLimit=4; });
    UIImage *image=[cache objectForKey:name];
    if(!image) {
        NSURL *url=[NSURL fileURLWithPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:[@"Theme/" stringByAppendingString:name]]];
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)url,NULL);
        if(source) {
            NSDictionary *options=@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,
                (__bridge id)kCGImageSourceThumbnailMaxPixelSize:@1024,(__bridge id)kCGImageSourceCreateThumbnailWithTransform:@YES,
                (__bridge id)kCGImageSourceShouldCacheImmediately:@YES};
            CGImageRef thumbnail=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
            if(thumbnail) { image=[UIImage imageWithCGImage:thumbnail];CGImageRelease(thumbnail); }
            CFRelease(source);
        }
        if(image) [cache setObject:image forKey:name];
    }
    return image;
}
static void HCDrawImageFill(UIImage *image,CGRect rect,CGFloat alpha,CGFloat zoom) {
    if(!image || image.size.width<=0 || image.size.height<=0) return;
    CGFloat scale=MAX(rect.size.width/image.size.width,rect.size.height/image.size.height)*zoom;
    CGSize size=CGSizeMake(image.size.width*scale,image.size.height*scale);
    CGContextRef context=UIGraphicsGetCurrentContext();CGContextSaveGState(context);CGContextClipToRect(context,rect);
    [image drawInRect:CGRectMake(CGRectGetMidX(rect)-size.width/2,CGRectGetMidY(rect)-size.height/2,size.width,size.height) blendMode:kCGBlendModeNormal alpha:alpha];
    CGContextRestoreGState(context);
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
static void HCFillGradient(CGRect rect,UIColor *first,UIColor *last) {
    CGContextRef context=UIGraphicsGetCurrentContext();
    CGContextSaveGState(context);[[UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:14] addClip];
    CGColorSpaceRef space=CGColorSpaceCreateDeviceRGB();
    NSArray *colors=@[(__bridge id)first.CGColor,(__bridge id)last.CGColor];
    CGGradientRef gradient=CGGradientCreateWithColors(space,(__bridge CFArrayRef)colors,NULL);
    CGContextDrawLinearGradient(context,gradient,rect.origin,CGPointMake(CGRectGetMaxX(rect),CGRectGetMaxY(rect)),0);
    CGGradientRelease(gradient);CGColorSpaceRelease(space);CGContextRestoreGState(context);
}

@protocol HCEspPainting <NSObject>
- (void)drawEsp;
@end
@interface HCEspDrawingView : UIView
@property(nonatomic,weak) id<HCEspPainting> painter;
@end
@implementation HCEspDrawingView
- (void)drawRect:(CGRect)rect { (void)rect;[self.painter drawEsp]; }
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
