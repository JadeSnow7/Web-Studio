#ifndef STUDIO_PTY_H
#define STUDIO_PTY_H
#import <stdint.h>
#include <sys/types.h>

typedef struct {
    pid_t pid;
    int master_fd;
    int error_stage;
    int error_number;
} StudioPTYResult;

StudioPTYResult studio_pty_spawn(const char *executable, char *const argv[], char *const envp[], const char *directory, uint16_t cols, uint16_t rows);
int studio_pty_resize(int master_fd, uint16_t cols, uint16_t rows);
int studio_pty_close(int master_fd);
int studio_pty_exit_code(int status, int *exited);
#endif
