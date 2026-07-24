#define _DARWIN_C_SOURCE
#define _DEFAULT_SOURCE
#define _POSIX_C_SOURCE 200809L

#include "spawn.h"

#include <errno.h>
#include <fcntl.h>
#include <grp.h>
#include <limits.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <unistd.h>

struct fd_map {
    int target;
    int source;
    int temporary;
};

struct limit_spec {
    int resource;
    struct rlimit value;
};

static int error_fd = -1;

static void fail(enum cpk_spawn_phase phase)
{
    struct cpk_spawn_error record;
    int saved_errno = errno == 0 ? EINVAL : errno;
    ssize_t ignored;

    record.phase = (uint32_t)phase;
    record.error_number = (int32_t)saved_errno;
    do {
        ignored = write(error_fd, &record, sizeof(record));
    } while (ignored < 0 && errno == EINTR);
    (void)ignored;
    _exit(127);
}

static long parse_long(const char *value)
{
    char *end = NULL;
    long result;

    errno = 0;
    result = strtol(value, &end, 0);
    if (errno != 0 || end == value || *end != '\0')
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    return result;
}

static void parse_pair(const char *value, long *first, long *second)
{
    const char *separator = strchr(value, ':');
    char left[64];
    size_t length;

    if (separator == NULL)
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    length = (size_t)(separator - value);
    if (length == 0 || length >= sizeof(left))
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    memcpy(left, value, length);
    left[length] = '\0';
    *first = parse_long(left);
    *second = parse_long(separator + 1);
}

static rlim_t parse_rlim(const char *value)
{
    unsigned long long parsed;
    char *end = NULL;

    if (strcmp(value, "infinity") == 0)
        return RLIM_INFINITY;
    errno = 0;
    parsed = strtoull(value, &end, 0);
    if (errno != 0 || end == value || *end != '\0')
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    return (rlim_t)parsed;
}

static int parse_resource(const char *name)
{
    if (strcmp(name, "nofile") == 0)
        return RLIMIT_NOFILE;
    if (strcmp(name, "fsize") == 0)
        return RLIMIT_FSIZE;
    if (strcmp(name, "core") == 0)
        return RLIMIT_CORE;
    if (strcmp(name, "cpu") == 0)
        return RLIMIT_CPU;
    fail(CPK_SPAWN_PHASE_ARGUMENT);
    return -1;
}

static struct limit_spec parse_limit(const char *value)
{
    struct limit_spec result;
    const char *first = strchr(value, ':');
    const char *second = NULL;
    char name[32];
    char soft[64];
    size_t name_length;
    size_t soft_length;

    if (first == NULL)
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    second = strchr(first + 1, ':');
    if (second == NULL)
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    name_length = (size_t)(first - value);
    soft_length = (size_t)(second - first - 1);
    if (name_length == 0 || name_length >= sizeof(name) ||
        soft_length == 0 || soft_length >= sizeof(soft))
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    memcpy(name, value, name_length);
    name[name_length] = '\0';
    memcpy(soft, first + 1, soft_length);
    soft[soft_length] = '\0';
    result.resource = parse_resource(name);
    result.value.rlim_cur = parse_rlim(soft);
    result.value.rlim_max = parse_rlim(second + 1);
    return result;
}

static void prepare_fd_maps(struct fd_map *maps, size_t count)
{
    int minimum = 3;
    size_t index;

    for (index = 0; index < count; index++) {
        if (maps[index].target >= minimum)
            minimum = maps[index].target + 1;
    }
    if (error_fd >= minimum)
        minimum = error_fd + 1;
    for (index = 0; index < count; index++) {
        if (maps[index].source >= 0) {
            maps[index].temporary =
                fcntl(maps[index].source, F_DUPFD_CLOEXEC, minimum);
            if (maps[index].temporary < 0)
                fail(CPK_SPAWN_PHASE_FD_SETUP);
            minimum = maps[index].temporary + 1;
        }
    }
}

static void apply_fd_maps(struct fd_map *maps, size_t count)
{
    size_t index;

    prepare_fd_maps(maps, count);
    for (index = 0; index < count; index++) {
        int target = maps[index].target;
        if (maps[index].source == -1) {
            if (close(target) < 0 && errno != EBADF)
                fail(CPK_SPAWN_PHASE_FD_SETUP);
        } else if (maps[index].source == -2) {
            int flags = target == STDIN_FILENO ? O_RDONLY : O_WRONLY;
            int null_fd = open("/dev/null", flags);
            if (null_fd < 0 || dup2(null_fd, target) < 0)
                fail(CPK_SPAWN_PHASE_FD_SETUP);
            if (null_fd != target)
                (void)close(null_fd);
        } else if (dup2(maps[index].temporary, target) < 0) {
            fail(CPK_SPAWN_PHASE_FD_SETUP);
        }
    }
    for (index = 0; index < count; index++) {
        if (maps[index].temporary >= 0)
            (void)close(maps[index].temporary);
    }
}

static gid_t *parse_groups(const char *value, size_t *count)
{
    gid_t *groups = NULL;
    char *copy = strdup(value);
    char *cursor = NULL;
    char *token;

    if (copy == NULL)
        fail(CPK_SPAWN_PHASE_ARGUMENT);
    *count = 0;
    token = strtok_r(copy, ",", &cursor);
    while (token != NULL) {
        gid_t *grown;
        if (*token == '\0')
            fail(CPK_SPAWN_PHASE_ARGUMENT);
        grown = realloc(groups, (*count + 1) * sizeof(*groups));
        if (grown == NULL)
            fail(CPK_SPAWN_PHASE_ARGUMENT);
        groups = grown;
        groups[*count] = (gid_t)parse_long(token);
        (*count)++;
        token = strtok_r(NULL, ",", &cursor);
    }
    free(copy);
    return groups;
}

