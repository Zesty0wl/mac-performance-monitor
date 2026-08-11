#include "CMacPerfMonitor.h"
#include <errno.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/un.h>

// Defined in <sys/proc.h> on macOS; guard in case a future SDK relocates it.
#ifndef P_TRANSLATED
#define P_TRANSLATED 0x00020000
#endif

int cmacperfmonitor_is_translated(pid_t pid) {
    int mib[4] = { CTL_KERN, KERN_PROC, KERN_PROC_PID, (int)pid };
    struct kinfo_proc info;
    size_t size = sizeof(info);
    memset(&info, 0, sizeof(info));
    if (sysctl(mib, 4, &info, &size, NULL, 0) != 0) {
        return -1;
    }
    if (size == 0) {
        // No such process.
        return -1;
    }
    return (info.kp_proc.p_flag & P_TRANSLATED) ? 1 : 0;
}

int cmacperfmonitor_rusage(pid_t pid,
                     uint64_t *phys_footprint,
                     uint64_t *lifetime_max_footprint,
                     uint64_t *disk_bytes_read,
                     uint64_t *disk_bytes_written,
                     uint64_t *billed_energy,
                     uint64_t *idle_wakeups) {
    struct rusage_info_v6 ru;
    memset(&ru, 0, sizeof(ru));
    int rc = proc_pid_rusage((int)pid, RUSAGE_INFO_V6, (rusage_info_t *)&ru);
    if (rc != 0) {
        return -1;
    }
    if (phys_footprint) {
        *phys_footprint = ru.ri_phys_footprint;
    }
    if (lifetime_max_footprint) {
        *lifetime_max_footprint = ru.ri_lifetime_max_phys_footprint;
    }
    if (disk_bytes_read) {
        *disk_bytes_read = ru.ri_diskio_bytesread;
    }
    if (disk_bytes_written) {
        *disk_bytes_written = ru.ri_diskio_byteswritten;
    }
    if (billed_energy) {
        *billed_energy = ru.ri_billed_energy;
    }
    if (idle_wakeups) {
        *idle_wakeups = ru.ri_pkg_idle_wkups + ru.ri_interrupt_wkups;
    }
    return 0;
}

// Format one IPv4/IPv6 endpoint (address plus port) into `buf`. `port_net` is
// the port in network byte order, as libproc reports it.
static void cmacperfmonitor_format_endpoint(int is_v6, const void *addr,
                                      int port_net, char *buf, size_t buflen) {
    char ip[INET6_ADDRSTRLEN];
    ip[0] = '\0';
    inet_ntop(is_v6 ? AF_INET6 : AF_INET, addr, ip, sizeof(ip));
    int port = ntohs((uint16_t)port_net);
    if (is_v6) {
        snprintf(buf, buflen, "[%s]:%d", ip, port);
    } else {
        snprintf(buf, buflen, "%s:%d", ip, port);
    }
}

// Describe a socket (TCP/UDP endpoints, or a unix-domain path) into `detail`.
static void cmacperfmonitor_format_socket(const struct socket_info *psi,
                                    char *detail, size_t len) {
    int kind = psi->soi_kind;
    if (kind == SOCKINFO_TCP || kind == SOCKINFO_IN) {
        const struct in_sockinfo *ini = (kind == SOCKINFO_TCP)
            ? &psi->soi_proto.pri_tcp.tcpsi_ini
            : &psi->soi_proto.pri_in;
        int v6 = (ini->insi_vflag & INI_IPV6) ? 1 : 0;
        const void *laddr = v6
            ? (const void *)&ini->insi_laddr.ina_6
            : (const void *)&ini->insi_laddr.ina_46.i46a_addr4;
        const void *faddr = v6
            ? (const void *)&ini->insi_faddr.ina_6
            : (const void *)&ini->insi_faddr.ina_46.i46a_addr4;
        char local[80], remote[80];
        cmacperfmonitor_format_endpoint(v6, laddr, ini->insi_lport, local, sizeof(local));
        cmacperfmonitor_format_endpoint(v6, faddr, ini->insi_fport, remote, sizeof(remote));
        const char *proto = (kind == SOCKINFO_TCP) ? "tcp" : "udp";
        if (ntohs((uint16_t)ini->insi_fport) == 0) {
            snprintf(detail, len, "%s %s (listening)", proto, local);
        } else {
            snprintf(detail, len, "%s %s -> %s", proto, local, remote);
        }
    } else if (kind == SOCKINFO_UN) {
        const struct sockaddr_un *un = &psi->soi_proto.pri_un.unsi_addr.ua_sun;
        if (un->sun_path[0] != '\0') {
            snprintf(detail, len, "unix %s", un->sun_path);
        } else {
            strlcpy(detail, "unix socket", len);
        }
    } else {
        strlcpy(detail, "socket", len);
    }
}

