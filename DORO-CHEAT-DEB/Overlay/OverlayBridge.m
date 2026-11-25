#include "../Protection/ProtectedStrings.h"
#import "OverlayCommon.h"
#include "OverlayLock.h"
#include <dlfcn.h>
#include <spawn.h>
#include <fcntl.h>
#include <notify.h>
#include <sys/wait.h>
#include <TargetConditionals.h>
#include <errno.h>
#include <string.h>

static NSDictionary *HCOverlayReply(BOOL ok, NSString *message, NSDictionary *state, NSString *directory) {
    NSMutableDictionary *reply = [@{@"ok": @(ok), @"message": message ?: @"", @"state": state ?: @{}} mutableCopy];
    if (!ok && directory) {
        NSString *path = [directory stringByAppendingPathComponent:@"startup.log"];
        NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
        if (file) {
            NSData *data = [file readDataOfLength:8192];
            [file closeFile];
            reply[@"startupLog"] = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
        }
    }
    return reply;
}

static void HCOverlayReapLater(pid_t child) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status = 0;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    });
}

static NSDictionary *HCOverlayLaunchReply(BOOL ok, NSString *message, NSDictionary *state,
                                        NSString *directory, NSDictionary *launch) {
    NSMutableDictionary *reply = [HCOverlayReply(ok, message, state, ok ? nil : directory) mutableCopy];
    reply[@"launch"] = launch;
    return reply;
}

