#ifndef CMACPERFMONITOR_H
#define CMACPERFMONITOR_H

#include <sys/types.h>
#include <sys/sysctl.h>
#include <sys/proc.h>
#include <sys/proc_info.h>
#include <sys/resource.h>
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/host_info.h>
#include <mach/vm_statistics.h>
#include <mach/task_info.h>
#include <mach/processor_info.h>
#include <mach/machine.h>
#include <unistd.h>
#include <stdint.h>

/// Detect whether a process is running translated under Rosetta 2.
///
/// Returns 1 if translated, 0 if native, -1 on error (process gone or not
/// permitted). Implemented in C because the `P_TRANSLATED` flag lives in
/// `<sys/proc.h>` and is awkward to reach from Swift.
int cmacperfmonitor_is_translated(pid_t pid);

/// Read `phys_footprint` and related rusage figures for a process via
/// `proc_pid_rusage(RUSAGE_INFO_V6, ...)`.
///
/// `billed_energy` is the kernel's per-process energy accounting in nanojoules
/// (`ri_billed_energy`); it is cumulative and best-effort (often 0 on hardware
/// or for processes the ledger does not track). `idle_wakeups` is the sum of
/// the package idle and interrupt wakeup counters (`ri_pkg_idle_wkups +
/// ri_interrupt_wkups`), the classic battery-drain signal: cumulative wakeups
/// that keep the CPU from staying in its low-power idle state.
///
/// Returns 0 on success; -1 on failure (errno set by proc_pid_rusage). The
/// out-params are only written on success and any of them may be NULL.
int cmacperfmonitor_rusage(pid_t pid,
                     uint64_t *phys_footprint,
                     uint64_t *lifetime_max_footprint,
                     uint64_t *disk_bytes_read,
                     uint64_t *disk_bytes_written,
                     uint64_t *billed_energy,
                     uint64_t *idle_wakeups);

/// One resolved open file descriptor for a process.
///
/// `type` is a small stable code rather than the raw `PROX_FDTYPE_*` value so
/// the Swift side does not have to import those constants:
///   1 = file (vnode)   2 = socket   3 = pipe   4 = kqueue   5 = other
/// `detail` holds the resolved file path (vnode), a formatted socket endpoint
/// description, or a short type word; it is always NUL-terminated.
typedef struct {
    int32_t fd;
    int32_t type;
    char detail[1024];
} cmacperfmonitor_fd_t;

/// Enumerate the open file descriptors of a process, resolving each one's
/// detail (file path or socket endpoints).
///
/// Two-pass, mirroring libproc's own sizing convention:
///   - Pass `out == NULL` (or `capacity <= 0`) to get the descriptor count
///     without resolving any details.
///   - Then allocate `capacity` entries and call again to fill `out`.
/// Returns the number of entries written (capped at `capacity` on the fill
/// pass, or the total count on a sizing pass), or -1 on a hard error. A process
/// the caller is not permitted to inspect reports 0 descriptors rather than an
/// error, matching `PROC_PIDLISTFDS`.
int cmacperfmonitor_list_fds(pid_t pid, cmacperfmonitor_fd_t *out, int capacity);

/// Read the raw 512-byte NVMe SMART / Health log for the NVMe controller or
/// block storage device with the given IORegistry entry ID, via the
/// `IONVMeSMARTUserClient` plug-in interface.
///
/// C code only fetches the bytes (the COM-style plug-in dance is impossible in
/// Swift); all parsing stays in Swift so it can be unit-tested against fixture
/// blobs. `out` must point to at least 512 bytes and is only written on
/// success.
///
/// Returns 0 on success, or a negative step code on failure: -1 no such
/// registry entry, -2 the service has no SMART plug-in (external and USB
/// enclosures commonly refuse this), -3 interface query failed, -4 the SMART
/// read itself failed. Callers should treat every nonzero result as "SMART not
/// available", not as an error worth surfacing.
int cmacperfmonitor_nvme_smart_read(uint64_t registry_entry_id, uint8_t *out);

#endif /* CMACPERFMONITOR_H */
