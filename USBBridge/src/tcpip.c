/**
 * Minimal TCP/IP stack for user-space RNDIS networking.
 *
 * Implements just enough of ARP, IPv4, and TCP to support a single
 * SSH connection over a direct USB-RNDIS link. No routing, no
 * fragmentation, minimal retransmission.
 *
 * All multi-byte fields are in network byte order unless noted.
 */

#include "tcpip.h"
#include "rndis.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <arpa/inet.h>  // htons, ntohs, htonl, ntohl

// ---------------------------------------------------------------------------
// Constants
// ---------------------------------------------------------------------------

#define ETH_HEADER_LEN   14
#define ETH_TYPE_ARP     0x0806
#define ETH_TYPE_IP      0x0800

#define IP_HEADER_LEN    20
#define IP_PROTO_TCP     6

#define TCP_HEADER_LEN   20     // without options
#define TCP_OPT_MSS_LEN  4     // MSS option: kind(1) + len(1) + mss(2)

// TCP flags
#define TCP_FIN  0x01
#define TCP_SYN  0x02
#define TCP_RST  0x04
#define TCP_PSH  0x08
#define TCP_ACK  0x10

// ARP
#define ARP_HW_ETHERNET 1
#define ARP_OP_REQUEST   1
#define ARP_OP_REPLY     2

// Sizes
#define MAX_FRAME_SIZE   1518
#define TCP_MSS          1460
#define TCP_WINDOW_SIZE  (TCP_MSS * 8)  // 11680 bytes
#define TCP_RECV_BUF_SIZE (TCP_MSS * 16) // 23360 bytes ring buffer

// Retransmission
#define TCP_MAX_RETRIES  5
#define TCP_RETRANSMIT_MS 500

// ---------------------------------------------------------------------------
// Ethernet header
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    uint8_t  dst_mac[6];
    uint8_t  src_mac[6];
    uint16_t ethertype;
} eth_header_t;

// ---------------------------------------------------------------------------
// ARP packet
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    uint16_t hw_type;
    uint16_t proto_type;
    uint8_t  hw_len;
    uint8_t  proto_len;
    uint16_t opcode;
    uint8_t  sender_mac[6];
    uint32_t sender_ip;
    uint8_t  target_mac[6];
    uint32_t target_ip;
} arp_packet_t;

// ---------------------------------------------------------------------------
// IPv4 header
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    uint8_t  ver_ihl;
    uint8_t  tos;
    uint16_t total_len;
    uint16_t identification;
    uint16_t flags_frag;
    uint8_t  ttl;
    uint8_t  protocol;
    uint16_t checksum;
    uint32_t src_ip;
    uint32_t dst_ip;
} ip_header_t;

// ---------------------------------------------------------------------------
// TCP header
// ---------------------------------------------------------------------------

typedef struct __attribute__((packed)) {
    uint16_t src_port;
    uint16_t dst_port;
    uint32_t seq;
    uint32_t ack;
    uint8_t  data_offset;   // upper 4 bits = header len in 32-bit words
    uint8_t  flags;
    uint16_t window;
    uint16_t checksum;
    uint16_t urgent;
} tcp_header_t;

// TCP pseudo-header for checksum
typedef struct __attribute__((packed)) {
    uint32_t src_ip;
    uint32_t dst_ip;
    uint8_t  zero;
    uint8_t  protocol;
    uint16_t tcp_len;
} tcp_pseudo_header_t;

// ---------------------------------------------------------------------------
// TCP connection state
// ---------------------------------------------------------------------------

typedef enum {
    TCP_STATE_CLOSED,
    TCP_STATE_SYN_SENT,
    TCP_STATE_ESTABLISHED,
    TCP_STATE_FIN_WAIT_1,
    TCP_STATE_FIN_WAIT_2,
    TCP_STATE_CLOSING,
    TCP_STATE_TIME_WAIT,
    TCP_STATE_CLOSE_WAIT,
    TCP_STATE_LAST_ACK,
} tcp_state_t;

