#ifndef HC_RUNTIME_SHARED_H
#define HC_RUNTIME_SHARED_H
#import <Foundation/Foundation.h>
#include <sys/stat.h>
#include <unistd.h>
#include <signal.h>
#include <math.h>
#include <stdint.h>
#include <errno.h>

#define HC_RUNTIME_BUILD "33"
#ifndef HC_RUNTIME_GENERATION
#define HC_RUNTIME_GENERATION "development"
#endif
static NSString *const HCRuntimeUUID = @"298E718A-DA06-33B8-8253-910447B649E3";
static NSString *const HCRuntimeBundle = @"com.garena.game.kgvn";
static NSString *const HCRuntimeFolder = @"Documents/HeroControlRuntime";

static inline BOOL HCRuntimeSettingsValid(id settings) {
    if (![settings isKindOfClass:NSDictionary.class]) return NO;
    id flags=settings[@"flags"], skins=settings[@"selectedSkins"], scale=settings[@"cameraScale"];
    if (![flags isKindOfClass:NSDictionary.class] || [flags count]>14 || ![skins isKindOfClass:NSDictionary.class] || [skins count]>512 ||
        ![scale isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)scale)==CFBooleanGetTypeID() ||
        !isfinite([scale doubleValue]) || [scale doubleValue]<1 || [scale doubleValue]>2.3) return NO;
    NSArray *keys=@[@"__ifxEnemyEspEnabledV1", @"DoroCheat.Reference.R1.Box", @"DoroCheat.Reference.R1.Icon", @"DoroCheat.Reference.R1.HP",
        @"DoroCheat.Reference.R1.Map", @"DoroCheat.Reference.R1.Unseen", @"DoroCheat.Reference.R1.Check",
        @"reports.enabled"];
    for (NSString *key in keys) {
        id flag=flags[key];
        if (![flag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID()) return NO;
    }
    NSArray *optional=@[@"DoroCheat.Style.Banner",@"HeroControl.ESP.HeroID",@"DoroCheat.Style.Buttons",@"DoroCheat.Style.Skin",@"DoroCheat.Style.BeforeMatch",@"DoroCheat.Style.LiveChange"];
    for(id key in flags) {
        if(![keys containsObject:key] && ![optional containsObject:key]) return NO;
        id flag=flags[key];if(![flag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID()) return NO;
    }
    id period=settings[@"reportsPeriod"];
    if(period && ![@[@"all",@"week",@"month"] containsObject:period]) return NO;
    id refresh=settings[@"reportsRefreshID"];
    if(refresh && (![refresh isKindOfClass:NSString.class] || [refresh length]>128)) return NO;
    id heroIDFlag=flags[@"HeroControl.ESP.HeroID"];
    if (heroIDFlag && (![heroIDFlag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)heroIDFlag)!=CFBooleanGetTypeID())) return NO;
    for (NSString *key in @[@"cameraEnabled",@"gameRuntimeEnabled",@"espCaptureProtected",@"minimapRotated",@"minimapAutoAlign"]) {
        id flag=settings[key];
        if (flag && (![flag isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)flag)!=CFBooleanGetTypeID())) return NO;
    }
    NSDictionary *ranges=@{@"espCombinedScale":@[@0.5,@4],@"minimapPortraitX":@[@0,@1],@"minimapPortraitY":@[@0,@1],@"minimapPortraitSize":@[@80,@240],@"minimapX":@[@0,@1],@"minimapY":@[@0,@1],@"minimapSize":@[@80,@240],@"minimapWorldExtent":@[@30,@200],@"minimapIconSize":@[@8,@40],@"espBoxWidthScale":@[@0.5,@3],@"espBoxHeightScale":@[@0.5,@3],@"espIconSize":@[@12,@64],@"minimapCenterX":@[@-200,@200],@"minimapCenterZ":@[@-200,@200],@"minimapAngle":@[@-180,@180]};
    for (NSString *key in ranges) {
        id value=settings[key];NSArray *range=ranges[key];
        if (value && (![value isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID() ||
            !isfinite([value doubleValue]) || [value doubleValue]<[range[0] doubleValue] || [value doubleValue]>[range[1] doubleValue])) return NO;
    }
    NSCharacterSet *nonDigits=[[NSCharacterSet characterSetWithCharactersInString:@"0123456789"] invertedSet];
    for (id hero in skins) {
        id skin=skins[hero];
        if (![hero isKindOfClass:NSString.class] || ![hero length] || [hero length]>10 ||
            [hero rangeOfCharacterFromSet:nonDigits].location!=NSNotFound || [hero longLongValue]>UINT32_MAX ||
            ![skin isKindOfClass:NSNumber.class] || CFGetTypeID((__bridge CFTypeRef)skin)==CFBooleanGetTypeID() ||
            [skin doubleValue]!=[skin unsignedIntValue]) return NO;
    }
    return YES;
}

