#ifndef GREYWALL_PROCESS_INFO_H
#define GREYWALL_PROCESS_INFO_H
#include <stddef.h>
#include <stdint.h>

typedef struct {
    int32_t pid;
    int32_t parent_pid;
    uint64_t start_seconds;
    uint64_t start_microseconds;
} gw_process_info;

int gw_process_lookup(int32_t pid, gw_process_info *out);
int32_t gw_audit_pid(const void *bytes, size_t length);
int64_t gw_process_uid(int32_t pid);
#endif
