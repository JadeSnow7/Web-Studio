#include "StudioPTY.h"
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <libproc.h>
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

StudioPTYResult studio_pty_spawn_pixels(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows, uint32_t width_px, uint32_t height_px) {
    StudioPTYResult result = { .pid = -1, .master_fd = -1, .error_stage = 0, .error_number = 0 };
    if (!executable || cols == 0 || rows == 0 || width_px > UINT16_MAX || height_px > UINT16_MAX) {
        result.error_stage = 0; result.error_number = EINVAL; errno = EINVAL; return result;
    }
    int error_pipe[2];
    if (pipe(error_pipe) != 0) { result.error_stage = 1; result.error_number = errno; return result; }
    if (fcntl(error_pipe[0], F_SETFD, FD_CLOEXEC) < 0 || fcntl(error_pipe[1], F_SETFD, FD_CLOEXEC) < 0) { result.error_stage = 1; result.error_number = errno; close(error_pipe[0]); close(error_pipe[1]); return result; }
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = (unsigned short)width_px, .ws_ypixel = (unsigned short)height_px };
    int master = -1;
    pid_t pid = forkpty(&master, NULL, NULL, &size);
    if (pid < 0) { result.error_stage = 2; result.error_number = errno; close(error_pipe[0]); close(error_pipe[1]); return result; }
    if (pid == 0) {
        close(error_pipe[0]);
        sigset_t empty;
        sigemptyset(&empty);
        if (sigprocmask(SIG_SETMASK, &empty, NULL) != 0) { ChildError e = { 8, errno }; report_child_error(error_pipe[1], e); _exit(124); }
        struct sigaction default_action;
        memset(&default_action, 0, sizeof(default_action));
        default_action.sa_handler = SIG_DFL;
        sigemptyset(&default_action.sa_mask);
        int signal_error = 0;
        int signals[] = { SIGINT, SIGQUIT, SIGTERM, SIGHUP, SIGCHLD, SIGPIPE, SIGTSTP, SIGTTIN, SIGTTOU };
        for (size_t i = 0; i < sizeof(signals) / sizeof(signals[0]); ++i) {
            if (sigaction(signals[i], &default_action, NULL) != 0 && signal_error == 0) signal_error = errno;
        }
        if (signal_error != 0) { ChildError e = { 8, signal_error }; report_child_error(error_pipe[1], e); _exit(124); }
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

StudioPTYResult studio_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows) {
    return studio_pty_spawn_pixels(executable, argv, envp, directory, cols, rows, 0, 0);
}

int studio_pty_resize_pixels(int master_fd, uint16_t cols, uint16_t rows, uint32_t width_px, uint32_t height_px) {
    if (master_fd < 0 || cols == 0 || rows == 0 || width_px > UINT16_MAX || height_px > UINT16_MAX) {
        errno = EINVAL;
        return -1;
    }
    struct winsize size = { .ws_row = rows, .ws_col = cols, .ws_xpixel = (unsigned short)width_px, .ws_ypixel = (unsigned short)height_px };
    return ioctl(master_fd, TIOCSWINSZ, &size);
}
int studio_pty_resize(int master_fd, uint16_t cols, uint16_t rows) { return studio_pty_resize_pixels(master_fd, cols, rows, 0, 0); }

