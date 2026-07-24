#ifndef CL_PROCESS_KIT_PTY_H
#define CL_PROCESS_KIT_PTY_H

#include <stddef.h>
#include <sys/types.h>

int cpk_pty_spawn(const char *path, const char *arguments, size_t argument_size,
                  size_t argument_count, const char *environment,
                  size_t environment_size, size_t environment_count,
                  const char *cwd, unsigned short rows, unsigned short cols,
                  int *master_fd, pid_t *pid);
ssize_t cpk_pty_read(int fd, void *buffer, size_t length);
ssize_t cpk_pty_write(int fd, const void *buffer, size_t length);
int cpk_pty_resize(int fd, unsigned short rows, unsigned short cols);
int cpk_pty_send_eof(int fd);
int cpk_pty_foreground_pgid(int fd, pid_t session, pid_t *pgid);
int cpk_pty_signal_foreground(int fd, pid_t session, int signal_number);
int cpk_pty_signal_session(pid_t session, int signal_number);
int cpk_pty_wait(pid_t pid, int nohang, int *status, int *ready);
int cpk_pty_close(int fd);

#endif
