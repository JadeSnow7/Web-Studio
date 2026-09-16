#include "../Web Studio/StudioPTY.h"
#include <assert.h>
#include <fcntl.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/select.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
int main(void) {
  char *argv[]={(char*)"/bin/zsh",(char*)"-df",NULL}; char *env[]={(char*)"TERM=xterm-256color",(char*)"PATH=/usr/bin:/bin",NULL};
  StudioPTYResult r=studio_pty_spawn_pixels("/bin/zsh",argv,env,NULL,97,31,873,558); assert(r.pid>0 && r.master_fd>=0);
  struct winsize actual = {0}; assert(ioctl(r.master_fd, TIOCGWINSZ, &actual) == 0);
  assert(actual.ws_col == 97 && actual.ws_row == 31 && actual.ws_xpixel == 873 && actual.ws_ypixel == 558);
  int flags=fcntl(r.master_fd,F_GETFL); assert(flags>=0 && fcntl(r.master_fd,F_SETFL,flags|O_NONBLOCK)==0);
  assert(studio_pty_resize_pixels(r.master_fd,100,30,800,480)==0);
  const char *cmd="printf 'READY_%s\\n' MARKER; exit 7\n"; assert(write(r.master_fd,cmd,strlen(cmd))==(ssize_t)strlen(cmd));
  char b[4096]={0}; size_t used=0; int found=0;
  for(int i=0;i<100 && !found;i++){ ssize_t n=read(r.master_fd,b+used,sizeof(b)-1-used); if(n>0){used+=(size_t)n;b[used]=0;found=strstr(b,"READY_MARKER")!=NULL;} usleep(10000); }
  assert(found); int status=0; pid_t waited=0; for(int i=0;i<100 && waited==0;i++){ waited=waitpid(r.pid,&status,WNOHANG); assert(waited>=0); if(waited==0) usleep(10000); } assert(waited==r.pid && WIFEXITED(status) && WEXITSTATUS(status)==7); close(r.master_fd);
  assert(studio_pty_spawn_pixels("/bin/sh",argv,env,NULL,97,31,UINT16_MAX+1u,18).pid < 0);
  sigset_t blocked, old; sigemptyset(&blocked); sigaddset(&blocked, SIGINT); assert(sigprocmask(SIG_BLOCK, &blocked, &old) == 0);
  char *signal_argv[]={(char*)"/bin/sh",(char*)"-c",(char*)"kill -INT $$",NULL};
  StudioPTYResult s=studio_pty_spawn("/bin/sh",signal_argv,env,NULL,80,24); assert(s.pid>0 && s.master_fd>=0);
  int signal_status=0; pid_t signal_waited=0; for(int i=0;i<100 && signal_waited==0;i++){ signal_waited=waitpid(s.pid,&signal_status,WNOHANG); assert(signal_waited>=0); if(signal_waited==0) usleep(10000); } assert(signal_waited==s.pid && WIFSIGNALED(signal_status) && WTERMSIG(signal_status)==SIGINT); close(s.master_fd); assert(sigprocmask(SIG_SETMASK, &old, NULL) == 0);
  puts("PTY transport smoke passed");
}
