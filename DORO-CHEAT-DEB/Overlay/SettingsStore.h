#ifndef HC_SETTINGS_STORE_H
#define HC_SETTINGS_STORE_H
#import "../Runtime/RuntimeShared.h"
#include <sys/file.h>
#include <fcntl.h>
static NSDictionary *HCSettingsSnapshot(NSString *profile,BOOL save) {
    NSString *lock=[profile stringByAppendingString:@".edit-lock"];
    int fd=open(lock.fileSystemRepresentation,O_RDWR|O_NOFOLLOW|O_CLOEXEC);
    struct stat st={0};
    if(fd<0 || fstat(fd,&st) || !S_ISREG(st.st_mode) || st.st_uid!=501 || flock(fd,LOCK_EX|LOCK_NB)) {
        if(fd>=0) close(fd);
        return @{@"ok":@NO,@"message":@"Cấu hình đang được sửa. Thử lại sau giây lát."};
    }
    NSDictionary *result;
    NSString *snapshot=[profile.stringByDeletingLastPathComponent stringByAppendingPathComponent:@"HeroControl.settings.json"];
    NSDictionary *root=HCRuntimeReadJSON(save ? profile : snapshot,131072);
    NSMutableDictionary *settings=[root[@"settings"] isKindOfClass:NSDictionary.class] ? [root[@"settings"] mutableCopy] : nil;
    if(settings && ![settings[@"flags"] isKindOfClass:NSDictionary.class]) settings=nil;
    NSMutableDictionary *flags=[NSMutableDictionary dictionary];
    if(settings && [root[@"schemaVersion"] isEqual:@1]) {
        for(NSDictionary *feature in HCFeatures()) {
            NSString *key=feature[@"key"];id value=settings[@"flags"][key];
            if(!value) value=@NO;
            if(![value isKindOfClass:NSNumber.class] || ([value doubleValue]!=0 && [value doubleValue]!=1)) { settings=nil;break; }
            flags[key]=[value boolValue] ? @YES : @NO;
        }
    } else settings=nil;
    if(settings) { settings[@"flags"]=flags;settings[@"selectedSkins"]=@{};settings[@"minimapAutoAlign"]=@NO; }
    if(!settings || !HCRuntimeSettingsValid(settings)) {
        result=@{@"ok":@NO,@"message":save ? @"Không lưu: cấu hình hiện tại không hợp lệ." : @"Chưa có bản lưu hợp lệ. Cấu hình hiện tại được giữ nguyên."};
    } else {
        if(!save) {
            NSDictionary *current=HCRuntimeReadJSON(profile,131072);
            if([current[@"settings"] isKindOfClass:NSDictionary.class] && [current[@"settings"][@"gameRuntimeEnabled"] isEqual:@YES])
                settings[@"gameRuntimeEnabled"]=@YES;
        }
        if(!save && [flags[@"reports.enabled"] isEqual:@YES]) {
            settings[@"reportsRefreshID"]=NSUUID.UUID.UUIDString;settings[@"gameRuntimeEnabled"]=@YES;
        }
        NSDictionary *value=@{@"schemaVersion":@1,@"settings":settings,@"revision":NSUUID.UUID.UUIDString};
        NSError *error=nil;
        BOOL written=HCRuntimeWriteJSON(value,save ? snapshot : profile,&error);
        result=@{@"ok":@(written),@"message":written ? (save ? @"Đã lưu cấu hình riêng." : @"Đã tải cấu hình đã lưu.") : (error.localizedDescription ?: @"Không ghi được cấu hình; bản trước được giữ nguyên.")};
    }
    flock(fd,LOCK_UN);close(fd);return result;
}
#endif
