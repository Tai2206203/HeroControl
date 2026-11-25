#include "../BackendSDK/MinimapProjection.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    double u=0,v=0;
    assert(HCMinimapProject(0,0,60,false,&u,&v) && u==0.5 && v==0.5);
    assert(HCMinimapProject(-60,60,60,false,&u,&v) && u==0 && v==0);
    assert(HCMinimapProject(60,-60,60,false,&u,&v) && u==1 && v==1);
    assert(HCMinimapProject(-60,60,60,true,&u,&v) && u==1 && v==1);
    assert(!HCMinimapProject(61,0,60,false,&u,&v));
    assert(!HCMinimapProject(0,0,0,false,&u,&v));
    assert(!HCMinimapProject(NAN,0,60,false,&u,&v));
    assert(!HCMinimapProject(0,INFINITY,60,false,&u,&v));
    HCMinimapAffine t={.ox=0.15,.oy=0.22,.xx=0.001,.xz=0.002,.yx=0.002,.yz=-0.001};
    assert(HCMinimapAffineProject(t,10,20,&u,&v));
    assert(fabs(u-0.20)<1e-10 && fabs(v-0.22)<1e-10);
    assert(!HCMinimapAffineProject((HCMinimapAffine){0},0,0,&u,&v));
    assert(HCMinimapManualProject(10,20,10,20,60,45,false,&u,&v) && u==0.5 && v==0.5);
    assert(HCMinimapManualProject(60,0,0,0,60,90,false,&u,&v) && fabs(u-0.5)<1e-10 && fabs(v)<1e-10);
    puts("Minimap projection passed: corners, center, rotation, bounds and invalid coordinates.");
}
