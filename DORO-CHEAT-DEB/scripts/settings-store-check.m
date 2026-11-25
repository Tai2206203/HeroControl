#import <Foundation/Foundation.h>
#import "HCFeatures.h"
#import "../Overlay/SettingsStore.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        if(getuid()!=501) { puts("Settings store file fixture requires mobile-equivalent UID 501; compile passed, fixture skipped.");return 0; }
        NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *profile=[folder stringByAppendingPathComponent:@"HeroControl.profile.json"];
        NSString *lock=[profile stringByAppendingString:@".edit-lock"];
        int fd=open(lock.fileSystemRepresentation,O_RDWR|O_CREAT|O_EXCL,0600);assert(fd>=0);close(fd);
        NSMutableDictionary *flags=[NSMutableDictionary dictionary];
        for(NSDictionary *feature in HCFeatures()) flags[feature[@"key"]]=@NO;
        NSDictionary *settings=@{@"readMemoryOnly":@NO,@"flags":flags,@"cameraScale":@1.7,@"selectedSkins":@{},@"minimapX":@0.08,@"minimapPortraitX":@0.21};
        assert(HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"settings":settings},profile,NULL));
        assert([HCSettingsSnapshot(profile,YES)[@"ok"] isEqual:@YES]);
        NSMutableDictionary *changed=[settings mutableCopy];changed[@"cameraScale"]=@2.1;changed[@"readMemoryOnly"]=@YES;
        assert(HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"settings":changed},profile,NULL));
        assert([HCSettingsSnapshot(profile,NO)[@"ok"] isEqual:@YES]);
        NSDictionary *restored=HCRuntimeReadJSON(profile,131072)[@"settings"];
        assert([restored[@"cameraScale"] isEqual:@1.7] && [restored[@"minimapPortraitX"] isEqual:@0.21]);
        assert(!HCReadMemoryOnly(restored));
        NSData *before=[NSData dataWithContentsOfFile:profile];
        NSString *snapshot=[folder stringByAppendingPathComponent:@"HeroControl.settings.json"];
        assert([[@"invalid" dataUsingEncoding:NSUTF8StringEncoding] writeToFile:snapshot atomically:YES]);
        assert([HCSettingsSnapshot(profile,NO)[@"ok"] isEqual:@NO]);
        assert([before isEqual:[NSData dataWithContentsOfFile:profile]]);
        assert([NSFileManager.defaultManager removeItemAtPath:folder error:NULL]);
        puts("Native settings store passed: snapshot round-trip, independent minimap layouts and corrupt-load preservation.");
    }
    return 0;
}
