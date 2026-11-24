#ifndef HC_LOGIC_ESP_H
#define HC_LOGIC_ESP_H
#include "EspMemory.h"
#define HC_LOGIC_SINGLETON_METHOD_RVA UINT64_C(0xD1129D0)
typedef struct { int stage,count,listCount;uint32_t frameNumber;uint64_t framework;HCEspTarget targets[HC_ESP_MAX_TARGETS]; } HCLogicFrame;
// Follows the instantiated Singleton<LLogicCore>.get_instance metadata path
// used by native code at 0x265F6FC. No remote functions are invoked.
static inline bool HCLogicRead(HCCameraMemory m,uint64_t base,int hostCamp,HCLogicFrame *out) {
    *out=(HCLogicFrame){0};out->stage=1;
    uint64_t method=0,klass=0,rgctx=0,singleton=0,fields=0,core=0,coreClass=0,parent=0;
    if(!m.read || (hostCamp!=1 && hostCamp!=2) || base>UINT64_MAX-HC_LOGIC_SINGLETON_METHOD_RVA) return false;
    for(int i=0;i<3;i++) {
        // get_instance, HasInstance, .ctor: all belong to this same closed type.
        if(m.read(m.context,base+HC_LOGIC_SINGLETON_METHOD_RVA-i*8,&method,8) && HCCameraPointer(method) &&
           m.read(m.context,method+0x20,&klass,8) && HCCameraName(m,klass,"Singleton`1")) break;
        klass=0;
    }
    if(!klass) return false;
    out->stage=2;
    singleton=klass;
    uint64_t resolved=0;
    if(m.read(m.context,klass+0xC0,&rgctx,8) && HCCameraPointer(rgctx) &&
       m.read(m.context,rgctx+0x10,&resolved,8) && HCCameraName(m,resolved,"Singleton`1")) singleton=resolved;
    if(!m.read(m.context,singleton+0xB8,&fields,8) || !HCCameraPointer(fields) ||
       !m.read(m.context,fields,&core,8) || !HCCameraPointer(core) ||
       !m.read(m.context,core,&coreClass,8) || !HCCameraName(m,coreClass,"LLogicCore") ||
       !m.read(m.context,coreClass+0x58,&parent,8) || parent!=singleton) return false;
    out->stage=3;
    uint64_t listView=0,list=0,array=0,length=0;int32_t count=0;
    if(!m.read(m.context,core+0x48,&listView,8) || !HCCameraPointer(listView) ||
       !m.read(m.context,listView+8,&list,8) || !HCCameraPointer(list) ||
       !m.read(m.context,list+8,&array,8) || !HCCameraPointer(array) ||
       !m.read(m.context,list+0x10,&count,4) || count<1 || count>8 ||
       !m.read(m.context,array+0x10,&length,8) || length<(uint64_t)count || length>64) return false;
    uint64_t framework=0;
    for(int i=0;i<count;i++) {
        uint64_t desk=0,deskClass=0;int32_t state=0;
        if(m.read(m.context,array+0x18+i*8,&desk,8) && HCCameraPointer(desk) &&
           m.read(m.context,desk,&deskClass,8) && HCCameraName(m,deskClass,"LFramework") &&
           m.read(m.context,desk+0x58,&state,4) && state==1) {
            if(framework) return false; // Ambiguous battle; do not choose one.
            framework=desk;
        }
    }
    out->stage=4;out->framework=framework;
    uint64_t battle=0,manager=0;
    if(!HCCameraPointer(framework) || !m.read(m.context,framework+0x68,&battle,8) || !HCCameraPointer(battle) ||
       !m.read(m.context,battle,&klass,8) || !HCCameraName(m,klass,"LMainBattleLogic") ||
       !m.read(m.context,battle+0xF8,&manager,8) || !HCCameraPointer(manager) ||
       !m.read(m.context,manager,&klass,8) || !HCCameraName(m,klass,"LGameActorMgr")) return false;
    out->stage=5;
    uint64_t heroes=0,items=0,capacity=0;int32_t size=0;
    if(!m.read(m.context,battle+0x40,&out->frameNumber,4) ||
       !m.read(m.context,manager+0x48,&heroes,8) || !HCCameraPointer(heroes) ||
       !m.read(m.context,heroes+8,&items,8) || !HCCameraPointer(items) ||
       !m.read(m.context,heroes+0x10,&size,4) || size<0 || size>64 ||
       !m.read(m.context,items+0x10,&capacity,8) || capacity<(uint64_t)size || capacity>256) return false;
    out->listCount=size;out->stage=6;
    for(int i=0;i<size && out->count<HC_ESP_MAX_TARGETS;i++) {
        uint64_t actor=0,component=0;uint8_t recycled=1;int32_t position[3]={0};HCEspTarget t={0};
        if(!m.read(m.context,items+0x18+i*16+8,&actor,8) || !HCCameraPointer(actor) ||
           !m.read(m.context,actor,&klass,8) || !HCCameraName(m,klass,"LActorRoot") ||
           !m.read(m.context,actor+0x420,&recycled,1) || recycled ||
           !m.read(m.context,actor+0x28,&t.objectID,4) || !t.objectID ||
           !m.read(m.context,actor+0x58,&t.heroID,4) || t.heroID<=0 || t.heroID>1000000 ||
           !m.read(m.context,actor+0x6C,&t.camp,4) || (t.camp!=1 && t.camp!=2) || t.camp==hostCamp ||
           !m.read(m.context,actor+0xE0,position,12)) continue;
        t.worldX=position[0]*0.001f;t.worldY=position[1]*0.001f;t.worldZ=position[2]*0.001f;
        if(fabsf(t.worldX)>10000 || fabsf(t.worldY)>10000 || fabsf(t.worldZ)>10000) continue;
        uint32_t hp[2]={0};uint64_t owner=0;
        if(m.read(m.context,actor+0x338,&component,8) && HCCameraPointer(component) &&
           m.read(m.context,component,&klass,8) && HCCameraName(m,klass,"ValuePropertyComponent") &&
           m.read(m.context,component+0x20,&owner,8) && owner==actor &&
           m.read(m.context,component+0x50,hp,8) && (hp[0]^hp[1])<=100000000) {
            t.hp=(int32_t)(hp[0]^hp[1]);t.hpCurrentKnown=true;
        }
        t.logicPosition=true;t.positionFrame=out->frameNumber;
        for(int k=0;k<3;k++) t.cooldowns[k]=-1;
        out->targets[out->count++]=t;
    }
    uint64_t itemsAfter=0,frameworkAfter=0;int32_t sizeAfter=0,stateAfter=0;uint32_t frameAfter=0;
    out->stage=7;
    if(!m.read(m.context,heroes+8,&itemsAfter,8) || itemsAfter!=items ||
       !m.read(m.context,heroes+0x10,&sizeAfter,4) || sizeAfter!=size ||
       !m.read(m.context,framework+0x68,&frameworkAfter,8) || frameworkAfter!=battle ||
       !m.read(m.context,framework+0x58,&stateAfter,4) || stateAfter!=1 ||
       !m.read(m.context,battle+0x40,&frameAfter,4) || frameAfter!=out->frameNumber) { out->count=0;return false; }
    out->stage=8;return true;
}
static inline void HCLogicMerge(HCEspFrame *visual,const HCLogicFrame *logic,bool available,bool unseenOnly) {
    if(available) for(int i=0;i<logic->count;i++) {
        HCEspTarget t=logic->targets[i];int slot=-1;
        for(int j=0;j<visual->count;j++) if(visual->targets[j].objectID==t.objectID && visual->targets[j].heroID==t.heroID) { slot=j;break; }
        if(t.hpCurrentKnown && t.hp==0) {
            if(slot>=0) visual->targets[slot]=visual->targets[--visual->count];
            continue;
        }
        if(slot>=0) {
            HCEspTarget *v=&visual->targets[slot];
            // Visible actors use their interpolated visual position; hidden
            // actors use the logic position, which does not require a mesh.
            if(!v->visible) {
                v->worldX=t.worldX;v->worldY=t.worldY;v->worldZ=t.worldZ;v->logicPosition=true;v->positionFrame=t.positionFrame;
            }
            if(t.hpCurrentKnown) { v->hp=t.hp;v->hpCurrentKnown=true;v->hpKnown=v->maxHP>=t.hp && v->maxHP>0; }
        } else if(visual->count<HC_ESP_MAX_TARGETS) visual->targets[visual->count++]=t;
    }
    int count=visual->count;visual->count=visual->projected=0;
    for(int i=0;i<count;i++) {
        HCEspTarget t=visual->targets[i];
        if(unseenOnly && t.visible) continue;
        float headX=0;t.x=t.feetY=t.headY=0;t.onScreen=false;
        if(visual->matricesValid && HCEspProject(visual->view,visual->projection,t.worldX,t.worldY,t.worldZ,&t.x,&t.feetY) &&
           HCEspProject(visual->view,visual->projection,t.worldX,t.worldY+2.73f,t.worldZ,&headX,&t.headY) && t.feetY>t.headY) { t.onScreen=true;visual->projected++; }
        visual->targets[visual->count++]=t;
    }
}
#endif
