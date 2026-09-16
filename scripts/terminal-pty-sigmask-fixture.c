#include <signal.h>
#include <stdio.h>
#include <termios.h>
#include <unistd.h>

int main(int argc, char **argv) {
    (void)argc; (void)argv;
    sigset_t current;
    struct sigaction action;
    if (sigprocmask(SIG_SETMASK, NULL, &current) != 0 || sigismember(&current, SIGINT) != 0) return 2;
    if (sigaction(SIGINT, NULL, &action) != 0 || action.sa_handler != SIG_DFL) return 3;
    struct termios raw;
    if (tcgetattr(STDIN_FILENO, &raw) == 0) {
        cfmakeraw(&raw);
        (void)tcsetattr(STDIN_FILENO, TCSANOW, &raw);
    }
    dprintf(STDOUT_FILENO, "SIGMASK_READY\n");
    for (;;) {
        unsigned char byte;
        if (read(STDIN_FILENO, &byte, 1) == 1 && byte == 0x03) raise(SIGINT);
    }
}
