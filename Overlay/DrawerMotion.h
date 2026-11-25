#ifndef HC_DRAWER_MOTION_H
#define HC_DRAWER_MOTION_H
#include <math.h>
typedef struct { double x,y,width,height; } HCMotionRect;
typedef struct { HCMotionRect reveal;double dx,dy; } HCDrawerGeometry;
static inline double HCMotionClamp(double value) { return isfinite(value) ? fmax(0,fmin(1,value)) : 0; }
static inline double HCMotionEase(double value) { value=HCMotionClamp(value);return 1-pow(1-value,3); }
static inline double HCMotionProgress(double from,double to,double elapsed,double duration) {
    return from+(to-from)*HCMotionEase(duration>0 ? elapsed/duration : 1);
}
static inline HCDrawerGeometry HCDrawerFromAnchor(HCMotionRect anchor,HCMotionRect destination,double progress) {
    double p=HCMotionClamp(progress),q=1-p;
    return (HCDrawerGeometry){{anchor.x*q+destination.x*p,anchor.y*q+destination.y*p,
        anchor.width*q+destination.width*p,anchor.height*q+destination.height*p},
        (anchor.x+anchor.width/2-destination.x-destination.width/2)*q,
        (anchor.y+anchor.height/2-destination.y-destination.height/2)*q};
}
// Four seconds total, including entering and leaving the bubble anchor.
static inline double HCReportNoticeProgress(double elapsed) {
    if(!isfinite(elapsed) || elapsed<0 || elapsed>=4) return 0;
    if(elapsed<0.24) return HCMotionEase(elapsed/0.24);
    if(elapsed>3.78) return 1-HCMotionEase((elapsed-3.78)/0.22);
    return 1;
}
#endif