static NSDictionary *HCOverlayHandle(NSDictionary *request) {
    NSString *action = request[@"action"], *directory = request[@"directory"], *profile = request[@"profile"];
    if (![@[@"start", @"status", @"stop", @"toggle"] containsObject:action])
        return HCOverlayReply(NO, @"Lệnh overlay không hợp lệ.", nil, nil);
#if !TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
    return HCOverlayReply(NO, @"Nút nổi hệ thống chỉ chạy trên iPhone có môi trường cấp quyền phù hợp.", nil, nil);
#else
    if (!HCOverlayPathsValid(directory, profile))
        return HCOverlayReply(NO, @"Đường dẫn cấu hình/overlay không thuộc vùng dữ liệu DEB hợp lệ.", nil, nil);
    NSDictionary *state = HCOverlayReadState(directory);
    BOOL running = HCOverlayFresh(state);
    if ([action isEqual:@"status"])
        return HCOverlayReply(YES, running ? @"Tiến trình nút nổi đang phản hồi." : @"Nút nổi chưa chạy hoặc đã dừng.",
            running ? state : @{@"schemaVersion": @1, @"phase": @"stopped", @"lastState": state ?: @{}}, nil);
    if ([action isEqual:@"stop"] || [action isEqual:@"toggle"]) {
        // Still send STOP when the state file is stale: failure to update a
        // heartbeat must not remove the user's route for dismissing the window.
        if (!running && ![action isEqual:@"stop"]) return HCOverlayReply(NO, @"Nút nổi chưa chạy.", state, nil);
        uint32_t result = notify_post(HCOverlayNotification(directory, action).UTF8String);
        // An acknowledgement from the process, not notify_post alone, determines
        // the new state. The app polls status after this short command returns.
        return HCOverlayReply(result == NOTIFY_STATUS_OK, @"Đã gửi yêu cầu đến nút nổi.", state, nil);
    }
    NSString *currentVersion = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    if (running && ((currentVersion && ![state[@"appVersion"] isEqual:currentVersion]) || ![state[@"generation"] isEqual:@HC_RUNTIME_GENERATION])) {
        // An app upgrade can leave the old root HUD alive even though the app
        // files have changed. Do not silently reuse its old input implementation.
        notify_post(HCOverlayNotification(directory, @"stop").UTF8String);
        NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 2;
        do {
            [NSThread sleepForTimeInterval:0.1];
            state = HCOverlayReadState(directory);
            running = HCOverlayFresh(state);
        } while (running && NSProcessInfo.processInfo.systemUptime < deadline);
        if (running) return HCOverlayReply(NO, @"Phiên nút nổi cũ chưa dừng. Bấm Tắt nút nổi rồi bật lại.", state, directory);
    }
    if (running) {
        notify_post(HCOverlayNotification(directory,@"welcome").UTF8String);
        return HCOverlayReply(YES,@"DORO-CHEAT",state,nil);
    }
    NSString *helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Tools/HeroOverlay.app/hero-overlay"];
    if (access(helper.fileSystemRepresentation, X_OK))
        return HCOverlayReply(NO, @"Gói cài thiếu Tools/HeroOverlay.app/hero-overlay.", state, nil);
    typedef int (*SetPersona)(const posix_spawnattr_t *, uid_t, uint32_t);
    typedef int (*SetID)(const posix_spawnattr_t *, uid_t);
    SetPersona persona = (SetPersona)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaNp));
    SetID setUID = (SetID)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaUidNp));
    SetID setGID = (SetID)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaGidNp));
    if (!persona || !setUID || !setGID)
        return HCOverlayReply(NO, @"Không có API persona để khởi chạy overlay riêng.", state, nil);
    posix_spawnattr_t attr;
    int result = posix_spawnattr_init(&attr);
    if (result) return HCOverlayReply(NO, @"Không tạo được thuộc tính tiến trình overlay.", state, nil);
    result = persona(&attr, 99, 1);
    if (!result) result = setUID(&attr, 0);
    if (!result) result = setGID(&attr, 0);
    if (!result) result = posix_spawnattr_setpgroup(&attr, 0);
    if (!result) result = posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETPGROUP);
    posix_spawn_file_actions_t files;
    int setup = posix_spawn_file_actions_init(&files);
    if (!result) result = setup;
    NSString *logPath = [directory stringByAppendingPathComponent:@"startup.log"];
    // Create as mobile before persona spawning; the root child must not leave
    // a new 0600 root-owned log that the app cannot read afterwards.
    int log = open(logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_NOFOLLOW | O_TRUNC, 0600);
    if (log < 0 && !result) result = errno;
    if (log >= 0) close(log);
    if (!result) result = posix_spawn_file_actions_addopen(&files, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    if (!result) result = posix_spawn_file_actions_addopen(&files, STDOUT_FILENO,
        logPath.fileSystemRepresentation, O_WRONLY | O_CREAT | O_TRUNC | O_NOFOLLOW, 0600);
    if (!result) result = posix_spawn_file_actions_adddup2(&files, STDOUT_FILENO, STDERR_FILENO);
    NSString *lockPath = [directory stringByAppendingPathComponent:[NSString stringWithUTF8String:HC_OVERLAY_LOCK_NAME]];
    int lockFD = -1, lockError = 0;
    if (!result) {
        lockFD = HCOverlayAcquireLock(lockPath.fileSystemRepresentation, &lockError);
        if (lockFD < 0) result = lockError;
    }
    if (!result) result = posix_spawn_file_actions_adddup2(&files, lockFD, HC_OVERLAY_LOCK_FD);
    if (!result) result = posix_spawn_file_actions_addclose(&files, lockFD);
    pid_t child = -1;
    char *argv[] = {(char *)helper.fileSystemRepresentation, "--run", (char *)directory.fileSystemRepresentation,
        (char *)profile.fileSystemRepresentation, "--lock-fd", "3", NULL};
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/mobile", "CFFIXED_USER_HOME=/var/mobile", NULL};
    BOOL spawnAttempted = result == 0;
    if (spawnAttempted) result = posix_spawn(&child, helper.fileSystemRepresentation, &files, &attr, argv, env);
    // Do not LOCK_UN: the inherited child descriptor shares the same lock.
    if (lockFD >= 0) close(lockFD);
    if (!setup) posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attr);
    if (result) {
        NSString *message = lockError ? [NSString stringWithFormat:@"Ứng dụng không lấy được khóa overlay: %d (%s).", lockError, strerror(lockError)] :
            [NSString stringWithFormat:@"Không khởi chạy được overlay: %d (%s).", result, strerror(result)];
        NSMutableDictionary *reply = [HCOverlayReply(NO, message, state, directory) mutableCopy];
        reply[@"launch"] = @{@"spawnAttempted": @(spawnAttempted), @"setupStatus": @(result), @"lockError": @(lockError)};
        return reply;
    }
    NSMutableDictionary *launch = [@{@"spawnStatus": @0, @"pid": @(child), @"helperPath": helper,
        @"directory": directory, @"profile": profile, @"appEUID": @(geteuid()), @"exited": @NO,
        @"lockPreparedByApp": @YES, @"inheritedLockFD": @(HC_OVERLAY_LOCK_FD)} mutableCopy];
    // Observe startup here before handing reaping to a background queue. The
    // old waiter discarded exit 64/73/77 and signals, masking all as a timeout.
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 8;
    do {
        [NSThread sleepForTimeInterval:0.1];
        state = HCOverlayReadState(directory);
        int status = 0;
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) {
            launch[@"exited"] = @YES;
            NSString *message;
            if (WIFSIGNALED(status)) {
                launch[@"signal"] = @(WTERMSIG(status));
                message = [NSString stringWithFormat:@"Overlay bị dừng bởi tín hiệu %d. Xem launch/startupLog; chưa xác định nguyên nhân.", WTERMSIG(status)];
            } else {
                launch[@"exitStatus"] = @(WEXITSTATUS(status));
                message = [NSString stringWithFormat:@"Overlay thoát với mã %d trước khi xác nhận cửa sổ. Xem launch/startupLog.", WEXITSTATUS(status)];
            }
            return HCOverlayLaunchReply(NO, message, state, directory, launch);
        }
        if (waited < 0 && errno != EINTR) {
            launch[@"waitError"] = @(errno);
            return HCOverlayLaunchReply(NO, @"Không thu được trạng thái tiến trình overlay.", state, directory, launch);
        }
        if (HCOverlayFresh(state)) {
            HCOverlayReapLater(child);
            return HCOverlayLaunchReply(YES, @"Nút nổi đã đăng ký cửa sổ hệ thống.", state, directory, launch);
        }
        if ([state[@"pid"] intValue] == child && [state[@"phase"] isEqual:@"failed"]) {
            HCOverlayReapLater(child);
            return HCOverlayLaunchReply(NO, state[@"message"], state, directory, launch);
        }
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    HCOverlayReapLater(child);
    launch[@"startupTimedOut"] = @YES;
    return HCOverlayLaunchReply(NO, @"Overlay chưa xác nhận cửa sổ sau 8 giây. Xem state.stage và startupLog.", state, directory, launch);
#endif
}

__attribute__((visibility("default"))) const char *hc_overlay_request(const char *json) {
    @autoreleasepool {
        NSDictionary *reply;
        @try {
            if (!json || strnlen(json, 16385) > 16384) reply = HCOverlayReply(NO, @"Yêu cầu quá dài.", nil, nil);
            else {
                id request = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:json] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
                reply = [request isKindOfClass:NSDictionary.class] ? HCOverlayHandle(request) : HCOverlayReply(NO, @"Yêu cầu JSON không hợp lệ.", nil, nil);
            }
        } @catch (NSException *exception) { reply = HCOverlayReply(NO, exception.reason, nil, nil); }
        NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
        return strdup([[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding].UTF8String ?: "{\"ok\":false,\"message\":\"serialization failed\",\"state\":{}}");
    }
}
__attribute__((visibility("default"))) void hc_overlay_release(const char *json) { free((void *)json); }