int main(int argc, char **argv)
{
    struct fd_map *maps = calloc((size_t)argc, sizeof(*maps));
    struct limit_spec *limits = calloc((size_t)argc, sizeof(*limits));
    int *pass_fds = calloc((size_t)argc, sizeof(*pass_fds));
    gid_t *groups = NULL;
    size_t map_count = 0;
    size_t limit_count = 0;
    size_t group_count = 0;
    size_t pass_fd_count = 0;
    const char *directory = NULL;
    long process_group = -1;
    uid_t uid = (uid_t)-1;
    gid_t gid = (gid_t)-1;
    mode_t mask = 0;
    int set_mask = 0;
    int new_session = 0;
    int detached = 0;
    int index = 1;
    size_t item;

    if (maps == NULL || limits == NULL || pass_fds == NULL)
        return 127;
    while (index < argc && strcmp(argv[index], "--") != 0) {
        const char *option = argv[index++];
        if (index >= argc)
            return 127;
        if (strcmp(option, "--error-fd") == 0) {
            error_fd = (int)parse_long(argv[index++]);
        } else if (strcmp(option, "--map") == 0) {
            long target;
            long source;
            parse_pair(argv[index++], &target, &source);
            if (target < 0 || target > INT_MAX || source < -2 || source > INT_MAX)
                fail(CPK_SPAWN_PHASE_ARGUMENT);
            for (item = 0; item < map_count; item++) {
                if (maps[item].target == (int)target)
                    fail(CPK_SPAWN_PHASE_ARGUMENT);
            }
            maps[map_count++] = (struct fd_map){
                .target = (int)target, .source = (int)source, .temporary = -1
            };
        } else if (strcmp(option, "--pass") == 0) {
            long fd = parse_long(argv[index++]);
            if (fd < 0 || fd > INT_MAX)
                fail(CPK_SPAWN_PHASE_ARGUMENT);
            pass_fds[pass_fd_count++] = (int)fd;
        } else if (strcmp(option, "--session") == 0) {
            new_session = (int)parse_long(argv[index++]);
        } else if (strcmp(option, "--pgroup") == 0) {
            process_group = parse_long(argv[index++]);
        } else if (strcmp(option, "--detached") == 0) {
            detached = (int)parse_long(argv[index++]);
        } else if (strcmp(option, "--uid") == 0) {
            uid = (uid_t)parse_long(argv[index++]);
        } else if (strcmp(option, "--gid") == 0) {
            gid = (gid_t)parse_long(argv[index++]);
        } else if (strcmp(option, "--groups") == 0) {
            groups = parse_groups(argv[index++], &group_count);
        } else if (strcmp(option, "--umask") == 0) {
            mask = (mode_t)parse_long(argv[index++]);
            set_mask = 1;
        } else if (strcmp(option, "--rlimit") == 0) {
            limits[limit_count++] = parse_limit(argv[index++]);
        } else if (strcmp(option, "--chdir") == 0) {
            directory = argv[index++];
        } else {
            return 127;
        }
    }
    if (error_fd < 0 || index >= argc || strcmp(argv[index], "--") != 0 ||
        ++index >= argc) {
        return 127;
    }
    {
        int flags = fcntl(error_fd, F_GETFD);
        if (flags < 0 || fcntl(error_fd, F_SETFD, flags | FD_CLOEXEC) < 0)
            fail(CPK_SPAWN_PHASE_FD_SETUP);
    }

    apply_fd_maps(maps, map_count);
    for (item = 0; item < pass_fd_count; item++) {
        int flags = fcntl(pass_fds[item], F_GETFD);
        if (flags < 0 ||
            fcntl(pass_fds[item], F_SETFD, flags & ~FD_CLOEXEC) < 0)
            fail(CPK_SPAWN_PHASE_FD_SETUP);
    }
    if (directory != NULL && chdir(directory) < 0)
        fail(CPK_SPAWN_PHASE_CHDIR);
    if (new_session || detached) {
        if (getpgrp() == getpid()) {
            pid_t parent_group = getpgid(getppid());
            if (parent_group < 0 || setpgid(0, parent_group) < 0)
                fail(CPK_SPAWN_PHASE_SESSION);
        }
        if (setsid() < 0)
            fail(CPK_SPAWN_PHASE_SESSION);
    }
    if (process_group >= 0 && !(new_session && process_group == 0) &&
        setpgid(0, process_group == 0 ? getpid() : (pid_t)process_group) < 0)
        fail(CPK_SPAWN_PHASE_PROCESS_GROUP);
    if (group_count > 0 && setgroups((int)group_count, groups) < 0)
        fail(CPK_SPAWN_PHASE_CREDENTIALS);
    if (gid != (gid_t)-1 && setgid(gid) < 0)
        fail(CPK_SPAWN_PHASE_CREDENTIALS);
    if (uid != (uid_t)-1 && setuid(uid) < 0)
        fail(CPK_SPAWN_PHASE_CREDENTIALS);
    if (set_mask)
        (void)umask(mask);
    for (item = 0; item < limit_count; item++) {
        if (setrlimit(limits[item].resource, &limits[item].value) < 0)
            fail(CPK_SPAWN_PHASE_RESOURCE_LIMIT);
    }
    execv(argv[index], &argv[index]);
    fail(CPK_SPAWN_PHASE_EXEC);
}
