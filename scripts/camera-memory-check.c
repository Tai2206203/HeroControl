#include "../BackendSDK/CameraMemory.h"
#include <assert.h>
#include <stdio.h>

typedef struct { uint64_t address; unsigned char bytes[512]; } Region;
typedef struct { Region regions[9]; int writes; bool failDirty; } Fixture;
static bool readMemory(void *ctx, uint64_t address, void *buffer, size_t size) {
    Fixture *fixture = ctx;
    for (int i = 0; i < 9; i++) {
        Region *r = &fixture->regions[i];
        if (address >= r->address && address - r->address <= sizeof(r->bytes) && size <= sizeof(r->bytes) - (address - r->address)) {
            memcpy(buffer, r->bytes + (address - r->address), size); return true;
        }
    }
    return false;
}
static bool writeMemory(void *ctx, uint64_t address, const void *buffer, size_t size) {
    Fixture *f = ctx;
    assert((address == 0x25098 && size == 4) || (address == 0x250DC && size == 1));
    f->writes++;
    if (f->failDirty && address == 0x250DC) return false;
    memcpy(f->regions[6].bytes + (address - 0x25000), buffer, size);
    return true;
}
static void pointer(Region *r, size_t offset, uint64_t address) { memcpy(r->bytes + offset, &address, 8); }
static void scalar(Region *r, size_t offset, float value) { memcpy(r->bytes + offset, &value, 4); }
static Fixture createFixture(void) {
    Fixture f = {0};
    uint64_t addresses[] = {0x10000000 + HC_CAMERA_TYPE_RVA, 0x20000, 0x21000, 0x22000, 0x23000, 0x24000, 0x25000, 0x30000, 0x31000};
    for (int i = 0; i < 9; i++) f.regions[i].address = addresses[i];
    pointer(&f.regions[0], 0, 0x20000);
    pointer(&f.regions[1], 0x10, 0x30000); strcpy((char *)f.regions[7].bytes, "CameraSystem");
    pointer(&f.regions[1], 0x58, 0x21000);
    pointer(&f.regions[2], 0x10, 0x30040); strcpy((char *)f.regions[7].bytes + 0x40, "MonoSingleton`1");
    pointer(&f.regions[2], 0xB8, 0x22000);
    pointer(&f.regions[3], 0, 0x23000);
    pointer(&f.regions[4], 0, 0x20000); pointer(&f.regions[4], 0x10, 0x40000);
    pointer(&f.regions[4], 0x18, 0x25000); scalar(&f.regions[4], 0x8C, 1.5f);
    pointer(&f.regions[5], 0x10, 0x30080); strcpy((char *)f.regions[7].bytes + 0x80, "Moba_Camera");
    pointer(&f.regions[6], 0, 0x24000); pointer(&f.regions[6], 0x10, 0x50000); scalar(&f.regions[6], 0x98, 1.5f);
    return f;
}
int main(void) {
    Fixture f = createFixture(); HCCameraMemory memory = {&f, readMemory, writeMemory};
    HCCameraSnapshot object; float written = 0, actual = 0;
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_OK);
    assert(fabsf(written - 2.4f) < 0.0001f);
    assert(f.regions[6].bytes[0xDC] == 1);
    // Repeated ticks must derive the multiplier from the unchanged game value.
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_OK);
    assert(fabsf(written - 2.4f) < 0.0001f);
    assert(HCCameraRestore(memory, 0x10000000, object, written) == HC_CAMERA_OK);
    readMemory(&f, 0x25098, &actual, 4); assert(actual == 1.5f);
    int writes = f.writes;
    assert(HCCameraApply(memory, 0x10000000, NAN, &object, &written) == HC_CAMERA_BAD_SCALE);
    assert(HCCameraApply(memory, 0x10000000, 2.4f, &object, &written) == HC_CAMERA_BAD_SCALE);
    assert(f.writes == writes);
    f.failDirty = true;
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_WRITE_FAILED);
    readMemory(&f, 0x25098, &actual, 4); assert(actual == 1.5f); // Rollback when the dirty write fails.
    f.failDirty = false;
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_OK);
    scalar(&f.regions[6], 0x98, 1.7f); // The game has changed the field itself.
    writes = f.writes;
    assert(HCCameraRestore(memory, 0x10000000, object, written) == HC_CAMERA_CHANGED);
    assert(f.writes == writes);
    f.regions[3].bytes[8] = 1; // Destroyed singleton.
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_NOT_READY);
    assert(f.writes == writes);
    f.regions[3].bytes[8] = 0; f.regions[7].bytes[0] = 'X'; // Wrong class identity.
    assert(HCCameraApply(memory, 0x10000000, 1.6f, &object, &written) == HC_CAMERA_BAD_LAYOUT);
    assert(f.writes == writes);
    puts("Camera memory core passed: identity, scale, dirty flag, non-compounding, rollback, cautious restore; fixture memory only.");
    return 0;
}
