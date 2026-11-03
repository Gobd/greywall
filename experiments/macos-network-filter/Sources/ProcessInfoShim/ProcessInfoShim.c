#include "ProcessInfoShim.h"
#include <bsm/libbsm.h>
#include <libproc.h>
#include <string.h>

int gw_process_lookup(int32_t pid, gw_process_info *out) {
    if (!out || pid <= 0) return 0;
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 0;
    *out = (gw_process_info){
        .pid = (int32_t)info.pbi_pid,
        .parent_pid = (int32_t)info.pbi_ppid,
        .start_seconds = info.pbi_start_tvsec,
        .start_microseconds = info.pbi_start_tvusec,
    };
    return 1;
}

int64_t gw_process_uid(int32_t pid) {
    struct proc_bsdinfo info = {0};
    if (pid <= 0 || proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return -1;
    return info.pbi_uid;
}

int32_t gw_audit_pid(const void *bytes, size_t length) {
    if (!bytes || length != sizeof(audit_token_t)) return -1;
    audit_token_t token;
    memcpy(&token, bytes, sizeof(token));
    return audit_token_to_pid(token);
}