struct tcp_conn {
    rndis_handle_t *rndis;

    // Addresses
    uint32_t src_ip;
    uint32_t dst_ip;
    uint16_t src_port;
    uint16_t dst_port;

    // MAC addresses
    uint8_t src_mac[6];
    uint8_t dst_mac[6];

    // TCP state
    tcp_state_t state;
    uint32_t seq_num;       // our next sequence number
    uint32_t ack_num;       // what we've acknowledged from peer
    uint32_t peer_window;

    // Receive ring buffer — stores TCP payload so it isn't lost
    // when data arrives during tcp_send's ACK-wait loop
    uint8_t recv_buf[TCP_RECV_BUF_SIZE];
    uint32_t recv_head;     // write position
    uint32_t recv_tail;     // read position

    // Frame scratch buffer for rndis_recv_packet
    uint8_t frame_buf[MAX_FRAME_SIZE];
};

// ---------------------------------------------------------------------------
// Ring buffer helpers
// ---------------------------------------------------------------------------

static uint32_t ringbuf_used(const tcp_conn_t *c) {
    return c->recv_head - c->recv_tail;
}

static void ringbuf_write(tcp_conn_t *c, const uint8_t *data, uint32_t len) {
    for (uint32_t i = 0; i < len; i++) {
        if (ringbuf_used(c) >= TCP_RECV_BUF_SIZE) {
            fprintf(stderr, "[TCP] Recv buffer overflow, dropping data\n");
            break;
        }
        c->recv_buf[c->recv_head % TCP_RECV_BUF_SIZE] = data[i];
        c->recv_head++;
    }
}

static uint32_t ringbuf_read(tcp_conn_t *c, uint8_t *out, uint32_t max_len) {
    uint32_t avail = ringbuf_used(c);
    uint32_t to_read = avail < max_len ? avail : max_len;
    for (uint32_t i = 0; i < to_read; i++) {
        out[i] = c->recv_buf[c->recv_tail % TCP_RECV_BUF_SIZE];
        c->recv_tail++;
    }
    return to_read;
}

// ---------------------------------------------------------------------------
// Timing helpers
// ---------------------------------------------------------------------------

static uint64_t now_ms(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ---------------------------------------------------------------------------
// Checksum helpers
// ---------------------------------------------------------------------------

static uint16_t ip_checksum(const void *data, int len) {
    const uint16_t *p = (const uint16_t *)data;
    uint32_t sum = 0;
    while (len > 1) {
        sum += *p++;
        len -= 2;
    }
    if (len == 1) {
        sum += *(const uint8_t *)p;
    }
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16_t)~sum;
}

static uint16_t tcp_checksum(const ip_header_t *ip, const tcp_header_t *tcp,
                              const uint8_t *payload, uint16_t payload_len) {
    uint16_t tcp_hdr_len = (tcp->data_offset >> 4) * 4;
    uint16_t tcp_total = tcp_hdr_len + payload_len;

    // Allocate buffer for pseudo-header + TCP header + payload
    uint32_t buf_len = sizeof(tcp_pseudo_header_t) + tcp_total;
    uint8_t *buf = malloc(buf_len);

    tcp_pseudo_header_t *pseudo = (tcp_pseudo_header_t *)buf;
    pseudo->src_ip = ip->src_ip;
    pseudo->dst_ip = ip->dst_ip;
    pseudo->zero = 0;
    pseudo->protocol = IP_PROTO_TCP;
    pseudo->tcp_len = htons(tcp_total);

    memcpy(buf + sizeof(tcp_pseudo_header_t), tcp, tcp_hdr_len);
    if (payload_len > 0 && payload) {
        memcpy(buf + sizeof(tcp_pseudo_header_t) + tcp_hdr_len, payload, payload_len);
    }

    // Zero the checksum field in the copy
    tcp_header_t *tcp_copy = (tcp_header_t *)(buf + sizeof(tcp_pseudo_header_t));
    tcp_copy->checksum = 0;

    uint16_t cksum = ip_checksum(buf, buf_len);
    free(buf);
    return cksum;
}

