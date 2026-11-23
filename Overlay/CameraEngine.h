#import <Foundation/Foundation.h>
@interface HCCameraEngine : NSObject
- (instancetype)initWithProfile:(NSString *)profile report:(void (^)(NSDictionary *))report;
- (void)start;
- (NSDictionary *)stop;
@end
