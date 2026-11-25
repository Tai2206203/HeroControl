#ifndef HC_REPORT_SCROLL_H
#define HC_REPORT_SCROLL_H
#include <math.h>
typedef struct { double offset,velocity; } HCReportScrollStep;
static inline double HCReportScrollClamp(double value,double content,double viewport) {
    double limit=fmax(0,content-viewport);
    if(!isfinite(value)) return 0;
    return fmax(0,fmin(value,limit));
}
static inline HCReportScrollStep HCReportScrollAdvance(double offset,double velocity,double elapsed,double content,double viewport) {
    if(!isfinite(velocity) || !isfinite(elapsed) || elapsed<=0) return (HCReportScrollStep){HCReportScrollClamp(offset,content,viewport),0};
    double dt=fmin(elapsed,0.05),decay=exp(-8*dt);
    double next=HCReportScrollClamp(offset+velocity*(1-decay)/8,content,viewport);
    double v=velocity*decay;
    if(next<=0 || next>=fmax(0,content-viewport) || fabs(v)<4) v=0;
    return (HCReportScrollStep){next,v};
}
#endif