static inline NSDictionary *HCRuntimeReadJSON(NSString *path, NSUInteger limit) {
    struct stat info = {0};
    if (lstat(path.fileSystemRepresentation, &info) || !S_ISREG(info.st_mode) ||
        info.st_size <= 0 || (uint64_t)info.st_size > limit) return nil;
    NSData *data = [NSData dataWithContentsOfFile:path];
    if (!data || data.length > limit) return nil;
    id value = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    return [value isKindOfClass:NSDictionary.class] ? value : nil;
}

static inline BOOL HCRuntimeFresh(NSDictionary *state) {
    id heartbeat = state[@"heartbeat"];
    if (![heartbeat isKindOfClass:NSNumber.class] || ![state[@"phase"] isEqual:@"active"] ||
        ![state[@"runtimeBuild"] isEqual:@HC_RUNTIME_BUILD] || ![state[@"generation"] isEqual:@HC_RUNTIME_GENERATION]) return NO;
    double age = NSProcessInfo.processInfo.systemUptime - [heartbeat doubleValue];
    return age >= 0 && age < 6 && [state[@"pid"] intValue] > 0 && kill([state[@"pid"] intValue], 0) == 0;
}

static inline NSString *HCRuntimeFindDirectory(void) {
    NSString *parent = @"/var/mobile/Containers/Data/Application";
    NSMutableSet *matches = [NSMutableSet set];
    for (NSString *name in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:NULL]) {
        if (name.length != 36 || [name rangeOfCharacterFromSet:
            [[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdefABCDEF-"] invertedSet]].location != NSNotFound) continue;
        NSString *home = [parent stringByAppendingPathComponent:name];
        struct stat info = {0};
        if (lstat(home.fileSystemRepresentation, &info) || !S_ISDIR(info.st_mode) || info.st_uid != 501) continue;
        NSDictionary *metadata = [NSDictionary dictionaryWithContentsOfFile:
            [home stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
        if ([metadata[@"MCMMetadataIdentifier"] isEqual:HCRuntimeBundle])
            [matches addObject:[home stringByResolvingSymlinksInPath]];
    }
    if (matches.count != 1) return nil;
    NSString *directory = [[matches anyObject] stringByAppendingPathComponent:HCRuntimeFolder];
    // Existing paths must be real directories owned by mobile, never aliases.
    for (NSString *path in @[directory.stringByDeletingLastPathComponent, directory]) {
        struct stat info = {0};
        if (lstat(path.fileSystemRepresentation, &info) == 0 && (!S_ISDIR(info.st_mode) || info.st_uid != 501)) return nil;
    }
    return directory;
}

static inline BOOL HCRuntimeWriteJSON(NSDictionary *value, NSString *path, NSError **error) {
    struct stat previous={0};
    if (!lstat(path.fileSystemRepresentation,&previous) && !S_ISREG(previous.st_mode)) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:nil];
        return NO;
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingSortedKeys error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    if ((geteuid() == 0 && chown(path.fileSystemRepresentation, 501, 501)) || chmod(path.fileSystemRepresentation, 0600)) {
        if (error) *error=[NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
        return NO;
    }
    return YES;
}
#endif
