#import <Foundation/Foundation.h>
@interface HCCameraEngine : NSObject
- (instancetype)initWithProfile:(NSString *)profile report:(void (^)(NSDictionary *))report espReport:(void (^)(NSDictionary *))espReport;
- (void)start;
- (NSDictionary *)stop;
@end
