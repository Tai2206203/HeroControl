#import "OverlayCommon.h"
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

static NSDictionary *HCOverlayHandle(NSDictionary *request) {
    NSString *action = request[@"action"], *directory = request[@"directory"], *profile = request[@"profile"];
    if (![@[@"start", @"status", @"stop", @"toggle"] containsObject:action])
        return HCOverlayReply(NO, @"Lệnh overlay không hợp lệ.", nil, nil);
#if !TARGET_OS_IPHONE || TARGET_OS_SIMULATOR
    return HCOverlayReply(NO, @"Nút nổi hệ thống chỉ chạy trên iPhone có môi trường cấp quyền phù hợp.", nil, nil);
#else
    if (!HCOverlayPathsValid(directory, profile))
        return HCOverlayReply(NO, @"Đường dẫn cấu hình/overlay không thuộc container Hero Control hợp lệ.", nil, nil);
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
    if (running) return HCOverlayReply(YES, @"Nút nổi đã chạy; giữ nguyên phiên hiện có.", state, nil);
    NSString *helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Tools/HeroOverlay.app/hero-overlay"];
    if (access(helper.fileSystemRepresentation, X_OK))
        return HCOverlayReply(NO, @"Gói cài thiếu Tools/HeroOverlay.app/hero-overlay.", state, nil);
    typedef int (*SetPersona)(const posix_spawnattr_t *, uid_t, uint32_t);
    typedef int (*SetID)(const posix_spawnattr_t *, uid_t);
    SetPersona persona = (SetPersona)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    SetID setUID = (SetID)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    SetID setGID = (SetID)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
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
    pid_t child = -1;
    char *argv[] = {(char *)helper.fileSystemRepresentation, "--run", (char *)directory.fileSystemRepresentation,
        (char *)profile.fileSystemRepresentation, NULL};
    char *env[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", "HOME=/var/mobile", "CFFIXED_USER_HOME=/var/mobile", NULL};
    if (!result) result = posix_spawn(&child, helper.fileSystemRepresentation, &files, &attr, argv, env);
    if (!setup) posix_spawn_file_actions_destroy(&files);
    posix_spawnattr_destroy(&attr);
    if (result) return HCOverlayReply(NO, [NSString stringWithFormat:@"Không khởi chạy được overlay: %d (%s).", result, strerror(result)], state, directory);
    // Reap on a background queue; never block the UI waiting for a persistent HUD.
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        int status;
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    });
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 3;
    do {
        [NSThread sleepForTimeInterval:0.1];
        state = HCOverlayReadState(directory);
        if (HCOverlayFresh(state)) return HCOverlayReply(YES, @"Nút nổi đã đăng ký cửa sổ hệ thống.", state, nil);
        if ([state[@"pid"] intValue] == child && [state[@"phase"] isEqual:@"failed"])
            return HCOverlayReply(NO, state[@"message"], state, directory);
    } while (NSProcessInfo.processInfo.systemUptime < deadline);
    return HCOverlayReply(NO, @"Chưa nhận được xác nhận khởi động overlay. Xem báo cáo nút nổi/startupLog.", state, directory);
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
