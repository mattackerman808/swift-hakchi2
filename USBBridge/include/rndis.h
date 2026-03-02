#ifndef RNDIS_H
#define RNDIS_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an RNDIS connection
typedef struct rndis_handle rndis_handle_t;

/// RNDIS error codes
typedef enum {
    RNDIS_OK = 0,
    RNDIS_ERROR_USB = -1,
    RNDIS_ERROR_TIMEOUT = -2,
    RNDIS_ERROR_PROTOCOL = -3,
    RNDIS_ERROR_INIT_FAILED = -4,
    RNDIS_ERROR_NO_DEVICE = -5,
} rndis_error_t;

/// Open an RNDIS device by VID/PID and perform RNDIS initialization.
/// Returns NULL on failure.
rndis_handle_t *rndis_open(uint16_t vid, uint16_t pid);

/// Get the negotiated max transfer size (for buffer allocation).
uint32_t rndis_max_transfer_size(rndis_handle_t *h);

/// Get the device's MAC address (6 bytes). Returns false if unknown.
bool rndis_get_device_mac(rndis_handle_t *h, uint8_t mac_out[6]);

/// Get the host MAC address we're using (6 bytes).
void rndis_get_host_mac(rndis_handle_t *h, uint8_t mac_out[6]);

/// Send an Ethernet frame via RNDIS. The frame must include the 14-byte
/// Ethernet header. Returns number of bytes sent or negative error.
int rndis_send_packet(rndis_handle_t *h, const uint8_t *eth_frame, uint32_t len);

/// Receive an Ethernet frame via RNDIS. Unwraps the RNDIS packet header.
/// Returns frame length, 0 on timeout, or negative error.
int rndis_recv_packet(rndis_handle_t *h, uint8_t *buf, uint32_t buf_len,
                       int timeout_ms);

/// Send RNDIS_MSG_HALT and close the USB device.
void rndis_close(rndis_handle_t *h);

/// Check if an RNDIS device with the given VID/PID is present.
bool rndis_device_exists(uint16_t vid, uint16_t pid);

/// Standard RNDIS VID/PID for Samsung-based NES/SNES Classic
#define RNDIS_VID  0x04E8
#define RNDIS_PID  0x6863

#ifdef __cplusplus
}
#endif

#endif /* RNDIS_H */
