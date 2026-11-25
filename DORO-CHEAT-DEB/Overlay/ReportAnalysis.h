#ifndef HC_REPORT_ANALYSIS_H
#define HC_REPORT_ANALYSIS_H
#import <Foundation/Foundation.h>
#include <math.h>
static NSString *HCReportValueText(id value) {
    if(!value || value==NSNull.null) return @"Chưa được cung cấp";
    if([value isKindOfClass:NSString.class]) return [value length] ? value : @"Chưa được cung cấp";
    if([value isKindOfClass:NSDictionary.class] || [value isKindOfClass:NSArray.class]) {
        NSData *json=[NSJSONSerialization dataWithJSONObject:value options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:NULL];
        if(json) return [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    }
    return [value description];
}
static NSString *HCReportReason(NSDictionary *record) {
    return HCReportValueText(record[@"reason"] ?: record[@"reasonDescription"]);
}
static NSArray<NSDictionary *> *HCReportAnalysisBlocks(NSDictionary *status,NSArray *input) {
    NSMutableArray *records=[NSMutableArray array];
    for(id value in input) if([value isKindOfClass:NSDictionary.class]) [records addObject:value];
    NSMutableArray *blocks=[NSMutableArray array];
    void (^add)(NSString *,NSString *,BOOL)=^(NSString *title,NSString *text,BOOL detail) {
        [blocks addObject:@{@"title":title,@"text":text,@"detail":@(detail)}];
    };
    NSMutableDictionary<NSString *,NSNumber *> *reasons=[NSMutableDictionary dictionary];
    NSUInteger live=0,mail=0;
    for(NSDictionary *record in records) {
        NSString *reason=HCReportReason(record);reasons[reason]=@([reasons[reason] unsignedIntegerValue]+1);
        if([record[@"source"] isEqual:@"live"]) live++;
        if([record[@"source"] isEqual:@"mail"]) mail++;
    }
    NSString *summary=[NSString stringWithFormat:@"%lu bản ghi trong khoảng đang chọn • %lu nhóm lý do\nTrực tiếp: %lu • Thư: %lu • Nguồn khác: %lu\nNgười chơi đã biết: %@ • Yêu cầu đã gửi: %@ • Phản hồi: %@\nTài khoản: %@",
        (unsigned long)records.count,(unsigned long)reasons.count,(unsigned long)live,(unsigned long)mail,
        (unsigned long)(records.count-live-mail),HCReportValueText(status[@"candidateCount"] ?: @0),
        HCReportValueText(status[@"sentRequestCount"] ?: @0),HCReportValueText(status[@"receivedResponseCount"] ?: @0),
        HCReportValueText(status[@"accountID"])];
    add(@"PHÂN TÍCH TỐ CÁO",summary,NO);
    NSMutableString *state=[NSMutableString stringWithString:HCReportValueText(status[@"message"])];
    if([status[@"queryStatus"] isKindOfClass:NSString.class] && [status[@"queryStatus"] length]) [state appendFormat:@"\nTruy vấn: %@",status[@"queryStatus"]];
    [state appendString:@"\nBảng hiển thị đầy đủ các bản ghi đã nhận trong khoảng chọn; không bảo đảm toàn bộ lịch sử trên máy chủ."];
    if([status[@"recordsTruncated"] boolValue]) [state appendString:@"\nNguồn dữ liệu báo đã giới hạn số bản ghi lưu giữ."];
    add(@"TRẠNG THÁI THU THẬP",state,NO);
    NSArray *reasonKeys=[reasons.allKeys sortedArrayUsingComparator:^NSComparisonResult(NSString *a,NSString *b) {
        NSComparisonResult count=[reasons[b] compare:reasons[a]];return count==NSOrderedSame ? [a compare:b] : count;
    }];
    for(NSString *reason in reasonKeys) add([NSString stringWithFormat:@"LÝ DO • %@ BẢN GHI",reasons[reason]],reason,NO);
    if(!records.count) add(@"CHƯA CÓ BẢN GHI",@"Chưa có dữ liệu đã nhận trong khoảng này. Không thể kết luận tài khoản chưa từng bị tố cáo.",NO);
    NSDictionary *labels=@{@"id":@"Mã bản ghi",@"reasonCode":@"Mã lý do",@"source":@"Nguồn",@"eventTime":@"Thời điểm máy chủ",@"accountID":@"Tài khoản",@"playerID":@"Người chơi",@"playerName":@"Tên người chơi",@"uid":@"UID",@"reasonDescription":@"Diễn giải lý do"};
    NSDateFormatter *date=[NSDateFormatter new];date.locale=[NSLocale localeWithLocaleIdentifier:@"vi_VN"];
    date.timeZone=[NSTimeZone timeZoneForSecondsFromGMT:25200];date.dateFormat=@"dd/MM/yyyy HH:mm:ss '+07:00'";
    NSArray *ordered=[records sortedArrayWithOptions:NSSortStable usingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b) {
        double ta=[a[@"eventTime"] respondsToSelector:@selector(doubleValue)] ? [a[@"eventTime"] doubleValue] : 0;
        double tb=[b[@"eventTime"] respondsToSelector:@selector(doubleValue)] ? [b[@"eventTime"] doubleValue] : 0;
        return ta>tb ? NSOrderedAscending : ta<tb ? NSOrderedDescending : NSOrderedSame;
    }];
    NSUInteger index=0;
    for(NSDictionary *record in ordered) {
        NSString *time=[record[@"time"] isKindOfClass:NSString.class] && [record[@"time"] length] ? record[@"time"] : nil;
        double stamp=[record[@"eventTime"] respondsToSelector:@selector(doubleValue)] ? [record[@"eventTime"] doubleValue] : 0;
        if(!time && isfinite(stamp) && stamp>0) time=[date stringFromDate:[NSDate dateWithTimeIntervalSince1970:stamp]];
        NSMutableString *text=[NSMutableString stringWithFormat:@"Thời gian: %@\nLý do: %@\nNội dung: %@",time ?: @"Chưa được cung cấp",HCReportReason(record),HCReportValueText(record[@"information"])];
        for(NSString *key in [record.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            if([@[@"time",@"reason",@"information"] containsObject:key]) continue;
            [text appendFormat:@"\n%@: %@",labels[key] ?: key,HCReportValueText(record[key])];
        }
        add([NSString stringWithFormat:@"BẢN GHI %lu / %lu",(unsigned long)++index,(unsigned long)records.count],text,YES);
    }
    return blocks;
}
#endif
