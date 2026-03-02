#ifndef TCPIP_H
#define TCPIP_H

#include <stdint.h>
#include <stdbool.h>
#include "rndis.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque TCP connection handle
typedef struct tcp_conn tcp_conn_t;

/// TCP/IP error codes
typedef enum {
    TCP_OK = 0,
    TCP_ERROR_TIMEOUT = -1,
    TCP_ERROR_REFUSED = -2,
    TCP_ERROR_RESET = -3,
    TCP_ERROR_CLOSED = -4,
    TCP_ERROR_ARP_FAILED = -5,
    TCP_ERROR_SEND = -6,
    TCP_ERROR_PARAM = -7,
} tcp_error_t;

/// Establish a TCP connection over RNDIS.
/// src_ip: our IP address (network byte order)
/// dst_ip: remote IP address (network byte order)
/// dst_port: remote port (host byte order)
/// Returns NULL on failure.
tcp_conn_t *tcp_connect(rndis_handle_t *rndis,
                         uint32_t src_ip, uint32_t dst_ip,
                         uint16_t dst_port, int timeout_ms);

/// Send data over an established TCP connection.
/// Returns number of bytes sent, or negative error code.
int tcp_send(tcp_conn_t *c, const uint8_t *data, uint32_t len, int timeout_ms);

/// Receive data from a TCP connection.
/// Returns number of bytes received, 0 on timeout, or negative error.
int tcp_recv(tcp_conn_t *c, uint8_t *buf, uint32_t len, int timeout_ms);

/// Close a TCP connection (sends FIN, waits for ACK).
void tcp_close(tcp_conn_t *c);

/// Poll for incoming TCP data (processes frames for up to timeout_ms).
/// Buffers any received data internally. Used in non-blocking SSH read loops.
void tcp_poll(tcp_conn_t *c, int timeout_ms);

/// Helper: convert dotted-quad string to network-byte-order uint32_t
uint32_t tcp_ip_addr(const char *dotted);

/// Console IP address: 169.254.13.37
#define CONSOLE_IP_STR  "169.254.13.37"
/// Our virtual host IP: 169.254.13.38
#define HOST_IP_STR     "169.254.13.38"

#ifdef __cplusplus
}
#endif

#endif /* TCPIP_H */
