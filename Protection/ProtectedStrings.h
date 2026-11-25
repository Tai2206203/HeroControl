#ifndef HC_PROTECTED_STRINGS_H
#define HC_PROTECTED_STRINGS_H
#ifdef __cplusplus
extern "C" {
#endif
typedef enum {
#define HC_STRING(group, name, value) name,
#include "ProtectedStrings.def"
#undef HC_STRING
    HCSStringCount
} HCStringID;
// Process-lifetime read-only UTF-8, decoded once on first use (thread safe).
__attribute__((visibility("hidden"))) const char *HCProtectedCString(HCStringID identifier);
#ifdef __cplusplus
}
#endif
#ifdef __OBJC__
#import <Foundation/Foundation.h>
#import <dispatch/dispatch.h>
static inline NSString *HCProtectedString(HCStringID identifier) {
    if((unsigned)identifier>=(unsigned)HCSStringCount) return @"";
    static NSString *values[HCSStringCount];
    static dispatch_once_t once[HCSStringCount];
    dispatch_once(&once[identifier],^{values[identifier]=[NSString stringWithUTF8String:HCProtectedCString(identifier)];});
    return values[identifier];
}
#endif
#endif
