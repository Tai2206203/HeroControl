#include "../Protection/ProtectedStrings.h"
#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#include <dlfcn.h>
#include <errno.h>
#include <stdio.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/utsname.h>
#include <unistd.h>
#include <limits.h>
#include <spawn.h>
#include <sys/wait.h>
#include <fcntl.h>
#include <TargetConditionals.h>
#include "HeroBackend.h"
#include "GameInspection.h"

typedef int (*HCKernelBase)(uint64_t *address);
typedef int (*HCKernelRead)(uint64_t address, void *buffer, size_t length);
static void *HCLibraryHandle;
static HCKernelBase HCBaseFunction;
static HCKernelRead HCReadFunction;
static NSString *HCLoadedPath;
static NSDictionary *HCSessionReport;
static NSDictionary *HCGameSessionReport;
static NSDictionary *HCRuntimeSessionReport;
static BOOL HCTraceStagesEnabled;

static void HCStage(const char *stage) {
    if (!HCTraceStagesEnabled) return;
    fprintf(stderr, "HC_STAGE %s uid=%u euid=%u\n", stage, (unsigned)getuid(), (unsigned)geteuid());
    fflush(stderr);
}

static NSDictionary *HCEntitlements(void) {
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    CreateTask create = (CreateTask)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSSecTaskCreateFromSelf));
    CopyEntitlement copy = (CopyEntitlement)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSSecTaskCopyValueForEntitlement));
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if (!create || !copy) return values;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return values;
    NSArray *keys = @[@"com.apple.private.security.no-sandbox", @"com.apple.private.security.no-container",
        @"platform-application", @"com.apple.private.security.storage.AppDataContainers", @"com.apple.private.security.storage.AppBundles", @"com.apple.private.persona-mgmt",
        @"task_for_pid-allow", @"com.apple.system-task-ports"];
    for (NSString *key in keys) {
        CFTypeRef value = copy(task, (__bridge CFStringRef)key, NULL);
        BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
        values[key] = enabled ? @YES : @NO;
        if (value) CFRelease(value);
    }
    NSString *clientKey = @"com.apple.security.exception.iokit-user-client-class";
    CFTypeRef clients = copy(task, (__bridge CFStringRef)clientKey, NULL);
    BOOL iosurfaceAllowed = clients && CFGetTypeID(clients) == CFArrayGetTypeID() &&
        [(__bridge NSArray *)clients containsObject:@"IOSurfaceRootUserClient"];
    values[clientKey] = iosurfaceAllowed ? @YES : @NO;
    if (clients) CFRelease(clients);
    CFRelease(task);
    return values;
}

static void HCAddRoot(NSMutableOrderedSet<NSString *> *roots, NSString *path) {
    if (!path || ![path hasPrefix:@"/"] || path.length >= PATH_MAX) return;
    [roots addObject:path.stringByStandardizingPath];
}

static NSArray<NSString *> *HCLibraryPaths(NSMutableDictionary *report) {
    NSMutableOrderedSet<NSString *> *roots = [NSMutableOrderedSet orderedSet];
    NSMutableArray<NSString *> *notes = [NSMutableArray array];
    // Prefer the standardized API when the jailbreak has already injected it.
    const char *(*prefixFunction)(void) = (const char *(*)(void))dlsym(RTLD_DEFAULT, HCProtectedCString(HCSLibrootGetJbrootPrefix));
    if (prefixFunction) {
        const char *prefix = prefixFunction();
        if (prefix && strnlen(prefix, PATH_MAX) < PATH_MAX) {
            NSString *path = [NSString stringWithUTF8String:prefix];
            HCAddRoot(roots, path.length ? path : @"/");
            [notes addObject:@"Đã hỏi libroot_get_jbroot_prefix trong tiến trình hiện tại."];
        }
    } else { [notes addObject:@"Không có API libroot trong tiến trình hiện tại."]; }

    // RootHide creates a .jbroot link beside binaries/libraries it manages.
    Dl_info image = {0};
    NSMutableArray<NSString *> *directories = [NSMutableArray arrayWithObject:NSBundle.mainBundle.bundlePath];
    if (dladdr((const void *)&HCLibraryPaths, &image) && image.dli_fname) {
        NSString *path = [NSString stringWithUTF8String:image.dli_fname];
        if (path) [directories addObject:path.stringByDeletingLastPathComponent];
    }
    for (NSString *directory in directories) {
        NSString *link = [directory stringByAppendingPathComponent:@".jbroot"];
        char resolved[PATH_MAX] = {0};
        if (realpath(link.fileSystemRepresentation, resolved)) {
            HCAddRoot(roots, [NSString stringWithUTF8String:resolved]);
            [notes addObject:[@"Đã phân giải liên kết " stringByAppendingString:link]];
        }
    }
    HCAddRoot(roots, @"/var/jb");
    HCAddRoot(roots, @"/jbroot");
    HCAddRoot(roots, @"/");

    // Only inspect immediate .jbroot-* names, never files inside other app bundles.
    // No fixed root from an OCR transcript is trusted; the name changes on reboot.
    NSRegularExpression *nameRule = [NSRegularExpression regularExpressionWithPattern:@"^\\.jbroot-[0-9A-Fa-f]{16}$" options:0 error:NULL];
    NSArray<NSString *> *parents = @[@"/var/containers/Bundle/Application", @"/private/var/containers/Bundle/Application"];
    for (NSString *parent in parents) {
        NSError *error = nil;
        NSArray<NSString *> *names = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:parent error:&error];
        if (!names) {
            [notes addObject:[NSString stringWithFormat:@"Không liệt kê được %@: %@", parent, error.localizedDescription ?: @"unknown error"]];
            continue;
        }
        NSUInteger matches = 0;
        for (NSString *name in [names sortedArrayUsingSelector:@selector(compare:)]) {
            if ([nameRule numberOfMatchesInString:name options:0 range:NSMakeRange(0, name.length)] != 1) continue;
            if (++matches > 32) break;
            HCAddRoot(roots, [parent stringByAppendingPathComponent:name]);
        }
        [notes addObject:[NSString stringWithFormat:@"%@: tìm thấy %lu thư mục jailbreak root phù hợp.", parent, (unsigned long)MIN(matches, 32)]];
    }
    NSMutableOrderedSet<NSString *> *paths = [NSMutableOrderedSet orderedSet];
    NSMutableArray *providers = [NSMutableArray array];
    for (NSString *root in roots) {
        [paths addObject:[root stringByAppendingPathComponent:HCProtectedString(HCSKRWVersioned)]];
        [paths addObject:[root stringByAppendingPathComponent:HCProtectedString(HCSKRWLibrary)]];
        NSString *provider = [root stringByAppendingPathComponent:HCProtectedString(HCSKRWProvider)];
        struct stat info = {0};
        errno = 0;
        BOOL visible = stat(provider.fileSystemRepresentation, &info) == 0;
        int status = visible ? 0 : errno;
        [providers addObject:@{@"path": provider, @"visible": visible ? @YES : @NO, @"status": @(status)}];
    }
    report[@"jailbreakRoots"] = roots.array;
    report[@"resolverNotes"] = notes;
    report[@"providerChecks"] = providers;
    return paths.array;
}

