#include "../Protection/ProtectedStrings.h"
// Bundled process adapter. It is loaded by the installed jailbreak's tweak
// loader on the next game launch; it never writes executable pages remotely.
#import <Foundation/Foundation.h>
#include <mach/mach.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <string.h>
#import "RuntimeShared.h"

static uintptr_t HCBase;
static NSString *HCDirectory;
static NSString *HCSession;
static BOOL HCBootstrapped, HCFaulted;
static BOOL HCPatchesActive;
static NSTimeInterval HCWaitStarted;
static BOOL HCDisabledApplied;
static NSDictionary *HCLastConfig;
static uint64_t HCEnvironment;
static dispatch_source_t HCTimer;
typedef kern_return_t (*HCReadSelfFunction)(mach_port_t, mach_vm_address_t, mach_vm_size_t, mach_vm_address_t, mach_vm_size_t *);

static bool HCReadSelf(uint64_t address, void *output, size_t size) {
    static HCReadSelfFunction read = (HCReadSelfFunction)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSMachRead));
    if (!read || !address || !size || size > 4 * 1024 * 1024 || address > UINT64_MAX-size) return false;
    mach_vm_size_t copied = 0;
    return read(mach_task_self(), address, size, (mach_vm_address_t)(uintptr_t)output, &copied) == KERN_SUCCESS && copied == size;
}
static void HCState(NSDictionary *value) {
    NSMutableDictionary *state = [value mutableCopy];
    state[@"schemaVersion"] = @1; state[@"runtimeBuild"] = @HC_RUNTIME_BUILD;
    state[@"generation"] = @HC_RUNTIME_GENERATION;
    state[@"pid"] = @(getpid()); state[@"heartbeat"] = @(NSProcessInfo.processInfo.systemUptime);
    state[@"sessionID"] = HCSession;
    state[@"timestamp"] = [[NSISO8601DateFormatter new] stringFromDate:NSDate.date];
    HCRuntimeWriteJSON(state, [HCDirectory stringByAppendingPathComponent:@"state.json"], NULL);
}
static void HCFailure(NSString *code, NSString *message) {
    HCState(@{@"phase": @"failed", @"code": code, @"message": message, @"effectsVerified": @NO});
}
static BOOL HCFindModule(void) {
    for (uint32_t i=0; i<_dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || ![[[NSString stringWithUTF8String:name] lastPathComponent] isEqual:@"UnityFramework"]) continue;
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header || header->magic != MH_MAGIC_64 || header->cputype != CPU_TYPE_ARM64) return NO;
        const struct mach_header_64 *h = (const struct mach_header_64 *)header;
        if (h->sizeofcmds > 65536 || h->ncmds > 4096) return NO;
        size_t offset = sizeof(*h), end = offset + h->sizeofcmds;
        for (uint32_t j=0; j<h->ncmds && offset+sizeof(struct load_command)<=end; j++) {
            const struct load_command *command = (const struct load_command *)((const char *)h+offset);
            if (command->cmdsize < sizeof(*command) || command->cmdsize > end-offset) return NO;
            if (command->cmd == LC_UUID && command->cmdsize == sizeof(struct uuid_command)) {
                const struct uuid_command *uuid = (const struct uuid_command *)command;
                if (![[[NSUUID alloc] initWithUUIDBytes:uuid->uuid].UUIDString isEqual:HCRuntimeUUID]) {
                    HCFaulted = YES; HCFailure(@"runtime_uuid_mismatch", @"UUID game khác bộ tham khảo; adapter không thực thi."); return NO;
                }
                HCBase = (uintptr_t)h; return YES;
            }
            offset += command->cmdsize;
        }
    }
    return NO;
}

static BOOL HCSignatures(void) {
    // Pinned against the supplied Mach-O, including its 8-byte object header.
    const uint8_t allocate[] = {0x5f,0x12,0xc9,0x15,0xff,0x83,0x01,0xd1,0xf8,0x5f,0x02,0xa9,0xf6,0x57,0x03,0xa9};
    const uint8_t execute[] = {0xf4,0x4f,0xbe,0xa9,0xfd,0x7b,0x01,0xa9,0xfd,0x43,0x00,0x91,0xf3,0x03,0x00,0xaa};
    uint8_t actual[16];
    // The instruction at AFB9044 stores string.length at +8. Character data
    // starts at +12, unlike stock IL2CPP headers in the generic dumper output.
    uint32_t lengthStore=0;
    return HCReadSelf(HCBase+0x3D74664, actual, sizeof(actual)) && !memcmp(actual, allocate, sizeof(actual)) &&
        HCReadSelf(HCBase+0x514A25C, actual, sizeof(actual)) && !memcmp(actual, execute, sizeof(actual)) &&
        HCReadSelf(HCBase+0xAFB9044, &lengthStore, 4) && lengthStore==UINT32_C(0xb9000a74);
}

