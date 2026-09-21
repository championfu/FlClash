#ifndef FlClashCore_h
#define FlClashCore_h

#include <stdbool.h>
#include <stdint.h>
#include <string.h>
#include <sys/ioctl.h>
#include <sys/socket.h>

// Xcode 26 no longer ships sys/kern_control.h in the iOS SDK. Keep the small
// ABI definitions needed for the utun lookup local instead of depending on
// that private header.
#define FLCLASH_MAX_KCTL_NAME 96
struct flclash_ctl_info {
    uint32_t ctl_id;
    char ctl_name[FLCLASH_MAX_KCTL_NAME];
};
struct flclash_sockaddr_ctl {
    uint8_t sc_len;
    uint8_t sc_family;
    uint16_t ss_sysaddr;
    uint32_t sc_id;
    uint32_t sc_unit;
    uint32_t sc_reserved[5];
};
#define FLCLASH_CTLIOCGINFO _IOWR('N', 3, struct flclash_ctl_info)

char *FlClashInvokeAction(char *params);
void FlClashFreeString(char *value);
char *FlClashPollEvent(void);
bool startTUN(void *callback, int fd, char *stack, char *address, char *dns);
void stopTun(void);

// NEPacketTunnelFlow no longer reliably exposes socket.fileDescriptor through
// KVC on recent iOS releases. Find the utun kernel-control socket owned by the
// Packet Tunnel extension process instead. This runs once during startup.
static inline int32_t FlClashFindUtunFileDescriptor(void) {
    struct flclash_ctl_info controlInfo;
    memset(&controlInfo, 0, sizeof(controlInfo));
    strlcpy(controlInfo.ctl_name, "com.apple.net.utun_control", sizeof(controlInfo.ctl_name));

    for (int32_t descriptor = 0; descriptor <= 1024; descriptor++) {
        struct flclash_sockaddr_ctl address;
        memset(&address, 0, sizeof(address));
        socklen_t addressLength = sizeof(address);
        if (getpeername(descriptor, (struct sockaddr *)&address, &addressLength) != 0 ||
            address.sc_family != AF_SYSTEM) {
            continue;
        }
        if (controlInfo.ctl_id == 0 && ioctl(descriptor, FLCLASH_CTLIOCGINFO, &controlInfo) != 0) {
            continue;
        }
        if (address.sc_id == controlInfo.ctl_id) {
            return descriptor;
        }
    }
    return -1;
}

#endif