static NSDictionary *HCReport(BOOL requestRead) {
    struct utsname system = {0};
    uname(&system);
    NSMutableDictionary *report = [@{
        @"schemaVersion": @1,
        @"timestamp": [[[NSISO8601DateFormatter alloc] init] stringFromDate:[NSDate date]],
        @"system": [NSString stringWithUTF8String:system.sysname] ?: @"unknown",
        @"machine": [NSString stringWithUTF8String:system.machine] ?: @"unknown",
        @"uid": @(getuid()), @"euid": @(geteuid()),
        @"kernelProbeRequested": requestRead ? @YES : @NO, @"kernelReadVerified": @NO,
        @"symbolsFound": @[], @"checkedPaths": @[], @"entitlementChecks": HCEntitlements(),
        @"executionContext": @"app-process"
    } mutableCopy];
    NSArray<NSString *> *paths = HCLibraryPaths(report);
    NSMutableArray *checks = [NSMutableArray array];
    void *library = HCLibraryHandle;
    HCKernelBase baseFunction = HCBaseFunction;
    HCKernelRead readFunction = HCReadFunction;
    if (library) {
        report[@"loadedLibrary"] = HCLoadedPath;
        report[@"symbolsFound"] = @[HCProtectedString(HCSKbase), HCProtectedString(HCSKread)];
    }
    for (NSString *path in paths) {
        struct stat info = {0};
        errno = 0;
        BOOL visible = stat(path.fileSystemRepresentation, &info) == 0;
        int status = visible ? 0 : errno;
        NSMutableDictionary *check = [@{@"path": path, @"visible": visible ? @YES : @NO, @"status": @(status)} mutableCopy];
        // Visibility and loadability are separate: try the loader even when stat
        // is restricted by sandbox policy. Loading does not invoke kbase/kread.
        if (!library) {
            dlerror();
            void *candidate = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
            if (candidate) {
                HCKernelBase base = (HCKernelBase)dlsym(candidate, HCProtectedCString(HCSKbase));
                HCKernelRead read = (HCKernelRead)dlsym(candidate, HCProtectedCString(HCSKread));
                if (base && read) {
                    library = candidate; baseFunction = base; readFunction = read;
                    HCLibraryHandle = candidate; HCBaseFunction = base; HCReadFunction = read; HCLoadedPath = path;
                    report[@"loadedLibrary"] = path;
                    report[@"symbolsFound"] = @[HCProtectedString(HCSKbase), HCProtectedString(HCSKread)];
                    check[@"loadMessage"] = @"Đã nạp thư viện và tìm thấy ABI đọc.";
                } else {
                    check[@"loadMessage"] = @"Thư viện thiếu kbase hoặc kread.";
                    dlclose(candidate);
                }
            } else {
                const char *error = dlerror();
                check[@"loadMessage"] = error ? [NSString stringWithUTF8String:error] : @"dlopen failed";
            }
        }
        [checks addObject:check];
    }
    report[@"checkedPaths"] = checks;
    if (!library) {
        report[@"code"] = @"library_unavailable";
        report[@"summary"] = @"Tiến trình này chưa nạp được libkrw. Xem lỗi đường dẫn/chữ ký/quyền; chưa thể kết luận gói chưa được cài.";
        return report;
    }
    if (!requestRead) {
        report[@"code"] = @"library_loaded_not_probed";
        report[@"summary"] = @"Đã nạp libkrw; chưa gọi primitive kernel. Đây chưa phải kết nối game.";
    } else if (geteuid() != 0) {
        report[@"code"] = @"root_helper_required";
        report[@"summary"] = @"Ứng dụng đang chạy với quyền mobile. Bộ kiểm tra không tự nâng quyền; cần chạy công cụ chẩn đoán trong terminal root để xác minh provider.";
    } else {
        uint64_t base = 0;
        HCStage("before_kbase");
        int result = baseFunction(&base);
        HCStage("after_kbase");
        report[@"kernelBaseStatus"] = @(result);
        if (result != 0) {
            report[@"code"] = @"kbase_failed";
            report[@"summary"] = [NSString stringWithFormat:@"kbase trả mã %d (%s).", result, result > 0 && result < 256 ? strerror(result) : "provider error"];
        } else if (base < UINT64_C(0xffff000000000000) || (base & 0xfff) != 0) {
            report[@"code"] = @"invalid_kernel_base";
            report[@"summary"] = @"Provider trả địa chỉ base không hợp lệ; bỏ qua bước đọc.";
        } else {
            // The only read performed by this utility: four bytes at the kernel
            // base returned by the installed provider. No caller-supplied address.
            uint32_t magic = 0;
            HCStage("before_kread");
            int readResult = readFunction(base, &magic, sizeof(magic));
            HCStage("after_kread");
            report[@"kernelReadStatus"] = @(readResult);
            if (readResult != 0) {
                report[@"code"] = @"kread_failed";
                report[@"summary"] = [NSString stringWithFormat:@"kread trả mã %d (%s).", readResult, readResult > 0 && readResult < 256 ? strerror(readResult) : "provider error"];
            } else {
                report[@"headerMagic"] = [NSString stringWithFormat:@"0x%08x", magic];
                BOOL verified = magic == UINT32_C(0xfeedfacf);
                report[@"kernelReadVerified"] = verified ? @YES : @NO;
                report[@"code"] = verified ? @"kernel_read_verified" : @"unexpected_kernel_header";
                report[@"summary"] = verified ? @"Đã đọc và xác minh header Mach-O của kernel. Phép thử này chỉ xác minh đọc kernel." : @"Lệnh đọc trả thành công nhưng header không khớp Mach-O 64-bit; không đánh dấu xác minh.";
            }
        }
    }
    // Some providers use dispatch_once and retain code pointers for the lifetime
    // of this process. Keep a loaded handle alive instead of unloading primitives.
    return report;
}

