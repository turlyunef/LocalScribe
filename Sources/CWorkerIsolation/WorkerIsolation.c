#include <sandbox.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
#include <fcntl.h>
#include <poll.h>
static int connection_denied(int family, const struct sockaddr *address, socklen_t length) {
    int fd = socket(family, SOCK_STREAM, 0);
    if (fd < 0) {
        if (family == AF_INET6 && (errno == EAFNOSUPPORT || errno == EPROTONOSUPPORT)) return 1;
        return errno == EPERM || errno == EACCES;
    }
    if (fcntl(fd, F_SETFL, O_NONBLOCK) < 0) {
        close(fd);
        return 0;
    }
    int result = connect(fd, address, length);
    int error = result < 0 ? errno : 0;
    if (error == EINPROGRESS) {
        struct pollfd event = {fd, POLLOUT, 0};
        socklen_t size = sizeof(error);
        if (poll(&event, 1, 250) <= 0 || getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) < 0) error = 0;
    }
    close(fd);
    return error == EPERM || error == EACCES;
}
static int network_is_denied(void) {
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(9);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    struct sockaddr_in6 address6 = {0};
    address6.sin6_family = AF_INET6; address6.sin6_port = htons(9);
    address6.sin6_addr = in6addr_loopback;
    return connection_denied(AF_INET, (const struct sockaddr *)&address, sizeof(address))
        && connection_denied(AF_INET6, (const struct sockaddr *)&address6, sizeof(address6));
}
int localscribe_deny_network(void) {
    // A shipping worker inherits a network-denied App Sandbox from the GUI.
    // Reinitializing an inherited sandbox is forbidden. Standalone developer probes
    // additionally install a deny-network profile before loading any model.
    if (network_is_denied()) return 0;
    char *error = 0;
    int result = sandbox_init("(version 1)(allow default)(deny network*)", 0, &error);
    if (error) sandbox_free_error(error);
    return result == 0 && network_is_denied() ? 0 : -1;
}