int studio_pty_close(int master_fd) { return master_fd >= 0 ? close(master_fd) : 0; }
int studio_pty_exit_code(int status, int *exited) { if (WIFEXITED(status)) { *exited = 1; return WEXITSTATUS(status); } *exited = 0; return 0; }
int studio_pty_signal_code(int status) { return WIFSIGNALED(status) ? WTERMSIG(status) : 0; }
int studio_pty_peek_exit(pid_t pid, int *status) {
    if (pid <= 0 || status == NULL) { errno = EINVAL; return -1; }
    siginfo_t info;
    memset(&info, 0, sizeof(info));
    if (waitid(P_PID, (id_t)pid, &info, WEXITED | WNOHANG | WNOWAIT) != 0) return -1;
    if (info.si_pid == 0) return 0;
    if (info.si_code == CLD_EXITED) *status = (info.si_status & 0xff) << 8;
    else if (info.si_code == CLD_KILLED || info.si_code == CLD_DUMPED) *status = info.si_status & 0x7f;
    else return 0;
    return 1;
}
int studio_pty_tty_session_matches(int master_fd, pid_t session_id) {
    if (master_fd < 0 || session_id <= 0) { errno = EINVAL; return 0; }
    pid_t tty_session = tcgetsid(master_fd);
    return tty_session == session_id;
}
int studio_pty_signal_group(pid_t group_id, pid_t session_id, int signal_number) {
    if (group_id <= 0 || session_id <= 0 || signal_number <= 0) { errno = EINVAL; return -1; }
    int capacity = 16;
    pid_t *members = NULL;
    int count = 0;
    for (;;) {
        pid_t *resized = realloc(members, (size_t)capacity * sizeof(*members));
        if (resized == NULL) { free(members); errno = ENOMEM; return -1; }
        members = resized;
        count = proc_listpgrppids(group_id, members, capacity * (int)sizeof(*members));
        if (count < 0) { free(members); return -1; }
        if (count < capacity) break;
        capacity *= 2;
    }
    if (count == 0) { free(members); errno = ESRCH; return -1; }
    int matched = 0;
    for (int i = 0; i < count; ++i) {
        pid_t member_session = getsid(members[i]);
        if (member_session < 0 && errno == ESRCH) continue;
        if (member_session != session_id) { free(members); errno = EPERM; return -1; }
        matched += 1;
    }
    free(members);
    if (matched == 0) { errno = ESRCH; return -1; }
    return kill(-group_id, signal_number);
}

int studio_pty_group_has_session_members_except(pid_t group_id, pid_t session_id, pid_t excluded_pid);

int studio_pty_session_groups(pid_t session_id, pid_t *groups, size_t capacity) {
    if (session_id <= 0 || (capacity > 0 && groups == NULL)) { errno = EINVAL; return -1; }
    int process_capacity = 256;
    pid_t *processes = NULL;
    int process_count = 0;
    for (;;) {
        pid_t *resized = realloc(processes, (size_t)process_capacity * sizeof(*processes));
        if (resized == NULL) { free(processes); errno = ENOMEM; return -1; }
        processes = resized;
        process_count = proc_listallpids(processes, process_capacity * (int)sizeof(*processes));
        if (process_count < 0) { free(processes); return -1; }
        if (process_count < process_capacity) break;
        process_capacity *= 2;
    }
    size_t found = 0;
    for (int i = 0; i < process_count; ++i) {
        pid_t pid = processes[i];
        if (pid <= 0) continue;
        errno = 0;
        pid_t member_session = getsid(pid);
        if (member_session < 0) {
            // System processes may be hidden from this process.  They cannot
            // belong to the PTY session unless this is the session leader.
            if (pid == session_id && errno != ESRCH) { free(processes); return -1; }
            continue;
        }
        if (member_session != session_id) continue;
        pid_t group = getpgid(pid);
        if (group <= 0) {
            if (pid == session_id && errno != ESRCH) { free(processes); return -1; }
            continue;
        }
        int duplicate = 0;
        for (size_t j = 0; j < found && j < capacity; ++j) {
            if (groups[j] == group) { duplicate = 1; break; }
        }
        if (duplicate) continue;
        if (found >= capacity) { found += 1; continue; }
        groups[found] = group;
        found += 1;
    }
    free(processes);
    if (found > capacity) { errno = EOVERFLOW; return -(int)found; }
    return (int)found;
}

int studio_pty_group_has_session_members(pid_t group_id, pid_t session_id) {
    return studio_pty_group_has_session_members_except(group_id, session_id, -1);
}

int studio_pty_group_has_session_members_except(pid_t group_id, pid_t session_id, pid_t excluded_pid) {
    if (group_id <= 0 || session_id <= 0) { errno = EINVAL; return -1; }
    int capacity = 16;
    pid_t *members = NULL;
    for (;;) {
        pid_t *resized = realloc(members, (size_t)capacity * sizeof(*members));
        if (resized == NULL) { free(members); errno = ENOMEM; return -1; }
        members = resized;
        int count = proc_listpgrppids(group_id, members, capacity * (int)sizeof(*members));
        if (count < 0) { free(members); return -1; }
        if (count == 0) { free(members); errno = ESRCH; return 0; }
        int matched = 0;
        for (int i = 0; i < count; ++i) {
            if (members[i] == excluded_pid) continue;
            pid_t member_session = getsid(members[i]);
            if (member_session < 0 && errno == ESRCH) continue;
            if (member_session != session_id) { free(members); errno = EPERM; return -1; }
            matched += 1;
        }
        if (count < capacity) {
            free(members);
            if (matched == 0) { errno = ESRCH; return 0; }
            return matched;
        }
        capacity *= 2;
    }
}