static NSData *HCReadOutput(int descriptor, NSUInteger limit) {
    struct stat info = {0};
    if (fstat(descriptor, &info) || info.st_size < 0 || (uint64_t)info.st_size > limit) return nil;
    NSMutableData *data = [NSMutableData dataWithLength:(NSUInteger)info.st_size];
    NSUInteger used = 0;
    while (used < data.length) {
        ssize_t count = pread(descriptor, (char *)data.mutableBytes + used, data.length - used, (off_t)used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return nil;
        used += (NSUInteger)count;
    }
    return data;
}

static int HCTemporaryFD(void) {
    NSString *pattern = [NSTemporaryDirectory() stringByAppendingPathComponent:@"hc-probe.XXXXXX"];
    char *name = strdup(pattern.fileSystemRepresentation);
    if (!name) return -1;
    int descriptor = mkstemp(name);
    if (descriptor >= 0) {
        // Keep only the file descriptor; no diagnostic output remains on disk.
        unlink(name);
        // UIKit processes need not have fd 0/1/2 open. Never use one of those
        // as a source: dup2/addclose actions would otherwise close/clobber stdout.
        if (descriptor < 3) {
            int promoted = fcntl(descriptor, F_DUPFD_CLOEXEC, 3);
            int savedError = errno;
            close(descriptor);
            descriptor = promoted;
            errno = savedError;
        } else if (fcntl(descriptor, F_SETFD, FD_CLOEXEC) != 0) {
            int savedError = errno;
            close(descriptor);
            descriptor = -1;
            errno = savedError;
        }
    }
    free(name);
    return descriptor;
}

static NSDictionary *HCGameReport(BOOL unused) {
    (void)unused;
    NSMutableDictionary *report = [HCReport(NO) mutableCopy];
    NSDictionary *game = HCGameInspection();
    report[@"gameInspection"] = game;
    report[@"code"] = game[@"code"]; report[@"summary"] = game[@"message"];
    return report;
}

#include "../Runtime/RuntimeInstaller.h"

static NSDictionary *HCDiagnoseMode(BOOL inspectGame, NSString *runtimeCommand, NSDictionary *config) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (geteuid() == 0) return runtimeCommand ? HCRuntimeReport(runtimeCommand, config) : (inspectGame ? HCGameReport(NO) : HCReport(YES));
    NSMutableDictionary *fallback = [HCReport(NO) mutableCopy];
    fallback[@"kernelProbeRequested"] = inspectGame || runtimeCommand ? @NO : @YES;
    fallback[@"appUID"] = @(getuid()); fallback[@"appEUID"] = @(geteuid());
    fallback[@"callerEntitlements"] = HCEntitlements();
    fallback[@"helperStage"] = @"preflight";
    NSString *helper = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"Tools/hero-kernel-check"];
    if (access(helper.fileSystemRepresentation, X_OK) != 0) {
        fallback[@"code"] = @"helper_missing";
        fallback[@"summary"] = @"Không truy cập được công cụ helper trong gói ứng dụng.";
        return fallback;
    }
    typedef int (*SetPersona)(const posix_spawnattr_t *, uid_t, uint32_t);
    typedef int (*SetIdentity)(const posix_spawnattr_t *, uid_t);
    SetPersona setPersona = (SetPersona)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaNp));
    SetIdentity setUID = (SetIdentity)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaUidNp));
    SetIdentity setGID = (SetIdentity)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSPosixSpawnattrSetPersonaGidNp));
    if (!setPersona || !setUID || !setGID) {
        fallback[@"code"] = @"persona_api_unavailable";
        fallback[@"summary"] = @"Môi trường này không cung cấp API khởi chạy helper theo persona.";
        return fallback;
    }
    posix_spawnattr_t attributes;
    int result = posix_spawnattr_init(&attributes);
    if (result) {
        fallback[@"code"] = @"helper_setup_failed"; fallback[@"helperSpawnStatus"] = @(result);
        return fallback;
    }
    result = setPersona(&attributes, 99, 1);
    if (!result) result = setUID(&attributes, 0);
    if (!result) result = setGID(&attributes, 0);
    if (result) {
        posix_spawnattr_destroy(&attributes);
        fallback[@"code"] = @"persona_setup_failed"; fallback[@"helperSpawnStatus"] = @(result);
        fallback[@"summary"] = @"Hệ thống từ chối thiết lập persona root cho helper; không tự coi là đã có quyền.";
        return fallback;
    }
    int output = HCTemporaryFD(), errors = HCTemporaryFD();
    if (output < 0 || errors < 0) {
        if (output >= 0) close(output);
        if (errors >= 0) close(errors);
        posix_spawnattr_destroy(&attributes);
        fallback[@"code"] = @"helper_output_failed";
        fallback[@"summary"] = @"Không tạo được bộ thu kết quả helper trong container ứng dụng.";
        return fallback;
    }
    posix_spawn_file_actions_t actions;
    fallback[@"helperCollectedFDs"] = @[@(output), @(errors)];
    result = posix_spawn_file_actions_init(&actions);
    BOOL actionsReady = result == 0;
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, output);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, errors);
    pid_t child = -1;
    NSString *configText = config ? [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:config options:0 error:NULL] encoding:NSUTF8StringEncoding] : nil;
    char *arguments[] = {(char *)helper.fileSystemRepresentation,
        runtimeCommand ? (char *)runtimeCommand.UTF8String : (inspectGame ? "--inspect-game" : "--kernel-read"),
        configText ? (char *)configText.UTF8String : NULL, NULL};
    char *environment[] = {"PATH=/usr/bin:/bin:/usr/sbin:/sbin", NULL};
    if (!result) result = posix_spawn(&child, helper.fileSystemRepresentation, &actions, &attributes, arguments, environment);
    if (actionsReady) posix_spawn_file_actions_destroy(&actions);
    posix_spawnattr_destroy(&attributes);
    fallback[@"helperSpawnStatus"] = @(result);
    if (result) {
        close(output); close(errors);
        fallback[@"helperStage"] = @"spawn"; fallback[@"code"] = @"helper_spawn_failed";
        fallback[@"summary"] = [NSString stringWithFormat:@"Không khởi chạy được helper root (mã %d). Kiểm tra entitlement/chữ ký sau cài đặt.", result];
        return fallback;
    }
    int status = 0;
    BOOL completed = NO;
    BOOL childOwned = YES;
    NSTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + 20;
    while (NSProcessInfo.processInfo.systemUptime < deadline) {
        pid_t waited = waitpid(child, &status, WNOHANG);
        if (waited == child) { completed = YES; break; }
        if (waited < 0 && errno != EINTR) {
            childOwned = NO;
            fallback[@"helperError"] = [NSString stringWithFormat:@"waitpid failed: %d", errno];
            break;
        }
        usleep(100000);
    }
    if (!completed && childOwned) {
        kill(child, SIGKILL);
        while (waitpid(child, &status, 0) < 0 && errno == EINTR) {}
    }
    NSData *stdoutData = HCReadOutput(output, runtimeCommand ? 4 * 1024 * 1024 : 256 * 1024);
    NSData *stderrData = HCReadOutput(errors, 16 * 1024);
    close(output); close(errors);
    NSString *errorText = stderrData ? [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] : nil;
    if (stdoutData) {
        fallback[@"helperStdoutByteCount"] = @(stdoutData.length);
        NSData *preview = [stdoutData subdataWithRange:NSMakeRange(0, MIN(stdoutData.length, 16 * 1024))];
        NSString *text = [[NSString alloc] initWithData:preview encoding:NSUTF8StringEncoding];
        if (text) fallback[@"helperStdoutPreview"] = text;
    }
    if (stderrData) fallback[@"helperStderrByteCount"] = @(stderrData.length);
    fallback[@"helperStage"] = completed ? @"decode" : @"timeout";
    fallback[@"helperExitStatus"] = @(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    if (WIFSIGNALED(status)) fallback[@"helperSignal"] = @(WTERMSIG(status));
    if (errorText.length) fallback[@"helperError"] = errorText;
    if (!completed) {
        fallback[@"code"] = @"helper_timeout";
        fallback[@"summary"] = @"Helper không hoàn tất trong 20 giây và đã được dừng.";
        return fallback;
    }
    if (!stdoutData) {
        fallback[@"code"] = @"helper_output_unreadable";
        fallback[@"summary"] = @"Không đọc được đầu ra helper trong giới hạn cho phép; không coi là JSON trống.";
        return fallback;
    }
    if (!stdoutData.length) {
        fallback[@"code"] = @"helper_empty_output";
        fallback[@"summary"] = @"Helper kết thúc nhưng không có stdout hợp lệ. Xem helperCollectedFDs, helperExitStatus và helperError.";
        return fallback;
    }
    NSError *decodeError = nil;
    id decoded = [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:&decodeError];
    if (decodeError) fallback[@"helperDecodeError"] = decodeError.localizedDescription;
    if (![decoded isKindOfClass:NSDictionary.class] || ![decoded[@"schemaVersion"] isEqual:@1] ||
        ![decoded[@"code"] isKindOfClass:NSString.class]) {
        fallback[@"code"] = @"helper_invalid_response";
        fallback[@"summary"] = @"Helper chưa trả được báo cáo root hợp lệ. Xem helperExitStatus/helperError.";
        return fallback;
    }
    if (![decoded[@"euid"] isEqual:@0]) {
        fallback[@"code"] = @"helper_not_root";
        fallback[@"summary"] = @"Helper trả JSON nhưng không có EUID 0; chưa thể coi persona đã cấp quyền root.";
        if ([decoded[@"euid"] isKindOfClass:NSNumber.class]) fallback[@"helperReportedEUID"] = decoded[@"euid"];
        return fallback;
    }
    NSMutableDictionary *report = [decoded mutableCopy];
    report[@"executionContext"] = @"root-helper";
    report[@"appUID"] = @(getuid()); report[@"appEUID"] = @(geteuid());
    report[@"callerEntitlements"] = fallback[@"callerEntitlements"];
    report[@"helperStage"] = @"complete"; report[@"helperSpawnStatus"] = @0;
    report[@"helperExitStatus"] = fallback[@"helperExitStatus"];
    report[@"helperCollectedFDs"] = fallback[@"helperCollectedFDs"];
    report[@"helperStdoutByteCount"] = fallback[@"helperStdoutByteCount"];
    if (stderrData) report[@"helperStderrByteCount"] = @(stderrData.length);
    if (errorText.length) report[@"helperError"] = errorText;
    return report;
#else
    return runtimeCommand ? HCRuntimeReport(runtimeCommand, config) : (inspectGame ? HCGameReport(NO) : HCReport(YES));
#endif
}

