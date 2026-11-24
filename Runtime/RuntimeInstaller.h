#ifndef HC_RUNTIME_INSTALLER_H
#define HC_RUNTIME_INSTALLER_H
#import "RuntimeShared.h"
#include <mach-o/dyld.h>
#include <limits.h>
#include <math.h>

// Included after HCReport/HCLibraryPaths in the diagnostic helper translation
// unit. All destinations are fixed names in verified game/loader directories.
static NSString *HCRuntimeLoaderDirectory(NSMutableDictionary *report) {
    NSMutableDictionary *roots = [NSMutableDictionary dictionary];
    HCLibraryPaths(roots);
    NSMutableSet *paths = [NSMutableSet set];
    for (NSString *root in roots[@"jailbreakRoots"]) {
        NSString *path = [root stringByAppendingPathComponent:@"Library/MobileSubstrate/DynamicLibraries"];
        struct stat info = {0};
        if (stat(path.fileSystemRepresentation, &info)==0 && S_ISDIR(info.st_mode) && info.st_uid==0 && !(info.st_mode & 0022))
            [paths addObject:path.stringByResolvingSymlinksInPath];
    }
    report[@"loaderCandidates"] = paths.allObjects;
    if (paths.count != 1) return nil;
    return paths.anyObject;
}
static BOOL HCRuntimeValidateConfig(NSDictionary *config) {
    return [config isKindOfClass:NSDictionary.class] &&
        [config[@"revision"] isKindOfClass:NSString.class] && [config[@"revision"] length]>0 &&
        [config[@"revision"] length]<=128 && HCRuntimeSettingsValid(config[@"settings"]);
}
static BOOL HCRuntimeSyncConfig(NSString *directory, NSDictionary *config, NSError **error) {
    if (!HCRuntimeValidateConfig(config)) return NO;
    NSMutableDictionary *value=[config mutableCopy];value[@"enabled"]=@YES;value[@"schemaVersion"]=@1;
    return HCRuntimeWriteJSON(value, [directory stringByAppendingPathComponent:@"config.json"], error);
}
static NSDictionary *HCRuntimeStatus(NSString *directory) {
    NSDictionary *state=HCRuntimeReadJSON([directory stringByAppendingPathComponent:@"state.json"], 4*1024*1024);
    NSMutableDictionary *value=[state ?: @{} mutableCopy];
    BOOL configured=[HCRuntimeReadJSON([directory stringByAppendingPathComponent:@"config.json"],131072)[@"enabled"] isEqual:@YES];
    BOOL fresh=configured && HCRuntimeFresh(state);
    value[@"responding"]=fresh ? @YES : @NO;
    if (!fresh) {
        if (!state) { value[@"phase"]=@"not_loaded";value[@"message"]=@"Chưa có phản hồi adapter. Cần bộ nạp tweak hoạt động và khởi động lại game."; }
        else if ([state[@"phase"] isEqual:@"active"]) { value[@"phase"]=@"stale";value[@"message"]=@"Phản hồi adapter đã cũ; không coi là đang kết nối."; }
        [value removeObjectForKey:@"appliedRevision"];
        if ([value[@"reports"] isKindOfClass:NSDictionary.class] && [value[@"reports"][@"code"] isKindOfClass:NSString.class] &&
            [value[@"reports"][@"message"] isKindOfClass:NSString.class]) value[@"historicalReports"]=value[@"reports"];
        else [value removeObjectForKey:@"historicalReports"];
        [value removeObjectForKey:@"reports"];
    }
    value[@"directory"]=directory;
    return value;
}

