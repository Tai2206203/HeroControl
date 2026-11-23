#import <Foundation/Foundation.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <mach/task_info.h>
#include <mach/mach_error.h>
#include <mach-o/loader.h>
#include <string.h>
#include <unistd.h>

// Target identity comes from Apple's lookup for app 1150288115 (VN).
// UUID comes from LC_UUID of the supplied UnityFramework, not an ASLR address.
static NSString *const HCGameBundleID = @"com.garena.game.kgvn";
static NSString *const HCExpectedUnityUUID = @"298E718A-DA06-33B8-8253-910447B649E3";

typedef kern_return_t (*HCRemoteRead)(mach_port_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);
static BOOL HCGameRead(HCRemoteRead read, mach_port_t task, uint64_t address, void *buffer, size_t size) {
    if (!read || !address || !size || size > 65536 || address > UINT64_MAX - size) return NO;
    mach_vm_size_t copied = 0;
    return read(task, address, size, (mach_vm_address_t)(uintptr_t)buffer, &copied) == KERN_SUCCESS && copied == size;
}

static NSDictionary *HCGameInspection(void) {
    NSMutableDictionary *result = [@{@"schemaVersion": @1, @"bundleID": HCGameBundleID,
        @"timestamp": [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date],
        @"gameRunning": @NO, @"processScanSucceeded": @NO, @"memoryReadVerified": @NO,
        @"moduleMatchesDump": @NO, @"expectedUnityUUID": HCExpectedUnityUUID,
        @"code": @"not_inspected", @"message": @"Chưa kiểm tra game."} mutableCopy];
#if TARGET_OS_IPHONE && !TARGET_OS_SIMULATOR
    if (geteuid() != 0) {
        result[@"code"] = @"game_helper_not_root"; result[@"message"] = @"Kiểm tra game cần helper root."; return result;
    }
    static void *procLibrary;
    if (!procLibrary) procLibrary = dlopen("/usr/lib/libproc.dylib", RTLD_NOW | RTLD_LOCAL);
    int (*list)(void *, int) = dlsym(procLibrary ?: RTLD_DEFAULT, "proc_listallpids");
    int (*pathForPID)(int, void *, uint32_t) = dlsym(procLibrary ?: RTLD_DEFAULT, "proc_pidpath");
    if (!list || !pathForPID) {
        result[@"code"] = @"process_api_unavailable"; result[@"message"] = @"Không nạp được API nhận diện tiến trình."; return result;
    }
    pid_t pids[8192] = {0};
    errno = 0;
    int count = list(pids, sizeof(pids));
    if (count <= 0) {
        result[@"processError"] = @(errno); result[@"code"] = @"process_scan_failed";
        result[@"message"] = @"Hệ thống chưa cho liệt kê tiến trình; chưa kết luận game đã đóng."; return result;
    }
    result[@"processScanSucceeded"] = @YES;
    result[@"scanTruncated"] = @(count >= 8192);
    NSMutableArray *matches = [NSMutableArray array];
    for (int i = 0; i < MIN(count, 8192); i++) {
        char path[4096] = {0};
        if (pids[i] <= 0 || pathForPID(pids[i], path, sizeof(path)) <= 0 || strnlen(path, sizeof(path)) == sizeof(path)) continue;
        NSString *executable = [NSString stringWithUTF8String:path];
        NSString *bundle = executable.stringByDeletingLastPathComponent;
        if (![bundle.pathExtension isEqual:@"app"]) continue;
        NSDictionary *info = [NSDictionary dictionaryWithContentsOfFile:[bundle stringByAppendingPathComponent:@"Info.plist"]];
        if (![info[@"CFBundleIdentifier"] isEqual:HCGameBundleID] || ![info[@"CFBundleExecutable"] isEqual:executable.lastPathComponent]) continue;
        [matches addObject:@{@"pid": @(pids[i]), @"executable": executable, @"bundle": bundle,
            @"version": [info[@"CFBundleShortVersionString"] isKindOfClass:NSString.class] ? info[@"CFBundleShortVersionString"] : @"unknown"}];
    }
    if (matches.count != 1) {
        result[@"matchingProcessCount"] = @(matches.count);
        result[@"code"] = matches.count ? @"game_process_ambiguous" : @"game_not_observed";
        result[@"message"] = matches.count ? @"Có nhiều tiến trình trùng game; chưa chọn để đọc." : @"Chưa quan sát được tiến trình Liên Quân. Mở game vào sảnh rồi kiểm tra lại.";
        return result;
    }
    NSDictionary *match = matches.firstObject;
    result[@"gameRunning"] = @YES; result[@"pid"] = match[@"pid"];
    result[@"gameVersion"] = match[@"version"]; result[@"executable"] = match[@"executable"];
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t status = task_for_pid(mach_task_self(), [match[@"pid"] intValue], &task);
    result[@"taskPortStatus"] = @(status);
    result[@"taskPortError"] = [NSString stringWithUTF8String:mach_error_string(status)] ?: @"Unknown Mach error";
    if (status != KERN_SUCCESS || task == MACH_PORT_NULL) {
        result[@"code"] = @"game_task_port_denied";
        result[@"message"] = @"Đã nhận diện game nhưng hệ thống chưa cấp task port. Xem taskPortStatus, taskPortError và entitlementChecks của helper; chưa xác định điều kiện nào bị từ chối."; return result;
    }
    // Always release the task port, including malformed headers and partial reads.
    @try {
        HCRemoteRead read = (HCRemoteRead)dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite");
        task_dyld_info_data_t dyld = {0};
        mach_msg_type_number_t size = TASK_DYLD_INFO_COUNT;
        status = task_info(task, TASK_DYLD_INFO, (task_info_t)&dyld, &size);
        result[@"dyldInfoStatus"] = @(status);
        struct { uint32_t version, count; uint64_t array; } prefix = {0};
        if (status != KERN_SUCCESS || dyld.all_image_info_format != TASK_DYLD_ALL_IMAGE_INFO_64 ||
            !HCGameRead(read, task, dyld.all_image_info_addr, &prefix, sizeof(prefix)) || !prefix.array || !prefix.count || prefix.count > 2048) {
            result[@"code"] = @"game_dyld_read_failed"; result[@"message"] = @"Chưa đọc được danh sách module 64-bit ổn định của game.";
        } else {
            struct HCImage { uint64_t base, path, modified; };
            NSMutableData *images = [NSMutableData dataWithLength:prefix.count * sizeof(struct HCImage)];
            if (!HCGameRead(read, task, prefix.array, images.mutableBytes, images.length)) {
                result[@"code"] = @"game_images_read_failed"; result[@"message"] = @"Không đọc đủ danh sách module game.";
            } else {
                result[@"code"] = @"unity_module_not_observed"; result[@"message"] = @"Chưa đọc được UnityFramework của game.";
                const struct HCImage *entries = images.bytes;
                for (uint32_t i = 0; i < prefix.count; i++) {
                    char imagePath[512] = {0};
                    size_t pathSize = MIN(sizeof(imagePath) - 1, 4096 - (entries[i].path & 4095));
                    if (!HCGameRead(read, task, entries[i].path, imagePath, pathSize) || !memchr(imagePath, 0, pathSize)) continue;
                    NSString *image = [NSString stringWithUTF8String:imagePath];
                    if (![image.lastPathComponent isEqual:@"UnityFramework"]) continue;
                    struct mach_header_64 header = {0};
                    if (!HCGameRead(read, task, entries[i].base, &header, sizeof(header)) || header.magic != MH_MAGIC_64 ||
                        header.cputype != CPU_TYPE_ARM64 || header.sizeofcmds > 65536 || header.ncmds > 4096) continue;
                    NSMutableData *commands = [NSMutableData dataWithLength:header.sizeofcmds];
                    if (!HCGameRead(read, task, entries[i].base + sizeof(header), commands.mutableBytes, commands.length)) continue;
                    NSUInteger offset = 0;
                    NSString *uuid = nil;
                    for (uint32_t j = 0; j < header.ncmds && offset + sizeof(struct load_command) <= commands.length; j++) {
                        const struct load_command *command = (const void *)((const char *)commands.bytes + offset);
                        if (command->cmdsize < sizeof(*command) || command->cmdsize > commands.length - offset) break;
                        if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) {
                            const struct uuid_command *value = (const void *)command;
                            uuid = [[NSUUID alloc] initWithUUIDBytes:value->uuid].UUIDString;
                        }
                        offset += command->cmdsize;
                    }
                    if (!uuid) continue;
                    result[@"memoryReadVerified"] = @YES; result[@"unityUUID"] = uuid;
                    result[@"unityBase"] = [NSString stringWithFormat:@"0x%llx", (unsigned long long)entries[i].base];
                    result[@"moduleMatchesDump"] = @([uuid isEqual:HCExpectedUnityUUID]);
                    result[@"code"] = [uuid isEqual:HCExpectedUnityUUID] ? @"game_memory_module_verified" : @"game_dump_mismatch";
                    result[@"message"] = [uuid isEqual:HCExpectedUnityUUID] ? @"Đã đọc UnityFramework trong tiến trình game và UUID khớp bộ dump. Chưa triển khai thao tác camera/ESP." : @"Đã đọc game nhưng UUID không khớp dump; không dùng các offset từ bộ dump này.";
                    break;
                }
            }
        }
    } @finally { mach_port_deallocate(mach_task_self(), task); }
#else
    result[@"code"] = @"game_inspection_requires_device";
    result[@"message"] = @"Kiểm tra bộ nhớ game chỉ thực hiện trên iPhone; host/Simulator không đọc tiến trình khác.";
#endif
    return result;
}
