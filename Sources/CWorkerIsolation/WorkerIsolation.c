#include <sandbox.h>
#include <sys/socket.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <errno.h>
static int network_is_denied(void) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return errno == EPERM || errno == EACCES;
    struct sockaddr_in address = {0};
    address.sin_family = AF_INET; address.sin_port = htons(9);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    int result = connect(fd, (struct sockaddr *)&address, sizeof(address));
    int error = errno; close(fd);
    return result < 0 && (error == EPERM || error == EACCES);
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
