#include "../Overlay/DrawerMotion.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    HCMotionRect bubble={12,90,52,52},panel={128,42,640,330};
    HCDrawerGeometry start=HCDrawerFromAnchor(bubble,panel,0),end=HCDrawerFromAnchor(bubble,panel,1);
    assert(start.reveal.x==bubble.x && start.reveal.width==52);
    assert(end.reveal.x==panel.x && end.reveal.width==640 && end.dx==0 && end.dy==0);
    double previous=0;
    for(int i=0;i<=28;i++) {
        double progress=HCMotionProgress(0,1,i/100.0,0.28);
        assert(progress>=previous && progress<=1);previous=progress;
        HCDrawerGeometry frame=HCDrawerFromAnchor(bubble,panel,progress);
        assert(frame.reveal.width>=52 && frame.reveal.width<=640);
    }
    double interrupted=HCMotionProgress(0,1,0.09,0.28);
    assert(HCMotionProgress(interrupted,0,0,0.28)==interrupted);
    assert(HCMotionProgress(interrupted,0,0.28,0.28)==0);
    assert(HCReportNoticeProgress(0)==0 && HCReportNoticeProgress(0.24)==1);
    assert(HCReportNoticeProgress(2)==1 && HCReportNoticeProgress(3.9)>0);
    assert(HCReportNoticeProgress(4)==0 && HCReportNoticeProgress(5)==0 && HCReportNoticeProgress(NAN)==0);
    puts("Drawer motion passed: bubble anchor, monotonic slide, reversible toggle, and 4-second notice expiry.");
}
