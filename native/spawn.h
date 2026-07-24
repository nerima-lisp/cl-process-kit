#ifndef CL_PROCESS_KIT_SPAWN_H
#define CL_PROCESS_KIT_SPAWN_H

#include <stdint.h>

enum cpk_spawn_phase {
    CPK_SPAWN_PHASE_ARGUMENT = 1,
    CPK_SPAWN_PHASE_FD_SETUP = 2,
    CPK_SPAWN_PHASE_CHDIR = 3,
    CPK_SPAWN_PHASE_SESSION = 4,
    CPK_SPAWN_PHASE_PROCESS_GROUP = 5,
    CPK_SPAWN_PHASE_CREDENTIALS = 6,
    CPK_SPAWN_PHASE_RESOURCE_LIMIT = 7,
    CPK_SPAWN_PHASE_EXEC = 8
};

struct cpk_spawn_error {
    uint32_t phase;
    int32_t error_number;
};

#endif
