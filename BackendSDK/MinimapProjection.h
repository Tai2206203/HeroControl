#ifndef HC_MINIMAP_PROJECTION_H
#define HC_MINIMAP_PROJECTION_H
#include <stdbool.h>
#include <math.h>
static inline bool HCMinimapProject(double x,double z,double extent,bool rotated,double *u,double *v) {
    if (!isfinite(x) || !isfinite(z) || !isfinite(extent) || extent<=0) return false;
    *u=(x+extent)/(2*extent);*v=1-(z+extent)/(2*extent);
    if(rotated) { *u=1-*u;*v=1-*v; }
    return *u>=0 && *u<=1 && *v>=0 && *v<=1;
}
#endif
