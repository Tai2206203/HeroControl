#include "../BackendSDK/LuaReports.h"
#include <assert.h>
#include <stdlib.h>
typedef struct { uint64_t address;unsigned char data[4096]; } Region;
typedef struct { Region regions[100];int count;uint64_t next,account,subtype,env;bool switchAccount;int accountReads; } Fixture;
static bool readMemory(void *ctx,uint64_t address,void *out,size_t size) {
    Fixture *f=ctx;
    for(int i=0;i<f->count;i++) {
        Region *r=&f->regions[i];
        if(address>=r->address && address-r->address<=sizeof(r->data) && size<=sizeof(r->data)-(address-r->address)) {
            memcpy(out,r->data+(address-r->address),size);
            if(address==f->account && ++f->accountReads>1 && f->switchAccount) { uint64_t changed=7;memcpy(out,&changed,8); }
            return true;
        }
    }
    return false;
}
static void bytes(Fixture *f,uint64_t address,const void *data,size_t size) {
    for(int i=0;i<f->count;i++) if(address>=f->regions[i].address && address+size<=f->regions[i].address+4096) {
        memcpy(f->regions[i].data+(address-f->regions[i].address),data,size);return;
    }
    assert(false);
}
static void ptr(Fixture *f,uint64_t address,uint64_t value) { bytes(f,address,&value,8); }
static uint64_t region(Fixture *f,uint64_t address) {
    assert(f->count<100);
    if(!address) { address=f->next;f->next+=0x1000; }
    f->regions[f->count++].address=address;return address;
}
static uint64_t klass(Fixture *f,const char *name) {
    uint64_t k=region(f,0);ptr(f,k+0x10,k+0x800);bytes(f,k+0x800,name,strlen(name)+1);return k;
}
static HCLuaValue value(uint32_t tag,uint64_t data) { return (HCLuaValue){data,tag,0}; }
static HCLuaValue string(Fixture *f,const char *text) {
    size_t n=strlen(text);assert(n<=40);uint64_t p=region(f,0);unsigned char type=4,len=(unsigned char)n;
    bytes(f,p+8,&type,1);bytes(f,p+11,&len,1);bytes(f,p+24,text,n+1);return value(68,p);
}
static uint64_t table(Fixture *f,uint32_t size) {
    uint64_t t=region(f,0),nodes=region(f,0);unsigned char type=5,log=4;
    bytes(f,t+8,&type,1);bytes(f,t+11,&log,1);bytes(f,t+12,&size,4);ptr(f,t+24,nodes);
    if(size) ptr(f,t+16,region(f,0));return t;
}
static uint64_t set(Fixture *f,uint64_t t,const char *key,HCLuaValue v) {
    uint64_t nodes=0;assert(readMemory(f,t+24,&nodes,8));int at=(int)(HCLuaHash(123,key)&15);
    HCLuaValue k;assert(readMemory(f,nodes+at*32+16,&k,16));
    if(k.tag) {
        int freeSlot=-1;
        for(int i=0;i<16;i++) { HCLuaValue empty;readMemory(f,nodes+i*32+16,&empty,16);if(!empty.tag) { freeSlot=i;break; } }
        assert(freeSlot>=0);
        int32_t next=0;
        while(readMemory(f,nodes+at*32+28,&next,4) && next) at+=next;
        next=freeSlot-at;bytes(f,nodes+at*32+28,&next,4);at=freeSlot;
    }
    k=string(f,key);bytes(f,nodes+at*32,&v,16);bytes(f,nodes+at*32+16,&k,16);
    return nodes+at*32;
}
static void init(Fixture *f) {
    f->next=0x10000;
    uint64_t roleSlot=region(f,0x10000000+HC_ROLE_SINGLETON_METHOD_RVA),method=region(f,0),single=klass(f,"Singleton`1"),fields=region(f,0),manager=region(f,0),roleClass=klass(f,"CRoleInfoManager");
    ptr(f,roleSlot,method);ptr(f,method+0x20,single);ptr(f,single+0xB8,fields);ptr(f,fields,manager);
    ptr(f,manager,roleClass);ptr(f,roleClass+0x58,single);f->account=manager+0x10;ptr(f,f->account,UINT64_C(9007199254740993));
    uint64_t luaSlot=region(f,0x10000000+HC_LUA_ROOT_TYPE_RVA),luaClass=klass(f,"LuaRoot"),luaFields=region(f,0),env=region(f,0),envClass=klass(f,"LuaEnv"),state=region(f,0),global=region(f,0);
    f->env=env;ptr(f,luaSlot,luaClass);ptr(f,luaClass+0xB8,luaFields);ptr(f,luaFields+0x18,env);ptr(f,env,envClass);ptr(f,env+8,state);ptr(f,state+0x18,global);
    uint32_t seed=123;bytes(f,global+0x50,&seed,4);
    uint64_t registry=table(f,2),globals=table(f,0),registryArray=0;HCLuaValue v=value(69,registry);bytes(f,global+0x40,&v,16);
    readMemory(f,registry+16,&registryArray,8);v=value(69,globals);bytes(f,registryArray+16,&v,16);
    uint64_t package=table(f,0),loaded=table(f,0),mail=table(f,0),mailbox=table(f,1),record=table(f,0),extra=table(f,0),data=table(f,0),receipt=table(f,0);
    set(f,globals,"package",value(69,package));set(f,package,"loaded",value(69,loaded));set(f,loaded,"AOV.Mail.MailSys",value(69,mail));
    uint64_t closure=region(f,0),upvalue=region(f,0),mailArray=0;unsigned char type=6,nup=1;
    bytes(f,closure+8,&type,1);bytes(f,closure+10,&nup,1);ptr(f,closure+32,upvalue);ptr(f,upvalue,upvalue+16);
    v=value(69,mailbox);bytes(f,upvalue+16,&v,16);set(f,mail,"GetMailList",value(70,closure));
    readMemory(f,mailbox+16,&mailArray,8);v=value(69,record);bytes(f,mailArray,&v,16);
    f->subtype=set(f,record,"subType",value(19,5));set(f,record,"mailIndex",value(19,42));set(f,record,"sendTime",value(19,1700000000));
    set(f,record,"subject",string(f,"Report received"));set(f,record,"userDataExtra",value(69,extra));set(f,extra,"UserData",value(69,data));
    set(f,extra,"UserDataType",value(19,1));
    set(f,data,"BeComplaintHistory",value(69,receipt));set(f,receipt,"ChgCreditType",value(19,7));set(f,receipt,"PassiveWarnCnt",value(19,2));set(f,receipt,"DeskID",value(19,99));
}
int main(void) {
    Fixture *f=calloc(1,sizeof(*f));assert(f);init(f);HCCameraMemory m={f,readMemory,NULL};HCReceiptScan scan;
    assert(HCReadReceiptCache(m,0x10000000,&scan));assert(scan.stage==9 && scan.complete && scan.count==1);
    assert(scan.account==UINT64_C(9007199254740993) && scan.records[0].mailIndex==42 && scan.records[0].sent==1700000000);
    assert(!strcmp(scan.records[0].subject,"Report received") && strstr(scan.records[0].reason,"ChgCreditType=7"));
    HCLuaValue wrong=value(19,4);bytes(f,f->subtype,&wrong,16);
    assert(HCReadReceiptCache(m,0x10000000,&scan) && scan.count==0);
    wrong=value(19,5);bytes(f,f->subtype,&wrong,16);f->accountReads=0;f->switchAccount=true;
    assert(!HCReadReceiptCache(m,0x10000000,&scan) && scan.count==0);
    f->switchAccount=false;unsigned char disposed=1;bytes(f,f->env+0x40,&disposed,1);
    assert(!HCReadReceiptCache(m,0x10000000,&scan) && scan.stage==2);
    HCLuaRead budget={.memory=m,.calls=6000};char out[64];
    assert(!HCLuaString(&budget,string(f,"test"),out,sizeof(out)) && budget.limited);
    uint64_t number=0;double fraction=1.5;uint64_t raw=0;memcpy(&raw,&fraction,8);
    assert(!HCLuaUInt(value(3,raw),&number));free(f);
    puts("Lua receipt fixture passed: native table hash/layout, closure upvalues, exact 64-bit account, own complaint-mail shape, subtype rejection, account-switch reset, disposed VM and bounded reads; no Lua execution/network.");
    return 0;
}
