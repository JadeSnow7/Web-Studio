#ifndef STUDIO_PTY_H
#define STUDIO_PTY_H
#import <stdint.h>
#include <sys/types.h>
#include <stddef.h>

typedef struct {
    pid_t pid;
    int master_fd;
    int error_stage;
    int error_number;
} StudioPTYResult;

StudioPTYResult studio_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows);
StudioPTYResult studio_pty_spawn_pixels(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows, uint32_t width_px, uint32_t height_px);
int studio_pty_resize(int master_fd, uint16_t cols, uint16_t rows);
int studio_pty_resize_pixels(int master_fd, uint16_t cols, uint16_t rows, uint32_t width_px, uint32_t height_px);
int studio_pty_close(int master_fd);
int studio_pty_exit_code(int status, int *exited);
int studio_pty_signal_code(int status);
int studio_pty_peek_exit(pid_t pid, int *status);
int studio_pty_tty_session_matches(int master_fd, pid_t session_id);
int studio_pty_signal_group(pid_t group_id, pid_t session_id, int signal_number);
int studio_pty_group_has_session_members(pid_t group_id, pid_t session_id);
int studio_pty_group_has_session_members_except(pid_t group_id, pid_t session_id, pid_t excluded_pid);
int studio_pty_session_groups(pid_t session_id, pid_t *groups, size_t capacity);
#endif
