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
    puts("Minimap projection passed: corners, center, rotation, bounds and invalid coordinates.");
}