// ---------------------------------------------------------------------------
// Frame construction helpers
// ---------------------------------------------------------------------------

static void build_eth_header(uint8_t *frame, const uint8_t *dst_mac,
                              const uint8_t *src_mac, uint16_t ethertype) {
    eth_header_t *eth = (eth_header_t *)frame;
    memcpy(eth->dst_mac, dst_mac, 6);
    memcpy(eth->src_mac, src_mac, 6);
    eth->ethertype = htons(ethertype);
}

static void build_ip_header(ip_header_t *ip, uint32_t src, uint32_t dst,
                              uint8_t protocol, uint16_t payload_len) {
    memset(ip, 0, sizeof(*ip));
    ip->ver_ihl = 0x45;        // IPv4, 5 words (20 bytes)
    ip->total_len = htons(IP_HEADER_LEN + payload_len);
    ip->identification = htons(rand() & 0xFFFF);
    ip->flags_frag = htons(0x4000);  // Don't Fragment
    ip->ttl = 64;
    ip->protocol = protocol;
    ip->src_ip = src;
    ip->dst_ip = dst;
    ip->checksum = 0;
    ip->checksum = ip_checksum(ip, IP_HEADER_LEN);
}

/// Build and send a TCP segment. Returns bytes sent or negative error.
static int send_tcp_segment(tcp_conn_t *c, uint8_t flags,
                             const uint8_t *payload, uint16_t payload_len,
                             const uint8_t *tcp_options, uint8_t options_len) {
    uint8_t tcp_hdr_len = TCP_HEADER_LEN + options_len;
    // Round up to 4-byte boundary
    tcp_hdr_len = (tcp_hdr_len + 3) & ~3;
    uint16_t ip_payload_len = tcp_hdr_len + payload_len;

    uint8_t frame[MAX_FRAME_SIZE];
    uint32_t frame_len = ETH_HEADER_LEN + IP_HEADER_LEN + ip_payload_len;

    // Ethernet
    build_eth_header(frame, c->dst_mac, c->src_mac, ETH_TYPE_IP);

    // IP
    ip_header_t *ip = (ip_header_t *)(frame + ETH_HEADER_LEN);
    build_ip_header(ip, c->src_ip, c->dst_ip, IP_PROTO_TCP, ip_payload_len);

    // TCP
    tcp_header_t *tcp = (tcp_header_t *)(frame + ETH_HEADER_LEN + IP_HEADER_LEN);
    memset(tcp, 0, tcp_hdr_len);
    tcp->src_port = htons(c->src_port);
    tcp->dst_port = htons(c->dst_port);
    tcp->seq = htonl(c->seq_num);
    tcp->ack = htonl(c->ack_num);
    tcp->data_offset = (tcp_hdr_len / 4) << 4;
    tcp->flags = flags;
    tcp->window = htons(TCP_WINDOW_SIZE);

    // Copy TCP options if any
    if (options_len > 0 && tcp_options) {
        memcpy((uint8_t *)tcp + TCP_HEADER_LEN, tcp_options, options_len);
    }

    // Copy payload
    if (payload_len > 0 && payload) {
        memcpy(frame + ETH_HEADER_LEN + IP_HEADER_LEN + tcp_hdr_len,
               payload, payload_len);
    }

    // TCP checksum
    tcp->checksum = tcp_checksum(ip, tcp,
                                  payload_len > 0 ? payload : NULL,
                                  payload_len);

    return rndis_send_packet(c->rndis, frame, frame_len);
}

// ---------------------------------------------------------------------------
// Frame reception and dispatch
// ---------------------------------------------------------------------------

