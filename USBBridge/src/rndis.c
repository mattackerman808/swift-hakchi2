/**
 * RNDIS (Remote NDIS) protocol implementation over USB.
 *
 * RNDIS is Microsoft's protocol for USB Ethernet devices. The NES/SNES Classic
 * uses it when booted with "hakchi-shell" in the kernel cmdline.
 *
 * Reference: Linux kernel drivers/net/usb/rndis_host.c
 *            MS RNDIS spec (publicly documented)
 *
 * USB layout:
 *   Interface 0 — CDC control (Encapsulated Command/Response on default pipe)
 *   Interface 1 — CDC data (bulk IN 0x81, bulk OUT 0x01)
 */

#include "rndis.h"
#include "usb_device.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// RNDIS message types and structures
// ---------------------------------------------------------------------------

#define RNDIS_MSG_INIT          0x00000002
#define RNDIS_MSG_INIT_C        0x80000002
#define RNDIS_MSG_HALT          0x00000003
#define RNDIS_MSG_QUERY         0x00000004
#define RNDIS_MSG_QUERY_C       0x80000004
#define RNDIS_MSG_SET           0x00000005
#define RNDIS_MSG_SET_C         0x80000005
#define RNDIS_MSG_PACKET        0x00000001
#define RNDIS_MSG_KEEPALIVE     0x00000008
#define RNDIS_MSG_KEEPALIVE_C   0x80000008

#define RNDIS_STATUS_SUCCESS    0x00000000

// OIDs
#define OID_802_3_PERMANENT_ADDRESS     0x01010101
#define OID_802_3_CURRENT_ADDRESS       0x01010102
#define OID_GEN_CURRENT_PACKET_FILTER   0x0001010E
#define OID_GEN_MAXIMUM_FRAME_SIZE      0x00010106

// Packet filter flags
#define NDIS_PACKET_TYPE_DIRECTED       0x00000001
#define NDIS_PACKET_TYPE_BROADCAST      0x00000008
#define NDIS_PACKET_TYPE_ALL_MULTICAST  0x00000004

// USB CDC class requests
#define CDC_SEND_ENCAPSULATED_COMMAND   0x00
#define CDC_GET_ENCAPSULATED_RESPONSE   0x01

// Generic RNDIS message header
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
} rndis_msg_hdr_t;

// RNDIS_MSG_INIT
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t major_version;
    uint32_t minor_version;
    uint32_t max_transfer_size;
} rndis_init_msg_t;

// RNDIS_MSG_INIT_C
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
    uint32_t major_version;
    uint32_t minor_version;
    uint32_t device_flags;
    uint32_t medium;
    uint32_t max_packets_per_transfer;
    uint32_t max_transfer_size;
    uint32_t packet_alignment_factor;
    uint32_t reserved1;
    uint32_t reserved2;
} rndis_init_cmplt_t;

// RNDIS_MSG_QUERY
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t oid;
    uint32_t info_buf_len;
    uint32_t info_buf_offset;   // from start of request_id
    uint32_t reserved;
} rndis_query_msg_t;

// RNDIS_MSG_QUERY_C
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
    uint32_t info_buf_len;
    uint32_t info_buf_offset;   // from start of request_id
} rndis_query_cmplt_t;

// RNDIS_MSG_SET
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t oid;
    uint32_t info_buf_len;
    uint32_t info_buf_offset;   // from start of request_id
    uint32_t reserved;
    // payload follows
} rndis_set_msg_t;

// RNDIS_MSG_SET_C
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
} rndis_set_cmplt_t;

// RNDIS_MSG_PACKET
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t data_offset;       // from start of data_offset field
    uint32_t data_len;
    uint32_t oob_data_offset;
    uint32_t oob_data_len;
    uint32_t num_oob_data_elements;
    uint32_t per_packet_info_offset;
    uint32_t per_packet_info_len;
    uint32_t reserved1;
    uint32_t reserved2;
} rndis_packet_hdr_t;

// RNDIS_MSG_HALT
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
} rndis_halt_msg_t;

// RNDIS_MSG_KEEPALIVE_C
typedef struct __attribute__((packed)) {
    uint32_t msg_type;
    uint32_t msg_len;
    uint32_t request_id;
    uint32_t status;
} rndis_keepalive_cmplt_t;

// ---------------------------------------------------------------------------
// Handle structure
// ---------------------------------------------------------------------------

struct rndis_handle {
    hakchi_usb_device_t *usb;
    uint32_t request_id;
    uint32_t max_transfer_size;
    uint8_t  device_mac[6];
    bool     have_device_mac;
    uint8_t  host_mac[6];
    uint8_t  *recv_buf;         // reusable buffer for bulk reads
    uint32_t recv_buf_size;
};

