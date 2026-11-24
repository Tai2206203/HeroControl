#ifndef HC_LUA_REPORTS_H
#define HC_LUA_REPORTS_H
#include "CameraMemory.h"
#include <stdio.h>
#include <inttypes.h>
#define HC_LUA_ROOT_TYPE_RVA UINT64_C(0xD0C2088)
#define HC_ROLE_SINGLETON_METHOD_RVA UINT64_C(0xD111F68)
typedef struct { uint64_t value;uint32_t tag,padding; } HCLuaValue;
typedef struct { uint32_t arraySize;uint8_t logNodes;uint64_t array,nodes; } HCLuaTable;
typedef struct { HCCameraMemory memory;uint32_t seed;unsigned calls;bool limited,unstable; } HCLuaRead;
typedef struct { uint64_t mailIndex,sent;char subject[256],reason[192]; } HCReceipt;
typedef struct { int stage,count,tables;bool complete;uint64_t account;HCReceipt records[32]; } HCReceiptScan;
static inline bool HCLuaReadBytes(HCLuaRead *r,uint64_t address,void *out,size_t size) {
    if(++r->calls>6000) { r->limited=true;return false; }
    return size && size<=65536 && address && address<=UINT64_MAX-size && r->memory.read(r->memory.context,address,out,size);
}
static inline bool HCLuaHeader(HCLuaRead *r,uint64_t table,HCLuaTable *out) {
    unsigned char h[32];if(!HCCameraPointer(table) || !HCLuaReadBytes(r,table,h,sizeof(h)) || h[8]!=5 || h[11]>16) return false;
    out->logNodes=h[11];memcpy(&out->arraySize,h+12,4);memcpy(&out->array,h+16,8);memcpy(&out->nodes,h+24,8);
    return out->arraySize<=16384 && HCCameraPointer(out->nodes) && (!out->arraySize || HCCameraPointer(out->array));
}
static inline bool HCLuaStable(HCLuaRead *r,uint64_t table,HCLuaTable before) {
    HCLuaTable after;
    bool same=HCLuaHeader(r,table,&after) && after.arraySize==before.arraySize && after.logNodes==before.logNodes && after.array==before.array && after.nodes==before.nodes;
    if(!same) r->unstable=true;return same;
}
static inline bool HCLuaString(HCLuaRead *r,HCLuaValue value,char *out,size_t capacity) {
    if((value.tag&15)!=4 || !HCCameraPointer(value.value) || !capacity) return false;
    unsigned char h[16];if(!HCLuaReadBytes(r,value.value+8,h,16)) return false;
    uint64_t length=0;
    if(h[0]==4) length=h[3];else if(h[0]==20) memcpy(&length,h+8,8);else return false;
    if(length>=capacity || length>2048) return false;
    if(length && !HCLuaReadBytes(r,value.value+24,out,(size_t)length)) return false;
    out[length]=0;return !memchr(out,0,(size_t)length);
}
// Native Lua 5.3 hash path at 0x9702CEC uses global_State.seed +0x50.
// Table/Node offsets confirmed in luaH_getint (0x9707C58) and getstr.
static inline uint32_t HCLuaHash(uint32_t seed,const char *key) {
    size_t n=strlen(key),step=(n>>5)+1;uint32_t h=seed^(uint32_t)n;
    for(size_t left=n;left>=step;left-=step) h^=(h<<5)+(h>>2)+(unsigned char)key[left-1];
    return h;
}
static inline bool HCLuaGet(HCLuaRead *r,uint64_t table,const char *key,HCLuaValue *out) {
    *out=(HCLuaValue){0};HCLuaTable h;if(strlen(key)>40 || !HCLuaHeader(r,table,&h)) return false;
    uint64_t count=UINT64_C(1)<<h.logNodes;int64_t index=HCLuaHash(r->seed,key)&(count-1);
    for(unsigned chain=0;chain<128;chain++) {
        if(index<0 || (uint64_t)index>=count) return false;
        unsigned char node[32];if(!HCLuaReadBytes(r,h.nodes+(uint64_t)index*32,node,32)) return false;
        HCLuaValue k;memcpy(&k,node+16,16);char text[64];
        if(HCLuaString(r,k,text,sizeof(text)) && !strcmp(text,key)) {
            memcpy(out,node,16);return HCLuaStable(r,table,h);
        }
        int32_t next=0;memcpy(&next,node+28,4);if(!next) return HCLuaStable(r,table,h);
        index+=next;
    }
    r->limited=true;return false;
}
static inline bool HCLuaUInt(HCLuaValue value,uint64_t *out) {
    if(value.tag==19) { if(value.value>INT64_MAX) return false;*out=value.value;return true; }
    if(value.tag==3) { double d;memcpy(&d,&value.value,8);if(!isfinite(d) || d<0 || d>4294967295.0 || floor(d)!=d) return false;*out=(uint64_t)d;return true; }
    return false;
}
static inline bool HCLuaGetUInt(HCLuaRead *r,uint64_t table,const char *key,uint64_t *out) {
    HCLuaValue value;return HCLuaGet(r,table,key,&value) && HCLuaUInt(value,out);
}
static inline uint64_t HCLuaGetTable(HCLuaRead *r,uint64_t table,const char *key) {
    HCLuaValue v;return HCLuaGet(r,table,key,&v) && v.tag==69 && HCCameraPointer(v.value) ? v.value : 0;
}
static inline bool HCReceiptAccount(HCCameraMemory m,uint64_t base,uint64_t *uid) {
    uint64_t method=0,klass=0,fields=0,manager=0,instanceClass=0,parent=0;
    return m.read(m.context,base+HC_ROLE_SINGLETON_METHOD_RVA,&method,8) && HCCameraPointer(method) &&
        m.read(m.context,method+0x20,&klass,8) && HCCameraName(m,klass,"Singleton`1") &&
        m.read(m.context,klass+0xB8,&fields,8) && HCCameraPointer(fields) &&
        m.read(m.context,fields,&manager,8) && HCCameraPointer(manager) &&
        m.read(m.context,manager,&instanceClass,8) && HCCameraName(m,instanceClass,"CRoleInfoManager") &&
        m.read(m.context,instanceClass+0x58,&parent,8) && parent==klass &&
        m.read(m.context,manager+0x10,uid,8) && *uid;
}
static inline bool HCReceiptFromMail(HCLuaRead *r,uint64_t table,HCReceipt *record) {
    *record=(HCReceipt){0};uint64_t subtype=0;
    if(!HCLuaGetUInt(r,table,"subType",&subtype) || subtype!=5 || !HCLuaGetUInt(r,table,"mailIndex",&record->mailIndex)) return false;
    uint64_t extra=HCLuaGetTable(r,table,"userDataExtra"),data=extra?HCLuaGetTable(r,extra,"UserData"):0;
    uint64_t dataType=0;
    if(!extra || !HCLuaGetUInt(r,extra,"UserDataType",&dataType) || !dataType || dataType>UINT32_MAX) return false;
    uint64_t receipt=data?HCLuaGetTable(r,data,"BeComplaintHistory"):0;if(!receipt) return false;
    HCLuaGetUInt(r,table,"sendTime",&record->sent);
    HCLuaValue subject;
    if(HCLuaGet(r,table,"subject",&subject)) HCLuaString(r,subject,record->subject,sizeof(record->subject));
    uint64_t number=0;char reason[32]="?",warnings[32]="?",desk[32]="?";
    if(HCLuaGetUInt(r,receipt,"ChgCreditType",&number)) snprintf(reason,sizeof(reason),"%" PRIu64,number);
    if(HCLuaGetUInt(r,receipt,"PassiveWarnCnt",&number)) snprintf(warnings,sizeof(warnings),"%" PRIu64,number);
    if(HCLuaGetUInt(r,receipt,"DeskID",&number)) snprintf(desk,sizeof(desk),"%" PRIu64,number);
    snprintf(record->reason,sizeof(record->reason),"UserDataType=%" PRIu64 "; ChgCreditType=%s; PassiveWarnCnt=%s; DeskID=%s",dataType,reason,warnings,desk);
    return true;
}
typedef struct { uint64_t address;uint8_t kind,depth; } HCLuaWork;
static inline void HCLuaEnqueue(HCLuaWork queue[128],int *total,HCLuaValue value,int depth,uint64_t globals,bool *limited) {
    if((value.tag!=69 && value.tag!=70) || value.value==globals || !HCCameraPointer(value.value) || depth>5) return;
    for(int i=0;i<*total;i++) if(queue[i].address==value.value) return;
    if(*total>=128) { *limited=true;return; }
    queue[(*total)++]=(HCLuaWork){value.value,(uint8_t)(value.tag&15),(uint8_t)depth};
}
static inline void HCLuaWalkMailbox(HCLuaRead *r,HCLuaValue getter,uint64_t globals,HCReceiptScan *out) {
    HCLuaWork queue[128];int total=0;HCLuaEnqueue(queue,&total,getter,0,globals,&r->limited);
    for(int at=0;at<total && !r->limited;at++) {
        HCLuaWork item=queue[at];
        if(item.kind==6) {
            unsigned char h[32];if(!HCLuaReadBytes(r,item.address,h,32) || h[8]!=6 || h[10]>32) continue;
            for(int i=0;i<h[10];i++) {
                uint64_t up=0,value=0;HCLuaValue v;
                if(HCLuaReadBytes(r,item.address+32+i*8,&up,8) && HCCameraPointer(up) &&
                   HCLuaReadBytes(r,up,&value,8) && HCCameraPointer(value) && HCLuaReadBytes(r,value,&v,16))
                    HCLuaEnqueue(queue,&total,v,item.depth+1,globals,&r->limited);
            }
            continue;
        }
        HCLuaTable h;if(!HCLuaHeader(r,item.address,&h)) continue;out->tables++;
        HCReceipt receipt;
        if(HCReceiptFromMail(r,item.address,&receipt)) {
            bool duplicate=false;for(int i=0;i<out->count;i++) if(out->records[i].mailIndex==receipt.mailIndex && out->records[i].sent==receipt.sent) duplicate=true;
            if(!duplicate) { if(out->count<32) out->records[out->count++]=receipt;else r->limited=true; }
        }
        if(item.depth>=5) continue;
        uint64_t nodes=UINT64_C(1)<<h.logNodes;
        if(h.arraySize>1024 || nodes>2048) { r->limited=true;break; }
        for(uint32_t i=0;i<h.arraySize;i++) {
            HCLuaValue v;if(!HCLuaReadBytes(r,h.array+i*16,&v,16)) { r->unstable=true;break; }
            HCLuaEnqueue(queue,&total,v,item.depth+1,globals,&r->limited);
        }
        for(uint64_t i=0;i<nodes && !r->limited;i++) {
            HCLuaValue v;if(!HCLuaReadBytes(r,h.nodes+i*32,&v,16)) { r->unstable=true;break; }
            HCLuaEnqueue(queue,&total,v,item.depth+1,globals,&r->limited);
        }
        HCLuaStable(r,item.address,h);
    }
    out->complete=!r->limited && !r->unstable;
}
static inline bool HCReadReceiptCache(HCCameraMemory m,uint64_t base,HCReceiptScan *out) {
    *out=(HCReceiptScan){0};out->stage=1;
    if(!m.read || base>UINT64_MAX-HC_ROLE_SINGLETON_METHOD_RVA || !HCReceiptAccount(m,base,&out->account)) return false;
    out->stage=2;uint64_t klass=0,fields=0,env=0,envClass=0,state=0,global=0;uint8_t disposed=1;
    if(!m.read(m.context,base+HC_LUA_ROOT_TYPE_RVA,&klass,8) || !HCCameraName(m,klass,"LuaRoot") ||
       !m.read(m.context,klass+0xB8,&fields,8) || !HCCameraPointer(fields) ||
       !m.read(m.context,fields+0x18,&env,8) || !HCCameraPointer(env) ||
       !m.read(m.context,env,&envClass,8) || !HCCameraName(m,envClass,"LuaEnv") ||
       !m.read(m.context,env+0x40,&disposed,1) || disposed ||
       !m.read(m.context,env+8,&state,8) || !HCCameraPointer(state) ||
       !m.read(m.context,state+0x18,&global,8) || !HCCameraPointer(global)) return false;
    out->stage=3;HCLuaRead r={.memory=m};HCLuaValue registry={0},globals={0};HCLuaTable registryTable;
    if(!HCLuaReadBytes(&r,global+0x50,&r.seed,4) || !HCLuaReadBytes(&r,global+0x40,&registry,16) || registry.tag!=69 ||
       !HCLuaHeader(&r,registry.value,&registryTable) || registryTable.arraySize<2 ||
       !HCLuaReadBytes(&r,registryTable.array+16,&globals,16) || globals.tag!=69) return false;
    out->stage=4;uint64_t package=HCLuaGetTable(&r,globals.value,"package");if(!package) return false;
    out->stage=5;uint64_t loaded=HCLuaGetTable(&r,package,"loaded");if(!loaded) return false;
    out->stage=6;uint64_t mail=HCLuaGetTable(&r,loaded,"AOV.Mail.MailSys");if(!mail) return false;
    out->stage=7;HCLuaValue getter;if(!HCLuaGet(&r,mail,"GetMailList",&getter) || getter.tag!=70) return false;
    out->stage=8;HCLuaWalkMailbox(&r,getter,globals.value,out);
    if(!out->tables) out->complete=false;
    uint64_t accountAfter=0,stateAfter=0,envAfter=0,globalAfter=0;uint8_t disposedAfter=1;
    if(!HCReceiptAccount(m,base,&accountAfter) || accountAfter!=out->account ||
       !m.read(m.context,env+8,&stateAfter,8) || stateAfter!=state ||
       !m.read(m.context,fields+0x18,&envAfter,8) || envAfter!=env ||
       !m.read(m.context,state+0x18,&globalAfter,8) || globalAfter!=global ||
       !m.read(m.context,env+0x40,&disposedAfter,1) || disposedAfter) { out->count=0;out->complete=false;return false; }
    if(!out->complete) { out->count=0;return false; }
    out->stage=9;return true;
}
#endif
