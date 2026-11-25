#import "../Overlay/ThemeResources.h"
#import <ImageIO/ImageIO.h>
#include <assert.h>
int main(int argc,const char **argv) { @autoreleasepool {
    assert(argc==2);NSString *root=[NSString stringWithUTF8String:argv[1]];
    for(NSString *name in @[@"violet-sss.png",@"lauriel-sss.jpg",@"airi-sss.jpg",@"app-background.jpg"]) {
        NSString *path=HCThemePathInRoots(name,@[@"/nonexistent-root",root]);assert(path);
        CGImageSourceRef source=CGImageSourceCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path],NULL);assert(source);
        NSDictionary *options=@{(__bridge id)kCGImageSourceCreateThumbnailFromImageAlways:@YES,(__bridge id)kCGImageSourceThumbnailMaxPixelSize:@640,(__bridge id)kCGImageSourceShouldCacheImmediately:@YES};
        CGImageRef image=CGImageSourceCreateThumbnailAtIndex(source,0,(__bridge CFDictionaryRef)options);
        assert(image && CGImageGetWidth(image)>0 && CGImageGetHeight(image)>0);
        CGImageRelease(image);CFRelease(source);
    }
    assert(!HCThemePathInRoots(@"../violet-sss.png",@[root]));
    assert(!HCThemePathInRoots(@"missing.jpg",@[root]));
    (void)HCThemeResourcePath;
    puts("Packaged theme assets passed: executable-root lookup fallback, SSS photos and icon decode, missing/traversal names rejected.");
} return 0; }
