#import <Foundation/Foundation.h>
#include <notify.h>
#include <unistd.h>
int main(void) { @autoreleasepool {
    // Stop only this package's HUD. Never kill SpringBoard or another app.
    notify_post("local.dorocheat.deb.overlay.DORO-CHEAT-DEB.stop");
    NSString *path=@"/var/mobile/Library/Application Support/DORO-CHEAT-DEB/Library/Caches/HeroOverlay/state.json";
    NSTimeInterval end=NSProcessInfo.processInfo.systemUptime+3;
    while(NSProcessInfo.processInfo.systemUptime<end) {
        NSData *data=[NSData dataWithContentsOfFile:path];
        NSDictionary *state=data.length && data.length<4*1024*1024 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if(![state isKindOfClass:NSDictionary.class] || ![state[@"phase"] isEqual:@"visible"]) break;
        usleep(100000);
    }
} return 0; }
