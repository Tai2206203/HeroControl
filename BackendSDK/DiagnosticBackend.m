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

typedef int (*HCKernelBase)(uint64_t *address);
typedef int (*HCKernelRead)(uint64_t address, void *buffer, size_t length);
static void *HCLibraryHandle;
static HCKernelBase HCBaseFunction;
static HCKernelRead HCReadFunction;
static NSString *HCLoadedPath;
static NSDictionary *HCSessionReport;

static NSDictionary *HCEntitlements(void) {
    typedef CFTypeRef (*CreateTask)(CFAllocatorRef);
    typedef CFTypeRef (*CopyEntitlement)(CFTypeRef, CFStringRef, CFErrorRef *);
    CreateTask create = (CreateTask)dlsym(RTLD_DEFAULT, "SecTaskCreateFromSelf");
    CopyEntitlement copy = (CopyEntitlement)dlsym(RTLD_DEFAULT, "SecTaskCopyValueForEntitlement");
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if (!create || !copy) return values;
    CFTypeRef task = create(kCFAllocatorDefault);
    if (!task) return values;
    NSArray *keys = @[@"com.apple.private.security.no-sandbox", @"com.apple.private.security.no-container",
        @"platform-application", @"com.apple.private.security.storage.AppDataContainers", @"com.apple.private.persona-mgmt"];
    for (NSString *key in keys) {
        CFTypeRef value = copy(task, (__bridge CFStringRef)key, NULL);
        BOOL enabled = value && CFGetTypeID(value) == CFBooleanGetTypeID() && CFBooleanGetValue((CFBooleanRef)value);
        values[key] = enabled ? @YES : @NO;
        if (value) CFRelease(value);
    }
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
    const char *(*prefixFunction)(void) = (const char *(*)(void))dlsym(RTLD_DEFAULT, "libroot_get_jbroot_prefix");
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
        [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libkrw.0.dylib"]];
        [paths addObject:[root stringByAppendingPathComponent:@"usr/lib/libkrw.dylib"]];
        NSString *provider = [root stringByAppendingPathComponent:@"usr/lib/libkrw/libkrw-dopamine.dylib"];
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
        report[@"symbolsFound"] = @[@"kbase", @"kread"];
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
                HCKernelBase base = (HCKernelBase)dlsym(candidate, "kbase");
                HCKernelRead read = (HCKernelRead)dlsym(candidate, "kread");
                if (base && read) {
                    library = candidate; baseFunction = base; readFunction = read;
                    HCLibraryHandle = candidate; HCBaseFunction = base; HCReadFunction = read; HCLoadedPath = path;
                    report[@"loadedLibrary"] = path;
                    report[@"symbolsFound"] = @[@"kbase", @"kread"];
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
        int result = baseFunction(&base);
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
            int readResult = readFunction(base, &magic, sizeof(magic));
            report[@"kernelReadStatus"] = @(readResult);
            if (readResult != 0) {
                report[@"code"] = @"kread_failed";
                report[@"summary"] = [NSString stringWithFormat:@"kread trả mã %d (%s).", readResult, readResult > 0 && readResult < 256 ? strerror(readResult) : "provider error"];
            } else {
                report[@"headerMagic"] = [NSString stringWithFormat:@"0x%08x", magic];
                BOOL verified = magic == UINT32_C(0xfeedfacf);
                report[@"kernelReadVerified"] = verified ? @YES : @NO;
                report[@"code"] = verified ? @"kernel_read_verified" : @"unexpected_kernel_header";
                report[@"summary"] = verified ? @"Đã đọc và xác minh header Mach-O của kernel. Bộ xử lý chức năng game chưa được triển khai." : @"Lệnh đọc trả thành công nhưng header không khớp Mach-O 64-bit; không đánh dấu xác minh.";
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
        fcntl(descriptor, F_SETFD, FD_CLOEXEC);
    }
    free(name);
    return descriptor;
}

static NSDictionary *HCDiagnose(void) {
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (geteuid() == 0) return HCReport(YES);
    NSMutableDictionary *fallback = [HCReport(NO) mutableCopy];
    fallback[@"kernelProbeRequested"] = @YES;
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
    SetPersona setPersona = (SetPersona)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_np");
    SetIdentity setUID = (SetIdentity)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_uid_np");
    SetIdentity setGID = (SetIdentity)dlsym(RTLD_DEFAULT, "posix_spawnattr_set_persona_gid_np");
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
    result = posix_spawn_file_actions_init(&actions);
    BOOL actionsReady = result == 0;
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, output, STDOUT_FILENO);
    if (!result) result = posix_spawn_file_actions_adddup2(&actions, errors, STDERR_FILENO);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, output);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, errors);
    pid_t child = -1;
    char *arguments[] = {(char *)helper.fileSystemRepresentation, "--kernel-read", NULL};
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
    NSData *stdoutData = HCReadOutput(output, 256 * 1024);
    NSData *stderrData = HCReadOutput(errors, 16 * 1024);
    close(output); close(errors);
    NSString *errorText = stderrData ? [[NSString alloc] initWithData:stderrData encoding:NSUTF8StringEncoding] : nil;
    fallback[@"helperStage"] = completed ? @"decode" : @"timeout";
    fallback[@"helperExitStatus"] = @(WIFEXITED(status) ? WEXITSTATUS(status) : -1);
    if (WIFSIGNALED(status)) fallback[@"helperSignal"] = @(WTERMSIG(status));
    if (errorText.length) fallback[@"helperError"] = errorText;
    if (!completed) {
        fallback[@"code"] = @"helper_timeout";
        fallback[@"summary"] = @"Helper không hoàn tất trong 20 giây và đã được dừng.";
        return fallback;
    }
    id decoded = stdoutData ? [NSJSONSerialization JSONObjectWithData:stdoutData options:0 error:NULL] : nil;
    if (![decoded isKindOfClass:NSDictionary.class] || ![decoded[@"schemaVersion"] isEqual:@1] ||
        ![decoded[@"code"] isKindOfClass:NSString.class] || ![decoded[@"euid"] isEqual:@0]) {
        fallback[@"code"] = @"helper_invalid_response";
        fallback[@"summary"] = @"Helper chưa trả được báo cáo root hợp lệ. Xem helperExitStatus/helperError.";
        return fallback;
    }
    NSMutableDictionary *report = [decoded mutableCopy];
    report[@"executionContext"] = @"root-helper";
    report[@"appUID"] = @(getuid()); report[@"appEUID"] = @(geteuid());
    report[@"callerEntitlements"] = fallback[@"callerEntitlements"];
    report[@"helperStage"] = @"complete"; report[@"helperSpawnStatus"] = @0;
    report[@"helperExitStatus"] = fallback[@"helperExitStatus"];
    if (errorText.length) report[@"helperError"] = errorText;
    return report;
