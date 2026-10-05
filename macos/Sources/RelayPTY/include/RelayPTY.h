#include <sys/types.h>
pid_t relay_pty_start(const char *shell, const char *home, char *const env[], int columns, int rows, int *master);
int relay_pty_resize(int fd, int columns, int rows);
void relay_pty_stop(pid_t pid);
