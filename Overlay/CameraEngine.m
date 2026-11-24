#import "CameraEngine.h"
#import "../BackendSDK/GameInspection.h"
#include "../BackendSDK/CameraMemory.h"
#include "../BackendSDK/EspMemory.h"

typedef kern_return_t (*HCMachWrite)(mach_port_t, mach_vm_address_t, vm_offset_t, mach_msg_type_number_t);
typedef struct { mach_port_t task; HCRemoteRead read; HCMachWrite write; } HCCameraTask;
static bool HCEngineRead(void *context, uint64_t address, void *buffer, size_t size) {
    HCCameraTask *target = context;
    return HCGameRead(target->read, target->task, address, buffer, size);
}
static bool HCEngineWrite(void *context, uint64_t address, const void *buffer, size_t size) {
    HCCameraTask *target = context;
    return target->write && (size == 1 || size == 4) &&
        target->write(target->task, address, (vm_offset_t)(uintptr_t)buffer, (mach_msg_type_number_t)size) == KERN_SUCCESS;
}

@implementation HCCameraEngine {
    NSString *_profile;
    void (^_report)(NSDictionary *);
    void (^_espReport)(NSDictionary *);
    BOOL _espActive;
    dispatch_queue_t _queue;
    dispatch_source_t _timer;
    HCCameraTask _target;
    uint64_t _base;
    pid_t _pid;
    NSTimeInterval _nextDiscovery;
    HCCameraSnapshot _lastObject;
    float _lastWritten;
    BOOL _hasWritten;
    NSUInteger _writes;
    NSDictionary *_lastReport;
    NSTimeInterval _lastEmission;
    NSString *_lastCode;
}
- (instancetype)initWithProfile:(NSString *)profile report:(void (^)(NSDictionary *))report espReport:(void (^)(NSDictionary *))espReport {
    if ((self = [super init])) {
        _profile = [profile copy]; _report = [report copy];
        _espReport = [espReport copy];
        _queue = dispatch_queue_create("local.herocontrol.camera", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (HCCameraMemory)memory { return (HCCameraMemory){&_target, HCEngineRead, HCEngineWrite}; }
- (void)emit:(NSString *)code message:(NSString *)message extra:(NSDictionary *)extra {
    NSMutableDictionary *value = [@{@"code": code, @"message": message, @"pid": @(_pid),
        @"writeCount": @(_writes), @"timestamp": [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date]} mutableCopy];
    if (extra) [value addEntriesFromDictionary:extra];
    _lastReport = value;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([_lastCode isEqual:code] && now - _lastEmission < 1) return;
    _lastCode = code; _lastEmission = now;
    void (^report)(NSDictionary *) = _report;
    dispatch_async(dispatch_get_main_queue(), ^{ report(value); });
}
- (void)releaseTarget {
    if (_target.task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), _target.task);
    _target = (HCCameraTask){0}; _base = 0; _pid = 0; _hasWritten = NO;
}
- (void)restoreCamera {
    if (_hasWritten) {
        int result = HCCameraRestore(self.memory, _base, _lastObject, _lastWritten);
        [self emit:result == HC_CAMERA_OK ? @"camera_restored" : @"camera_restore_skipped"
            message:result == HC_CAMERA_OK ? @"Đã trả hệ số camera về giá trị hiện tại của game." : @"Không ghi hoàn tác vì đối tượng/giá trị đã thay đổi."
            extra:@{@"memoryStatus": @(result)}];
    }
    _hasWritten = NO;
}
- (void)restore {
    [self restoreCamera]; [self releaseTarget];
}
- (void)emitEsp:(NSDictionary *)value {
    void (^callback)(NSDictionary *) = _espReport;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(value); });
}
- (void)readEsp:(BOOL)unseenOnly {
    HCEspFrame frame;
    int status = HCEspRead(self.memory, _base, unseenOnly, &frame);
    NSMutableArray *targets = [NSMutableArray array];
    for (int i = 0; i < frame.count; i++) {
        HCEspTarget t = frame.targets[i];
        [targets addObject:@{@"objectID": @(t.objectID), @"heroID": @(t.heroID), @"hp": @(t.hp), @"maxHP": @(t.maxHP),
            @"worldX": @(t.worldX), @"worldZ": @(t.worldZ), @"x": @(t.x), @"feetY": @(t.feetY), @"headY": @(t.headY),
            @"visible": t.visible ? @YES : @NO, @"onScreen": t.onScreen ? @YES : @NO,
            @"cooldowns": @[@(t.cooldowns[0]), @(t.cooldowns[1]), @(t.cooldowns[2])]}];
    }
    NSString *code = status == HC_ESP_OK ? @"esp_frame_read" : status == HC_ESP_MATRICES_PENDING ? @"esp_matrices_pending" : @"esp_waiting";
    [self emitEsp:@{@"code": code, @"message": status == HC_ESP_OK ? @"Đã đọc khung ESP; cần đối chiếu hình vẽ trong trận." : @"Đang chờ đối tượng hoặc ma trận camera hợp lệ trong trận.",
        @"memoryStatus": @(status), @"pid": @(_pid), @"targetCount": @(frame.count), @"projectedCount": @(frame.projected),
        @"listCount": @(frame.listCount), @"matricesValid": frame.matricesValid ? @YES : @NO,
        @"matrixStage": @(frame.matrixStage), @"viewMode": @(frame.viewMode), @"projectionDirty": @(frame.projectionDirty),
        @"nativeCamera": [NSString stringWithFormat:@"0x%llx", (unsigned long long)frame.nativeCamera],
        @"hostX": @(frame.hostX), @"hostZ": @(frame.hostZ), @"hasHostPosition": frame.hasHostPosition ? @YES : @NO,
        @"targets": targets, @"timestamp": [[[NSISO8601DateFormatter alloc] init] stringFromDate:NSDate.date]}];
}
- (BOOL)discover {
    NSDictionary *inspection = HCGameInspection();
    if (![inspection[@"moduleMatchesDump"] boolValue] || ![inspection[@"memoryReadVerified"] boolValue]) {
        [self restore];
        [self emit:inspection[@"code"] message:inspection[@"message"] extra:nil]; return NO;
    }
    pid_t pid = [inspection[@"pid"] intValue];
    uint64_t base = strtoull([inspection[@"unityBase"] UTF8String], NULL, 0);
    if (_target.task && pid == _pid && base == _base) return YES;
    [self restore];
    mach_port_t task = MACH_PORT_NULL;
    kern_return_t status = task_for_pid(mach_task_self(), pid, &task);
    if (status != KERN_SUCCESS || !task) {
        [self emit:@"camera_task_denied" message:@"Chưa lấy được task port cho tiến trình camera." extra:@{@"taskPortStatus": @(status)}]; return NO;
    }
    _target = (HCCameraTask){task, (HCRemoteRead)dlsym(RTLD_DEFAULT, "mach_vm_read_overwrite"),
        (HCMachWrite)dlsym(RTLD_DEFAULT, "mach_vm_write")};
    _base = base; _pid = pid;
    // Also verify the setter's exact instructions, not just the module UUID.
    const unsigned char signature[] = {0x68,0x9a,0x00,0xbd,0x28,0x00,0x80,0x52,0x68,0x72,0x03,0x39};
    unsigned char actual[sizeof(signature)] = {0};
    const unsigned char updateSignature[] = {0x60,0x0e,0x40,0xf9,0xe0,0x03,0x00,0xb4,0x60,0x8e,0x40,0xbd,0x01,0x00,0x80,0xd2,0xfa,0x02,0x04,0x94};
    unsigned char updateActual[sizeof(updateSignature)] = {0};
    const unsigned char hpSignature[] = {0x00,0x40,0x40,0xb9,0xc0,0x03,0x5f,0xd6};
    const unsigned char maxHPSignature[] = {0x00,0x44,0x40,0xb9,0xc0,0x03,0x5f,0xd6};
    unsigned char hpActual[8] = {0}, maxHPActual[8] = {0};
    if (!HCEngineRead(&_target, base + 0x550F16C, actual, sizeof(actual)) || memcmp(actual, signature, sizeof(actual)) ||
        !HCEngineRead(&_target, base + 0x540E520, updateActual, sizeof(updateActual)) ||
        memcmp(updateActual, updateSignature, sizeof(updateActual)) || !_target.write ||
        !HCEngineRead(&_target, base + 0x70279A4, hpActual, 8) || memcmp(hpActual, hpSignature, 8) ||
        !HCEngineRead(&_target, base + 0x70279B4, maxHPActual, 8) || memcmp(maxHPActual, maxHPSignature, 8)) {
        [self releaseTarget];
        [self emit:@"camera_signature_mismatch" message:@"Mã setter camera không khớp bản đã đối chiếu; không ghi." extra:nil]; return NO;
    }
    return YES;
}
- (void)tick {
    @autoreleasepool {
        NSData *data = [NSData dataWithContentsOfFile:_profile];
        id root = data && data.length < 131072 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
        id settings = [root isKindOfClass:NSDictionary.class] && [root[@"schemaVersion"] isEqual:@1] ? root[@"settings"] : nil;
        id enabled = [settings isKindOfClass:NSDictionary.class] ? settings[@"cameraEnabled"] : nil;
        id flags = [settings isKindOfClass:NSDictionary.class] ? settings[@"flags"] : nil;
        id espFlag = [flags isKindOfClass:NSDictionary.class] ? flags[@"__ifxEnemyEspEnabledV1"] : nil;
        BOOL espEnabled = [espFlag isKindOfClass:NSNumber.class] && [espFlag doubleValue] == 1;
        BOOL cameraEnabled = [enabled isKindOfClass:NSNumber.class] && [enabled doubleValue] == 1;
        if (!espEnabled && _espActive) [self emitEsp:@{@"code": @"esp_disabled", @"message": @"ESP đang tắt.", @"targets": @[]}];
        _espActive = espEnabled;
        if (!cameraEnabled) {
            BOOL wasActive = _hasWritten; [self restoreCamera];
            if (!wasActive && ![_lastReport[@"code"] hasPrefix:@"camera_restore"])
                [self emit:@"camera_disabled" message:@"Camera xa đang tắt." extra:nil];
            if (!espEnabled) { [self releaseTarget]; _nextDiscovery = 0; return; }
        }
        id value = settings[@"cameraScale"];
        double scale = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
        if (cameraEnabled && (!isfinite(scale) || scale < 1 || scale > 2.3)) {
            [self restore]; [self emit:@"camera_invalid_scale" message:@"Hệ số camera không hợp lệ; không ghi." extra:nil]; return;
        }
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now >= _nextDiscovery) {
            _nextDiscovery = now + 2;
            if (![self discover]) {
                if (espEnabled) [self emitEsp:@{@"code": @"esp_access_unavailable", @"message": @"Chưa xác minh quyền đọc và module game.", @"targets": @[]}];
                return;
            }
        }
        if (!_target.task) return;
        if (espEnabled) [self readEsp:[flags[@"DoroCheat.Reference.R1.Unseen"] boolValue]];
        if (!cameraEnabled) return;
        HCCameraSnapshot object = {0};
        float written = 0;
        int result = HCCameraApply(self.memory, _base, (float)scale, &object, &written);
        if (result != HC_CAMERA_OK) {
            // A successful write followed by a failed readback is not success,
            // but retain its identity/value so disabling can cautiously restore.
            if (result == HC_CAMERA_READBACK_FAILED || result == HC_CAMERA_WRITE_FAILED) {
                _lastObject = object; _lastWritten = written; _hasWritten = YES;
            }
            if (result == HC_CAMERA_READ_FAILED) { [self restore]; _nextDiscovery = 0; }
            [self emit:@"camera_waiting" message:@"Chưa có camera hợp lệ hoặc chưa xác nhận ghi. Vào trận tập để thử."
                extra:@{@"memoryStatus": @(result),
                    @"cameraClass": [NSString stringWithFormat:@"0x%llx", (unsigned long long)object.cameraClass],
                    @"cameraObject": [NSString stringWithFormat:@"0x%llx", (unsigned long long)object.camera],
                    @"mobaObject": [NSString stringWithFormat:@"0x%llx", (unsigned long long)object.moba]}]; return;
        }
        _lastObject = object; _lastWritten = written; _hasWritten = YES; _writes++;
        [self emit:@"camera_write_verified" message:@"Đã ghi và đọc lại hệ số camera. Cần kiểm tra hình ảnh trong trận."
            extra:@{@"scale": @(scale), @"sourceZoom": @(object.sourceZoom), @"writtenZoom": @(written), @"memoryStatus": @0}];
    }
}
- (void)start {
    _timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _queue);
    dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_MSEC * 100, NSEC_PER_MSEC * 20);
    __weak HCCameraEngine *weakSelf = self;
    dispatch_source_set_event_handler(_timer, ^{ [weakSelf tick]; });
    dispatch_resume(_timer);
}
- (NSDictionary *)stop {
    dispatch_group_t group = dispatch_group_create();
    __block NSDictionary *report;
    dispatch_group_async(group, _queue, ^{
        if (self->_timer) dispatch_source_cancel(self->_timer);
        self->_timer = nil;
        [self restore];
        report = self->_lastReport;
    });
    if (dispatch_group_wait(group, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)))
        return @{@"code": @"camera_stop_timeout", @"message": @"Chưa xác nhận hoàn tác trước khi dừng."};
    return report ?: @{@"code": @"camera_disabled", @"message": @"Camera xa đang tắt."};
}
@end
