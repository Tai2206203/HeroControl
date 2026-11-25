#import "../Overlay/ReportNotice.h"
#include <assert.h>
static NSDictionary *row(NSString *identifier,double event) {
    return @{@"id":identifier,@"eventTime":@(event),@"source":@"live",@"reason":@"Rớt mạng/AFK"};
}
static NSDictionary *status(NSString *account,NSArray *records,BOOL fresh) {
    return @{@"accountID":account,@"records":records,@"runtimeResponding":@(fresh)};
}
int main(void) {
    @autoreleasepool {
        NSString *folder=[NSTemporaryDirectory() stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
        assert([NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:NO attributes:nil error:NULL]);
        NSString *path=[folder stringByAppendingPathComponent:@"seen.json"];
        HCReportNoticeTracker *tracker=[[HCReportNoticeTracker alloc] initWithPath:path];
        NSDictionary *old=row(@"old",1),*first=row(@"first",1001),*off=row(@"off",1002),*late=row(@"late",1003);
        assert([tracker observe:status(@"A",@[old],YES) enabled:YES now:1000].count==0);
        assert([tracker observe:status(@"A",@[old,first],YES) enabled:YES now:1001].count==1);
        assert([tracker observe:status(@"A",@[first,old],YES) enabled:YES now:1001].count==0);
        tracker=[[HCReportNoticeTracker alloc] initWithPath:path];
        assert([tracker observe:status(@"A",@[old,first],YES) enabled:YES now:1002].count==0);
        assert([tracker observe:status(@"A",@[old,first,off],YES) enabled:NO now:1002].count==0);
        assert([tracker observe:status(@"A",@[old,first,off],YES) enabled:YES now:1002].count==0);
        assert([tracker observe:status(@"A",@[old,first,off,late],NO) enabled:YES now:1003].count==0);
        assert([tracker observe:status(@"A",@[old,first,off,late],YES) enabled:YES now:1003].count==1);
        assert([tracker observe:status(@"B",@[row(@"other",1003)],YES) enabled:YES now:1003].count==0);
        assert([tracker observe:status(@"A",@[old,first,off,late],YES) enabled:YES now:1004].count==0);
        NSMutableArray *large=[NSMutableArray array];
        for(int i=0;i<2048;i++) [large addObject:row([NSString stringWithFormat:@"%d-%@",i,[@"x" stringByPaddingToLength:230 withString:@"x" startingAtIndex:0]],1)];
        tracker=[[HCReportNoticeTracker alloc] initWithPath:path];
        assert([tracker observe:status(@"large",large,YES) enabled:YES now:1005].count==0);
        assert([tracker observe:status(@"large",large,YES) enabled:YES now:1006].count==0);
        NSDictionary *attributes=[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        assert([attributes[NSFileSize] unsignedLongLongValue]<=196608);
        tracker=[[HCReportNoticeTracker alloc] initWithPath:path];
        assert([tracker observe:status(@"large",large,YES) enabled:YES now:1007].count==0);
        assert([NSFileManager.defaultManager removeItemAtPath:folder error:NULL]);
        puts("Report notices passed: history baseline, single arrival, dedup/restart, OFF, stale deferral, account switch and bounded checkpoint.");
    }
    return 0;
}