static NSDictionary *HCRuntimeReport(NSString *action, NSDictionary *config) {
    NSMutableDictionary *report=[HCReport(NO) mutableCopy];
    report[@"executionContext"]=@"runtime-helper";
    report[@"code"]=@"runtime_unavailable";report[@"summary"]=@"Chưa truy cập được adapter game.";
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (geteuid()!=0) { report[@"code"]=@"runtime_root_required";return report; }
    NSString *directory=HCRuntimeFindDirectory();
    if (!directory) { report[@"code"]=@"runtime_container_unavailable";report[@"summary"]=@"Không xác định duy nhất container dữ liệu của game; không ghi tệp.";return report; }
    NSFileManager *manager=NSFileManager.defaultManager;
    BOOL install=[action isEqual:@"--runtime-install"], remove=[action isEqual:@"--runtime-remove"];
    if (install || remove) {
        NSString *loader=HCRuntimeLoaderDirectory(report);
        if (!loader) { report[@"code"]=@"runtime_loader_unavailable";report[@"summary"]=@"Không tìm được duy nhất thư mục bộ nạp tweak được quản lý bởi root. Không tự đoán đường dẫn.";return report; }
        NSString *library=[loader stringByAppendingPathComponent:@"HeroControlRuntime.dylib"];
        NSString *filter=[loader stringByAppendingPathComponent:@"HeroControlRuntime.plist"];
        for (NSString *path in @[library,filter]) {
            struct stat info={0};
            if (!lstat(path.fileSystemRepresentation,&info) && (!S_ISREG(info.st_mode) || info.st_uid!=0)) {
                report[@"code"]=@"runtime_install_path_rejected";return report;
            }
        }
        NSError *error=nil;
        if (remove) {
            // Remove the filter first. No recursive deletion or wildcard paths.
            if ([manager fileExistsAtPath:filter] && ![manager removeItemAtPath:filter error:&error]) goto failed;
            if ([manager fileExistsAtPath:library] && ![manager removeItemAtPath:library error:&error]) goto failed;
            if ([manager fileExistsAtPath:directory])
                HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"enabled":@NO},[directory stringByAppendingPathComponent:@"config.json"],NULL);
            report[@"code"]=@"runtime_removed_restart_required";
            report[@"summary"]=@"Đã gỡ bộ nạp HeroControl. Đóng hoàn toàn và mở lại game để gỡ hook trong bộ nhớ. Nhật ký được giữ lại.";
        } else {
            if (!HCRuntimeValidateConfig(config)) { report[@"code"]=@"runtime_config_invalid";return report; }
            NSDictionary *inspection=HCGameInspection();
            if (![inspection[@"moduleMatchesDump"] isEqual:@YES]) {
                report[@"code"]=@"runtime_install_requires_matching_game";
                report[@"summary"]=@"Mở đúng phiên bản game và kiểm tra UUID trước khi cài adapter.";return report;
            }
            char executable[PATH_MAX];uint32_t size=sizeof(executable);
            if (_NSGetExecutablePath(executable,&size)) { report[@"code"]=@"runtime_helper_path_failed";return report; }
            NSString *app=[[[NSString stringWithUTF8String:executable] stringByResolvingSymlinksInPath] stringByDeletingLastPathComponent].stringByDeletingLastPathComponent;
            NSDictionary *appInfo=[NSDictionary dictionaryWithContentsOfFile:[app stringByAppendingPathComponent:@"Info.plist"]];
            if (![appInfo[@"CFBundleIdentifier"] isEqual:@"local.herocontrol.app"]) { report[@"code"]=@"runtime_app_bundle_rejected";return report; }
            NSString *source=[app stringByAppendingPathComponent:@"Runtime"];
            NSArray *files=@[@"HeroSkin_1.patch",@"HeroSkin_2.patch",@"ComplaintHistory.lua",@"Runtime.lua",@"manifest.json"];
            for (NSString *name in [files arrayByAddingObjectsFromArray:@[@"HeroControlRuntime.dylib",@"HeroControlRuntime.plist"]]) {
                struct stat info={0};NSString *path=[source stringByAppendingPathComponent:name];
                if (lstat(path.fileSystemRepresentation,&info) || !S_ISREG(info.st_mode) || info.st_size<=0 || info.st_size>4*1024*1024) {
                    report[@"code"]=@"runtime_payload_missing";report[@"summary"]=[@"Thiếu payload: " stringByAppendingString:name];return report;
                }
            }
            if (![manager createDirectoryAtPath:directory withIntermediateDirectories:NO attributes:@{NSFilePosixPermissions:@0700} error:&error] &&
                ![manager fileExistsAtPath:directory]) goto failed;
            if (chown(directory.fileSystemRepresentation,501,501) || chmod(directory.fileSystemRepresentation,0700)) goto failed;
            // Publish the injection filter only after all payload/config writes.
            if ([manager fileExistsAtPath:filter] && ![manager removeItemAtPath:filter error:&error]) goto failed;
            for (NSString *name in files) {
                NSString *path=[directory stringByAppendingPathComponent:name];
                struct stat existing={0};
                if (!lstat(path.fileSystemRepresentation,&existing) && !S_ISREG(existing.st_mode)) {
                    error=[NSError errorWithDomain:NSPOSIXErrorDomain code:EINVAL userInfo:@{NSLocalizedDescriptionKey:@"Đích payload không phải tệp thường; không ghi."}];goto failed;
                }
                NSData *data=[NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:name]];
                if (![data writeToFile:path options:NSDataWritingAtomic error:&error] ||
                    chown(path.fileSystemRepresentation,501,501) || chmod(path.fileSystemRepresentation,0600)) goto failed;
            }
            if (!HCRuntimeSyncConfig(directory,config,&error)) goto failed;
            for (NSString *name in @[@"HeroControlRuntime.dylib",@"HeroControlRuntime.plist"]) {
                NSString *path=[loader stringByAppendingPathComponent:name];
                NSData *data=[NSData dataWithContentsOfFile:[source stringByAppendingPathComponent:name]];
                if (![data writeToFile:path options:NSDataWritingAtomic error:&error] || chown(path.fileSystemRepresentation,0,0) || chmod(path.fileSystemRepresentation,0644)) goto failed;
            }
            report[@"code"]=@"runtime_installed_restart_required";
            report[@"summary"]=@"Đã cài payload và bộ lọc riêng cho game. Đóng hoàn toàn rồi mở lại game; chỉ phản hồi adapter mới xác nhận nạp thành công.";
        }
        {
            NSMutableDictionary *state=[HCRuntimeStatus(directory) mutableCopy];
            state[@"responding"]=@NO;state[@"phase"]=remove ? @"removed_restart_required" : @"restart_required";
            state[@"message"]=report[@"summary"];
            [state removeObjectForKey:@"appliedRevision"];
            if ([state[@"reports"] isKindOfClass:NSDictionary.class]) {
                state[@"historicalReports"]=state[@"reports"];
                [state removeObjectForKey:@"reports"];
            }
            report[@"runtime"]=state;return report;
        }
    failed:
        report[@"code"]=@"runtime_install_io_failed";report[@"summary"]=error.localizedDescription ?: [NSString stringWithFormat:@"Không hoàn tất ghi/gỡ adapter: errno=%d (%s).",errno,strerror(errno)];
        return report;
    }
    if ([action isEqual:@"--runtime-apply"]) {
        NSError *error=nil;
        if (!HCRuntimeSyncConfig(directory,config,&error)) {
            report[@"code"]=@"runtime_config_write_failed";report[@"summary"]=error.localizedDescription ?: @"Cấu hình runtime không hợp lệ.";return report;
        }
        report[@"runtimeRequestAccepted"]=@YES;
        NSTimeInterval deadline=NSProcessInfo.processInfo.systemUptime+3;
        do {
            NSDictionary *state=HCRuntimeStatus(directory);
            if ([state[@"responding"] isEqual:@YES] && [state[@"appliedRevision"] isEqual:config[@"revision"]]) break;
            usleep(100000);
        } while (NSProcessInfo.processInfo.systemUptime<deadline);
    }
    NSDictionary *state=HCRuntimeStatus(directory);
    report[@"runtime"]=state;report[@"code"]=state[@"code"] ?: @"runtime_not_loaded";
    report[@"summary"]=state[@"message"] ?: @"Chưa có phản hồi adapter.";
    if ([action isEqual:@"--runtime-apply"] && ![state[@"appliedRevision"] isEqual:config[@"revision"]]) {
        report[@"code"]=@"runtime_request_queued";
        report[@"summary"]=@"Đã lưu yêu cầu. Vào game để adapter thực thi, sau đó quay lại kiểm tra; chưa xác nhận revision mới.";
    }
#else
    (void)action;(void)config;
    report[@"code"]=@"runtime_requires_device";report[@"summary"]=@"Adapter chỉ chạy trên iPhone có bộ nạp tweak tương thích.";
#endif
    return report;
}
#endif
