#ifndef HC_CAPTURE_POLICY_H
#define HC_CAPTURE_POLICY_H
#include <stdbool.h>
static inline bool HCShouldHideOverlay(bool locked,bool enabled,bool captured,bool secureAvailable) {
    return locked || (enabled && (captured || !secureAvailable));
}
#endif