static NSDictionary *HCDiagnose(BOOL inspectGame) { return HCDiagnoseMode(inspectGame, nil, nil); }

static const char *HCEncode(NSDictionary *value) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:NULL];
    if (!data || data.length > 4 * 1024 * 1024) return NULL;
    char *text = malloc(data.length + 1);
    if (!text) return NULL;
    memcpy(text, data.bytes, data.length); text[data.length] = 0;
    return text;
}

__attribute__((visibility("default"))) uint32_t hc_backend_api_version(void) { return 1; }
__attribute__((visibility("default"))) const char *hc_backend_request(const char *request_json) {
    @autoreleasepool {
        if (!request_json || strnlen(request_json, 1024 * 1024 + 1) > 1024 * 1024) return NULL;
        NSString *input = [NSString stringWithUTF8String:request_json];
        if (!input) return NULL;
        id parsed = [NSJSONSerialization JSONObjectWithData:[input dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        if (![parsed isKindOfClass:NSDictionary.class] || ![parsed[@"protocolVersion"] isKindOfClass:NSNumber.class] ||
            [parsed[@"protocolVersion"] integerValue] != 1 || ![parsed[@"action"] isKindOfClass:NSString.class]) {
            return HCEncode(@{@"protocolVersion": @1, @"ok": @NO, @"message": @"Invalid v1 request"});
        }
        NSString *action = parsed[@"action"];
        if (![@[@"status", @"diagnose", @"inspectGame", @"apply", @"installRuntime", @"removeRuntime", @"runtimeStatus"] containsObject:action]) {
            return HCEncode(@{@"protocolVersion": @1, @"ok": @NO, @"message": @"Unsupported action"});
        }
        BOOL apply = [action isEqual:@"apply"];
        BOOL installRuntime = [action isEqual:@"installRuntime"], removeRuntime = [action isEqual:@"removeRuntime"];
        NSDictionary *requestSettings=[parsed[@"settings"] isKindOfClass:NSDictionary.class] ? parsed[@"settings"] : @{};
        NSDictionary *requestFlags=[requestSettings[@"flags"] isKindOfClass:NSDictionary.class] ? requestSettings[@"flags"] : @{};
        BOOL runtimeEnabled = [[NSUserDefaults standardUserDefaults] boolForKey:@"HeroControl.runtimeInstalled"] || [requestSettings[@"gameRuntimeEnabled"] isEqual:@YES];
        BOOL reportsRequested=[requestFlags[@"reports.enabled"] isEqual:@YES];
        if (installRuntime || removeRuntime || [action isEqual:@"runtimeStatus"] || (runtimeEnabled && ([action isEqual:@"status"] || apply)) || (reportsRequested && [action isEqual:@"status"])) {
            NSDictionary *config = @{@"settings": parsed[@"settings"] ?: @{}, @"revision": parsed[@"revision"] ?: @""};
            NSString *command = installRuntime ? @"--runtime-install" : removeRuntime ? @"--runtime-remove" : apply ? @"--runtime-apply" : @"--runtime-status";
            HCRuntimeSessionReport = HCDiagnoseMode(NO, command, (installRuntime || apply) ? config : nil);
            if ([HCRuntimeSessionReport[@"code"] isEqual:@"runtime_installed_restart_required"]) {
                [[NSUserDefaults standardUserDefaults] setBool:YES forKey:@"HeroControl.runtimeInstalled"];
            } else if ([HCRuntimeSessionReport[@"code"] isEqual:@"runtime_removed_restart_required"]) {
                [[NSUserDefaults standardUserDefaults] setBool:NO forKey:@"HeroControl.runtimeInstalled"];
            }
        }
        // Status polling never invokes kernel primitives. Explicit diagnose is
        // still subject to the root precondition inside HCReport.
        if (!HCSessionReport || [action isEqual:@"diagnose"]) {
            HCSessionReport = [action isEqual:@"diagnose"] ? HCDiagnose(NO) : HCReport(NO);
        }
        if ([action isEqual:@"inspectGame"]) HCGameSessionReport = HCDiagnose(YES);
        NSDictionary *report = HCSessionReport;
        NSDictionary *game = HCGameSessionReport[@"gameInspection"];
        NSString *message;
        if (apply) message = @"Chưa có game adapter; cấu hình chưa được áp dụng.";
        else if (HCGameSessionReport && ![action isEqual:@"diagnose"]) message = HCGameSessionReport[@"summary"];
        else message = report[@"summary"];
        NSMutableDictionary *snapshot = [@{
            @"protocolVersion": @1, @"backendName": @"Hero Control diagnostics 0.17.2",
            @"connected": @NO, @"gameRunning": [game[@"gameRunning"] boolValue] ? @YES : @NO,
            @"gameInspectionAvailable": [game[@"processScanSucceeded"] boolValue] ? @YES : @NO, @"supportedKeys": @[],
            @"heroes": @[], @"reports": @[], @"message": message, @"diagnostics": report
        } mutableCopy];
        if (game) snapshot[@"gameInspection"] = game;
        if (HCGameSessionReport) snapshot[@"gameProbeDiagnostics"] = HCGameSessionReport;
        NSDictionary *runtime = HCRuntimeSessionReport[@"runtime"];
        BOOL runtimeConnected = [runtime[@"responding"] isEqual:@YES] && HCRuntimeFresh(runtime);
        if (HCRuntimeSessionReport) {
            NSMutableDictionary *runtimeSummary=[runtime ?: @{@"phase": @"unavailable", @"code":HCRuntimeSessionReport[@"code"] ?: @"runtime_unavailable", @"message": HCRuntimeSessionReport[@"summary"] ?: @"Chưa có phản hồi runtime."} mutableCopy];
            [runtimeSummary removeObjectForKey:@"heroes"];
            runtimeSummary[@"responding"]=runtimeConnected ? @YES : @NO;
            snapshot[@"runtime"] = runtimeSummary;
            NSMutableDictionary *diagnostics=[HCRuntimeSessionReport mutableCopy];
            [diagnostics removeObjectForKey:@"runtime"];
            snapshot[@"runtimeDiagnostics"] = diagnostics;
            if ([runtime[@"heroes"] isKindOfClass:NSArray.class]) snapshot[@"heroes"]=runtime[@"heroes"];
        }
        if (runtimeConnected) {
            snapshot[@"connected"]=@YES;snapshot[@"gameRunning"]=@YES;snapshot[@"gameInspectionAvailable"]=@YES;
            snapshot[@"sessionID"]=runtime[@"sessionID"] ?: @"";
            snapshot[@"backendName"]=@"HeroControl in-process donor runtime";
            snapshot[@"supportedKeys"]=@[@"HeroControl.ESP.HeroID",@"__ifxEnemyEspEnabledV1",@"DoroCheat.Reference.R1.Box",@"DoroCheat.Reference.R1.Icon",@"DoroCheat.Reference.R1.HP",
                @"DoroCheat.Reference.R1.Map",@"DoroCheat.Reference.R1.Unseen",@"DoroCheat.Reference.R1.Check",
                @"reports.enabled",@"DoroCheat.Reference.R2.CameraScale"];
            if ([runtime[@"appliedRevision"] isKindOfClass:NSString.class]) snapshot[@"appliedRevision"]=runtime[@"appliedRevision"];
        }
        BOOL runtimeAction=(reportsRequested && [action isEqual:@"status"]) || ([action isEqual:@"status"] && HCRuntimeSessionReport && !runtime) || installRuntime || removeRuntime || [action isEqual:@"runtimeStatus"] || (runtimeEnabled && (apply || [action isEqual:@"status"]));
        if (runtimeAction) { message=HCRuntimeSessionReport[@"summary"] ?: @"Chưa có phản hồi runtime.";snapshot[@"message"]=message; }
        BOOL ok=!apply;
        if (apply) ok=(runtimeConnected && [runtime[@"appliedRevision"] isEqual:parsed[@"revision"]]) ||
            [HCRuntimeSessionReport[@"runtimeRequestAccepted"] isEqual:@YES];
        if (installRuntime) ok=[HCRuntimeSessionReport[@"code"] isEqual:@"runtime_installed_restart_required"];
        if (removeRuntime) ok=[HCRuntimeSessionReport[@"code"] isEqual:@"runtime_removed_restart_required"];
        // C's ! operator has type int, so @(!apply) serializes as 0/1, not
        // JSON false/true. Swift's Bool decoder correctly rejects those numbers.
        return HCEncode(@{@"protocolVersion": @1, @"ok": ok ? @YES : @NO, @"message": message, @"snapshot": snapshot});
    }
}
__attribute__((visibility("default"))) void hc_backend_release(const char *response_json) { free((void *)response_json); }

#ifdef HC_DIAGNOSTIC_CLI
static BOOL HCWriteAll(int descriptor, const void *buffer, size_t size) {
    size_t used = 0;
    while (used < size) {
        ssize_t count = write(descriptor, (const char *)buffer + used, size - used);
        if (count < 0 && errno == EINTR) continue;
        if (count <= 0) return NO;
        used += (size_t)count;
    }
    return YES;
}

typedef NSDictionary *(*HCReportProducer)(BOOL);
static NSString *HCCLIRuntimeAction;
static NSDictionary *HCCLIRuntimeConfig;
static BOOL HCCLICompactRuntime;
static NSDictionary *HCCompactRuntimeResult(NSDictionary *report) {
    NSMutableDictionary *compact=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"code",@"summary",@"installStage",@"installPath",@"installErrorDomain",@"installErrorCode",@"installPOSIXError"])
        if(report[key]) compact[key]=report[key];
    return compact;
}
static NSDictionary *HCProduceRuntime(BOOL unused) {
    (void)unused;
    NSDictionary *report=HCRuntimeReport(HCCLIRuntimeAction,HCCLIRuntimeConfig);
    return HCCLICompactRuntime ? HCCompactRuntimeResult(report) : report;
}
static int HCWriteIsolatedReport(BOOL requestRead, HCReportProducer producer) {
    // Preserve the result channel before provider initialization. Some providers
    // print warnings to stdout; redirect all such logging to captured stderr.
    int resultFD = fcntl(STDOUT_FILENO, F_DUPFD_CLOEXEC, 3);
    if (resultFD < 0) return 74;
    if (fflush(stdout) || dup2(STDERR_FILENO, STDOUT_FILENO) < 0) { close(resultFD); return 74; }
    setvbuf(stdout, NULL, _IONBF, 0);
    HCStage("start");
    NSDictionary *report = producer(requestRead);
    HCStage("report_ready");
    fflush(stdout);
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:&error];
    BOOL sent = data && HCWriteAll(resultFD, data.bytes, data.length) && HCWriteAll(resultFD, "\n", 1);
    close(resultFD);
    if (!sent) {
        fprintf(stderr, "HC_STAGE output_failed errno=%d\n", errno); fflush(stderr);
        return 74;
    }
    return requestRead && ![report[@"kernelReadVerified"] boolValue] ? 2 : 0;
}

