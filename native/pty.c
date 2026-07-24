#define _GNU_SOURCE
#include "pty.h"

#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <termios.h>
#include <unistd.h>

#ifdef __APPLE__
#include <util.h>
#else
#include <pty.h>
#endif

static int fail(int error_number) {
  errno = error_number;
  return -1;
}

static int set_cloexec(int fd) {
  int flags = fcntl(fd, F_GETFD);
  return flags < 0 ? -1 : fcntl(fd, F_SETFD, flags | FD_CLOEXEC);
}

static void child_fail(int error_fd) {
  int saved_errno = errno;
  ssize_t ignored = write(error_fd, &saved_errno, sizeof(saved_errno));
  (void)ignored;
  _exit(127);
}

static char **split_block(const char *block, size_t size, size_t count) {
  char **items = calloc(count + 1, sizeof(*items));
  size_t offset = 0, index;
  if (!items)
    return NULL;
  for (index = 0; index < count; index++) {
    size_t remaining;
    if (offset >= size) {
      free(items);
      errno = EINVAL;
      return NULL;
    }
    items[index] = (char *)block + offset;
    remaining = size - offset;
    offset += strnlen(block + offset, remaining) + 1;
    if (offset > size) {
      free(items);
      errno = EINVAL;
      return NULL;
    }
  }
  if (offset != size) {
    free(items);
    errno = EINVAL;
    return NULL;
  }
  return items;
}

int cpk_pty_spawn(const char *path, const char *arguments, size_t argument_size,
                  size_t argument_count, const char *environment,
                  size_t environment_size, size_t environment_count,
                  const char *cwd, unsigned short rows, unsigned short cols,
                  int *master_fd, pid_t *pid) {
  int master = -1, slave = -1, error_pipe[2] = {-1, -1};
  struct winsize size = {.ws_row = rows, .ws_col = cols};
  pid_t child;
  int child_errno = 0, status;
  ssize_t count;
  char **argv = NULL, **envp = NULL;

  if (!path || !arguments || !environment || !master_fd || !pid ||
      argument_count == 0 || rows == 0 || cols == 0)
    return fail(EINVAL);
  argv = split_block(arguments, argument_size, argument_count);
  if (!argv)
    return -1;
  envp = split_block(environment, environment_size, environment_count);
  if (!envp && environment_count != 0) {
    free(argv);
    return -1;
  }
  if (!envp) {
    envp = calloc(1, sizeof(*envp));
    if (!envp) {
      free(argv);
      return -1;
    }
  }
  if (openpty(&master, &slave, NULL, NULL, &size) < 0)
    goto parent_error;
  if (set_cloexec(master) < 0 || set_cloexec(slave) < 0 ||
      pipe(error_pipe) < 0 || set_cloexec(error_pipe[0]) < 0 ||
      set_cloexec(error_pipe[1]) < 0)
    goto parent_error;

  child = fork();
  if (child < 0)
    goto parent_error;
  if (child == 0) {
    close(error_pipe[0]);
    close(master);
    if (setsid() < 0)
      child_fail(error_pipe[1]);
#ifdef TIOCSCTTY
    if (ioctl(slave, TIOCSCTTY, 0) < 0)
      child_fail(error_pipe[1]);
#endif
    if (tcsetpgrp(slave, getpid()) < 0)
      child_fail(error_pipe[1]);
    if (dup2(slave, STDIN_FILENO) < 0 || dup2(slave, STDOUT_FILENO) < 0 ||
        dup2(slave, STDERR_FILENO) < 0)
      child_fail(error_pipe[1]);
    if (slave > STDERR_FILENO)
      close(slave);
    if (cwd && chdir(cwd) < 0)
      child_fail(error_pipe[1]);
    execve(path, argv, envp);
    child_fail(error_pipe[1]);
  }

  close(error_pipe[1]);
  error_pipe[1] = -1;
  close(slave);
  slave = -1;
  do {
    count = read(error_pipe[0], &child_errno, sizeof(child_errno));
  } while (count < 0 && errno == EINTR);
  close(error_pipe[0]);
  error_pipe[0] = -1;
  if (count == 0) {
    free(argv);
    free(envp);
    *master_fd = master;
    *pid = child;
    return 0;
  }
  close(master);
  free(argv);
  free(envp);
  do {
    status = waitpid(child, NULL, 0);
  } while (status < 0 && errno == EINTR);
  return fail(count == sizeof(child_errno) ? child_errno : EIO);

parent_error:
  status = errno;
  if (error_pipe[0] >= 0) close(error_pipe[0]);
  if (error_pipe[1] >= 0) close(error_pipe[1]);
  if (slave >= 0) close(slave);
  if (master >= 0) close(master);
  free(argv);
  free(envp);
  return fail(status);
}

ssize_t cpk_pty_read(int fd, void *buffer, size_t length) {
  ssize_t count;
  do {
    count = read(fd, buffer, length);
  } while (count < 0 && errno == EINTR);
  if (count < 0 && errno == EIO)
    return 0;
  return count;
}

ssize_t cpk_pty_write(int fd, const void *buffer, size_t length) {
  ssize_t count;
  do {
    count = write(fd, buffer, length);
  } while (count < 0 && errno == EINTR);
  return count;
}

int cpk_pty_resize(int fd, unsigned short rows, unsigned short cols) {
  struct winsize size = {.ws_row = rows, .ws_col = cols};
  if (rows == 0 || cols == 0)
    return fail(EINVAL);
  return ioctl(fd, TIOCSWINSZ, &size);
}

int cpk_pty_send_eof(int fd) {
  struct termios attributes;
  unsigned char eof;
  if (tcgetattr(fd, &attributes) < 0)
    return -1;
  if (!(attributes.c_lflag & ICANON))
    return fail(EINVAL);
  eof = attributes.c_cc[VEOF];
  return cpk_pty_write(fd, &eof, 1) == 1 ? 0 : -1;
}

int cpk_pty_foreground_pgid(int fd, pid_t session, pid_t *pgid) {
  pid_t foreground, foreground_session;
  if (!pgid || session <= 0)
    return fail(EINVAL);
  foreground = tcgetpgrp(fd);
  if (foreground < 0)
    return -1;
  foreground_session = getsid(foreground);
  if (foreground_session < 0)
    return -1;
  if (foreground_session != session)
    return fail(EPERM);
  *pgid = foreground;
  return 0;
}

int cpk_pty_signal_foreground(int fd, pid_t session, int signal_number) {
  pid_t pgid;
  if (signal_number <= 0 || cpk_pty_foreground_pgid(fd, session, &pgid) < 0)
    return -1;
  return kill(-pgid, signal_number);
}

int cpk_pty_signal_session(pid_t session, int signal_number) {
  if (session <= 0 || signal_number <= 0)
    return fail(EINVAL);
  if (getsid(session) != session)
    return fail(EPERM);
  return kill(-session, signal_number);
}

int cpk_pty_wait(pid_t pid, int nohang, int *status, int *ready) {
  pid_t result;
  if (pid <= 0 || !status || !ready)
    return fail(EINVAL);
  do {
    result = waitpid(pid, status, nohang ? WNOHANG : 0);
  } while (result < 0 && errno == EINTR);
  if (result < 0)
    return -1;
  *ready = result == pid;
  return 0;
}

int cpk_pty_close(int fd) {
  return close(fd);
}
