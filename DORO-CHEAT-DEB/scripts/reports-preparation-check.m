#import "../Overlay/ReportsPreparation.h"
#include <assert.h>
int main(void) {
    @autoreleasepool {
        NSDictionary *report=HCPrepareReportRuntime(@{});
        assert([report[@"code"] isEqual:@"reports_prepare_helper_missing"]);
        assert([report[@"message"] length]>0);
        puts("Reports preparation preflight passed: a host/outside-app process cannot launch an installer.");
    }
    return 0;
}
