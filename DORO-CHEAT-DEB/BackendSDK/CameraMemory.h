#ifndef HC_CAMERA_MEMORY_H
#define HC_CAMERA_MEMORY_H
#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include <string.h>
#include <math.h>

// Verified in the supplied UnityFramework / il2cpp.h. The caller must verify
// the module UUID before using this interface. No executable pages are changed.
#define HC_CAMERA_TYPE_RVA UINT64_C(0xD0B9AD8)
typedef bool (*HCCameraRead)(void *, uint64_t, void *, size_t);
typedef bool (*HCCameraWrite)(void *, uint64_t, const void *, size_t);
typedef struct { void *context; HCCameraRead read; HCCameraWrite write; } HCCameraMemory;
typedef struct {
    uint64_t cameraClass, camera, moba;
    float sourceZoom, actualZoom;
} HCCameraSnapshot;
enum { HC_CAMERA_OK, HC_CAMERA_NOT_READY, HC_CAMERA_BAD_LAYOUT, HC_CAMERA_READ_FAILED,
       HC_CAMERA_WRITE_FAILED, HC_CAMERA_READBACK_FAILED, HC_CAMERA_CHANGED, HC_CAMERA_BAD_SCALE };

static inline bool HCCameraPointer(uint64_t value) { return value >= 0x10000 && value < UINT64_C(0x800000000000) && !(value & 7); }
static inline bool HCCameraName(HCCameraMemory m, uint64_t klass, const char *expected) {
    uint64_t address = 0;
    char name[32] = {0};
    size_t size = strlen(expected) + 1;
    return HCCameraPointer(klass) && m.read(m.context, klass + 0x10, &address, 8) &&
        address && size <= sizeof(name) && m.read(m.context, address, name, size) && !memcmp(name, expected, size);
}
static inline int HCCameraLocate(HCCameraMemory m, uint64_t base, HCCameraSnapshot *out) {
    *out = (HCCameraSnapshot){0};
    uint64_t klass = 0, parent = 0, fields = 0, camera = 0, objectClass = 0, native = 0, moba = 0;
    uint8_t destroyed = 0, dirty = 0;
    if (!m.read || !base || base > UINT64_MAX - HC_CAMERA_TYPE_RVA) return HC_CAMERA_BAD_LAYOUT;
    if (!m.read(m.context, base + HC_CAMERA_TYPE_RVA, &klass, 8)) return HC_CAMERA_READ_FAILED;
    out->cameraClass = klass;
    if (!HCCameraPointer(klass)) return HC_CAMERA_NOT_READY;
    if (!HCCameraName(m, klass, "CameraSystem")) return HC_CAMERA_BAD_LAYOUT;
    if (!m.read(m.context, klass + 0x58, &parent, 8) || !HCCameraName(m, parent, "MonoSingleton`1") ||
        !m.read(m.context, parent + 0xB8, &fields, 8) || !HCCameraPointer(fields)) return HC_CAMERA_BAD_LAYOUT;
    if (!m.read(m.context, fields, &camera, 8) || !m.read(m.context, fields + 8, &destroyed, 1)) return HC_CAMERA_READ_FAILED;
    out->camera = camera;
    if (!HCCameraPointer(camera) || destroyed) return HC_CAMERA_NOT_READY;
    if (!m.read(m.context, camera, &objectClass, 8) || objectClass != klass ||
        !m.read(m.context, camera + 0x08, &native, 8) || !native ||
        !m.read(m.context, camera + 0x18, &moba, 8) || !HCCameraPointer(moba)) return HC_CAMERA_NOT_READY;
    out->moba = moba;
    if (!m.read(m.context, moba, &objectClass, 8) || !HCCameraName(m, objectClass, "Moba_Camera") ||
        !m.read(m.context, moba + 0x08, &native, 8) || !native) return HC_CAMERA_BAD_LAYOUT;
    float source = 0, actual = 0;
    if (!m.read(m.context, camera + 0x8C, &source, 4) || !m.read(m.context, moba + 0x98, &actual, 4) ||
        !m.read(m.context, moba + 0xDC, &dirty, 1)) return HC_CAMERA_READ_FAILED;
    if (!isfinite(source) || !isfinite(actual) || source <= 0 || source > 8 || actual <= 0 || actual > 20 || dirty > 1)
        return HC_CAMERA_NOT_READY;
    *out = (HCCameraSnapshot){klass, camera, moba, source, actual};
    return HC_CAMERA_OK;
}

// Mirrors the native Moba_Camera.set_currentZoomRate data path:
// str s8,[x19,#0x98]; mov w8,#1; strb w8,[x19,#0xDC].
// CameraSystem.m_curZoom remains unchanged, preventing compound multiplication.
static inline int HCCameraSet(HCCameraMemory m, uint64_t base, HCCameraSnapshot expected, float value) {
    HCCameraSnapshot now;
    int result = HCCameraLocate(m, base, &now);
    if (result) return result;
    if (now.camera != expected.camera || now.moba != expected.moba || now.cameraClass != expected.cameraClass) return HC_CAMERA_CHANGED;
    if (!m.write || !isfinite(value) || value <= 0 || value > 20) return HC_CAMERA_BAD_SCALE;
    if (!m.write(m.context, now.moba + 0x98, &value, 4)) return HC_CAMERA_WRITE_FAILED;
    uint8_t dirty = 1;
    if (!m.write(m.context, now.moba + 0xDC, &dirty, 1)) {
        m.write(m.context, now.moba + 0x98, &now.actualZoom, 4);
        return HC_CAMERA_WRITE_FAILED;
    }
    float readback = 0;
    if (!m.read(m.context, now.moba + 0x98, &readback, 4) || memcmp(&readback, &value, 4)) return HC_CAMERA_READBACK_FAILED;
    return HC_CAMERA_OK;
}

static inline int HCCameraApply(HCCameraMemory m, uint64_t base, float scale, HCCameraSnapshot *out, float *written) {
    if (!isfinite(scale) || scale < 1 || scale > 2.3f) return HC_CAMERA_BAD_SCALE;
    int result = HCCameraLocate(m, base, out);
    if (result) return result;
    float target = out->sourceZoom * scale;
    *written = target;
    result = HCCameraSet(m, base, *out, target);
    return result;
}

static inline int HCCameraRestore(HCCameraMemory m, uint64_t base, HCCameraSnapshot previous, float lastWritten) {
    HCCameraSnapshot now;
    int result = HCCameraLocate(m, base, &now);
    if (result) return result;
    if (now.camera != previous.camera || now.moba != previous.moba || now.cameraClass != previous.cameraClass ||
        memcmp(&now.actualZoom, &lastWritten, 4)) return HC_CAMERA_CHANGED;
    return HCCameraSet(m, base, now, now.sourceZoom);
}
#endif
