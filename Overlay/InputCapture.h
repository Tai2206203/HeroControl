#ifndef HC_INPUT_CAPTURE_H
#define HC_INPUT_CAPTURE_H
#include <math.h>
#include <stdbool.h>
typedef enum { HCInputIgnore, HCInputAccept, HCInputRestart, HCInputCancel } HCInputDecision;
// Unknown HID path identity is zero. A mismatched terminal event cancels safely.
static inline HCInputDecision HCInputDecide(long captured,long incoming,bool began,bool terminal,double elapsed,double distance) {
    if(began) {
        if(captured<0) return HCInputAccept;
        if(captured==incoming && elapsed>=0 && elapsed<0.05 && distance<2) return HCInputIgnore;
        return HCInputRestart;
    }
    if(captured<0) return HCInputIgnore;
    if(incoming>0 && captured>0 && incoming!=captured) return terminal ? HCInputCancel : HCInputIgnore;
    return HCInputAccept;
}
#endif