#else
    return HCReport(YES);
#endif
}

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
        if (![action isEqual:@"status"] && ![action isEqual:@"diagnose"] && ![action isEqual:@"apply"]) {
            return HCEncode(@{@"protocolVersion": @1, @"ok": @NO, @"message": @"Unsupported action"});
        }
        BOOL apply = [action isEqual:@"apply"];
        // Status polling never invokes kernel primitives. Explicit diagnose is
        // still subject to the root precondition inside HCReport.
        if (!HCSessionReport || [action isEqual:@"diagnose"]) {
            HCSessionReport = [action isEqual:@"diagnose"] ? HCDiagnose() : HCReport(NO);
        }
        NSDictionary *report = HCSessionReport;
        NSString *message = apply ? @"Chưa có game adapter; cấu hình chưa được áp dụng." : report[@"summary"];
        NSDictionary *snapshot = @{
            @"protocolVersion": @1, @"backendName": @"Dopamine diagnostics 0.3.0",
            @"connected": @NO, @"gameRunning": @NO, @"gameInspectionAvailable": @NO, @"supportedKeys": @[],
            @"heroes": @[], @"reports": @[], @"message": message, @"diagnostics": report
        };
        // C's ! operator has type int, so @(!apply) serializes as 0/1, not
        // JSON false/true. Swift's Bool decoder correctly rejects those numbers.
        return HCEncode(@{@"protocolVersion": @1, @"ok": apply ? @NO : @YES, @"message": message, @"snapshot": snapshot});
    }
}
__attribute__((visibility("default"))) void hc_backend_release(const char *response_json) { free((void *)response_json); }

#ifdef HC_DIAGNOSTIC_CLI
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
    puts("Diagnostic ABI tests passed: malformed input, status, apply refusal; no kernel primitive invoked.");
    return 0;
}
int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc == 2 && strcmp(argv[1], "--self-test") == 0) return HCSelfTest();
        if (argc != 2 || (strcmp(argv[1], "--inspect") != 0 && strcmp(argv[1], "--kernel-read") != 0)) {
            fprintf(stderr, "Usage: hero-kernel-check --inspect | --kernel-read\n");
            return 64;
        }
        signal(SIGALRM, HCTimeout);
        alarm(15);
        NSDictionary *report = HCReport(strcmp(argv[1], "--kernel-read") == 0);
        alarm(0);
        NSData *data = [NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted error:NULL];
        if (!data) return 1;
        fwrite(data.bytes, 1, data.length, stdout); putchar('\n');
        return strcmp(argv[1], "--kernel-read") == 0 && ![report[@"kernelReadVerified"] boolValue] ? 2 : 0;
    }
}
#endif
