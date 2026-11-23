#ifndef HC_OVERLAY_LOCK_H
#define HC_OVERLAY_LOCK_H
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

#define HC_OVERLAY_LOCK_FD 3
#define HC_OVERLAY_LOCK_NAME "overlay-mobile.lock"

// Called by the mobile app, never the root HUD. Lock ownership is attached to
// the open file description and survives dup2/exec in posix_spawn. The parent
// closes its reference without LOCK_UN, leaving the HUD's reference locked.
static inline int HCOverlayAcquireLock(const char *path, int *failure) {
    int fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
    if (fd < 0) { *failure = errno; return -1; }
    if (fd <= HC_OVERLAY_LOCK_FD) {
        int promoted = fcntl(fd, F_DUPFD_CLOEXEC, HC_OVERLAY_LOCK_FD + 1);
        int saved = errno;
        close(fd); fd = promoted;
        if (fd < 0) { *failure = saved; return -1; }
    }
    struct stat info = {0};
    if (fstat(fd, &info)) { *failure = errno; close(fd); return -1; }
    if (!S_ISREG(info.st_mode) || info.st_uid != geteuid()) {
        *failure = EPERM; close(fd); return -1;
    }
    if (flock(fd, LOCK_EX | LOCK_NB)) { *failure = errno; close(fd); return -1; }
    *failure = 0;
    return fd;
}

static inline int HCOverlayValidateLockFD(int fd, const char *path, uid_t owner) {
    struct stat descriptor = {0}, named = {0};
    if (fstat(fd, &descriptor) || lstat(path, &named)) return errno;
    if (!S_ISREG(descriptor.st_mode) || !S_ISREG(named.st_mode) ||
        descriptor.st_uid != owner || descriptor.st_dev != named.st_dev || descriptor.st_ino != named.st_ino) return EINVAL;
    return 0;
}
#endif
