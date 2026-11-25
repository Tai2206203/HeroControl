#ifndef HC_THEME_RESOURCES_H
#define HC_THEME_RESOURCES_H
#import <Foundation/Foundation.h>
#include <mach-o/dyld.h>
static NSString *HCThemePathInRoots(NSString *name,NSArray<NSString *> *roots) {
    if(!name.length || ![name.lastPathComponent isEqual:name]) return nil;
    for(NSString *root in roots) {
        NSString *path=[[root stringByAppendingPathComponent:@"Theme"] stringByAppendingPathComponent:name];
        BOOL directory=NO;
        if([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&directory] && !directory) return path;
    }
    return nil;
}
static NSString *HCThemeResourcePath(NSString *name) {
    static NSArray *roots;static dispatch_once_t once;
    dispatch_once(&once,^{
        NSMutableArray *paths=[NSMutableArray array];
        uint32_t length=0;_NSGetExecutablePath(NULL,&length);
        if(length && length<65536) {
            NSMutableData *buffer=[NSMutableData dataWithLength:length];
            if(_NSGetExecutablePath(buffer.mutableBytes,&length)==0) {
                NSString *executable=[NSString stringWithUTF8String:buffer.bytes];
                if(executable.length) [paths addObject:executable.stringByResolvingSymlinksInPath.stringByDeletingLastPathComponent];
            }
        }
        if(NSBundle.mainBundle.resourcePath) [paths addObject:NSBundle.mainBundle.resourcePath];
        if(NSBundle.mainBundle.bundlePath) [paths addObject:NSBundle.mainBundle.bundlePath];
        roots=paths;
    });
    return HCThemePathInRoots(name,roots);
}
#endif
