#include "../BackendSDK/LogicEsp.h"
#include <assert.h>
#include <stdio.h>
typedef struct { uint64_t address;unsigned char data[2048]; } Region;
typedef struct { Region regions[32];bool changeFrame;int frameReads; } Fixture;
static bool readLogic(void *ctx,uint64_t address,void *out,size_t size) {
    Fixture *f=ctx;
    for(int i=0;i<32;i++) {
        Region *r=&f->regions[i];
        if(address>=r->address && address-r->address<=sizeof(r->data) && size<=sizeof(r->data)-(address-r->address)) {
            memcpy(out,r->data+(address-r->address),size);
            if(address==0x1C040 && ++f->frameReads>1 && f->changeFrame) { uint32_t changed=11;memcpy(out,&changed,4); }
            return true;
        }
    }
    return false;
}
static void p(Fixture *f,int i,size_t offset,uint64_t value) { memcpy(f->regions[i].data+offset,&value,8); }
static void n(Fixture *f,int i,size_t offset,int32_t value) { memcpy(f->regions[i].data+offset,&value,4); }
static void name(Fixture *f,int i,const char *value) { p(f,i,0x10,f->regions[i].address+0x600);strcpy((char *)f->regions[i].data+0x600,value); }
static Fixture fixture(void) {
    Fixture f={0};for(int i=0;i<32;i++) f.regions[i].address=0x10000+(uint64_t)i*0x1000;
    f.regions[0].address=0x10000000+HC_LOGIC_SINGLETON_METHOD_RVA;p(&f,0,0,0x11000);
    p(&f,1,0x20,0x12000);name(&f,2,"Singleton`1");p(&f,2,0xC0,0x13000);p(&f,3,0x10,0x12000);
    p(&f,2,0xB8,0x14000);p(&f,4,0,0x15000);p(&f,5,0,0x16000);name(&f,6,"LLogicCore");p(&f,6,0x58,0x12000);
    p(&f,5,0x48,0x17000);p(&f,7,8,0x18000);p(&f,8,8,0x19000);n(&f,8,0x10,1);p(&f,9,0x10,1);p(&f,9,0x18,0x1A000);
    p(&f,10,0,0x1B000);name(&f,11,"LFramework");n(&f,10,0x58,1);p(&f,10,0x68,0x1C000);
    p(&f,12,0,0x1D000);name(&f,13,"LMainBattleLogic");p(&f,12,0xF8,0x1E000);n(&f,12,0x40,10);
    p(&f,14,0,0x1F000);name(&f,15,"LGameActorMgr");p(&f,14,0x48,0x20000);
    p(&f,16,8,0x21000);n(&f,16,0x10,1);p(&f,17,0x10,1);p(&f,17,0x20,0x22000);
    p(&f,18,0,0x23000);name(&f,19,"LActorRoot");n(&f,18,0x28,99);n(&f,18,0x58,123);n(&f,18,0x6C,2);
    n(&f,18,0xE0,1000);n(&f,18,0xE8,-10000);p(&f,18,0x338,0x24000);
    p(&f,20,0,0x25000);name(&f,21,"ValuePropertyComponent");p(&f,20,0x20,0x22000);
    n(&f,20,0x50,0x123456);n(&f,20,0x54,0x123456^800);
    p(&f,18,0x328,0x26000);p(&f,22,0,0x27000);name(&f,23,"LSkillComponent");p(&f,22,0x20,0x22000);
    p(&f,22,0x88,0x28000);p(&f,24,0x10,4);name(&f,25,"SkillSlot");
    for(int i=0;i<3;i++) {
        p(&f,24,0x18+(i+1)*8,0x2A000+(uint64_t)i*0x1000);
        p(&f,26+i,0,0x29000);p(&f,26+i,0x38,0x22000);n(&f,26+i,0x4C,1);
        n(&f,26+i,0xFC,0x1234);n(&f,26+i,0x100,0x1234^(i==0?1001:i==1?0:600001));
    }
    return f;
}
static HCEspFrame visual(void) {
    HCEspFrame f={0};f.status=HC_ESP_OK;f.matricesValid=true;f.view[0]=f.view[5]=f.view[10]=f.view[15]=1;
    f.projection[0]=f.projection[5]=1;f.projection[11]=-1;return f;
}
int main(void) {
    Fixture f=fixture();HCCameraMemory bus={&f,readLogic,NULL};HCLogicFrame logic;
    assert(HCLogicRead(bus,0x10000000,1,&logic) && logic.count==1 && logic.stage==8 && logic.targets[0].hp==800);
    assert(logic.targets[0].cooldowns[0]==2 && logic.targets[0].cooldowns[1]==0 && logic.targets[0].cooldowns[2]==-1);
    HCEspFrame frame=visual();HCLogicMerge(&frame,&logic,true,false);
    assert(frame.count==1 && frame.targets[0].logicPosition && !frame.targets[0].visible && frame.projected==1);
    assert(fabsf(frame.targets[0].x-0.55f)<0.001f);
    n(&f,18,0xE0,2000); // Enemy moves while NO visual ActorLinker exists.
    assert(HCLogicRead(bus,0x10000000,1,&logic));frame=visual();HCLogicMerge(&frame,&logic,true,false);
    assert(frame.count==1 && fabsf(frame.targets[0].x-0.6f)<0.001f);
    frame=visual();frame.count=1;frame.targets[0]=logic.targets[0];frame.targets[0].visible=true;
    frame.targets[0].logicPosition=false;frame.targets[0].worldX=1.4f;
    HCLogicMerge(&frame,&logic,true,false);
    assert(frame.targets[0].worldX==1.4f && !frame.targets[0].logicPosition);
    frame.targets[0].visible=false;HCLogicMerge(&frame,&logic,true,false);
    assert(frame.targets[0].worldX==2 && frame.targets[0].logicPosition);
    n(&f,20,0x54,0x123456);assert(HCLogicRead(bus,0x10000000,1,&logic));
    HCLogicMerge(&frame,&logic,true,false);assert(frame.count==0); // Known dead.
    f=fixture();f.regions[18].data[0x420]=1;
    assert(HCLogicRead(bus,0x10000000,1,&logic) && logic.count==0); // Recycled actor.
    f=fixture();f.changeFrame=true;
    assert(!HCLogicRead(bus,0x10000000,1,&logic) && logic.count==0 && logic.stage==7);
    f=fixture();n(&f,10,0x58,2);assert(!HCLogicRead(bus,0x10000000,1,&logic));
    f=fixture();p(&f,2,0xC0,0);assert(HCLogicRead(bus,0x10000000,1,&logic));
    f=fixture();p(&f,1,0x20,0);assert(!HCLogicRead(bus,0x10000000,1,&logic));
    frame=visual();HCLogicMerge(&frame,&logic,false,false);assert(frame.count==0);
    puts("Logic ESP fixture passed: hidden moving actor without visual object, current-frame reprojection, XOR HP, dead/recycled rejection, battle frame stability and ended-battle refusal.");
    return 0;
}
