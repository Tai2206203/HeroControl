#import "../Overlay/ReportAnalysis.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    NSString *longReason=[@"Dòng nội dung đầy đủ\n" stringByPaddingToLength:12000 withString:@"nội dung tiếng Việt dài " startingAtIndex:0];
    NSArray *records=@[@{@"id":@"old",@"eventTime":@100,@"reason":longReason,@"reasonCode":@1,@"information":@"ĐẦY ĐỦ NỘI DUNG",@"source":@"live",@"extra":@{@"detail":@"GIỮ TRƯỜNG MỞ RỘNG"}},
        @{@"id":@"new",@"eventTime":@200,@"reason":@"AFK",@"information":@"mail",@"source":@"mail"}];
    NSArray *blocks=HCReportAnalysisBlocks(@{@"message":@"Đang theo dõi",@"accountID":@"123_1",@"recordsTruncated":@YES},records);
    NSMutableArray *details=[NSMutableArray array];
    for(NSDictionary *block in blocks) if([block[@"detail"] boolValue]) [details addObject:block];
    assert(details.count==2);
    assert([details[0][@"text"] containsString:@"new"]);
    assert([details[1][@"text"] containsString:longReason]);
    assert([details[1][@"text"] containsString:@"ĐẦY ĐỦ NỘI DUNG"]);
    assert([details[1][@"text"] containsString:@"GIỮ TRƯỜNG MỞ RỘNG"]);
    assert([details[1][@"text"] containsString:@"Mã lý do: 1"]);
    assert([blocks[1][@"text"] containsString:@"giới hạn"]);
    assert(HCReportAnalysisBlocks(@{},@[]).count==3);
    NSMutableArray *large=[NSMutableArray array];
    for(int i=0;i<2048;i++) [large addObject:@{@"id":@(i),@"reason":@"AFK"}];
    NSUInteger count=0;for(NSDictionary *block in HCReportAnalysisBlocks(@{},large)) if([block[@"detail"] boolValue]) count++;
    assert(count==2048);
    puts("Report analysis passed: full long text/extra fields, chronological order, truncation disclosure, empty list and all 2048 records.");
} return 0; }
