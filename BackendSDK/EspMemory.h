#ifndef HC_ESP_MEMORY_H
#define HC_ESP_MEMORY_H
#include "CameraMemory.h"
#define HC_KYRIOS_TYPE_RVA UINT64_C(0xD0BF320)
#define HC_ESP_MAX_TARGETS 32
typedef struct {
    uint32_t objectID; int32_t heroID, hp, maxHP, camp;
    float worldX, worldY, worldZ, x, feetY, headY;
    bool visible, onScreen;
    bool hpKnown;
    bool hpCurrentKnown, logicPosition;
    uint32_t positionFrame;
    int cooldowns[3];
} HCEspTarget;
typedef struct {
    int status, hostCamp, listCount, count, projected;
    uint64_t framework, manager, nativeCamera;
    float hostX, hostZ;
    bool hasHostPosition, matricesValid;
    int matrixStage;
    uint8_t viewMode, projectionDirty;
    float view[16], projection[16];
    HCEspTarget targets[HC_ESP_MAX_TARGETS];
} HCEspFrame;
enum { HC_ESP_OK, HC_ESP_NOT_READY, HC_ESP_BAD_LAYOUT, HC_ESP_READ_FAILED, HC_ESP_MATRICES_PENDING };

static inline bool HCEspProject(const float view[16], const float projection[16], float x, float y, float z, float *outX, float *outY) {
    float point[4] = {x,y,z,1}, eye[4] = {0}, clip[4] = {0};
    for (int r=0;r<4;r++) for(int c=0;c<4;c++) eye[r]+=view[c*4+r]*point[c];
    for (int r=0;r<4;r++) for(int c=0;c<4;c++) clip[r]+=projection[c*4+r]*eye[c];
    if (!isfinite(clip[3]) || clip[3] <= 0.01f) return false;
    *outX = (clip[0]/clip[3]+1)*0.5f; *outY = (1-clip[1]/clip[3])*0.5f;
    return isfinite(*outX) && isfinite(*outY) && *outX > -0.5f && *outX < 1.5f && *outY > -0.5f && *outY < 1.5f;
}
static inline bool HCEspMatrices(HCCameraMemory m, uint64_t base, HCEspFrame *frame, float view[16], float projection[16]) {
    uint64_t klass=0,parent=0,fields=0,camera=0,main=0,mainClass=0,native=0;
    uint8_t viewMode=255,dirtyProjection=255,afterView=255,afterProjection=255;
    frame->matrixStage=1;frame->viewMode=255;frame->projectionDirty=255;
    if (!m.read(m.context,base+HC_CAMERA_TYPE_RVA,&klass,8) || !HCCameraName(m,klass,"CameraSystem") ||
        !m.read(m.context,klass+0x58,&parent,8) || !HCCameraName(m,parent,"MonoSingleton`1") ||
        !m.read(m.context,parent+0xB8,&fields,8) || !HCCameraPointer(fields) ||
        !m.read(m.context,fields,&camera,8) || !HCCameraPointer(camera)) return false;
    frame->matrixStage=2;
    if (!m.read(m.context,camera+0x108,&main,8) || !HCCameraPointer(main) ||
        !m.read(m.context,main,&mainClass,8) || !HCCameraName(m,mainClass,"Camera")) return false;
    frame->matrixStage=3;
    if (!m.read(m.context,main+8,&native,8) || !HCCameraPointer(native)) return false;
    frame->nativeCamera=native;
    // Native getters in this exact module return Camera+0x80 / +0xC0 after
    // refreshing their caches. +0x512 is AUTO-VIEW MODE, not a dirty flag:
    // 0xAAC0ACC recomputes when it is 1, without clearing it on return.
    // +0x510 is projection dirty (0xAABE2DC explicitly clears it).
    // Accept either view mode; double-read the matrices to reject torn samples.
    frame->matrixStage=4;
    if (!m.read(m.context,native+0x512,&viewMode,1) || !m.read(m.context,native+0x510,&dirtyProjection,1)) return false;
    frame->viewMode=viewMode;frame->projectionDirty=dirtyProjection;
    if (viewMode>1 || dirtyProjection) return false;
    frame->matrixStage=5;
    float viewAgain[16], projectionAgain[16];
    if (
        !m.read(m.context,native+0x80,view,64) || !m.read(m.context,native+0xC0,projection,64) ||
        !m.read(m.context,native+0x80,viewAgain,64) || !m.read(m.context,native+0xC0,projectionAgain,64) ||
        !m.read(m.context,native+0x512,&afterView,1) || !m.read(m.context,native+0x510,&afterProjection,1) ||
        afterView!=viewMode || afterProjection || memcmp(view,viewAgain,64) || memcmp(projection,projectionAgain,64)) return false;
    frame->matrixStage=6;
    for(int i=0;i<16;i++) if(!isfinite(view[i]) || !isfinite(projection[i]) || fabsf(view[i])>1e7f || fabsf(projection[i])>1e7f) return false;
    if (!(fabsf(view[15]-1)<0.05f && fabsf(view[3])<0.01f && fabsf(view[7])<0.01f && fabsf(view[11])<0.01f &&
        fabsf(projection[0])>0.001f && fabsf(projection[5])>0.001f)) return false;
    frame->matrixStage=7;return true;
}
static inline void HCEspCooldowns(HCCameraMemory m, uint64_t actor, int values[3]) {
    // Visual SkillSlot.getCurSkillCD constructs a CrypticInt32 from this plain
    // millisecond field (0x65E1768 -> op_Implicit at 0x4F547AC in the dump).
    // Unknown/unlearned slots remain -1 rather than pretending to be ready.
    uint64_t component=0,klass=0,array=0,length=0;
    for(int i=0;i<3;i++) values[i]=-1;
    if(!m.read(m.context,actor+0x18,&component,8) || !HCCameraPointer(component) ||
       !m.read(m.context,component,&klass,8) || !HCCameraName(m,klass,"SkillComponent") ||
       !m.read(m.context,component+0x30,&array,8) || !HCCameraPointer(array) ||
       !m.read(m.context,array+0x10,&length,8) || length<4 || length>32) return;
    for(int i=0;i<3;i++) {
        uint64_t slot=0;int32_t level=0,cd=0;
        if(m.read(m.context,array+0x18+(i+1)*8,&slot,8) && HCCameraPointer(slot) && m.read(m.context,slot,&klass,8) &&
           HCCameraName(m,klass,"SkillSlot") && m.read(m.context,slot+0x1C,&level,4) && level>0 && level<=18 &&
           m.read(m.context,slot+0x50,&cd,4) && cd>=0 && cd<=600000) values[i]=(cd+999)/1000;
    }
}
static inline int HCEspRead(HCCameraMemory m,uint64_t base,bool unseenOnly,HCEspFrame *frame) {
    *frame=(HCEspFrame){0};
    frame->viewMode=frame->projectionDirty=255;
    uint64_t klass=0,parent=0,fields=0,root=0,manager=0,host=0,player=0,list=0,array=0,length=0;
    int32_t size=0;
    if(!m.read || !base || base>UINT64_MAX-HC_KYRIOS_TYPE_RVA) return frame->status=HC_ESP_BAD_LAYOUT;
    if(!m.read(m.context,base+HC_KYRIOS_TYPE_RVA,&klass,8) || !HCCameraPointer(klass)) return frame->status=HC_ESP_NOT_READY;
    if(!HCCameraName(m,klass,"KyriosFramework") || !m.read(m.context,klass+0x58,&parent,8) || !HCCameraName(m,parent,"MonoSingleton`1") ||
       !m.read(m.context,parent+0xB8,&fields,8) || !HCCameraPointer(fields)) return frame->status=HC_ESP_BAD_LAYOUT;
    if(!m.read(m.context,fields,&root,8) || !HCCameraPointer(root)) return frame->status=HC_ESP_NOT_READY;
    uint64_t rootClass=0;
    if(!m.read(m.context,root,&rootClass,8) || rootClass!=klass) return frame->status=HC_ESP_BAD_LAYOUT;
    uint8_t running=0;
    if(!m.read(m.context,root+0x18,&running,1) || running!=1) return frame->status=HC_ESP_NOT_READY;
    frame->framework=root;
    if(!m.read(m.context,root+0x28,&manager,8) || !HCCameraPointer(manager)) return frame->status=HC_ESP_NOT_READY;
    frame->manager=manager;
    if(!m.read(m.context,manager,&klass,8) || !HCCameraName(m,klass,"ActorManager") ||
       !m.read(m.context,root+0x50,&host,8) || !HCCameraPointer(host) || !m.read(m.context,host+8,&player,8) || !HCCameraPointer(player) ||
       !m.read(m.context,player+0x30,&frame->hostCamp,4) || (frame->hostCamp!=1 && frame->hostCamp!=2)) return frame->status=HC_ESP_NOT_READY;
    uint64_t captain=0;int32_t hostPosition[3]={0};
    if(m.read(m.context,player+0x1A0,&captain,8) && HCCameraPointer(captain) &&
       m.read(m.context,captain,&klass,8) && HCCameraName(m,klass,"ActorLinker") &&
       m.read(m.context,captain+0x18C,hostPosition,12) &&
       fabsf(hostPosition[0]*0.001f)<=10000 && fabsf(hostPosition[2]*0.001f)<=10000) {
        frame->hostX=hostPosition[0]*0.001f;frame->hostZ=hostPosition[2]*0.001f;frame->hasHostPosition=true;
    }
    if(!m.read(m.context,manager+0x20,&list,8) || !HCCameraPointer(list) || !m.read(m.context,list+8,&array,8) ||
       !m.read(m.context,list+0x10,&size,4) || size<0 || size>64 || !HCCameraPointer(array) ||
       !m.read(m.context,array+0x10,&length,8) || length<(uint64_t)size || length>256) return frame->status=HC_ESP_READ_FAILED;
    frame->listCount=size;
    frame->matricesValid=HCEspMatrices(m,base,frame,frame->view,frame->projection);
    for(int i=0;i<size && frame->count<HC_ESP_MAX_TARGETS;i++) {
        uint64_t actor=0,value=0;uint8_t visible=0;HCEspTarget t={0};int32_t position[3]={0};
        if(!m.read(m.context,array+0x18+i*16+8,&actor,8) || !HCCameraPointer(actor) || !m.read(m.context,actor,&klass,8) ||
           !HCCameraName(m,klass,"ActorLinker") || !m.read(m.context,actor+0x22C,&t.camp,4) ||
           (t.camp!=1 && t.camp!=2) || t.camp==frame->hostCamp || !m.read(m.context,actor+0x218,&t.heroID,4) || t.heroID<=0 || t.heroID>1000000 ||
           !m.read(m.context,actor+0x148,&t.objectID,4) || !t.objectID || !m.read(m.context,actor+0x1DD,&visible,1) || visible>1 ||
           (unseenOnly && visible) || !m.read(m.context,actor+0x18C,position,12)) continue;
        // Hidden actors can keep receiving positions while their visual HP
        // component is unavailable. Do not discard a valid position for that.
        bool hpRead=m.read(m.context,actor+0x28,&value,8) && HCCameraPointer(value) &&
           m.read(m.context,value,&klass,8) && HCCameraName(m,klass,"ValueLinkerComponent") &&
           m.read(m.context,value+0x40,&t.hp,4) && m.read(m.context,value+0x44,&t.maxHP,4);
        if(hpRead && visible && t.hp==0 && t.maxHP>0 && t.maxHP<=100000000) continue;
        t.hpKnown=hpRead && t.hp>0 && t.maxHP>0 && t.hp<=t.maxHP && t.maxHP<=100000000;
        t.hpCurrentKnown=hpRead && t.hp>=0 && t.hp<=100000000;
        if(!t.hpKnown) { if(!t.hpCurrentKnown) t.hp=0; t.maxHP=0; }
        m.read(m.context,actor+0x144,&t.positionFrame,4);
        t.worldX=position[0]*0.001f;t.worldY=position[1]*0.001f;t.worldZ=position[2]*0.001f;
        if(fabsf(t.worldX)>10000 || fabsf(t.worldY)>10000 || fabsf(t.worldZ)>10000) continue;
        t.visible=visible!=0;
        float headX=0;
        if(frame->matricesValid && HCEspProject(frame->view,frame->projection,t.worldX,t.worldY,t.worldZ,&t.x,&t.feetY) &&
            HCEspProject(frame->view,frame->projection,t.worldX,t.worldY+2.73f,t.worldZ,&headX,&t.headY) && t.feetY>t.headY) {
            t.onScreen=true;frame->projected++;
        }
        HCEspCooldowns(m,actor,t.cooldowns);
        frame->targets[frame->count++]=t;
    }
    uint64_t currentRoot=0,currentArray=0;int32_t currentSize=0;
    if (!m.read(m.context,fields,&currentRoot,8) || currentRoot!=root ||
        !m.read(m.context,list+8,&currentArray,8) || currentArray!=array ||
        !m.read(m.context,list+0x10,&currentSize,4) || currentSize!=size) {
        frame->count=frame->projected=0;frame->hasHostPosition=false;
        return frame->status=HC_ESP_READ_FAILED;
    }
    return frame->status=frame->matricesValid ? HC_ESP_OK : HC_ESP_MATRICES_PENDING;
}
#endif
