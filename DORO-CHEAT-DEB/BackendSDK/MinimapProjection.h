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
typedef struct { double ox,oy,xx,xz,yx,yz; } HCMinimapAffine;
static inline bool HCMinimapAffineProject(HCMinimapAffine t,double x,double z,double *u,double *v) {
    if(!isfinite(x) || !isfinite(z) || !isfinite(t.ox) || !isfinite(t.oy) || !isfinite(t.xx) || !isfinite(t.xz) || !isfinite(t.yx) || !isfinite(t.yz) ||
       fabs(t.xx*t.yz-t.xz*t.yx)<1e-10) return false;
    *u=t.ox+t.xx*x+t.xz*z;*v=t.oy+t.yx*x+t.yz*z;
    return isfinite(*u) && isfinite(*v) && *u>=0 && *u<=1 && *v>=0 && *v<=1;
}
static inline bool HCMinimapManualProject(double x,double z,double centerX,double centerZ,double extent,double angle,bool rotated,double *u,double *v) {
    if(!isfinite(centerX) || !isfinite(centerZ) || !isfinite(angle)) return false;
    double rad=angle*3.14159265358979323846/180.0;
    x-=centerX;z-=centerZ;
    return HCMinimapProject(x*cos(rad)-z*sin(rad),x*sin(rad)+z*cos(rad),extent,rotated,u,v);
}
#endif