/// Process one received frame. Returns:
///   > 0: TCP payload bytes buffered into ring buffer
///   0: non-data frame processed (ARP reply, ACK, etc.)
///   < 0: error (RST, etc.)
static int process_frame(tcp_conn_t *c, const uint8_t *frame, int frame_len) {
    if (frame_len < ETH_HEADER_LEN) return 0;

    eth_header_t *eth = (eth_header_t *)frame;
    uint16_t ethertype = ntohs(eth->ethertype);

    // Handle ARP requests for our IP
    if (ethertype == ETH_TYPE_ARP && frame_len >= ETH_HEADER_LEN + (int)sizeof(arp_packet_t)) {
        arp_packet_t *arp = (arp_packet_t *)(frame + ETH_HEADER_LEN);
        if (ntohs(arp->opcode) == ARP_OP_REQUEST && arp->target_ip == c->src_ip) {
            // Reply with our MAC
            uint8_t reply[ETH_HEADER_LEN + sizeof(arp_packet_t)];
            build_eth_header(reply, arp->sender_mac, c->src_mac, ETH_TYPE_ARP);
            arp_packet_t *reply_arp = (arp_packet_t *)(reply + ETH_HEADER_LEN);
            reply_arp->hw_type = htons(ARP_HW_ETHERNET);
            reply_arp->proto_type = htons(ETH_TYPE_IP);
            reply_arp->hw_len = 6;
            reply_arp->proto_len = 4;
            reply_arp->opcode = htons(ARP_OP_REPLY);
            memcpy(reply_arp->sender_mac, c->src_mac, 6);
            reply_arp->sender_ip = c->src_ip;
            memcpy(reply_arp->target_mac, arp->sender_mac, 6);
            reply_arp->target_ip = arp->sender_ip;
            rndis_send_packet(c->rndis, reply, sizeof(reply));
        }
        return 0;
    }

    // Only handle IPv4+TCP from here
    if (ethertype != ETH_TYPE_IP) return 0;
    if (frame_len < ETH_HEADER_LEN + IP_HEADER_LEN + TCP_HEADER_LEN) return 0;

    ip_header_t *ip = (ip_header_t *)(frame + ETH_HEADER_LEN);
    if (ip->protocol != IP_PROTO_TCP) return 0;
    if (ip->src_ip != c->dst_ip || ip->dst_ip != c->src_ip) return 0;

    uint8_t ip_hdr_len = (ip->ver_ihl & 0x0F) * 4;
    tcp_header_t *tcp = (tcp_header_t *)(frame + ETH_HEADER_LEN + ip_hdr_len);
    uint8_t tcp_hdr_len = (tcp->data_offset >> 4) * 4;

    if (ntohs(tcp->src_port) != c->dst_port || ntohs(tcp->dst_port) != c->src_port) return 0;

    uint16_t ip_total = ntohs(ip->total_len);
    uint16_t payload_len = ip_total - ip_hdr_len - tcp_hdr_len;
    const uint8_t *payload = frame + ETH_HEADER_LEN + ip_hdr_len + tcp_hdr_len;

    uint32_t peer_seq = ntohl(tcp->seq);
    uint32_t peer_ack = ntohl(tcp->ack);
    uint8_t  flags = tcp->flags;

    // Handle RST
    if (flags & TCP_RST) {
        fprintf(stderr, "[TCP] Received RST\n");
        c->state = TCP_STATE_CLOSED;
        return TCP_ERROR_RESET;
    }

    // Update peer window
    c->peer_window = ntohs(tcp->window);

    // State machine
    switch (c->state) {
    case TCP_STATE_SYN_SENT:
        if ((flags & (TCP_SYN | TCP_ACK)) == (TCP_SYN | TCP_ACK)) {
            c->ack_num = peer_seq + 1;
            c->seq_num = peer_ack;  // their ACK of our SYN
            c->state = TCP_STATE_ESTABLISHED;
            // Send ACK to complete handshake
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            return 0;
        }
        break;

    case TCP_STATE_ESTABLISHED:
    case TCP_STATE_CLOSE_WAIT:
        // ACK received data
        if (flags & TCP_ACK) {
            // peer_ack acknowledges our data up to this point
        }

        if (payload_len > 0 && peer_seq == c->ack_num) {
            c->ack_num = peer_seq + payload_len;
            // Send ACK
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            // Buffer payload into ring buffer
            ringbuf_write(c, payload, payload_len);
            if (flags & TCP_FIN) {
                c->ack_num++;
                send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
                c->state = TCP_STATE_CLOSE_WAIT;
            }
            return (int)payload_len;
        }

        if (flags & TCP_FIN) {
            c->ack_num = peer_seq + 1;
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            c->state = TCP_STATE_CLOSE_WAIT;
            return TCP_ERROR_CLOSED;
        }
        break;

    case TCP_STATE_FIN_WAIT_1:
        if ((flags & TCP_ACK) && (flags & TCP_FIN)) {
            c->ack_num = peer_seq + 1;
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            c->state = TCP_STATE_TIME_WAIT;
        } else if (flags & TCP_ACK) {
            c->state = TCP_STATE_FIN_WAIT_2;
        } else if (flags & TCP_FIN) {
            c->ack_num = peer_seq + 1;
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            c->state = TCP_STATE_CLOSING;
        }
        break;

    case TCP_STATE_FIN_WAIT_2:
        if (flags & TCP_FIN) {
            c->ack_num = peer_seq + 1;
            send_tcp_segment(c, TCP_ACK, NULL, 0, NULL, 0);
            c->state = TCP_STATE_TIME_WAIT;
        }
        break;

    case TCP_STATE_CLOSING:
        if (flags & TCP_ACK) {
            c->state = TCP_STATE_TIME_WAIT;
        }
        break;

    case TCP_STATE_LAST_ACK:
        if (flags & TCP_ACK) {
            c->state = TCP_STATE_CLOSED;
        }
        break;

    default:
        break;
    }

    return 0;
}

