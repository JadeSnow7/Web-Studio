#include <poll.h>
#include <stdio.h>
#include <string.h>
#include <sys/ioctl.h>
#include <termios.h>
#include <unistd.h>

int main(void) {
  struct termios saved, raw;
  if (tcgetattr(STDIN_FILENO, &saved) != 0) return 4;
  raw = saved; cfmakeraw(&raw); if (tcsetattr(STDIN_FILENO, TCSANOW, &raw) != 0) return 5;
  write(STDOUT_FILENO, "\033[6n", 4);
  char b[256]; size_t used = 0; int size_sent = 0;
  for (;;) {
    struct pollfd p = { .fd = STDIN_FILENO, .events = POLLIN };
    if (poll(&p, 1, 3000) <= 0) return 2;
    ssize_t n = read(STDIN_FILENO, b + used, sizeof(b) - used - 1);
    if (n <= 0) return 3; used += (size_t)n; b[used] = 0;
    if (strstr(b, "EXIT7")) { write(STDOUT_FILENO, "EXIT_FINAL", 10); tcsetattr(STDIN_FILENO, TCSANOW, &saved); return 7; }
    char *query = strstr(b, "\033[1;1R");
    if (query) { size_t off = (size_t)(query - b); write(STDOUT_FILENO, "QUERY_OK", 8); memmove(b + off, b + off + 6, used - off - 6); used -= 6; b[used] = 0; }
    if (!size_sent && strstr(b, "SIZE?\n")) {
      struct winsize w = {0}; ioctl(STDIN_FILENO, TIOCGWINSZ, &w);
      dprintf(STDOUT_FILENO, "SIZE=%u,%u,%u,%u", w.ws_row, w.ws_col, w.ws_xpixel, w.ws_ypixel); size_sent = 1;
    }
    char *hidden = strstr(b, "HIDDEN\n");
    if (hidden) { size_t off = (size_t)(hidden - b); write(STDOUT_FILENO, "HIDDEN_MARK", 11); memmove(b + off, b + off + 7, used - off - 7); used -= 7; b[used] = 0; }
    char *final = strstr(b, "FINAL\n");
    if (final) { size_t off = (size_t)(final - b); write(STDOUT_FILENO, "FINAL_MARK", 10); memmove(b + off, b + off + 6, used - off - 6); used -= 6; b[used] = 0; }
  }
}
