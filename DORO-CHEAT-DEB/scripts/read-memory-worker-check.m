#import "../Overlay/CameraEngine.h"
#include <assert.h>
static void check(NSString *profile,BOOL explicitOff) {
    NSMutableDictionary *flags=[NSMutableDictionary dictionary];
    for(NSString *key in @[@"__ifxEnemyEspEnabledV1",@"HeroControl.ESP.HeroID",@"DoroCheat.Reference.R1.Box",@"DoroCheat.Reference.R1.Icon",@"DoroCheat.Reference.R1.HP",@"DoroCheat.Reference.R1.Map",@"DoroCheat.Reference.R1.Unseen",@"DoroCheat.Reference.R1.Check",@"reports.enabled"]) flags[key]=@NO;
    flags[@"reports.enabled"]=explicitOff ? @NO : @YES;
    NSMutableDictionary *settings=[@{@"flags":flags,@"cameraScale":@1.7,@"selectedSkins":@{},@"cameraEnabled":(explicitOff ? @NO : @YES),@"gameRuntimeEnabled":(explicitOff ? @NO : @YES)} mutableCopy];
    if(explicitOff) settings[@"readMemoryOnly"]=@NO;
    NSData *bytes=[NSJSONSerialization dataWithJSONObject:@{@"schemaVersion":@1,@"revision":@"test",@"settings":settings} options:0 error:NULL];
    assert([bytes writeToFile:profile atomically:YES]);
    __block BOOL camera=NO,reports=NO;
    HCCameraEngine *worker=[[HCCameraEngine alloc] initWithProfile:profile report:^(NSDictionary *value) {
        assert([value[@"writeCount"] unsignedIntegerValue]==0);
        if([value[@"code"] isEqual:explicitOff ? @"camera_disabled" : @"read_memory_only"]) camera=YES;
    } espReport:^(NSDictionary *value) { (void)value; } reportsReport:^(NSDictionary *value) {
        if([value[@"code"] isEqual:@"reports_read_memory_only"]) reports=YES;
    }];
    [worker start];NSDate *deadline=[NSDate dateWithTimeIntervalSinceNow:3];
    while((!camera || (!explicitOff && !reports)) && [deadline timeIntervalSinceNow]>0) [NSRunLoop.currentRunLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    assert(camera);
    if(!explicitOff) assert(reports);
    [worker stop];
}
int main(void) { @autoreleasepool {
    NSString *path=[NSTemporaryDirectory() stringByAppendingPathComponent:[NSUUID.UUID.UUIDString stringByAppendingString:@".json"]];
    check(path,NO);check(path,YES);
    assert([NSFileManager.defaultManager removeItemAtPath:path error:NULL]);
    puts("Read-memory worker passed: missing mode blocks saved camera/report intent, zero writes; explicit OFF uses normal disabled path.");
} return 0; }
