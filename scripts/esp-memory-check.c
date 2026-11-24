#include "../BackendSDK/EspMemory.h"
#include <assert.h>
#include <stdio.h>

typedef struct { uint64_t address; unsigned char bytes[2048]; } EspRegion;
typedef struct { EspRegion regions[30]; int reads, sizeReads; bool mutate; } EspFixture;
static bool readEspMemory(void *ctx,uint64_t address,void *out,size_t size) {
    EspFixture *f=ctx; f->reads++;
    for(int i=0;i<30;i++) {
        EspRegion *r=&f->regions[i];
        if(address>=r->address && address-r->address<=sizeof(r->bytes) && size<=sizeof(r->bytes)-(address-r->address)) {
            memcpy(out,r->bytes+(address-r->address),size);
            if(address==0x15010 && ++f->sizeReads>1 && f->mutate) { int32_t bad=63;memcpy(out,&bad,4); }
            return true;
        }
    }
    return false;
}
static void p(EspFixture *f,int region,size_t offset,uint64_t value) { memcpy(f->regions[region].bytes+offset,&value,8); }
static void n(EspFixture *f,int region,size_t offset,int32_t value) { memcpy(f->regions[region].bytes+offset,&value,4); }
static void name(EspFixture *f,int region,const char *value) {
    p(f,region,0x10,f->regions[region].address+0x600);strcpy((char *)f->regions[region].bytes+0x600,value);
}
static EspFixture fixture(void) {
    EspFixture f={0};
    for(int i=0;i<30;i++) f.regions[i].address=0x10000+(uint64_t)i*0x1000;
    // Shared singleton + enemy list, one visible enemy and one friendly.
    f.regions[0].address=0x10000000+HC_KYRIOS_TYPE_RVA;
    p(&f,0,0,0x11000);name(&f,1,"KyriosFramework");p(&f,1,0x58,0x12000);
    name(&f,2,"MonoSingleton`1");p(&f,2,0xB8,0x13000);p(&f,3,0,0x14000);
    p(&f,4,0,0x11000);p(&f,4,0x28,0x16000);p(&f,4,0x50,0x17000);
    name(&f,6,"ActorManager");p(&f,6,0,0x16000);p(&f,6,0x20,0x15000);p(&f,7,8,0x18000);n(&f,8,0x30,1);
    p(&f,5,8,0x19000);n(&f,5,0x10,2);p(&f,9,0x10,2);
    p(&f,9,0x20,0x1A000);p(&f,9,0x30,0x1B000);
    name(&f,12,"ActorLinker");name(&f,13,"ValueLinkerComponent");
    for(int i=10;i<=11;i++) {
        p(&f,i,0,0x1C000);n(&f,i,0x22C,i==10?2:1);n(&f,i,0x218,123);
        n(&f,i,0x148,i);f.regions[i].bytes[0x1DD]=1;p(&f,i,0x28,0x1E000);
        n(&f,i,0x18C,1000);n(&f,i,0x194,-10000);
    }
    p(&f,14,0,0x1D000);n(&f,14,0x40,800);n(&f,14,0x44,1000);
    // Main Camera native pointer is at managed+8. Matrix cache at +0x80/+0xC0.
    f.regions[15].address=0x10000000+HC_CAMERA_TYPE_RVA;
    p(&f,15,0,0x20000);name(&f,16,"CameraSystem");p(&f,16,0x58,0x21000);
    name(&f,17,"MonoSingleton`1");p(&f,17,0xB8,0x22000);p(&f,18,0,0x23000);
    p(&f,19,0x108,0x24000);p(&f,20,0,0x25000);p(&f,20,8,0x26000);name(&f,21,"Camera");
    float view[16]={0},projection[16]={0};
    view[0]=view[5]=view[10]=view[15]=1;
    projection[0]=projection[5]=1;projection[11]=-1;
    memcpy(f.regions[22].bytes+0x80,view,64);memcpy(f.regions[22].bytes+0xC0,projection,64);
    p(&f,10,0x18,0x27000);p(&f,23,0,0x28000);name(&f,24,"SkillComponent");p(&f,23,0x30,0x29000);
    p(&f,25,0x10,4);name(&f,26,"SkillSlot");
    for(int i=0;i<3;i++) {
        p(&f,25,0x18+(i+1)*8,0x2B000+(uint64_t)i*0x1000);
        p(&f,27+i,0,0x2A000);n(&f,27+i,0x1C,1);n(&f,27+i,0x50,i==0?1001:i==1?0:600001);
    }
    return f;
}
int main(void) {
    EspFixture f=fixture();HCCameraMemory bus={&f,readEspMemory,NULL};HCEspFrame frame;
    assert(HCEspRead(bus,0x10000000,false,&frame)==HC_ESP_OK);
    assert(frame.count==1 && frame.projected==1 && frame.targets[0].hp==800);
    assert(frame.targets[0].heroID==123 && frame.targets[0].cooldowns[0]==2);
    assert(frame.targets[0].cooldowns[1]==0 && frame.targets[0].cooldowns[2]==-1);
    assert(fabsf(frame.targets[0].x-0.55f)<0.001f && frame.targets[0].headY<frame.targets[0].feetY);
    assert(HCEspRead(bus,0x10000000,true,&frame)==HC_ESP_OK && frame.count==0);
    f.regions[10].bytes[0x1DD]=0;
    assert(HCEspRead(bus,0x10000000,true,&frame)==HC_ESP_OK && frame.count==1);
    f.regions[22].bytes[0x512]=1;
    assert(HCEspRead(bus,0x10000000,false,&frame)==HC_ESP_MATRICES_PENDING && frame.projected==0);
    f.regions[22].bytes[0x512]=0;n(&f,14,0x40,1001);
    assert(HCEspRead(bus,0x10000000,false,&frame)==HC_ESP_OK && frame.count==0);
    n(&f,5,0x10,65);
    assert(HCEspRead(bus,0x10000000,false,&frame)==HC_ESP_READ_FAILED);
    f=fixture();f.mutate=true;
    assert(HCEspRead(bus,0x10000000,false,&frame)==HC_ESP_READ_FAILED && frame.count==0);
    puts("ESP fixture passed: projection, native header, team/unseen filter, HP validation, dirty matrices, bounded lists, concurrent list change; no device memory accessed.");
    return 0;
}
