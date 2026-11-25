#include "../Overlay/InputCapture.h"
#include <assert.h>
#include <stdio.h>
int main(void) {
    assert(HCInputDecide(-1,42,true,false,1,0)==HCInputAccept);
    assert(HCInputDecide(42,0,false,true,0.1,0)==HCInputAccept); // missing lift identity
    assert(HCInputDecide(0,42,false,false,0.1,10)==HCInputAccept);
    assert(HCInputDecide(42,42,true,false,0.01,0)==HCInputIgnore); // duplicate down
    assert(HCInputDecide(42,42,true,false,1,0)==HCInputRestart); // lost lift
    assert(HCInputDecide(42,7,true,false,0.1,20)==HCInputRestart);
    assert(HCInputDecide(42,7,false,false,0.1,20)==HCInputIgnore);
    assert(HCInputDecide(42,7,false,true,0.1,20)==HCInputCancel); // never click wrong target
    assert(HCInputDecide(-1,0,false,true,0.1,0)==HCInputIgnore);
    puts("Input capture passed: missing identity, duplicate down, lost lift and mismatched cancellation.");
    return 0;
}
