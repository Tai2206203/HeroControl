#include "../BackendSDK/EspPresentation.h"
#include <assert.h>
#include <stdio.h>

static HCEspFrame sample(float x) {
    HCEspFrame f={0};f.status=HC_ESP_OK;f.framework=0x10000;f.nativeCamera=0x20000;f.hostCamp=1;
    f.matricesValid=true;f.view[0]=f.view[5]=f.view[10]=f.view[15]=1;
    f.projection[0]=f.projection[5]=1;f.projection[11]=-1;
    f.count=1;f.targets[0]=(HCEspTarget){.objectID=42,.heroID=123,.worldX=x,.worldZ=-10,.visible=true};
    return f;
}
static HCEspFrame failure(int status) {
    HCEspFrame f={0};f.status=status;f.framework=0x10000;f.hostCamp=1;return f;
}
int main(void) {
    HCEspSampleBuffer buffer={0};HCEspFrame f=sample(0);
    HCEspPresentation p=HCEspPresent(&buffer,&f,0,false);
    assert(f.count==1 && f.projected==1 && !p.retained);
    f=failure(HC_ESP_READ_FAILED);p=HCEspPresent(&buffer,&f,0.1,false);
    assert(f.count==1 && f.projected==1 && p.retained && fabs(p.age-0.1)<0.000001);
    f=failure(HC_ESP_READ_FAILED);p=HCEspPresent(&buffer,&f,0.6,false);
    assert(f.count==1 && p.retained);
    f=failure(HC_ESP_READ_FAILED);HCEspPresent(&buffer,&f,0.6001,false);assert(f.count==0);

    HCEspSampleReset(&buffer);f=sample(0);HCEspPresent(&buffer,&f,1,false);
    f=sample(2);f.status=HC_ESP_MATRICES_PENDING;f.matricesValid=false;
    p=HCEspPresent(&buffer,&f,1.2,false);
    assert(p.retained && f.projected==1 && fabsf(f.targets[0].x-0.6f)<0.0001f);
    f=sample(0);f.status=HC_ESP_READ_FAILED;f.count=0;f.view[12]=2;
    HCEspPresent(&buffer,&f,1.3,false);
    assert(f.count==1 && fabsf(f.targets[0].x-0.7f)<0.0001f); // Latest matrices, retained WORLD position.
    f=sample(0);f.count=0;HCEspPresent(&buffer,&f,1.4,false);assert(f.count==0);
    f=failure(HC_ESP_READ_FAILED);HCEspPresent(&buffer,&f,1.5,false);assert(f.count==0); // Authoritative removal.

    f=sample(0);HCEspPresent(&buffer,&f,2,false);
    f=failure(HC_ESP_NOT_READY);HCEspPresent(&buffer,&f,2.1,false);assert(f.count==0);
    f=failure(HC_ESP_READ_FAILED);HCEspPresent(&buffer,&f,2.2,false);assert(f.count==0);
    f=sample(0);HCEspPresent(&buffer,&f,3,false);
    f=failure(HC_ESP_READ_FAILED);f.framework=0x30000;HCEspPresent(&buffer,&f,3.1,false);assert(f.count==0);
    f=sample(0);HCEspPresent(&buffer,&f,4,false);
    f=sample(0);f.nativeCamera=0x40000;f.matricesValid=false;f.status=HC_ESP_MATRICES_PENDING;
    HCEspPresent(&buffer,&f,4.1,false);assert(f.projected==0);
    f=sample(0);HCEspPresent(&buffer,&f,5,false);
    f=failure(HC_ESP_READ_FAILED);HCEspPresent(&buffer,&f,5.1,true);assert(f.count==0); // Fresh Unseen filter on held data.
    f=sample(0);f.targets[0].worldY=20;HCEspPresent(&buffer,&f,5.2,false);
    assert(f.count==1 && !f.targets[0].onScreen && f.projected==0);
    f=sample(0);HCEspPresent(&buffer,&f,4.9,false);assert(!buffer.hasMatrices || buffer.matricesTime==4.9);

    HCEspScreenState smooth={0};
    assert(HCEspSmooth(&smooth,42,123,0,0.5f,0.3f,0.5f));
    assert(HCEspSmooth(&smooth,42,123,0.016,0.6f,0.3f,0.5f));
    assert(smooth.x>0.5f && smooth.x<0.6f);
    HCEspSmooth(&smooth,43,123,0.032,0.7f,0.3f,0.5f);assert(smooth.x==0.7f); // Recycled identity snaps.
    assert(!HCEspSmooth(&smooth,43,123,0.04,NAN,0.3f,0.5f));
    HCEspScreenState a={0},b={0};
    HCEspSmooth(&a,1,1,0,0.5f,0.3f,0.5f);HCEspSmooth(&b,1,1,0,0.5f,0.3f,0.5f);
    for(int i=1;i<=60;i++) HCEspSmooth(&a,1,1,i/60.0,0.6f,0.3f,0.5f);
    for(int i=1;i<=120;i++) HCEspSmooth(&b,1,1,i/120.0,0.6f,0.3f,0.5f);
    assert(fabsf(a.x-b.x)<0.00001f);
    puts("ESP presentation passed: 600-ms bounded hold, fresh-world reprojection, authoritative removal, identity/camera resets, viewport clipping and frame-rate-independent smoothing.");
    return 0;
}
