#import "../Runtime/RuntimeShared.h"
#include <assert.h>
int main(void) { @autoreleasepool {
    assert(HCReadMemoryOnly(nil));assert(HCReadMemoryOnly(@{}));
    assert(HCReadMemoryOnly(@{@"readMemoryOnly":@YES}));
    assert(!HCReadMemoryOnly(@{@"readMemoryOnly":@NO}));
    assert(HCReadMemoryOnly(@{@"readMemoryOnly":NSNull.null}));
    assert(HCReadMemoryOnly(@{@"readMemoryOnly":@0}));
    puts("Read-memory policy passed: legacy/missing profiles default ON, explicit OFF unlocks.");
} return 0; }