// ---------------------------------------------------------------------------
// USB CDC control message helpers
// ---------------------------------------------------------------------------

/// Send an RNDIS control message via CDC Send Encapsulated Command
static int rndis_send_control(rndis_handle_t *h, const void *msg, uint16_t len) {
    // bmRequestType: 0x21 = Host-to-device, Class, Interface
    return hakchi_usb_control_transfer(h->usb,
        0x21, CDC_SEND_ENCAPSULATED_COMMAND,
        0, 0,   // wValue=0, wIndex=0 (interface 0)
        (uint8_t *)msg, len, 5000);
}

/// Get RNDIS control response via CDC Get Encapsulated Response
static int rndis_get_response(rndis_handle_t *h, void *buf, uint16_t buf_len) {
    // bmRequestType: 0xA1 = Device-to-host, Class, Interface
    return hakchi_usb_control_transfer(h->usb,
        0xA1, CDC_GET_ENCAPSULATED_RESPONSE,
        0, 0,
        (uint8_t *)buf, buf_len, 5000);
}

// ---------------------------------------------------------------------------
// RNDIS protocol operations
// ---------------------------------------------------------------------------

/// Send RNDIS_MSG_INIT and receive RNDIS_MSG_INIT_C
static rndis_error_t rndis_init_device(rndis_handle_t *h) {
    rndis_init_msg_t msg = {
        .msg_type = RNDIS_MSG_INIT,
        .msg_len = sizeof(msg),
        .request_id = ++h->request_id,
        .major_version = 1,
        .minor_version = 0,
        .max_transfer_size = 0x4000,    // 16KB — reasonable for USB HS
    };

    int ret = rndis_send_control(h, &msg, sizeof(msg));
    if (ret < 0) {
        fprintf(stderr, "[RNDIS] Init send failed: %d\n", ret);
        return RNDIS_ERROR_USB;
    }

    uint8_t resp_buf[256];
    ret = rndis_get_response(h, resp_buf, sizeof(resp_buf));
    if (ret < (int)sizeof(rndis_init_cmplt_t)) {
        fprintf(stderr, "[RNDIS] Init response too short: %d\n", ret);
        return RNDIS_ERROR_PROTOCOL;
    }

    rndis_init_cmplt_t *cmplt = (rndis_init_cmplt_t *)resp_buf;
    if (cmplt->msg_type != RNDIS_MSG_INIT_C) {
        fprintf(stderr, "[RNDIS] Expected INIT_C, got 0x%08X\n", cmplt->msg_type);
        return RNDIS_ERROR_PROTOCOL;
    }
    if (cmplt->status != RNDIS_STATUS_SUCCESS) {
        fprintf(stderr, "[RNDIS] Init failed with status 0x%08X\n", cmplt->status);
        return RNDIS_ERROR_INIT_FAILED;
    }

    h->max_transfer_size = cmplt->max_transfer_size;
    fprintf(stderr, "[RNDIS] Initialized: max_transfer=%u, max_packets=%u, alignment=%u\n",
            cmplt->max_transfer_size, cmplt->max_packets_per_transfer,
            cmplt->packet_alignment_factor);

    return RNDIS_OK;
}

/// Query an OID value
static rndis_error_t rndis_query(rndis_handle_t *h, uint32_t oid,
                                  void *out, uint32_t out_len, uint32_t *actual_len) {
    rndis_query_msg_t msg = {
        .msg_type = RNDIS_MSG_QUERY,
        .msg_len = sizeof(msg),
        .request_id = ++h->request_id,
        .oid = oid,
        .info_buf_len = 0,
        .info_buf_offset = 0,
        .reserved = 0,
    };

    int ret = rndis_send_control(h, &msg, sizeof(msg));
    if (ret < 0) return RNDIS_ERROR_USB;

    uint8_t resp_buf[512];
    ret = rndis_get_response(h, resp_buf, sizeof(resp_buf));
    if (ret < (int)sizeof(rndis_query_cmplt_t)) return RNDIS_ERROR_PROTOCOL;

    rndis_query_cmplt_t *cmplt = (rndis_query_cmplt_t *)resp_buf;
    if (cmplt->msg_type != RNDIS_MSG_QUERY_C) return RNDIS_ERROR_PROTOCOL;
    if (cmplt->status != RNDIS_STATUS_SUCCESS) return RNDIS_ERROR_PROTOCOL;

    // Data starts at offset from request_id (byte 8 of the message)
    uint32_t data_start = 8 + cmplt->info_buf_offset;
    uint32_t copy_len = cmplt->info_buf_len < out_len ? cmplt->info_buf_len : out_len;
    if (data_start + copy_len <= (uint32_t)ret) {
        memcpy(out, resp_buf + data_start, copy_len);
        if (actual_len) *actual_len = copy_len;
    } else {
        return RNDIS_ERROR_PROTOCOL;
    }

    return RNDIS_OK;
}

