#include "../BackendSDK/RemoteCString.h"
#include <assert.h>
#include <stdio.h>
typedef struct { unsigned char bytes[8192]; bool denySecond; int reads; } Fixture;
static bool readString(void *ctx,uint64_t address,void *out,size_t size) {
    Fixture *f=ctx;f->reads++;
    assert((address&4095)+size<=4096); // No read crosses an accessible-page boundary.
    if(address<0x10000 || address-0x10000+size>sizeof(f->bytes) || (f->denySecond && address>=0x11000)) return false;
    memcpy(out,f->bytes+(address-0x10000),size);return true;
}
int main(void) {
    Fixture f={0};char out[512];const char *path="/Game.app/Frameworks/UnityFramework.framework/UnityFramework";
    strcpy((char *)f.bytes+4090,path);
    assert(HCReadCString(&f,readString,0x10FFA,out,sizeof(out)) && !strcmp(out,path) && f.reads>=2);
    f.denySecond=true;
    assert(!HCReadCString(&f,readString,0x10FFA,out,sizeof(out)) && out[0]==0);
    f.denySecond=false;memset(f.bytes,'X',sizeof(f.bytes));
    assert(!HCReadCString(&f,readString,0x10FFA,out,sizeof(out)) && out[0]==0);
    assert(!HCReadCString(&f,readString,UINT64_MAX-2,out,sizeof(out)));
    puts("Remote string fixture passed: cross-page path, denied next page, bounded unterminated string, overflow.");
    return 0;
}
