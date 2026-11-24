#import <UIKit/UIKit.h>

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
    [[UIColor colorWithRed:1 green:0.44 blue:0.48 alpha:1] setStroke];circle.lineWidth=1.5;[circle stroke];
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