/// Set an OID value
static rndis_error_t rndis_set(rndis_handle_t *h, uint32_t oid,
                                const void *data, uint32_t data_len) {
    uint8_t buf[256];
    rndis_set_msg_t *msg = (rndis_set_msg_t *)buf;
    memset(buf, 0, sizeof(buf));

    msg->msg_type = RNDIS_MSG_SET;
    msg->msg_len = sizeof(rndis_set_msg_t) + data_len;
    msg->request_id = ++h->request_id;
    msg->oid = oid;
    msg->info_buf_len = data_len;
    msg->info_buf_offset = 20;  // offset from request_id to end of rndis_set_msg_t header
    msg->reserved = 0;
    memcpy(buf + sizeof(rndis_set_msg_t), data, data_len);

    int ret = rndis_send_control(h, buf, msg->msg_len);
    if (ret < 0) return RNDIS_ERROR_USB;

    uint8_t resp_buf[128];
    ret = rndis_get_response(h, resp_buf, sizeof(resp_buf));
    if (ret < (int)sizeof(rndis_set_cmplt_t)) return RNDIS_ERROR_PROTOCOL;

    rndis_set_cmplt_t *cmplt = (rndis_set_cmplt_t *)resp_buf;
    if (cmplt->msg_type != RNDIS_MSG_SET_C) return RNDIS_ERROR_PROTOCOL;
    if (cmplt->status != RNDIS_STATUS_SUCCESS) {
        fprintf(stderr, "[RNDIS] Set OID 0x%08X failed: status 0x%08X\n", oid, cmplt->status);
        return RNDIS_ERROR_PROTOCOL;
    }

    return RNDIS_OK;
}

