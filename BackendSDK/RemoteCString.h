#ifndef HC_REMOTE_CSTRING_H
#define HC_REMOTE_CSTRING_H
#include <stdbool.h>
#include <stdint.h>
#include <stddef.h>
#include <string.h>
typedef bool (*HCCStringRead)(void *,uint64_t,void *,size_t);
// A string may cross a page boundary. Bound each read to a 4 KiB subpage
// (also safe within iOS 16 KiB pages), then continue until NUL or the limit.
static inline bool HCReadCString(void *ctx,HCCStringRead read,uint64_t address,char *out,size_t capacity) {
    if (!read || !out || capacity<2 || capacity>4096 || !address || address>UINT64_MAX-capacity) return false;
    out[0]=0;
    for(size_t offset=0;offset<capacity;) {
        size_t chunk=4096-((address+offset)&4095);
        if(chunk>128) chunk=128;
        if(chunk>capacity-offset) chunk=capacity-offset;
        if(!read(ctx,address+offset,out+offset,chunk)) { out[0]=0;return false; }
        if(memchr(out+offset,0,chunk)) return true;
        offset+=chunk;
    }
    out[0]=0;return false;
}
#endif
