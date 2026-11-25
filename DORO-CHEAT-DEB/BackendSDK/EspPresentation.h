#ifndef HC_ESP_PRESENTATION_H
#define HC_ESP_PRESENTATION_H
#include "EspMemory.h"

// Hold independently verified actor/matrix samples through short read failures.
// No sleeps and no queued 120-ms backlog: every fresh sample replaces the cache.
#define HC_ESP_HOLD_SECONDS 0.12
typedef struct {
    HCEspFrame actors, matrices;
    double actorsTime, matricesTime;
    bool hasActors, hasMatrices;
} HCEspSampleBuffer;
typedef struct { bool retained; double sourceTime, age; } HCEspPresentation;

static inline void HCEspSampleReset(HCEspSampleBuffer *buffer) {
    *buffer=(HCEspSampleBuffer){0};
}
static inline void HCEspReproject(HCEspFrame *frame,bool unseenOnly) {
    int count=frame->count;frame->count=frame->projected=0;
    for(int i=0;i<count;i++) {
        HCEspTarget t=frame->targets[i];
        if(unseenOnly && t.visible) continue;
        float headX=0;t.x=t.feetY=t.headY=0;t.onScreen=false;
        if(frame->matricesValid && HCEspProject(frame->view,frame->projection,t.worldX,t.worldY,t.worldZ,&t.x,&t.feetY) &&
           HCEspProject(frame->view,frame->projection,t.worldX,t.worldY+2.73f,t.worldZ,&headX,&t.headY) &&
           t.feetY>t.headY && t.x>=0 && t.x<=1 && t.feetY>0 && t.headY<1) {
            t.onScreen=true;frame->projected++;
        }
        frame->targets[frame->count++]=t;
    }
}
static inline HCEspPresentation HCEspPresent(HCEspSampleBuffer *buffer,HCEspFrame *input,double now,bool unseenOnly) {
    HCEspPresentation result={false,now,0};
    int status=input->status;
    bool actorsValid=status==HC_ESP_OK || status==HC_ESP_MATRICES_PENDING;
    bool transient=actorsValid || status==HC_ESP_READ_FAILED;
    if(!isfinite(now) || input->count<0 || input->count>HC_ESP_MAX_TARGETS || !transient || !input->framework) {
        HCEspSampleReset(buffer);input->count=input->projected=0;return result;
    }
    if((buffer->hasActors && (input->framework!=buffer->actors.framework ||
        (input->hostCamp && input->hostCamp!=buffer->actors.hostCamp) || now<buffer->actorsTime)) ||
       (buffer->hasMatrices && now<buffer->matricesTime)) HCEspSampleReset(buffer);
    if(buffer->hasMatrices && input->nativeCamera && input->nativeCamera!=buffer->matrices.nativeCamera) buffer->hasMatrices=false;
    if(input->matricesValid) { buffer->matrices=*input;buffer->matricesTime=now;buffer->hasMatrices=true; }
    if(actorsValid) { buffer->actors=*input;buffer->actorsTime=now;buffer->hasActors=true; }
    if(!buffer->hasActors || !buffer->hasMatrices || now-buffer->actorsTime>HC_ESP_HOLD_SECONDS ||
       now-buffer->matricesTime>HC_ESP_HOLD_SECONDS) {
        HCEspSampleReset(buffer);input->count=input->projected=0;input->matricesValid=false;return result;
    }
    HCEspFrame frame=buffer->actors;
    frame.status=status;
    memcpy(frame.view,buffer->matrices.view,sizeof(frame.view));
    memcpy(frame.projection,buffer->matrices.projection,sizeof(frame.projection));
    frame.nativeCamera=buffer->matrices.nativeCamera;frame.matricesValid=true;
    result.sourceTime=fmin(buffer->actorsTime,buffer->matricesTime);
    result.age=now-result.sourceTime;
    result.retained=!actorsValid || !input->matricesValid || result.age>0;
    HCEspReproject(&frame,unseenOnly);
    *input=frame;return result;
}

typedef struct {
    bool valid;
    uint32_t objectID;
    int32_t heroID;
    double time;
    float x,headY,feetY;
} HCEspScreenState;
static inline bool HCEspSmooth(HCEspScreenState *state,uint32_t objectID,int32_t heroID,double now,float x,float headY,float feetY) {
    if(!isfinite(now) || !isfinite(x) || !isfinite(headY) || !isfinite(feetY) || feetY<=headY) {
        state->valid=false;return false;
    }
    double elapsed=now-state->time;
    bool reset=!state->valid || state->objectID!=objectID || state->heroID!=heroID || elapsed<0 || elapsed>HC_ESP_HOLD_SECONDS ||
        fabsf(x-state->x)>0.35f || fabsf(headY-state->headY)>0.35f;
    if(reset) { state->x=x;state->headY=headY;state->feetY=feetY; }
    else {
        float alpha=(float)(1.0-exp(-elapsed/0.025));
        state->x+=(x-state->x)*alpha;
        state->headY+=(headY-state->headY)*alpha;
        state->feetY+=(feetY-state->feetY)*alpha;
    }
    state->valid=true;state->objectID=objectID;state->heroID=heroID;state->time=now;
    return true;
}
#endif