/// Query the device's permanent MAC address
static rndis_error_t rndis_query_mac(rndis_handle_t *h) {
    uint8_t mac[6];
    uint32_t actual = 0;
    rndis_error_t err = rndis_query(h, OID_802_3_PERMANENT_ADDRESS, mac, 6, &actual);
    if (err == RNDIS_OK && actual == 6) {
        memcpy(h->device_mac, mac, 6);
        h->have_device_mac = true;
        fprintf(stderr, "[RNDIS] Device MAC: %02X:%02X:%02X:%02X:%02X:%02X\n",
                mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
    }
    return err;
}

/// Set the packet filter to receive directed + broadcast frames
static rndis_error_t rndis_set_filter(rndis_handle_t *h) {
    uint32_t filter = NDIS_PACKET_TYPE_DIRECTED | NDIS_PACKET_TYPE_BROADCAST |
                      NDIS_PACKET_TYPE_ALL_MULTICAST;
    return rndis_set(h, OID_GEN_CURRENT_PACKET_FILTER, &filter, sizeof(filter));
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

rndis_handle_t *rndis_open(uint16_t vid, uint16_t pid) {
    fprintf(stderr, "[RNDIS] Opening device VID=0x%04X PID=0x%04X\n", vid, pid);

    hakchi_usb_error_t usb_err;
    hakchi_usb_device_t *usb = hakchi_usb_open_rndis(vid, pid, &usb_err);
    if (!usb) {
        fprintf(stderr, "[RNDIS] USB open failed: %d\n", usb_err);
        return NULL;
    }

    rndis_handle_t *h = calloc(1, sizeof(rndis_handle_t));
    h->usb = usb;
    h->request_id = 0;

    // Our host MAC — locally administered, unique-ish
    h->host_mac[0] = 0x02;  // locally administered
    h->host_mac[1] = 0x48;  // 'H'
    h->host_mac[2] = 0x41;  // 'A'
    h->host_mac[3] = 0x4B;  // 'K'
    h->host_mac[4] = 0x43;  // 'C'
    h->host_mac[5] = 0x48;  // 'H'

    // RNDIS initialization sequence
    rndis_error_t err = rndis_init_device(h);
    if (err != RNDIS_OK) {
        fprintf(stderr, "[RNDIS] Init failed: %d\n", err);
        hakchi_usb_close(usb);
        free(h);
        return NULL;
    }

    // Query device MAC (informational, not critical)
    rndis_query_mac(h);

    // Set packet filter
    err = rndis_set_filter(h);
    if (err != RNDIS_OK) {
        fprintf(stderr, "[RNDIS] Warning: set filter failed: %d\n", err);
        // Non-fatal — some devices work without it
    }

    // Allocate reusable receive buffer
    h->recv_buf_size = h->max_transfer_size > 0 ? h->max_transfer_size : 16384;
    h->recv_buf = malloc(h->recv_buf_size);

    fprintf(stderr, "[RNDIS] Device ready\n");
    return h;
}

uint32_t rndis_max_transfer_size(rndis_handle_t *h) {
    return h ? h->max_transfer_size : 0;
}

bool rndis_get_device_mac(rndis_handle_t *h, uint8_t mac_out[6]) {
    if (!h || !h->have_device_mac) return false;
    memcpy(mac_out, h->device_mac, 6);
    return true;
}

void rndis_get_host_mac(rndis_handle_t *h, uint8_t mac_out[6]) {
    if (!h) return;
    memcpy(mac_out, h->host_mac, 6);
}

int rndis_send_packet(rndis_handle_t *h, const uint8_t *eth_frame, uint32_t len) {
    if (!h || !h->usb) return RNDIS_ERROR_USB;

    // Build RNDIS_MSG_PACKET wrapping the Ethernet frame
    uint32_t total_len = sizeof(rndis_packet_hdr_t) + len;
    uint8_t *pkt = malloc(total_len);
    if (!pkt) return RNDIS_ERROR_USB;

    rndis_packet_hdr_t *hdr = (rndis_packet_hdr_t *)pkt;
    memset(hdr, 0, sizeof(*hdr));
    hdr->msg_type = RNDIS_MSG_PACKET;
    hdr->msg_len = total_len;
    hdr->data_offset = 36;     // offset from data_offset field to payload
    hdr->data_len = len;

    memcpy(pkt + sizeof(rndis_packet_hdr_t), eth_frame, len);

    uint8_t pipe_out = hakchi_usb_get_pipe_out(h->usb);
    int ret = hakchi_usb_bulk_write_pipe(h->usb, pipe_out, pkt, total_len, 5000);
    free(pkt);

    if (ret < 0) return ret;
    return (int)len;
}

int rndis_recv_packet(rndis_handle_t *h, uint8_t *buf, uint32_t buf_len,
                       int timeout_ms) {
    if (!h || !h->usb) return RNDIS_ERROR_USB;

    uint8_t pipe_in = hakchi_usb_get_pipe_in(h->usb);
    int ret = hakchi_usb_bulk_read_pipe(h->usb, pipe_in, h->recv_buf,
                                         h->recv_buf_size, timeout_ms);
    if (ret < 0) {
        if (ret == HAKCHI_USB_ERROR_TIMEOUT) return 0; // timeout → no packet
        return ret;
    }
    if (ret < (int)sizeof(rndis_packet_hdr_t)) return 0;

    rndis_packet_hdr_t *hdr = (rndis_packet_hdr_t *)h->recv_buf;

    // Handle keepalive messages transparently
    if (hdr->msg_type == RNDIS_MSG_KEEPALIVE) {
        rndis_keepalive_cmplt_t resp = {
            .msg_type = RNDIS_MSG_KEEPALIVE_C,
            .msg_len = sizeof(resp),
            .request_id = ((uint32_t *)(h->recv_buf))[2],
            .status = RNDIS_STATUS_SUCCESS,
        };
        rndis_send_control(h, &resp, sizeof(resp));
        return 0; // no data packet
    }

    if (hdr->msg_type != RNDIS_MSG_PACKET) {
        // Not a data packet — ignore
        return 0;
    }

    // Extract Ethernet frame from RNDIS packet
    uint32_t data_start = 8 + hdr->data_offset; // 8 = offset of data_offset field
    uint32_t data_len = hdr->data_len;

    if (data_start + data_len > (uint32_t)ret) {
        fprintf(stderr, "[RNDIS] Truncated packet: start=%u len=%u total=%d\n",
                data_start, data_len, ret);
        return 0;
    }

    if (data_len > buf_len) data_len = buf_len;
    memcpy(buf, h->recv_buf + data_start, data_len);
    return (int)data_len;
}

void rndis_close(rndis_handle_t *h) {
    if (!h) return;

    if (h->usb) {
        // Send RNDIS_MSG_HALT
        rndis_halt_msg_t halt = {
            .msg_type = RNDIS_MSG_HALT,
            .msg_len = sizeof(halt),
            .request_id = ++h->request_id,
        };
        rndis_send_control(h, &halt, sizeof(halt));
        hakchi_usb_close(h->usb);
    }

    free(h->recv_buf);
    free(h);
}

bool rndis_device_exists(uint16_t vid, uint16_t pid) {
    return hakchi_usb_device_exists(vid, pid);
}
