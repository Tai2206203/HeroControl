#include "../Protection/ProtectedStrings.h"
#import "CameraEngine.h"
#import "ReportsPreparation.h"
#import "../BackendSDK/GameInspection.h"
#include "../BackendSDK/CameraMemory.h"
#include "../BackendSDK/EspMemory.h"
#include "../BackendSDK/LogicEsp.h"
#include "../BackendSDK/EspPresentation.h"
#include "../BackendSDK/LuaReports.h"
#include "../Runtime/RuntimeShared.h"

static BOOL HCEngineProcessAlive(pid_t pid) { return pid>0 && (kill(pid,0)==0 || errno==EPERM); }

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
typedef struct { HCCameraTask target; NSTimeInterval deadline; bool exceeded; } HCReceiptReadTask;
static bool HCReceiptBudgetRead(void *context, uint64_t address, void *buffer, size_t size) {
    HCReceiptReadTask *value = context;
    if (NSProcessInfo.processInfo.systemUptime > value->deadline) { value->exceeded = true; return false; }
    return HCEngineRead(&value->target, address, buffer, size);
}

@implementation HCCameraEngine {
    NSString *_profile;
    void (^_report)(NSDictionary *);
    void (^_espReport)(NSDictionary *);
    void (^_reportsReport)(NSDictionary *);
    BOOL _reportsActive;
    BOOL _readModeCleanupPending,_readModeCleaned;
    NSTimeInterval _nextReadModeCleanup,_nextReadModeReport;
    pid_t _readModeAdapterPID;
    NSString *_readModeMessage;
    NSTimeInterval _nextReportsRead;
    BOOL _espActive;
    BOOL _logicLayoutVerified;
    NSDictionary *_settings;
    NSTimeInterval _nextProfileRead, _nextCameraTick;
    NSInteger _timerHz, _requestedHz;
    NSISO8601DateFormatter *_dateFormatter;
    NSLock *_frameLock;
    NSDictionary *_pendingEsp;
    BOOL _deliveryQueued;
    NSTimeInterval _readWindow;
    NSUInteger _readSamples;
    double _measuredReadHz;
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
    NSString *_profileRevision;
    NSString *_runtimeDirectory;
    dispatch_queue_t _preparationQueue;
    BOOL _reportsPreparing;
    NSString *_reportsPreparationToken;
    NSDictionary *_reportsPreparationResult;
    NSTimeInterval _nextReportsPreparationAttempt;
    NSDictionary *_minimapProjection;
    NSTimeInterval _minimapProjectionUptime;
    pid_t _minimapProjectionPID;
    NSTimeInterval _nextRuntimeSync;
    HCEspSampleBuffer _espSamples;
}
- (instancetype)initWithProfile:(NSString *)profile report:(void (^)(NSDictionary *))report espReport:(void (^)(NSDictionary *))espReport reportsReport:(void (^)(NSDictionary *))reportsReport {
    if ((self = [super init])) {
        _profile = [profile copy]; _report = [report copy];
        _espReport = [espReport copy];
        _reportsReport = [reportsReport copy];
        _dateFormatter = [NSISO8601DateFormatter new];
        _frameLock = [NSLock new]; _requestedHz = 60;
        _preparationQueue=dispatch_queue_create("local.herocontrol.reports.prepare",DISPATCH_QUEUE_SERIAL);
        _queue = dispatch_queue_create("local.herocontrol.camera", DISPATCH_QUEUE_SERIAL);
    }
    return self;
}
- (HCCameraMemory)memory { return (HCCameraMemory){&_target, HCEngineRead, HCEngineWrite}; }
- (void)emit:(NSString *)code message:(NSString *)message extra:(NSDictionary *)extra {
    NSMutableDictionary *value = [@{@"code": code, @"message": message, @"pid": @(_pid),
        @"writeCount": @(_writes), @"timestamp": [_dateFormatter stringFromDate:NSDate.date]} mutableCopy];
    if (extra) [value addEntriesFromDictionary:extra];
    _lastReport = value;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    if ([_lastCode isEqual:code] && now - _lastEmission < 1) return;
    _lastCode = code; _lastEmission = now;
    void (^report)(NSDictionary *) = _report;
    dispatch_async(dispatch_get_main_queue(), ^{ report(value); });
}
- (void)releaseTarget {
    HCEspSampleReset(&_espSamples);
    if (_reportsActive && _pid) [self emitReports:@{@"code": @"reports_session_reset", @"message": @"Phiên đọc game đã thay đổi; đang chờ mẫu thư mới.", @"records": @[], @"querySupported": @NO}];
    if (_target.task != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), _target.task);
    _target = (HCCameraTask){0}; _base = 0; _pid = 0; _hasWritten = NO;
    _logicLayoutVerified = NO;
}
- (void)restoreCamera {
    if (_hasWritten) {
        int result = HCCameraRestore(self.memory, _base, _lastObject, _lastWritten);
        [self emit:result == HC_CAMERA_OK ? @"camera_restored" : @"camera_restore_skipped"
            message:result == HC_CAMERA_OK ? @"Đã trả hệ số camera về giá trị hiện tại của game." : @"Không ghi hoàn tác vì đối tượng/giá trị đã thay đổi."
            extra:@{@"memoryStatus": @(result)}];
        if (result != HC_CAMERA_OK && result != HC_CAMERA_CHANGED && result != HC_CAMERA_NOT_READY && result != HC_CAMERA_BAD_LAYOUT) return;
    }
    _hasWritten = NO;
}
- (void)enforceReadMemoryMode:(NSTimeInterval)now {
    // One transition cleanup may restore our previous camera write. No repeat writes.
    if(_hasWritten) { [self restoreCamera];if([_lastReport[@"memoryStatus"] intValue]!=HC_CAMERA_OK) _readModeAdapterPID=_pid;_hasWritten=NO; }
    if(!_readModeCleaned && !_readModeCleanupPending && now>=_nextReadModeCleanup) {
        _readModeCleanupPending=YES;_readModeMessage=@"Đang dừng và gỡ adapter cũ. Chỉ ESP được phép hoạt động.";
        NSString *directory=HCRuntimeFindDirectory();
        NSDictionary *state=directory ? HCRuntimeReadJSON([directory stringByAppendingPathComponent:@"state.json"],4*1024*1024) : nil;
        pid_t previous=[state[@"pid"] intValue];
        if(HCEngineProcessAlive(previous)) _readModeAdapterPID=previous;
        if(directory) HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"enabled":@NO,@"settings":@{@"readMemoryOnly":@YES}},[directory stringByAppendingPathComponent:@"config.json"],NULL);
        dispatch_async(_preparationQueue,^{
            NSDictionary *result=HCRemoveReportRuntime();
            dispatch_async(self->_queue,^{
                self->_readModeCleanupPending=NO;
                self->_readModeCleaned=[result[@"code"] isEqual:@"runtime_removed_restart_required"];
                if([result[@"removedAdapterPID"] intValue]>0) self->_readModeAdapterPID=[result[@"removedAdapterPID"] intValue];
                self->_nextReadModeCleanup=NSProcessInfo.processInfo.systemUptime+5;
                self->_readModeMessage=self->_readModeCleaned ? @"READ MEMORY: chỉ ESP. Adapter cũ đã gỡ; nếu game đang mở, đóng hẳn rồi mở lại game." :
                    @"READ MEMORY chặn cam/truy vấn mới; chưa xác nhận gỡ adapter cũ. Mở lại game sau khi gỡ thành công.";
                self->_reportsPreparationToken=nil;self->_nextRuntimeSync=0;
            });
        });
    }
    BOOL restart=HCEngineProcessAlive(_readModeAdapterPID);
    NSString *message=restart ? @"READ MEMORY chặn cam/truy vấn mới. Đóng hẳn và mở lại game để loại adapter đang nằm trong bộ nhớ." :
        (_readModeMessage ?: @"READ MEMORY: chỉ đọc và vẽ ESP.");
    if(now<_nextReadModeReport) return;_nextReadModeReport=now+1;
    [self emit:@"read_memory_only" message:message extra:@{@"restartRequired":@(restart),@"cleanupComplete":@(_readModeCleaned)}];
    [self emitReports:@{@"code":@"reports_read_memory_only",@"message":message,@"records":@[],@"querySupported":@NO,@"runtimeResponding":@NO}];
}
- (void)prepareReports:(NSDictionary *)settings {
    if(HCReadMemoryOnly(settings)) return;
    if(![settings[@"flags"][@"reports.enabled"] isEqual:@YES]) return;
    NSString *token=settings[@"reportsRefreshID"] ?: @"legacy-on";
    NSString *failure=_reportsPreparationResult[@"code"];
    BOOL waitingGame=[failure isEqual:@"runtime_install_requires_matching_game"] || [failure isEqual:@"runtime_container_unavailable"];
    if(waitingGame && NSProcessInfo.processInfo.systemUptime>=_nextReportsPreparationAttempt) _reportsPreparationToken=nil;
    if(_reportsPreparing || [_reportsPreparationToken isEqual:token]) return;
    _reportsPreparationToken=[token copy];
    NSString *revision=_profileRevision ?: NSUUID.UUID.UUIDString;
    NSString *directory=HCRuntimeFindDirectory();
    NSDictionary *stamp=directory ? HCRuntimeReadJSON([directory stringByAppendingPathComponent:@"installed.json"],8192) : nil;
    if([stamp[@"enabled"] isEqual:@YES] && [stamp[@"runtimeBuild"] isEqual:@HC_RUNTIME_BUILD] && [stamp[@"generation"] isEqual:@HC_RUNTIME_GENERATION]) {
        // Re-enable an existing installation without reinstalling or restarting.
        NSError *error=nil;
        if(!HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"enabled":@YES,@"revision":revision,@"settings":settings},
            [directory stringByAppendingPathComponent:@"config.json"],&error))
            _reportsPreparationResult=@{@"code":@"reports_prepare_config_failed",@"message":error.localizedDescription ?: @"Không ghi được cấu hình."};
        else _reportsPreparationResult=nil;
        return;
    }
    _reportsPreparing=YES;_reportsPreparationResult=nil;
    NSDictionary *request=@{@"revision":revision,@"settings":settings};
    dispatch_async(_preparationQueue,^{
        NSDictionary *result=HCPrepareReportRuntime(request);
        dispatch_async(self->_queue,^{
            self->_reportsPreparing=NO;
            self->_reportsPreparationResult=result;
            self->_nextReportsPreparationAttempt=NSProcessInfo.processInfo.systemUptime+5;
            self->_nextRuntimeSync=0;
            if(!HCReadMemoryOnly(self->_settings) && ![self->_settings[@"flags"][@"reports.enabled"] isEqual:@YES]) {
                NSString *directory=HCRuntimeFindDirectory();
                if(directory && self->_profileRevision && self->_settings)
                    HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"enabled":@YES,@"revision":self->_profileRevision,@"settings":self->_settings},
                        [directory stringByAppendingPathComponent:@"config.json"],NULL);
            }
        });
    });
}
- (void)syncRuntime:(NSDictionary *)settings now:(NSTimeInterval)now {
    if(HCReadMemoryOnly(settings)) return;
    [self prepareReports:settings];
    if (now<_nextRuntimeSync) return;
    _nextRuntimeSync=now+1;
    _runtimeDirectory=HCRuntimeFindDirectory();
    NSDictionary *manifest=_runtimeDirectory ? HCRuntimeReadJSON([_runtimeDirectory stringByAppendingPathComponent:@"manifest.json"],131072) : nil;
    NSDictionary *state=nil;
    if ([manifest[@"unityUUID"] isEqual:HCRuntimeUUID] && _profileRevision) {
        NSString *path=[_runtimeDirectory stringByAppendingPathComponent:@"config.json"];
        NSDictionary *previous=HCRuntimeReadJSON(path,131072);
        // A remove operation writes enabled=false. Do not silently reinstall or
        // re-enable it simply because the root HUD still has an old profile.
        if ([previous[@"enabled"] isEqual:@YES] && ![previous[@"revision"] isEqual:_profileRevision]) {
            NSError *error=nil;
            if (!HCRuntimeWriteJSON(@{@"schemaVersion":@1,@"enabled":@YES,@"revision":_profileRevision,@"settings":settings},path,&error)) {
                [self emitReports:@{@"code":@"runtime_sync_failed",@"message":error.localizedDescription ?: @"Không đồng bộ được cấu hình vào container game.",@"records":@[],@"querySupported":@NO}];
                return;
            }
        }
        state=HCRuntimeReadJSON([_runtimeDirectory stringByAppendingPathComponent:@"state.json"],4*1024*1024);
    }
    BOOL responding=HCRuntimeFresh(state);
    _minimapProjection=responding && [state[@"minimapProjection"] isKindOfClass:NSDictionary.class] ? state[@"minimapProjection"] : nil;
    _minimapProjectionUptime=[state[@"heartbeat"] doubleValue];_minimapProjectionPID=[state[@"pid"] intValue];
    NSString *message=state[@"message"] ?: @"Chưa có phản hồi game. Mở game; nếu vừa chuẩn bị adapter, đóng/mở lại game một lần.";
    if (!responding && [state[@"phase"] isEqual:@"active"]) message=@"Phản hồi adapter đã cũ. Không sử dụng mẫu này làm trạng thái hiện tại.";
    NSDictionary *lastReports=[state[@"reports"] isKindOfClass:NSDictionary.class] ? state[@"reports"] : nil;
    NSMutableDictionary *reports=lastReports ? [lastReports mutableCopy] :
        [@{@"code":@"runtime_unavailable",@"message":message,@"records":@[],@"querySupported":@NO} mutableCopy];
    if(!responding && lastReports) {
        reports[@"code"]=@"runtime_stale_reports";
        reports[@"message"]=[NSString stringWithFormat:@"Dữ liệu tố cáo lần cuối (adapter hiện không phản hồi): %@",lastReports[@"message"] ?: @""];
    }
    reports[@"runtimeResponding"]=@(responding);
    reports[@"runtimePhase"]=state[@"phase"] ?: @"missing";
    reports[@"runtimeCode"]=state[@"code"] ?: @"runtime_missing";
    reports[@"runtimeMessage"]=message;
    for(NSString *key in @[@"runtimeBuild",@"generation",@"pid",@"sessionID",@"timestamp"])
        if(state[key]) reports[key]=state[key];
    if(!responding && state && (![state[@"runtimeBuild"] isEqual:@HC_RUNTIME_BUILD] || ![state[@"generation"] isEqual:@HC_RUNTIME_GENERATION])) {
        reports[@"code"]=@"runtime_installed_restart_required";
        reports[@"message"]=@"Game còn giữ adapter bản trước. Đóng hoàn toàn rồi mở lại game để nạp bản đã chuẩn bị.";
    }
    BOOL requested=[settings[@"flags"][@"reports.enabled"] isEqual:@YES];
    if(!requested) {
        reports[@"code"]=@"reports_disabled";reports[@"message"]=@"Check tố cáo đang tắt.";
    } else if(_reportsPreparing) {
        reports[@"code"]=@"reports_preparing";reports[@"message"]=@"Đang tự chuẩn bị adapter và luồng kiểm tra…";
    } else if(_reportsPreparationResult && !responding) {
        NSString *code=_reportsPreparationResult[@"code"];
        reports[@"code"]=code ?: @"reports_prepare_failed";
        reports[@"message"]=[code isEqual:@"runtime_installed_restart_required"] ?
            @"Đã tự chuẩn bị xong. Đóng hoàn toàn rồi mở lại game một lần để bắt đầu." :
            (_reportsPreparationResult[@"summary"] ?: _reportsPreparationResult[@"message"] ?: @"Chuẩn bị chưa thành công. Bấm Thử lại.");
        reports[@"preparation"]=_reportsPreparationResult;
    }
    [self emitReports:reports];
}
- (void)restore {
    [self restoreCamera]; [self releaseTarget];
}
- (void)emitEsp:(NSDictionary *)value {
    // Keep only the latest frame if the main thread cannot consume at 120 Hz.
    [_frameLock lock]; _pendingEsp = value;
    if (_deliveryQueued) { [_frameLock unlock]; return; }
    _deliveryQueued = YES; [_frameLock unlock];
    void (^callback)(NSDictionary *) = _espReport;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_frameLock lock];
        NSDictionary *latest = self->_pendingEsp; self->_pendingEsp = nil; self->_deliveryQueued = NO;
        [self->_frameLock unlock];
        if (latest) callback(latest);
    });
}
- (void)emitReports:(NSDictionary *)value {
    void (^callback)(NSDictionary *) = _reportsReport;
    dispatch_async(dispatch_get_main_queue(), ^{ callback(value); });
}
- (void)readReports {
    HCReceiptScan scan;
    HCReceiptReadTask readTask = {_target, NSProcessInfo.processInfo.systemUptime + 0.05, false};
    HCCameraMemory readOnly = {&readTask, HCReceiptBudgetRead, NULL};
    BOOL available = HCReadReceiptCache(readOnly, _base, &scan);
    NSMutableArray *records = [NSMutableArray array];
    NSString *account = [NSString stringWithFormat:@"%llu", (unsigned long long)scan.account];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (available) for (int i = 0; i < scan.count; i++) {
        HCReceipt receipt = scan.records[i];
        NSString *time = receipt.sent >= 946684800 && receipt.sent <= now + 300 ?
            [_dateFormatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:receipt.sent]] : @"Chưa xác minh thời gian máy chủ";
        NSString *subject = [NSString stringWithUTF8String:receipt.subject];
        [records addObject:@{@"id": [NSString stringWithFormat:@"%@:mail:%llu:%llu", account, (unsigned long long)receipt.mailIndex, (unsigned long long)receipt.sent],
            @"time": time, @"information": subject.length ? subject : @"Thư thông báo tố cáo",
            @"reason": [NSString stringWithUTF8String:receipt.reason] ?: @"Không đọc được mã lý do"}];
    }
    NSString *message = available ? (records.count ? @"Đã đọc thư tố cáo game đã tải cho tài khoản này." : @"Chưa quan sát được thư tố cáo trong cache đã đọc; không kết luận không có tố cáo.") :
        @"Chưa đọc được cache thư tố cáo. Mở hộp thư trong game, quay lại và kiểm tra bước đọc.";
    [self emitReports:@{@"code": available ? @"complaint_mail_cache_read" : @"complaint_mail_cache_unavailable",
        @"message": message, @"available": available ? @YES : @NO, @"stage": @(scan.stage), @"tablesRead": @(scan.tables),
        @"accountID": account, @"source": @"cached_game_mail", @"querySupported": @NO, @"records": records,
        @"readBudgetExceeded": readTask.exceeded ? @YES : @NO,
        @"timestamp": [_dateFormatter stringFromDate:NSDate.date]}];
}
- (void)readEsp:(BOOL)unseenOnly {
    HCEspFrame frame;
    NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
    HCCameraMemory readOnly={&_target,HCEngineRead,NULL};
    int status = HCEspRead(readOnly, _base, false, &frame);
    HCLogicFrame logic = {0};
    BOOL logicAvailable = _logicLayoutVerified && (status == HC_ESP_OK || status == HC_ESP_MATRICES_PENDING) &&
        HCLogicRead(readOnly, _base, frame.hostCamp, &logic);
    if (status == HC_ESP_OK || status == HC_ESP_MATRICES_PENDING) HCLogicMerge(&frame, &logic, logicAvailable, false);
    HCEspPresentation presentation=HCEspPresent(&_espSamples,&frame,now,unseenOnly);
    if (!_readWindow) _readWindow = now;
    _readSamples++;
    if (now - _readWindow >= 1) { _measuredReadHz = _readSamples / (now - _readWindow); _readSamples = 0; _readWindow = now; }
    NSMutableArray *targets = [NSMutableArray array];
    NSUInteger hiddenCount = 0, logicCount = 0, cooldownKnownCount = 0;
    for (int i = 0; i < frame.count; i++) {
        HCEspTarget t = frame.targets[i];
        if (!t.visible) hiddenCount++;
        if (t.logicPosition) logicCount++;
        NSUInteger knownSlots = 0;
        for (int k = 0; k < 3; k++) if (t.cooldowns[k] >= 0) knownSlots++;
        cooldownKnownCount += knownSlots;
        [targets addObject:@{@"objectID": @(t.objectID), @"heroID": @(t.heroID), @"hp": @(t.hp), @"maxHP": @(t.maxHP),
            @"worldX": @(t.worldX), @"worldZ": @(t.worldZ), @"x": @(t.x), @"feetY": @(t.feetY), @"headY": @(t.headY),
            @"visible": t.visible ? @YES : @NO, @"onScreen": t.onScreen ? @YES : @NO,
            @"hpKnown": t.hpKnown ? @YES : @NO, @"maxHPSource": !t.hpKnown ? @"unavailable" : t.hpFromNtfCache ? @"ntf_property" : @"visual", @"hpCurrentKnown": t.hpCurrentKnown ? @YES : @NO,
            @"positionSource": t.logicPosition ? @"logic" : @"visual", @"positionFrame": @(t.positionFrame),
            @"cooldownSource": knownSlots ? (t.logicCooldowns ? @"logic" : @"visual") : @"unavailable",
            @"cooldowns": @[@(t.cooldowns[0]), @(t.cooldowns[1]), @(t.cooldowns[2])]}];
    }
    NSString *code = presentation.retained ? @"esp_frame_retained" : status == HC_ESP_OK ? @"esp_frame_read" : status == HC_ESP_MATRICES_PENDING ? @"esp_matrices_pending" : @"esp_waiting";
    NSString *message=presentation.retained ? @"Đang dùng mẫu đã xác minh trong cửa sổ tối đa 0,12 giây để tránh nháy." :
        status == HC_ESP_OK ? @"Đã đọc khung ESP; cần đối chiếu hình vẽ trong trận." : @"Đang chờ đối tượng hoặc ma trận camera hợp lệ trong trận.";
    [self emitEsp:@{@"code": code, @"message": message,
        @"memoryStatus": @(status), @"pid": @(_pid), @"targetCount": @(frame.count), @"projectedCount": @(frame.projected),
        @"requestedReadHz": @(_requestedHz), @"measuredReadHz": @(_measuredReadHz),
        @"hiddenClientCount": @(hiddenCount),
        @"logicAvailable": logicAvailable ? @YES : @NO, @"logicStage": @(logic.stage), @"logicTargetCount": @(logicCount),
        @"logicFrameNumber": @(logic.frameNumber),
        @"cooldownKnownCount": @(cooldownKnownCount),
        @"listCount": @(frame.listCount), @"matricesValid": frame.matricesValid ? @YES : @NO,
        @"matrixStage": @(frame.matrixStage), @"viewMode": @(frame.viewMode), @"projectionDirty": @(frame.projectionDirty),
        @"nativeCamera": [NSString stringWithFormat:@"0x%llx", (unsigned long long)frame.nativeCamera],
        @"hostX": @(frame.hostX), @"hostZ": @(frame.hostZ), @"hasHostPosition": frame.hasHostPosition ? @YES : @NO,
        @"minimapProjection": (_minimapProjectionPID==_pid && now-_minimapProjectionUptime>=0 && now-_minimapProjectionUptime<2.5) ? (_minimapProjection ?: @{}) : @{},
        @"targets": targets, @"sampleUptime": @(presentation.sourceTime), @"readSampleUptime": @(now),
        @"sampleRetained": presentation.retained ? @YES : @NO, @"sampleAge": @(presentation.age), @"holdWindowSeconds": @(HC_ESP_HOLD_SECONDS),
        @"timestamp": [_dateFormatter stringFromDate:NSDate.date]}];
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
    _target = (HCCameraTask){task, (HCRemoteRead)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSMachRead)),
        (HCMachWrite)dlsym(RTLD_DEFAULT, HCProtectedCString(HCSMachVmWrite))};
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
        memcmp(updateActual, updateSignature, sizeof(updateActual)) ||
        !HCEngineRead(&_target, base + 0x70279A4, hpActual, 8) || memcmp(hpActual, hpSignature, 8) ||
        !HCEngineRead(&_target, base + 0x70279B4, maxHPActual, 8) || memcmp(maxHPActual, maxHPSignature, 8)) {
        [self releaseTarget];
        [self emit:@"camera_signature_mismatch" message:@"Mã setter camera không khớp bản đã đối chiếu; không ghi." extra:nil]; return NO;
    }
    const unsigned char locationSignature[] = {0x60,0x72,0x40,0xf9,0x61,0xea,0x40,0xb9};
    const unsigned char crypticSignature[] = {0x08,0xfc,0x60,0xd3,0x00,0x01,0x00,0x4a,0xc0,0x03,0x5f,0xd6};
    unsigned char locationActual[8] = {0}, crypticActual[12] = {0};
    _logicLayoutVerified = HCEngineRead(&_target, base + 0x49FB604, locationActual, 8) && !memcmp(locationActual, locationSignature, 8) &&
        HCEngineRead(&_target, base + 0x4F54874, crypticActual, 12) && !memcmp(crypticActual, crypticSignature, 12);
    return YES;
}
- (void)tick {
    @autoreleasepool {
        NSTimeInterval now = NSProcessInfo.processInfo.systemUptime;
        if (now >= _nextProfileRead) {
            _nextProfileRead = now + 0.25;
            NSData *data = [NSData dataWithContentsOfFile:_profile];
            id root = data && data.length < 131072 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL] : nil;
            id settings = [root isKindOfClass:NSDictionary.class] && [root[@"schemaVersion"] isEqual:@1] ? root[@"settings"] : nil;
            NSDictionary *nextSettings=[settings isKindOfClass:NSDictionary.class] ? settings : nil;
            if(![nextSettings[@"cameraScale"] isEqual:_settings[@"cameraScale"]] ||
               ![nextSettings[@"cameraEnabled"] isEqual:_settings[@"cameraEnabled"]]) _nextCameraTick=0;
            _settings=nextSettings;
            _profileRevision=[root isKindOfClass:NSDictionary.class] && [root[@"revision"] isKindOfClass:NSString.class] ? root[@"revision"] : nil;
        }
        NSDictionary *settings = _settings;
        id enabled = [settings isKindOfClass:NSDictionary.class] ? settings[@"cameraEnabled"] : nil;
        id flags = [settings isKindOfClass:NSDictionary.class] ? settings[@"flags"] : nil;
        if (!HCRuntimeSettingsValid(settings)) {
            [self restore];[self enforceReadMemoryMode:now];
            [self emit:@"profile_invalid" message:@"Cấu hình không hợp lệ; đã dừng worker." extra:nil];
            [self emitEsp:@{@"code":@"profile_invalid",@"message":@"Cấu hình không hợp lệ.",@"targets":@[]}];
            return;
        }
        BOOL readOnly=HCReadMemoryOnly(settings);
        if(readOnly) [self enforceReadMemoryMode:now];
        else { _readModeCleaned=NO;_nextReadModeCleanup=0;_readModeMessage=nil; }
        BOOL runtimeMode=!readOnly && ([settings[@"gameRuntimeEnabled"] isEqual:@YES] || [flags[@"reports.enabled"] isEqual:@YES]);
        // Runtime is a report transport, never the owner of external camera/ESP.
        if (runtimeMode) [self syncRuntime:settings now:now];
        if(!readOnly && !runtimeMode && now>=_nextRuntimeSync) {
            _nextRuntimeSync=now+1;
            NSString *directory=HCRuntimeFindDirectory();
            NSDictionary *state=directory ? HCRuntimeReadJSON([directory stringByAppendingPathComponent:@"state.json"],4*1024*1024) : nil;
            _minimapProjection=HCRuntimeFresh(state) && [state[@"minimapProjection"] isKindOfClass:NSDictionary.class] ? state[@"minimapProjection"] : nil;
            _minimapProjectionUptime=[state[@"heartbeat"] doubleValue];_minimapProjectionPID=[state[@"pid"] intValue];
        }
        id espFlag = [flags isKindOfClass:NSDictionary.class] ? flags[@"__ifxEnemyEspEnabledV1"] : nil;
        BOOL espEnabled = [espFlag isKindOfClass:NSNumber.class] && [espFlag doubleValue] == 1;
        BOOL cameraEnabled = !readOnly && [enabled isKindOfClass:NSNumber.class] && [enabled doubleValue] == 1;
        BOOL reportsEnabled = !readOnly && !runtimeMode && [flags[@"reports.enabled"] isEqual:@YES];
        if (!readOnly && !reportsEnabled && _reportsActive) [self emitReports:@{@"code": @"reports_disabled", @"message": @"Đọc thư tố cáo đang tắt.", @"records": @[], @"querySupported": @NO}];
        _reportsActive = reportsEnabled;
        _requestedHz = [settings[@"espReadHz"] isEqual:@120] ? 120 : 60;
        NSInteger targetHz = espEnabled ? _requestedHz : 10;
        if (_timerHz != targetHz) {
            _timerHz = targetHz;
            dispatch_source_set_timer(_timer, DISPATCH_TIME_NOW, NSEC_PER_SEC / (uint64_t)targetHz, NSEC_PER_MSEC);
            _readSamples = 0; _readWindow = now; _measuredReadHz = 0;
        }
        if (!espEnabled && _espActive) {
            HCEspSampleReset(&_espSamples);
            [self emitEsp:@{@"code": @"esp_disabled", @"message": @"ESP đang tắt.", @"targets": @[]}];
        }
        _espActive = espEnabled;
        if (!cameraEnabled) {
            BOOL wasActive = _hasWritten; [self restoreCamera];
            if (!readOnly && !wasActive && ![_lastReport[@"code"] hasPrefix:@"camera_restore"] && ![_lastReport[@"code"] isEqual:@"camera_disabled"])
                [self emit:@"camera_disabled" message:@"Camera xa đang tắt." extra:nil];
            if (!espEnabled && !reportsEnabled) { [self releaseTarget]; _nextDiscovery = 0; return; }
        }
        id value = settings[@"cameraScale"];
        double scale = [value isKindOfClass:NSNumber.class] ? [value doubleValue] : NAN;
        if (cameraEnabled && (!isfinite(scale) || scale < 1 || scale > 2.3)) {
            [self restore]; [self emit:@"camera_invalid_scale" message:@"Hệ số camera không hợp lệ; không ghi." extra:nil]; return;
        }
        if (now >= _nextDiscovery) {
            _nextDiscovery = now + 2;
            if (![self discover]) {
                if (espEnabled) [self emitEsp:@{@"code": @"esp_access_unavailable", @"message": @"Chưa xác minh quyền đọc và module game.", @"targets": @[]}];
                if (reportsEnabled) [self emitReports:@{@"code": @"reports_access_unavailable", @"message": @"Chưa xác minh quyền đọc và module game.", @"records": @[], @"querySupported": @NO}];
                return;
            }
        }
        if (!_target.task) return;
        if (espEnabled) [self readEsp:[flags[@"DoroCheat.Reference.R1.Unseen"] boolValue]];
        if (reportsEnabled && now >= _nextReportsRead) { _nextReportsRead = now + 2; [self readReports]; }
        if (!cameraEnabled) return;
        // Preserve the already verified camera write cadence independently of ESP.
        if (now < _nextCameraTick) return;
        _nextCameraTick = now + 0.1;
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
