#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
    int ack[2];
    if (pipe(ack) != 0) return 2;
    signal(SIGHUP, SIG_IGN);
    signal(SIGTERM, SIG_IGN);
    int natural = argc > 1 && strcmp(argv[1], "--natural") == 0;
    pid_t background = fork();
    if (background < 0) return 2;
    if (background == 0) {
        setpgid(0, 0);
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
        for (;;) pause();
    }
    setpgid(background, background);
    pid_t child = fork();
    if (child < 0) return 2;
    if (child == 0) {
        close(ack[0]);
        setpgid(0, 0);
        signal(SIGHUP, SIG_IGN);
        signal(SIGTERM, SIG_IGN);
        close(STDIN_FILENO); close(STDOUT_FILENO); close(STDERR_FILENO);
        (void)write(ack[1], "A", 1); close(ack[1]);
        for (;;) pause();
    }
    close(ack[1]);
    setpgid(child, child);
    for (int attempt = 0; attempt != 50 && tcsetpgrp(STDIN_FILENO, child) != 0; ++attempt) usleep(10000);
    if (tcgetpgrp(STDIN_FILENO) != child) return 3;
    char acknowledged;
    if (read(ack[0], &acknowledged, 1) != 1) return 4;
    close(ack[0]);
    dprintf(STDOUT_FILENO, "CHILD_PID=%ld\nBACKGROUND_PID=%ld\n%s\n", (long)child, (long)background, natural ? "NATURAL_READY" : "READY");
    fsync(STDOUT_FILENO);
    if (natural) return 7;
    // Neither leader nor foreground child cooperates with close. The
    // transport must SIGKILL the owned groups and wait for live members to
    // disappear; the child may briefly be an orphaned zombie afterward.
    for (;;) pause();
}
