// Regression for the production lock implementation: real spawn/dup2/exec,
// exclusive ownership, release on exit, and rejection of a symlink lock path.
#include "../Overlay/OverlayLock.h"
#include <spawn.h>
#include <sys/wait.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <limits.h>

extern char **environ;

int main(int argc, char **argv) {
    if (argc == 3 && !strcmp(argv[1], "--child")) {
        if (HCOverlayValidateLockFD(HC_OVERLAY_LOCK_FD, argv[2], geteuid())) return 10;
        int failure = 0;
        int duplicate = HCOverlayAcquireLock(argv[2], &failure);
        if (duplicate >= 0) { close(duplicate); return 11; }
        return failure == EWOULDBLOCK || failure == EAGAIN ? 0 : 12;
    }
    char folder[] = "/tmp/hc-overlay-lock.XXXXXX";
    if (!mkdtemp(folder)) return 20;
    char path[PATH_MAX], linkPath[PATH_MAX];
    snprintf(path, sizeof(path), "%s/lock", folder);
    snprintf(linkPath, sizeof(linkPath), "%s/link", folder);
    int failure = 0, status = 0, result = 0;
    int fd = HCOverlayAcquireLock(path, &failure);
    if (fd < 4) return 21;
    posix_spawn_file_actions_t actions;
    if (posix_spawn_file_actions_init(&actions)) return 22;
    result = posix_spawn_file_actions_adddup2(&actions, fd, HC_OVERLAY_LOCK_FD);
    if (!result) result = posix_spawn_file_actions_addclose(&actions, fd);
    pid_t child = -1;
    char *args[] = {argv[0], "--child", path, NULL};
    if (!result) result = posix_spawn(&child, argv[0], &actions, NULL, args, environ);
    posix_spawn_file_actions_destroy(&actions);
    close(fd); // NEVER unlock the shared description before the child exits.
    if (result) return 23;
    pid_t waited;
    do { waited = waitpid(child, &status, 0); } while (waited < 0 && errno == EINTR);
    if (waited != child || !WIFEXITED(status) || WEXITSTATUS(status) != 0) return 24;
    fd = HCOverlayAcquireLock(path, &failure);
    if (fd < 0) return 25; // The child's final reference must have released it.
    close(fd);
    if (symlink(path, linkPath)) return 26;
    fd = HCOverlayAcquireLock(linkPath, &failure);
    if (fd >= 0) { close(fd); return 27; }
    if (failure != ELOOP) return 28;
    unlink(linkPath); unlink(path); rmdir(folder);
    return 0;
}
