#include "../Overlay/ReportScroll.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(HCReportScrollClamp(-10,1000,200)==0);
    assert(HCReportScrollClamp(9999,1000,200)==800);
    assert(HCReportScrollClamp(20,100,200)==0);
    assert(HCReportScrollClamp(NAN,1000,200)==0);
    HCReportScrollStep down=HCReportScrollAdvance(300,1500,1.0/60,5000,200);
    assert(down.offset>300 && down.velocity>0 && down.velocity<1500);
    HCReportScrollStep up=HCReportScrollAdvance(300,-1500,1.0/60,5000,200);
    assert(up.offset<300 && up.velocity<0);
    HCReportScrollStep edge=HCReportScrollAdvance(799,2000,0.05,1000,200);
    assert(edge.offset==800 && edge.velocity==0);
    edge=HCReportScrollAdvance(1,-2000,0.05,1000,200);
    assert(edge.offset==0 && edge.velocity==0);
    HCReportScrollStep a={1000,900},b=a;
    for(int i=0;i<30;i++) a=HCReportScrollAdvance(a.offset,a.velocity,1.0/60,10000,200);
    for(int i=0;i<60;i++) b=HCReportScrollAdvance(b.offset,b.velocity,1.0/120,10000,200);
    assert(fabs(a.offset-b.offset)<0.001 && fabs(a.velocity-b.velocity)<0.001);
    puts("Report scrolling passed: bounds, empty list, both directions, edge stop and 60/120-Hz momentum parity.");
    return 0;
}
