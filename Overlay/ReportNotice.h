#ifndef HC_REPORT_NOTICE_H
#define HC_REPORT_NOTICE_H
#import <Foundation/Foundation.h>
#import "../Runtime/RuntimeShared.h"
@interface HCReportNoticeTracker : NSObject
- (instancetype)initWithPath:(NSString *)path;
- (NSArray<NSDictionary *> *)observe:(NSDictionary *)status enabled:(BOOL)enabled now:(NSTimeInterval)now;
@end
@implementation HCReportNoticeTracker {
    NSString *_path,*_account;
    NSMutableOrderedSet<NSString *> *_seen;
    BOOL _primed,_allowRecentInitial;
}
- (instancetype)initWithPath:(NSString *)path {
    if((self=[super init])) { _path=[path copy];_seen=[NSMutableOrderedSet orderedSet]; }
    return self;
}
- (NSArray<NSDictionary *> *)observe:(NSDictionary *)status enabled:(BOOL)enabled now:(NSTimeInterval)now {
    NSString *account=[status[@"accountID"] isKindOfClass:NSString.class] ? status[@"accountID"] : nil;
    if(!account.length || account.length>128) return @[];
    if(![_account isEqual:account]) {
        BOOL switching=_account!=nil;
        _account=[account copy];[_seen removeAllObjects];_primed=NO;
        NSDictionary *saved=HCRuntimeReadJSON(_path,196608);
        _allowRecentInitial=!switching && ![NSFileManager.defaultManager fileExistsAtPath:_path];
        if([saved[@"schemaVersion"] isEqual:@1] && [saved[@"accountID"] isEqual:account] && [saved[@"ids"] isKindOfClass:NSArray.class]) {
            for(id identifier in saved[@"ids"]) if([identifier isKindOfClass:NSString.class] && [identifier length]<=256) {
                [_seen addObject:identifier];if(_seen.count>=4096) break;
            }
            _primed=[saved[@"primed"] isEqual:@YES] && ![saved[@"complete"] isEqual:@NO];
        }
    }
    NSArray *records=[status[@"records"] isKindOfClass:NSArray.class] ? status[@"records"] : @[];
    if(records.count>2048) records=[records subarrayWithRange:NSMakeRange(records.count-2048,2048)];
    BOOL fresh=![status[@"runtimeResponding"] isEqual:@NO];
    NSMutableArray *arrivals=[NSMutableArray array];NSMutableOrderedSet *active=[NSMutableOrderedSet orderedSet];
    BOOL changed=NO;BOOL wasPrimed=_primed;
    for(id value in records) {
        if(![value isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *record=value;
        NSString *identifier=[record[@"id"] isKindOfClass:NSString.class] ? record[@"id"] : nil;
        if(!identifier.length || identifier.length>256) continue;
        [active addObject:identifier];
        if([_seen containsObject:identifier]) { [_seen removeObject:identifier];[_seen addObject:identifier];continue; }
        double event=[record[@"eventTime"] isKindOfClass:NSNumber.class] ? [record[@"eventTime"] doubleValue] : 0;
        BOOL recentLive=[record[@"source"] isEqual:@"live"] && isfinite(event) && now>=event && now-event<=30;
        // Historical first snapshots seed the baseline; later stale samples do
        // not consume IDs before a live sample can deliver the notification.
        if(_primed && enabled && !fresh) continue;
        if(enabled && fresh && (_primed || (_allowRecentInitial && recentLive))) [arrivals addObject:record];
        [_seen addObject:identifier];changed=YES;
    }
    if(fresh || records.count) _primed=YES;
    if(wasPrimed!=_primed) changed=YES;
    while(_seen.count>4096) [_seen removeObjectAtIndex:0];
    if(changed) {
        // Persist the active window first, then older IDs. The HUD inherits a
        // 256-KiB file limit, so never write an unbounded receipt checkpoint.
        NSMutableOrderedSet *ordered=[active mutableCopy];
        for(NSString *identifier in _seen.reverseObjectEnumerator) [ordered addObject:identifier];
        NSMutableArray *ids=[ordered.array mutableCopy];NSDictionary *snapshot;
        while(YES) {
            snapshot=@{@"schemaVersion":@1,@"accountID":_account,@"primed":@(_primed),@"complete":@(ids.count>=active.count),@"ids":ids};
            NSData *bytes=[NSJSONSerialization dataWithJSONObject:snapshot options:NSJSONWritingSortedKeys error:NULL];
            if(bytes && bytes.length<=196608) break;
            if(!ids.count) return arrivals;
            [ids removeObjectsInRange:NSMakeRange(ids.count-MIN((NSUInteger)128,ids.count),MIN((NSUInteger)128,ids.count))];
        }
        HCRuntimeWriteJSON(snapshot,_path,NULL);
    }
    return arrivals;
}
@end
#endif
