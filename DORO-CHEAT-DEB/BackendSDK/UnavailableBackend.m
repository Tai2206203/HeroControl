#import <Foundation/Foundation.h>
#include <stdlib.h>
#include <string.h>
#include "HeroBackend.h"

// ABI example only. It deliberately advertises no game capabilities.
__attribute__((visibility("default"))) uint32_t hc_backend_api_version(void) { return 1; }
__attribute__((visibility("default"))) const char *hc_backend_request(const char *request_json) {
    @autoreleasepool {
        if (!request_json) return NULL;
        NSData *input = [[NSString stringWithUTF8String:request_json] dataUsingEncoding:NSUTF8StringEncoding];
        if (!input) return NULL;
        id request = [NSJSONSerialization JSONObjectWithData:input options:0 error:NULL];
        BOOL status = [request isKindOfClass:[NSDictionary class]] && [request[@"action"] isEqual:@"status"];
        NSDictionary *snapshot = @{
            @"protocolVersion": @1, @"backendName": @"Unavailable ABI example",
            @"connected": @NO, @"gameRunning": @NO, @"supportedKeys": @[],
            @"heroes": @[], @"reports": @[],
            @"message": @"Chưa tích hợp kernel/game provider."
        };
        NSDictionary *reply = @{
            @"protocolVersion": @1, @"ok": status ? @YES : @NO, @"snapshot": snapshot,
            @"message": status ? @"Ví dụ ABI đã nạp; chưa có kết nối game." : @"Backend ví dụ không áp dụng chức năng."
        };
        NSData *data = [NSJSONSerialization dataWithJSONObject:reply options:0 error:NULL];
        if (!data) return NULL;
        char *result = malloc(data.length + 1);
        if (!result) return NULL;
        memcpy(result, data.bytes, data.length); result[data.length] = 0;
        return result;
    }
}
__attribute__((visibility("default"))) void hc_backend_release(const char *response_json) {
    free((void *)response_json);
}