/// Receive and process frames until we get TCP data or timeout.
/// Data is buffered in the ring buffer. Returns > 0 if data was buffered,
/// 0 on timeout, or negative error.
/// If return_on_any_frame is true, returns 0 as soon as any valid TCP frame
/// is processed (including ACK-only frames with no payload). This avoids
/// blocking on ACK-wait during writes.
static int recv_and_process(tcp_conn_t *c, int timeout_ms, bool return_on_any_frame) {
    uint64_t deadline = now_ms() + timeout_ms;

    while (now_ms() < deadline) {
        int remaining = (int)(deadline - now_ms());
        if (remaining <= 0) break;
        if (remaining > 500) remaining = 500; // poll in 500ms chunks

        int frame_len = rndis_recv_packet(c->rndis, c->frame_buf,
                                           sizeof(c->frame_buf), remaining);
        if (frame_len <= 0) continue;

        int result = process_frame(c, c->frame_buf, frame_len);
        if (result != 0) return result; // data buffered or error
        if (return_on_any_frame) return 0; // ACK processed, return immediately
    }

    return 0; // timeout
}

// ---------------------------------------------------------------------------
// ARP resolution
// ---------------------------------------------------------------------------

/// Resolve the MAC address for an IP via ARP.
static bool arp_resolve(tcp_conn_t *c, int timeout_ms) {
    uint8_t frame[ETH_HEADER_LEN + sizeof(arp_packet_t)];
    uint8_t broadcast[6] = {0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF};

    build_eth_header(frame, broadcast, c->src_mac, ETH_TYPE_ARP);

    arp_packet_t *arp = (arp_packet_t *)(frame + ETH_HEADER_LEN);
    arp->hw_type = htons(ARP_HW_ETHERNET);
    arp->proto_type = htons(ETH_TYPE_IP);
    arp->hw_len = 6;
    arp->proto_len = 4;
    arp->opcode = htons(ARP_OP_REQUEST);
    memcpy(arp->sender_mac, c->src_mac, 6);
    arp->sender_ip = c->src_ip;
    memset(arp->target_mac, 0, 6);
    arp->target_ip = c->dst_ip;

    uint64_t deadline = now_ms() + timeout_ms;

    for (int attempt = 0; attempt < 10 && now_ms() < deadline; attempt++) {
        rndis_send_packet(c->rndis, frame, sizeof(frame));

        // Wait for ARP reply
        uint64_t wait_until = now_ms() + 1000; // 1s per attempt
        while (now_ms() < wait_until && now_ms() < deadline) {
            int remaining = (int)(wait_until - now_ms());
            if (remaining <= 0) break;

            uint8_t recv_buf[MAX_FRAME_SIZE];
            int len = rndis_recv_packet(c->rndis, recv_buf, sizeof(recv_buf), remaining);
            if (len < ETH_HEADER_LEN + (int)sizeof(arp_packet_t)) continue;

            eth_header_t *eth = (eth_header_t *)recv_buf;
            if (ntohs(eth->ethertype) != ETH_TYPE_ARP) continue;

            arp_packet_t *reply = (arp_packet_t *)(recv_buf + ETH_HEADER_LEN);
            if (ntohs(reply->opcode) == ARP_OP_REPLY &&
                reply->sender_ip == c->dst_ip) {
                memcpy(c->dst_mac, reply->sender_mac, 6);
                fprintf(stderr, "[TCP] ARP resolved %s → %02X:%02X:%02X:%02X:%02X:%02X\n",
                        "console", c->dst_mac[0], c->dst_mac[1], c->dst_mac[2],
                        c->dst_mac[3], c->dst_mac[4], c->dst_mac[5]);
                return true;
            }
        }
    }

    fprintf(stderr, "[TCP] ARP resolution failed\n");
    return false;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

uint32_t tcp_ip_addr(const char *dotted) {
    struct in_addr addr;
    if (inet_pton(AF_INET, dotted, &addr) == 1) {
        return addr.s_addr;
    }
    return 0;
}

tcp_conn_t *tcp_connect(rndis_handle_t *rndis,
                         uint32_t src_ip, uint32_t dst_ip,
                         uint16_t dst_port, int timeout_ms) {
    if (!rndis) return NULL;

    fprintf(stderr, "[TCP] Connecting to port %d\n", dst_port);

    tcp_conn_t *c = calloc(1, sizeof(tcp_conn_t));
    c->rndis = rndis;
    c->src_ip = src_ip;
    c->dst_ip = dst_ip;
    c->src_port = 49152 + (rand() % 16384); // ephemeral port
    c->dst_port = dst_port;
    c->state = TCP_STATE_CLOSED;

    // Set our MAC from RNDIS
    rndis_get_host_mac(rndis, c->src_mac);

    // Initial sequence number
    c->seq_num = (uint32_t)rand();

    // ARP: resolve console's MAC
    if (!arp_resolve(c, timeout_ms > 10000 ? 10000 : timeout_ms)) {
        free(c);
        return NULL;
    }

    // TCP 3-way handshake: send SYN
    c->state = TCP_STATE_SYN_SENT;

    // SYN with MSS option
    uint8_t syn_options[TCP_OPT_MSS_LEN];
    syn_options[0] = 2;  // MSS option kind
    syn_options[1] = 4;  // MSS option length
    syn_options[2] = (TCP_MSS >> 8) & 0xFF;
    syn_options[3] = TCP_MSS & 0xFF;

    uint64_t deadline = now_ms() + timeout_ms;

    for (int attempt = 0; attempt < TCP_MAX_RETRIES && now_ms() < deadline; attempt++) {
        send_tcp_segment(c, TCP_SYN, NULL, 0, syn_options, TCP_OPT_MSS_LEN);
        c->seq_num++; // SYN consumes one sequence number

        // Wait for SYN-ACK
        int remaining = (int)(deadline - now_ms());
        if (remaining <= 0) break;
        if (remaining > 3000) remaining = 3000;

        int result = recv_and_process(c, remaining, false);
        if (c->state == TCP_STATE_ESTABLISHED) {
            fprintf(stderr, "[TCP] Connected! seq=%u ack=%u\n", c->seq_num, c->ack_num);
            return c;
        }
        if (result == TCP_ERROR_RESET || result == TCP_ERROR_REFUSED) {
            fprintf(stderr, "[TCP] Connection refused\n");
            free(c);
            return NULL;
        }

        // Retry — reset seq for SYN retransmit
        c->seq_num--;
        c->state = TCP_STATE_SYN_SENT;
    }

    fprintf(stderr, "[TCP] Connection timed out\n");
    free(c);
    return NULL;
}

int tcp_send(tcp_conn_t *c, const uint8_t *data, uint32_t len, int timeout_ms) {
    if (!c || c->state != TCP_STATE_ESTABLISHED) return TCP_ERROR_CLOSED;
    if (len > 4096) {
        fprintf(stderr, "[TCP] send: %u bytes, peer_window=%u\n", len, c->peer_window);
    }

    uint32_t sent = 0;
    uint64_t deadline = now_ms() + timeout_ms;
    int segments_since_poll = 0;

    while (sent < len && now_ms() < deadline) {
        uint32_t chunk = len - sent;
        if (chunk > TCP_MSS) chunk = TCP_MSS;

        // Only set PSH on last segment of the batch
        uint8_t flags = TCP_ACK;
        if (sent + chunk >= len) flags |= TCP_PSH;

        int ret = send_tcp_segment(c, flags, data + sent, chunk, NULL, 0);
        if (ret < 0) return ret;

        c->seq_num += chunk;
        sent += chunk;
        segments_since_poll++;

        // Every 8 segments (~11KB), poll briefly for ACKs and incoming data.
        // This prevents overrunning the peer's receive window on a USB link.
        if (segments_since_poll >= 8) {
            recv_and_process(c, 1, true); // 1ms quick poll, return on ACK
            segments_since_poll = 0;
            if (c->state == TCP_STATE_CLOSED) return TCP_ERROR_RESET;
        }
    }

    // Final poll to process trailing ACKs
    if (sent > 0) {
        recv_and_process(c, 50, true);
    }

    return (int)sent;
}

int tcp_recv(tcp_conn_t *c, uint8_t *buf, uint32_t len, int timeout_ms) {
    if (!c) return TCP_ERROR_PARAM;
    if (c->state != TCP_STATE_ESTABLISHED && c->state != TCP_STATE_CLOSE_WAIT) {
        return TCP_ERROR_CLOSED;
    }

    // First, drain any data already in the ring buffer
    uint32_t buffered = ringbuf_read(c, buf, len);
    if (buffered > 0) return (int)buffered;

    // No buffered data — receive from network until data arrives or timeout
    uint64_t deadline = now_ms() + timeout_ms;
    while (now_ms() < deadline) {
        int remaining = (int)(deadline - now_ms());
        if (remaining <= 0) break;

        int result = recv_and_process(c, remaining, false);
        if (result < 0) return result; // error

        // Check if data was buffered
        buffered = ringbuf_read(c, buf, len);
        if (buffered > 0) return (int)buffered;
    }

    return 0; // timeout
}

void tcp_poll(tcp_conn_t *c, int timeout_ms) {
    if (!c) return;
    if (c->state != TCP_STATE_ESTABLISHED && c->state != TCP_STATE_CLOSE_WAIT) return;
    recv_and_process(c, timeout_ms, false);
}

void tcp_close(tcp_conn_t *c) {
    if (!c) return;

    if (c->state == TCP_STATE_ESTABLISHED) {
        // Send FIN
        c->state = TCP_STATE_FIN_WAIT_1;
        send_tcp_segment(c, TCP_FIN | TCP_ACK, NULL, 0, NULL, 0);
        c->seq_num++; // FIN consumes one

        // Wait for FIN-ACK (best effort)
        recv_and_process(c, 2000, false);
    } else if (c->state == TCP_STATE_CLOSE_WAIT) {
        // Peer already sent FIN, we send ours
        c->state = TCP_STATE_LAST_ACK;
        send_tcp_segment(c, TCP_FIN | TCP_ACK, NULL, 0, NULL, 0);
        c->seq_num++;
        recv_and_process(c, 2000, false);
    }

    free(c);
}
