#include "../BackendSDK/EspVisualStyle.h"
#include "../Overlay/CapturePolicy.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    HCEspDimensions normal=HCEspCombinedDimensions(48,100,32,1),large=HCEspCombinedDimensions(48,100,32,2);
    assert(large.width==normal.width*2 && large.height==normal.height*2 && large.icon==normal.icon*2);
    assert(HCHeroBadgeSized(large.width,large.height,large.icon)==64);
    assert(HCEspCombinedDimensions(48,100,32,NAN).width==0);
    HCHeroHealth hp=HCHeroHealthValue(100,100,true);
    assert(hp.known && hp.ratio==1 && hp.green==1 && hp.red==0);
    hp=HCHeroHealthValue(50,100,true);
    assert(hp.ratio==0.5 && hp.red==1 && hp.green==1);
    hp=HCHeroHealthValue(0,100,true);
    assert(hp.known && hp.ratio==0 && hp.red==1 && hp.green==0);
    assert(!HCHeroHealthValue(80,0,true).known);
    assert(!HCHeroHealthValue(101,100,true).known);
    assert(!HCHeroHealthValue(NAN,100,true).known);
    assert(!HCHeroHealthValue(50,100,false).known);
    for(int height=4;height<=400;height++) {
        double width=height*0.48,d=HCHeroBadgeDiameter(width,height);
        assert(d==0 || (d+4<=width && d+4<=height && d<=38));
    }
    assert(HCHeroBadgeSized(100,100,64)==64);
    assert(HCHeroBadgeSized(30,100,64)==26);
    assert(HCHeroBadgeSized(100,100,12)==12);
    assert(HCHeroBadgeSized(100,100,NAN)==0);
    assert(HCMinimapDragPosition(10,-100,896,150)==0);
    assert(HCMinimapDragPosition(10,1000,896,150)==(896.0-150)/896);
    double saved=HCMinimapDragPosition(10,70,896,150);
    assert(saved*896==80);
    assert(HCMinimapDragPosition(0,0,0,150)==0);
    assert(HCShouldHideOverlay(false,true,true,true));
    assert(HCShouldHideOverlay(false,true,false,false));
    assert(!HCShouldHideOverlay(false,true,false,true));
    assert(!HCShouldHideOverlay(false,false,true,false));
    assert(HCShouldHideOverlay(true,false,false,true));
    puts("ESP visuals passed: HP colors/unknowns, badge containment and bounded minimap dragging.");
}