int cmacperfmonitor_list_fds(pid_t pid, cmacperfmonitor_fd_t *out, int capacity) {
    int buffer_size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, NULL, 0);
    if (buffer_size < 0) {
        return -1;
    }
    if (buffer_size == 0) {
        return 0;
    }

    struct proc_fdinfo *fds = (struct proc_fdinfo *)malloc((size_t)buffer_size);
    if (!fds) {
        return -1;
    }
    int ret = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, fds, buffer_size);
    if (ret <= 0) {
        free(fds);
        return ret < 0 ? -1 : 0;
    }
    int n = ret / (int)sizeof(struct proc_fdinfo);

    // Sizing pass: report the count without resolving per-descriptor detail.
    if (out == NULL || capacity <= 0) {
        free(fds);
        return n;
    }

    int limit = n < capacity ? n : capacity;
    int written = 0;
    for (int i = 0; i < limit; i++) {
        int32_t fd = fds[i].proc_fd;
        int32_t type_code = 5;
        char detail[1024];
        detail[0] = '\0';

        switch (fds[i].proc_fdtype) {
            case PROX_FDTYPE_VNODE: {
                type_code = 1;
                struct vnode_fdinfowithpath vi;
                memset(&vi, 0, sizeof(vi));
                int r = proc_pidfdinfo(pid, fd, PROC_PIDFDVNODEPATHINFO, &vi, sizeof(vi));
                if (r == (int)sizeof(vi)) {
                    strlcpy(detail, vi.pvip.vip_path, sizeof(detail));
                }
                break;
            }
            case PROX_FDTYPE_SOCKET: {
                type_code = 2;
                struct socket_fdinfo si;
                memset(&si, 0, sizeof(si));
                int r = proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &si, sizeof(si));
                if (r == (int)sizeof(si)) {
                    cmacperfmonitor_format_socket(&si.psi, detail, sizeof(detail));
                }
                break;
            }
            case PROX_FDTYPE_PIPE:
                type_code = 3;
                strlcpy(detail, "pipe", sizeof(detail));
                break;
            case PROX_FDTYPE_KQUEUE:
                type_code = 4;
                strlcpy(detail, "kqueue", sizeof(detail));
                break;
            default:
                type_code = 5;
                break;
        }

        out[written].fd = fd;
        out[written].type = type_code;
        strlcpy(out[written].detail, detail, sizeof(out[written].detail));
        written++;
    }

    free(fds);
    return written;
}

#include <CoreFoundation/CoreFoundation.h>
#include <IOKit/IOKitLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <IOKit/storage/nvme/NVMeSMARTLibExternal.h>

int cmacperfmonitor_nvme_smart_read(uint64_t registry_entry_id, uint8_t *out) {
    io_service_t service = IOServiceGetMatchingService(
        kIOMainPortDefault, IORegistryEntryIDMatching(registry_entry_id));
    if (service == IO_OBJECT_NULL) {
        return -1;
    }

    // COM-style plug-in dance: create the plug-in for the service, then query
    // the SMART interface off it. Both must be released, in reverse order.
    IOCFPlugInInterface **plugin = NULL;
    SInt32 score = 0;
    kern_return_t kr = IOCreatePlugInInterfaceForService(
        service, kIONVMeSMARTUserClientTypeID, kIOCFPlugInInterfaceID, &plugin, &score);
    IOObjectRelease(service);
    if (kr != KERN_SUCCESS || plugin == NULL) {
        return -2;
    }

    IONVMeSMARTInterface **smart = NULL;
    HRESULT hr = (*plugin)->QueryInterface(
        plugin, CFUUIDGetUUIDBytes(kIONVMeSMARTInterfaceID), (LPVOID *)&smart);
    if (hr != S_OK || smart == NULL) {
        IODestroyPlugInInterface(plugin);
        return -3;
    }

    NVMeSMARTData data;
    memset(&data, 0, sizeof(data));
    IOReturn ret = (*smart)->SMARTReadData(smart, &data);
    (*smart)->Release(smart);
    IODestroyPlugInInterface(plugin);
    if (ret != kIOReturnSuccess) {
        return -4;
    }

    // NVMeSMARTData is pragma pack(1) and exactly the 512-byte log page.
    _Static_assert(sizeof(NVMeSMARTData) == 512, "NVMe SMART log must be 512 bytes");
    memcpy(out, &data, sizeof(data));
    return 0;
}
