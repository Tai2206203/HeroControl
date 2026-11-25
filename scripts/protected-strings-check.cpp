#include "../Protection/ProtectedStrings.h"
#include <cassert>
#include <cstring>
#include <cstdio>
#include <thread>
#include <vector>
#include <atomic>
#define HC_ASSERT(name,literal) { const char *value=HCProtectedCString(name); \
    assert(std::strcmp(value,literal)==0);assert(value==HCProtectedCString(name)); }
#define HC_TEST_COMMON HC_ASSERT
#ifdef HC_OBF_GROUP_BACKEND
#define HC_TEST_BACKEND HC_ASSERT
#else
#define HC_TEST_BACKEND(name,literal) assert(HCProtectedCString(name)[0]==0);
#endif
#ifdef HC_OBF_GROUP_OVERLAY
#define HC_TEST_OVERLAY HC_ASSERT
#else
#define HC_TEST_OVERLAY(name,literal) assert(HCProtectedCString(name)[0]==0);
#endif
#ifdef HC_OBF_GROUP_RUNTIME
#define HC_TEST_RUNTIME HC_ASSERT
#else
#define HC_TEST_RUNTIME(name,literal) assert(HCProtectedCString(name)[0]==0);
#endif
int main() {
    std::atomic<bool> start{false};std::vector<std::thread> workers;
    for(int i=0;i<8;i++) workers.emplace_back([&] {
        while(!start.load()) std::this_thread::yield();
        for(int repeat=0;repeat<100;repeat++) {
#define HC_STRING(group,name,literal) HC_TEST_##group(name,literal)
#include "../Protection/ProtectedStrings.def"
#undef HC_STRING
        }
    });
    start.store(true);
    for(auto &thread:workers) thread.join();
    assert(HCProtectedCString(static_cast<HCStringID>(-1))[0]==0);
    assert(HCProtectedCString(HCSStringCount)[0]==0);
    std::puts("Protected strings passed: exact decode, stable lifetime, concurrent first use and component isolation.");
}