static uint64_t HCReadyEnvironment(void) {
    uint64_t klass=0, fields=0, environment=0;
    uint8_t disposed=1;
    if (!HCReadSelf(HCBase+0xD0C2088, &klass, 8) || !klass ||
        !HCReadSelf(klass+0xB8, &fields, 8) || !fields ||
        !HCReadSelf(fields+0x18, &environment, 8) || !environment ||
        !HCReadSelf(environment+0x40, &disposed, 1) || disposed) return 0;
    return environment;
}

static NSString *HCManagedResult(uint64_t array) {
    uint64_t length=0, string=0; int32_t count=0;
    if (!HCReadSelf(array+0x10, &length, 8) || length!=1 ||
        !HCReadSelf(array+0x18, &string, 8) || !string ||
        !HCReadSelf(string+8, &count, 4) || count<0 || count>2*1024*1024) return nil;
    NSMutableData *chars = [NSMutableData dataWithLength:(NSUInteger)count*2];
    if (count && !HCReadSelf(string+12, chars.mutableBytes, chars.length)) return nil;
    return [[NSString alloc] initWithCharacters:(const unichar *)chars.bytes length:(NSUInteger)count];
}

static NSString *HCExecute(NSString *script) {
    if (!pthread_main_np() || script.length>1024*1024) return nil;
    typedef void *(*Allocate)(int32_t, const void *);
    typedef void *(*Execute)(void *, const void *);
    // C++ catches the managed exception wrapper used by this IL2CPP runtime.
    // Objective-C exception handling alone cannot catch that wrapper.
    try {
        void *text = ((Allocate)(HCBase+0x3D74664))((int32_t)script.length, NULL);
        if (!text) return nil;
        int32_t length=0;
        if (!HCReadSelf((uintptr_t)text+8, &length, 4) || length!=(int32_t)script.length) return nil;
        [script getCharacters:(unichar *)((char *)text+12) range:NSMakeRange(0, script.length)];
        void *result = ((Execute)(HCBase+0x514A25C))(text, NULL);
        return result ? HCManagedResult((uintptr_t)result) : nil;
    } catch (...) { return nil; }
}

