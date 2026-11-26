#ifndef HC_CAPTURE_POLICY_H
#define HC_CAPTURE_POLICY_H
#include <stdbool.h>
// Capture exclusion belongs to the compositor host. Never hide the local HUD
// merely because recording starts or the optional secure host is unavailable.
static inline bool HCShouldHideOverlay(bool locked,bool enabled,bool captured,bool secureAvailable) {
    (void)enabled; (void)captured; (void)secureAvailable;
    return locked;
}
#endif
