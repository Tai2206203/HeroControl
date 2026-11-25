#ifndef HC_CAMERA_CONTROL_H
#define HC_CAMERA_CONTROL_H
#include <math.h>
// Display-only distance: 0 is native/default, 2 retains the verified max zoom.
static inline double HCCameraDistance(double scale) { return isfinite(scale) ? fmax(0,fmin(2,(scale-1)/0.65)) : 0; }
static inline double HCCameraScaleFromDistance(double distance) { return 1+0.65*(isfinite(distance) ? fmax(0,fmin(2,distance)) : 0); }
#endif
