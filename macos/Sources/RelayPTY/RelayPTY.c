#include "RelayPTY.h"
#include <util.h>
#include <unistd.h>
#include <fcntl.h>
#include <errno.h>
#include <signal.h>
#include <stdlib.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <libproc.h>

pid_t relay_pty_start(const char *shell, const char *home, char *const env[], int columns, int rows, int *master) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    // All allocation and argument construction happen before fork. The child
    // never enters Swift, Foundation, or Objective-C before replacing itself.
    char *args[] = { (char *)shell, "-l", NULL };
    int descriptorLimit = getdtablesize();
    pid_t child = forkpty(master, NULL, NULL, &size);
    if (child == 0) {
        for (int fd = 3; fd < descriptorLimit; fd++) close(fd);
        sigset_t mask; sigemptyset(&mask); sigprocmask(SIG_SETMASK, &mask, NULL);
        for (int sig = 1; sig < NSIG; sig++) signal(sig, SIG_DFL);
        if (chdir(home) != 0) _exit(126);
        execve(shell, args, env);
        _exit(127);
    }
    if (child > 0) {
        fcntl(*master, F_SETFD, FD_CLOEXEC);
        fcntl(*master, F_SETFL, O_NONBLOCK);
    }
    return child;
}

int relay_pty_resize(int fd, int columns, int rows) {
    struct winsize size = { .ws_row = rows, .ws_col = columns };
    return ioctl(fd, TIOCSWINSZ, &size);
}

void relay_pty_stop(pid_t pid) {
    if (pid <= 0) return;
    // The unreaped session leader reserves this session ID. Include foreground
    // and background job groups, not just the login shell's process group.
    int count = proc_listallpids(NULL, 0);
    pid_t *pids = calloc(count + 256, sizeof(pid_t));
    if (pids) {
        count = proc_listallpids(pids, (count + 256) * (int)sizeof(pid_t));
        for (int i = 0; i < count; i++) {
            if (pids[i] > 0 && pids[i] != pid && getsid(pids[i]) == pid) kill(pids[i], SIGKILL);
        }
        free(pids);
    }
    kill(-pid, SIGKILL);
    kill(pid, SIGKILL);
    while (waitpid(pid, NULL, 0) < 0 && errno == EINTR) {}
}
