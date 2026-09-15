#include "StudioPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>
#include <util.h>

typedef struct { int stage; int number; } ChildError;

static void report_child_error(int fd, ChildError error) {
    const char *bytes = (const char *)&error;
    size_t left = sizeof(error);
    while (left > 0) {
        ssize_t written = write(fd, bytes, left);
        if (written > 0) { bytes += written; left -= (size_t)written; }
        else if (written < 0 && errno == EINTR) continue;
        else break;
    }
}

StudioPTYResult studio_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows) {
    StudioPTYResult result = { .pid = -1, .master_fd = -1, .error_stage = 0, .error_number = 0 };
    int error_pipe[2];
    if (pipe(error_pipe) != 0) { result.error_stage = 1; result.error_number = errno; return result; }
    if (fcntl(error_pipe[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) < 0) { result.error_stage = 1; result.error_number = errno; close(error_pipe[0]); close(error_pipe[1]); return result; }
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) { result.error_stage = 2; result.error_number = errno; close(error_pipe[0]); close(error_pipe[1]); return result; }
    if (pid == 0) {
        close(error_pipe[0]);
        // forkpty may be unable to establish the controlling terminal inside
        // an App Sandbox. Fail explicitly before chdir/exec rather than
        // presenting a shell whose line discipline and signals cannot work.
        if (tcgetpgrp(STDIN_FILENO) < 0) { ChildError e = { 7, errno }; report_child_error(error_pipe[1], e); _exit(125); }
        if (directory && chdir(directory) != 0) { ChildError e = { 3, errno }; report_child_error(error_pipe[1], e); _exit(126); }
        execve(executable, argv, envp);
        ChildError e = { 4, errno }; report_child_error(error_pipe[1], e); _exit(127);
    }
    if (close(error_pipe[1]) < 0) { result.error_stage = 5; result.error_number = errno; }
    if (fcntl(master, F_SETFD, FD_CLOEXEC) < 0) { result.error_stage = 5; result.error_number = errno; close(master); kill(pid, SIGHUP); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} close(error_pipe[0]); return result; }
    ChildError child_error; ssize_t count; do { count = read(error_pipe[0], &child_error, sizeof(child_error)); } while (count < 0 && errno == EINTR);
    int read_errno = errno; (void)close(error_pipe[0]);
    if (count == (ssize_t)sizeof(child_error)) {
        result.error_stage = child_error.stage; result.error_number = child_error.number;
        close(master); kill(pid, SIGHUP); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} return result;
    }
    if (count < 0) { result.error_stage = 6; result.error_number = read_errno; close(master); kill(pid, SIGHUP); while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {} return result; }
    result.pid = pid; result.master_fd = master; return result;
}

int studio_pty_resize(int master_fd, uint16_t cols, uint16_t rows) {
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = 0, .ws_ypixel = 0 };
    return ioctl(master_fd, TIOCSWINSZ, &size);
}

int studio_pty_close(int master_fd) { return master_fd >= 0 ? close(master_fd) : 0; }
int studio_pty_exit_code(int status, int *exited) { if (WIFEXITED(status)) { *exited = 1; return WEXITSTATUS(status); } *exited = 0; return 0; }