static NSString *HCLuaString(NSString *value) {
    NSMutableString *out = [NSMutableString stringWithString:@"\""];
    NSData *utf8 = [value dataUsingEncoding:NSUTF8StringEncoding];
    const uint8_t *bytes = (const uint8_t *)utf8.bytes;
    for (NSUInteger i=0; i<utf8.length; i++) [out appendFormat:@"\\%03u", (unsigned)bytes[i]];
    [out appendString:@"\""]; return out;
}
static NSString *HCLuaValue(id value) {
    if ([value isKindOfClass:NSString.class]) return HCLuaString(value);
    if ([value isKindOfClass:NSNumber.class]) {
        if (CFGetTypeID((__bridge CFTypeRef)value)==CFBooleanGetTypeID()) return [value boolValue] ? @"true" : @"false";
        return [value stringValue];
    }
    if ([value isKindOfClass:NSDictionary.class]) {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *key in value) [parts addObject:[NSString stringWithFormat:@"[%@]=%@", HCLuaString(key), HCLuaValue(value[key])]];
        return [NSString stringWithFormat:@"{%@}", [parts componentsJoinedByString:@","]];
    }
    return @"nil";
}
static void HCPulse(void) {
    @autoreleasepool {
        if (HCFaulted) return;
        if (!HCBase && !HCFindModule()) return;
        if (!HCSignatures()) { HCFaulted=YES; HCFailure(@"runtime_signature_mismatch", @"Mã native không khớp; adapter không gọi hàm game."); return; }
        uint64_t environment = HCReadyEnvironment();
        if (!environment) { HCState(@{@"phase": @"waiting", @"code": @"runtime_waiting_lua", @"message": @"Đang chờ game khởi tạo Lua/đăng nhập."}); return; }
        if (HCEnvironment && HCEnvironment!=environment && HCPatchesActive) {
            HCFaulted=YES; HCFailure(@"runtime_vm_changed", @"Lua VM đã thay đổi; đóng hoàn toàn và mở lại game để tránh nạp hook hai lần."); return;
        }
        if (HCEnvironment && HCEnvironment!=environment) HCBootstrapped=NO;
        HCEnvironment=environment;
        NSDictionary *config = HCRuntimeReadJSON([HCDirectory stringByAppendingPathComponent:@"config.json"], 131072);
        if (![config[@"enabled"] isEqual:@YES]) {
            if (HCBootstrapped && HCLastConfig && !HCDisabledApplied) {
                NSMutableDictionary *settings=[HCLastConfig[@"settings"] mutableCopy];
                NSMutableDictionary *flags=[settings[@"flags"] mutableCopy];
                for (NSString *key in flags.allKeys) flags[key]=@NO;
                settings[@"flags"]=flags;settings[@"cameraEnabled"]=@NO;settings[@"selectedSkins"]=@{};
                NSDictionary *disabled=@{@"settings":settings,@"revision":@"adapter-disabled"};
                HCExecute([NSString stringWithFormat:HCProtectedString(HCSPulseCall),HCLuaValue(disabled),HCLuaString(HCDirectory)]);
                HCDisabledApplied=YES;
            }
            HCState(@{@"phase": @"disabled", @"code": @"runtime_disabled", @"message": @"Adapter đã tắt. Khởi động lại game để gỡ hook khỏi bộ nhớ."}); return;
        }
        if (!HCRuntimeSettingsValid(config[@"settings"]) || ![config[@"revision"] isKindOfClass:NSString.class] || [config[@"revision"] length]>128) {
            HCFailure(@"runtime_config_invalid",@"Cấu hình sai kiểu/giới hạn; adapter không thực thi.");return;
        }
        HCLastConfig=config;HCDisabledApplied=NO;
        if (!HCBootstrapped) {
            NSString *script = [NSString stringWithContentsOfFile:[HCDirectory stringByAppendingPathComponent:@"Runtime.lua"] encoding:NSUTF8StringEncoding error:NULL];
            NSString *result = script ? HCExecute(script) : nil;
            if (![result isEqual:@"initialized"] && ![result isEqual:@"already_initialized"]) {
                NSTimeInterval now=NSProcessInfo.processInfo.systemUptime;
                if (!HCWaitStarted) HCWaitStarted=now;
                if (!script || now-HCWaitStarted>60) {
                    HCFaulted=YES; HCFailure(@"runtime_bootstrap_failed", @"Không khởi tạo được Lua adapter; cần xem log và khởi động lại game.");
                } else {
                    HCState(@{@"phase":@"waiting",@"code":@"runtime_waiting_bootstrap",@"message":@"Đang chờ LuaInteraction của game sẵn sàng."});
                }
                return;
            }
            HCBootstrapped=YES;
        }
        NSString *call = [NSString stringWithFormat:HCProtectedString(HCSPulseCall), HCLuaValue(config), HCLuaString(HCDirectory)];
        NSString *result = HCExecute(call);
        NSData *data = [result dataUsingEncoding:NSUTF8StringEncoding];
        id state = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        if (![state isKindOfClass:NSDictionary.class]) { HCFaulted=YES; HCFailure(@"runtime_invalid_response", @"Adapter chưa trả JSON hợp lệ; không xác nhận áp dụng."); return; }
        HCState(state);
        if ([state[@"phase"] isEqual:@"active"]) HCPatchesActive=YES;
        if ([state[@"phase"] isEqual:@"failed"]) HCFaulted=YES;
    }
}

__attribute__((constructor)) static void HCInitialize(void) {
    @autoreleasepool {
        if (![NSBundle.mainBundle.bundleIdentifier isEqual:HCRuntimeBundle]) return;
        HCDirectory = [NSHomeDirectory() stringByAppendingPathComponent:HCRuntimeFolder];
        HCSession = NSUUID.UUID.UUIDString;
        dispatch_async(dispatch_get_main_queue(), ^{
            HCState(@{@"phase": @"starting", @"code": @"runtime_loaded", @"message": @"Adapter đã được nạp vào game; đang chờ Unity/Lua."});
            HCTimer=dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
            dispatch_source_set_timer(HCTimer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), 750*NSEC_PER_MSEC, 20*NSEC_PER_MSEC);
            dispatch_source_set_event_handler(HCTimer, ^{ HCPulse(); });
            dispatch_resume(HCTimer);
        });
    }
}