static NSDictionary *HCNoisyFixture(BOOL requestRead) {
    (void)requestRead;
    fputs("fixture-provider-warning {not-json}\n", stdout);
    fputs("fixture-stderr\n", stderr); fflush(stderr);
    return @{@"fixture": @YES};
}

// The runner invokes this in an isolated process with fd 0/1/2 closed. It
// exercises the actual temporary-fd allocator and dup2/close collector actions.
static int HCFDRegression(const char *executable) {
    close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
    int out = HCTemporaryFD(), err = HCTemporaryFD();
    if (out < 3 || err < 3 || out == err) return 31;
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) return 32;
    int result = posix_spawn_file_actions_adddup2(&actions, out, STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, err, STDERR_FILENO);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, out);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, err);
    char *args[] = {(char *)executable, "--emit-fd-fixture", NULL};
    char *env[] = {"PATH=/usr/bin:/bin", NULL};
    pid_t child = -1;
    if (!result) result = posix_spawn(&child, executable, &actions, NULL, args, env);
    posix_spawn_file_actions_destroy(&actions);
    if (result) return 33;
    int status = 0;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    NSData *outData = HCReadOutput(out, 4096), *errData = HCReadOutput(err, 4096);
    close(out); close(err);
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status)) return 34;
    NSDictionary *value = outData ? [NSJSONSerialization JSONObjectWithData:outData options:0 error:NULL] : nil;
    NSString *errorText = errData ? [[NSString alloc] initWithData:errData encoding:NSUTF8StringEncoding] : nil;
    return [value[@"fixture"] isEqual:@YES] && [errorText containsString:@"fixture-stderr\n"] &&
        [errorText containsString:@"fixture-provider-warning {not-json}\n"] ? 0 : 35;
}
static BOOL HCIsJSONBoolean(id value) {
    return [value isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)value) == CFBooleanGetTypeID();
}
static void HCTimeout(int number) {
    (void)number;
    static const char text[] = "Kernel diagnostic provider timed out after 15 seconds.\n";
    write(STDERR_FILENO, text, sizeof(text) - 1);
    _exit(124);
}
static int HCSelfTest(void) {
    const char *invalid[] = {"{}", "[]", "null", "{", "{\"protocolVersion\":1,\"action\":123}", "{\"protocolVersion\":1,\"action\":\"unknown\"}"};
    for (size_t i = 0; i < sizeof(invalid)/sizeof(invalid[0]); ++i) {
        const char *reply = hc_backend_request(invalid[i]);
        if (!reply) return 1;
        NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:reply] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        BOOL validBoolean = HCIsJSONBoolean(value[@"ok"]);
        BOOL ok = [value[@"ok"] boolValue];
        hc_backend_release(reply);
        if (ok || !validBoolean) return 2;
    }
    const char *request[] = {"{\"protocolVersion\":1,\"action\":\"status\"}", "{\"protocolVersion\":1,\"action\":\"apply\",\"revision\":\"must-not-ack\"}"};
    for (size_t i = 0; i < 2; ++i) {
        const char *reply = hc_backend_request(request[i]);
        if (!reply) return 3;
        NSDictionary *value = [NSJSONSerialization JSONObjectWithData:[[NSString stringWithUTF8String:reply] dataUsingEncoding:NSUTF8StringEncoding] options:0 error:NULL];
        NSDictionary *snapshot = value[@"snapshot"];
        BOOL correctTypes = HCIsJSONBoolean(value[@"ok"]) && HCIsJSONBoolean(snapshot[@"connected"]) &&
            HCIsJSONBoolean(snapshot[@"gameRunning"]) && HCIsJSONBoolean(snapshot[@"gameInspectionAvailable"]) &&
            HCIsJSONBoolean(snapshot[@"diagnostics"][@"kernelProbeRequested"]) &&
            HCIsJSONBoolean(snapshot[@"diagnostics"][@"kernelReadVerified"]);
        for (NSDictionary *check in snapshot[@"diagnostics"][@"checkedPaths"]) {
            correctTypes = correctTypes && HCIsJSONBoolean(check[@"visible"]);
        }
        BOOL invalid = [snapshot[@"connected"] boolValue] || [snapshot[@"gameRunning"] boolValue] || [snapshot[@"supportedKeys"] count] || snapshot[@"appliedRevision"] ||
                       [snapshot[@"diagnostics"][@"kernelProbeRequested"] boolValue] || (i == 1 && [value[@"ok"] boolValue]);
        hc_backend_release(reply);
        if (invalid || !correctTypes) return 4;
    }
    NSDictionary *fresh=@{@"phase":@"active",@"runtimeBuild":@HC_RUNTIME_BUILD,@"generation":@HC_RUNTIME_GENERATION,@"pid":@(getpid()),
        @"heartbeat":@(NSProcessInfo.processInfo.systemUptime)};
    if (!HCRuntimeFresh(fresh) || HCRuntimeValidateConfig(nil) || HCRuntimeSettingsValid(@{@"flags":@[]})) return 5;
    NSMutableDictionary *stale=[fresh mutableCopy];stale[@"heartbeat"]=@(NSProcessInfo.processInfo.systemUptime-10);
    if (HCRuntimeFresh(stale)) return 6;
    stale=[fresh mutableCopy];stale[@"phase"]=@"failed";
    if (HCRuntimeFresh(stale)) return 7;
    NSDictionary *compact=HCCompactRuntimeResult(@{@"code":@"runtime_installed_restart_required",@"summary":@"ready",@"runtime":@{@"heroes":@[@1]},@"installPOSIXError":@13});
    if(compact.count!=3 || compact[@"runtime"] || ![compact[@"installPOSIXError"] isEqual:@13]) return 8;
    puts("Diagnostic ABI tests passed: malformed input, status, apply refusal, runtime freshness/config guards; no kernel primitive invoked.");
    return 0;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--emit-fd-fixture") == 0) {
            return HCWriteIsolatedReport(NO, HCNoisyFixture);
        }
        if (argc == 2 && strcmp(argv[1], "--fd-self-test") == 0) return HCFDRegression(argv[0]);
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return HCSelfTest();
        if ((argc==2 || argc==3) && [@[@"--runtime-prepare",@"--runtime-install",@"--runtime-remove",@"--runtime-status",@"--runtime-apply"] containsObject:[NSString stringWithUTF8String:argv[1]]]) {
            HCCLICompactRuntime=strcmp(argv[1],"--runtime-prepare")==0;
            HCCLIRuntimeAction=HCCLICompactRuntime ? @"--runtime-install" : [NSString stringWithUTF8String:argv[1]];
            if (argc==3 && strnlen(argv[2],131073)<=131072) {
                NSData *data=[[NSString stringWithUTF8String:argv[2]] dataUsingEncoding:NSUTF8StringEncoding];
                id value=data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
                if ([value isKindOfClass:NSDictionary.class]) HCCLIRuntimeConfig=value;
            }
            signal(SIGALRM,HCTimeout);alarm(15);
            int result=HCWriteIsolatedReport(NO,HCProduceRuntime);
            alarm(0);return result;
        }
        if (argc != 2 || (strcmp(argv[1], "--inspect") != 0 && strcmp(argv[1], "--kernel-read") != 0 && strcmp(argv[1], "--inspect-game") != 0)) {
            fprintf(stderr, "Usage: hero-kernel-check --inspect | --kernel-read | --inspect-game\n");
            return 64;
        }
        signal(SIGALRM, HCTimeout);
        alarm(15);
        HCTraceStagesEnabled = strcmp(argv[1], "--kernel-read") == 0;
        int result = HCWriteIsolatedReport(HCTraceStagesEnabled, strcmp(argv[1], "--inspect-game") == 0 ? HCGameReport : HCReport);
        alarm(0);
        return result;
    }
}
#endif
