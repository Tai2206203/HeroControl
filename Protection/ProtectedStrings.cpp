#include "ProtectedStrings.h"
#include <array>
#include <cstddef>
#include <cstring>
#if defined(_DEBUG) || defined(OXORANY_DISABLE_OBFUSCATION)
#error Release string protection must not be disabled
#endif
#if (defined(HC_OBF_GROUP_OVERLAY) + defined(HC_OBF_GROUP_BACKEND) + defined(HC_OBF_GROUP_RUNTIME)) != 1
#error Select exactly one native protection group
#endif
#include "../ThirdParty/oxorany/oxorany.h"
// Copy during the full expression: oxorany returns a temporary buffer.
// A function-local static provides a stable lifetime and thread-safe first use.
#define HC_DECODE(name, literal) case name: { \
    static const auto value=[] { std::array<char,sizeof(literal)> result{}; \
        std::memcpy(result.data(),oxorany(literal),result.size());return result; }(); \
    return value.data(); }
#define HC_SELECT_COMMON HC_DECODE
#ifdef HC_OBF_GROUP_OVERLAY
#define HC_SELECT_OVERLAY HC_DECODE
#else
#define HC_SELECT_OVERLAY(name,literal)
#endif
#ifdef HC_OBF_GROUP_BACKEND
#define HC_SELECT_BACKEND HC_DECODE
#else
#define HC_SELECT_BACKEND(name,literal)
#endif
#ifdef HC_OBF_GROUP_RUNTIME
#define HC_SELECT_RUNTIME HC_DECODE
#else
#define HC_SELECT_RUNTIME(name,literal)
#endif
extern "C" const char *HCProtectedCString(HCStringID identifier) {
    switch(identifier) {
#define HC_STRING(group, name, literal) HC_SELECT_##group(name,literal)
#include "ProtectedStrings.def"
#undef HC_STRING
    default:return "";
    }
}
