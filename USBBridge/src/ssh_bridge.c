/**
 * SSH bridge: libssh2 over user-space TCP/IP over RNDIS.
 *
 * Uses libssh2's custom transport callbacks to route SSH traffic
 * through our minimal TCP/IP stack instead of a real socket.
 */

#include "ssh_bridge.h"
#include "rndis.h"
#include "tcpip.h"

#include <libssh2.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <errno.h>
#include <time.h>
#include <unistd.h>
#include <sys/socket.h>

// ---------------------------------------------------------------------------
// Timing helper
// ---------------------------------------------------------------------------

static uint64_t now_ms_ssh(void) {
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (uint64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}

// ---------------------------------------------------------------------------
// Session structure
// ---------------------------------------------------------------------------

struct ssh_session {
    rndis_handle_t   *rndis;
    tcp_conn_t       *tcp;
    LIBSSH2_SESSION  *ssh;
    libssh2_socket_t  dummy_sock;  // kept open for libssh2's fcntl calls
    int               recv_timeout_ms;  // timeout for recv callback (adjustable)
};

// ---------------------------------------------------------------------------
// libssh2 custom transport callbacks
// ---------------------------------------------------------------------------

/// libssh2 send callback — routes through our TCP stack
static ssize_t ssh_send_cb(libssh2_socket_t fd, const void *buf, size_t len,
                             int flags, void **abstract) {
    (void)fd; (void)flags;
    ssh_session_t *s = (ssh_session_t *)*abstract;
    if (!s || !s->tcp) return -1;

    int ret = tcp_send(s->tcp, (const uint8_t *)buf, (uint32_t)len, 30000);
    if (ret < 0) {
        fprintf(stderr, "[SSH] send_cb: tcp_send failed: %d (len=%zu)\n", ret, len);
        errno = ECONNRESET;
        return -1;
    }
    return (ssize_t)ret;
}

/// libssh2 recv callback — routes through our TCP stack
static ssize_t ssh_recv_cb(libssh2_socket_t fd, void *buf, size_t len,
                             int flags, void **abstract) {
    (void)fd; (void)flags;
    ssh_session_t *s = (ssh_session_t *)*abstract;
    if (!s || !s->tcp) return -1;

    int ret = tcp_recv(s->tcp, (uint8_t *)buf, (uint32_t)len, s->recv_timeout_ms);
    if (ret == 0) {
        // Timeout — tell libssh2 to try again
        errno = EAGAIN;
        return -EAGAIN;
    }
    if (ret < 0) {
        fprintf(stderr, "[SSH] recv_cb: tcp_recv error: %d\n", ret);
        errno = ECONNRESET;
        return -1;
    }
    return (ssize_t)ret;
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

ssh_session_t *ssh_session_open(uint16_t vid, uint16_t pid,
                                 const char *host_ip, const char *remote_ip) {
    fprintf(stderr, "[SSH] Opening session\n");

    // Initialize libssh2
    int rc = libssh2_init(0);
    if (rc != 0) {
        fprintf(stderr, "[SSH] libssh2_init failed: %d\n", rc);
        return NULL;
    }

    // Step 1: Open RNDIS device
    rndis_handle_t *rndis = rndis_open(vid, pid);
    if (!rndis) {
        fprintf(stderr, "[SSH] RNDIS open failed\n");
        return NULL;
    }

    // Step 2: TCP connect to console:22
    uint32_t src_ip = tcp_ip_addr(host_ip);
    uint32_t dst_ip = tcp_ip_addr(remote_ip);
    tcp_conn_t *tcp = tcp_connect(rndis, src_ip, dst_ip, 22, 30000);
    if (!tcp) {
        fprintf(stderr, "[SSH] TCP connect failed\n");
        rndis_close(rndis);
        return NULL;
    }

    // Step 3: Create libssh2 session with custom transport
    ssh_session_t *s = calloc(1, sizeof(ssh_session_t));
    s->rndis = rndis;
    s->tcp = tcp;
    s->recv_timeout_ms = 30000; // default for handshake/auth

    s->ssh = libssh2_session_init_ex(NULL, NULL, NULL, s);
    if (!s->ssh) {
        fprintf(stderr, "[SSH] libssh2_session_init failed\n");
        tcp_close(tcp);
        rndis_close(rndis);
        free(s);
        return NULL;
    }

    // Set custom send/recv callbacks
    libssh2_session_callback_set2(s->ssh, LIBSSH2_CALLBACK_SEND, (libssh2_cb_generic *)ssh_send_cb);
    libssh2_session_callback_set2(s->ssh, LIBSSH2_CALLBACK_RECV, (libssh2_cb_generic *)ssh_recv_cb);

    // Set blocking mode
    libssh2_session_set_blocking(s->ssh, 1);
    libssh2_session_set_timeout(s->ssh, 30000);

    // Step 4: SSH handshake (uses our callbacks)
    // libssh2_session_handshake needs a valid socket fd — it calls
    // fcntl() on it even with custom callbacks. Create a real but unused socket.
    s->dummy_sock = socket(AF_INET, SOCK_STREAM, 0);
    if (s->dummy_sock < 0) {
        fprintf(stderr, "[SSH] Failed to create dummy socket\n");
        libssh2_session_free(s->ssh);
        tcp_close(tcp);
        rndis_close(rndis);
        free(s);
        return NULL;
    }
    rc = libssh2_session_handshake(s->ssh, s->dummy_sock);
    if (rc != 0) {
        char *errmsg = NULL;
        libssh2_session_last_error(s->ssh, &errmsg, NULL, 0);
        fprintf(stderr, "[SSH] Handshake failed: %s (rc=%d)\n", errmsg ? errmsg : "unknown", rc);
        close(s->dummy_sock);
        libssh2_session_free(s->ssh);
        tcp_close(tcp);
        rndis_close(rndis);
        free(s);
        return NULL;
    }
    fprintf(stderr, "[SSH] Handshake complete\n");

    // Step 5: Authenticate as root
    // First, query auth methods — this sends a "none" auth request.
    // Dropbear with empty root password may accept "none" directly.
    char *auth_list = libssh2_userauth_list(s->ssh, "root", 4);
    if (libssh2_userauth_authenticated(s->ssh)) {
        fprintf(stderr, "[SSH] Authenticated via 'none' method\n");
    } else {
        fprintf(stderr, "[SSH] Auth methods: %s\n", auth_list ? auth_list : "(null)");
        // Try password auth with empty password
        rc = libssh2_userauth_password(s->ssh, "root", "");
        if (rc != 0) {
            char *errmsg = NULL;
            libssh2_session_last_error(s->ssh, &errmsg, NULL, 0);
            fprintf(stderr, "[SSH] Auth failed: %s (rc=%d)\n", errmsg ? errmsg : "unknown", rc);
            libssh2_session_disconnect(s->ssh, "auth failed");
            close(s->dummy_sock);
            libssh2_session_free(s->ssh);
            tcp_close(tcp);
            rndis_close(rndis);
            free(s);
            return NULL;
        }
    }

    fprintf(stderr, "[SSH] Authenticated as root\n");
    return s;
}

int ssh_exec(ssh_session_t *s, const char *command, ssh_exec_result_t *result,
             int timeout_ms) {
    if (!s || !s->ssh || !result) return -1;
    memset(result, 0, sizeof(*result));

    fprintf(stderr, "[SSH] exec: opening channel for '%s'\n", command);
    libssh2_session_set_timeout(s->ssh, timeout_ms);

    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->ssh);
    if (!ch) {
        char *errmsg = NULL;
        libssh2_session_last_error(s->ssh, &errmsg, NULL, 0);
        fprintf(stderr, "[SSH] Failed to open channel: %s\n", errmsg ? errmsg : "unknown");
        return -1;
    }
    fprintf(stderr, "[SSH] exec: channel open, sending exec\n");

    int rc = libssh2_channel_exec(ch, command);
    if (rc != 0) {
        fprintf(stderr, "[SSH] Exec failed: %d\n", rc);
        libssh2_channel_free(ch);
        return -1;
    }
    fprintf(stderr, "[SSH] exec: reading output\n");

    // Switch to non-blocking for the read loop so we can poll EOF.
    // Use short recv timeout so callbacks return quickly.
    libssh2_session_set_blocking(s->ssh, 0);
    s->recv_timeout_ms = 100;

    // Read stdout
    size_t stdout_cap = 4096;
    size_t stdout_len = 0;
    char *stdout_buf = malloc(stdout_cap);

    // Read stderr
    size_t stderr_cap = 4096;
    size_t stderr_len = 0;
    char *stderr_buf = malloc(stderr_cap);

    char tmp[4096];
    uint64_t read_deadline = now_ms_ssh() + (uint64_t)timeout_ms;

    for (;;) {
        if (now_ms_ssh() > read_deadline) {
            fprintf(stderr, "[SSH] exec: read timed out after %d ms\n", timeout_ms);
            break;
        }

        int got_data = 0;

        // Read stdout (non-blocking)
        ssize_t n = libssh2_channel_read(ch, tmp, sizeof(tmp));
        if (n > 0) {
            if (stdout_len + n > stdout_cap) {
                stdout_cap = (stdout_len + n) * 2;
                stdout_buf = realloc(stdout_buf, stdout_cap);
            }
            memcpy(stdout_buf + stdout_len, tmp, n);
            stdout_len += n;
            got_data = 1;
        }

        // Read stderr (non-blocking)
        n = libssh2_channel_read_stderr(ch, tmp, sizeof(tmp));
        if (n > 0) {
            if (stderr_len + n > stderr_cap) {
                stderr_cap = (stderr_len + n) * 2;
                stderr_buf = realloc(stderr_buf, stderr_cap);
            }
            memcpy(stderr_buf + stderr_len, tmp, n);
            stderr_len += n;
            got_data = 1;
        }

        if (libssh2_channel_eof(ch)) break;

        // If no data available, pump the TCP stack to receive more
        if (!got_data) {
            tcp_poll(s->tcp, 100);
        }
    }

    // Restore blocking mode and long recv timeout
    s->recv_timeout_ms = 30000;
    libssh2_session_set_blocking(s->ssh, 1);
    libssh2_session_set_timeout(s->ssh, 30000);

    // Null-terminate
    stdout_buf = realloc(stdout_buf, stdout_len + 1);
    stdout_buf[stdout_len] = '\0';
    stderr_buf = realloc(stderr_buf, stderr_len + 1);
    stderr_buf[stderr_len] = '\0';

    result->stdout_buf = stdout_buf;
    result->stdout_len = (uint32_t)stdout_len;
    result->stderr_buf = stderr_buf;
    result->stderr_len = (uint32_t)stderr_len;
    result->exit_code = libssh2_channel_get_exit_status(ch);

    libssh2_channel_close(ch);
    libssh2_channel_free(ch);

    return 0;
}

int ssh_exec_stdin(ssh_session_t *s, const char *command,
                    const uint8_t *stdin_data, uint32_t stdin_len,
                    ssh_exec_result_t *result, int timeout_ms) {
    if (!s || !s->ssh || !result) return -1;
    memset(result, 0, sizeof(*result));

    libssh2_session_set_timeout(s->ssh, timeout_ms);

    fprintf(stderr, "[SSH] exec_stdin: '%s' (%u bytes stdin)\n", command, stdin_len);

    LIBSSH2_CHANNEL *ch = libssh2_channel_open_session(s->ssh);
    if (!ch) {
        fprintf(stderr, "[SSH] Failed to open channel for stdin exec\n");
        return -1;
    }

    int rc = libssh2_channel_exec(ch, command);
    if (rc != 0) {
        fprintf(stderr, "[SSH] exec_stdin: exec failed: %d\n", rc);
        libssh2_channel_free(ch);
        return -1;
    }

    // Write stdin data in chunks — use shorter recv timeout during writes
    // so libssh2 can quickly process WINDOW_ADJUST messages
    s->recv_timeout_ms = 50;

    fprintf(stderr, "[SSH] exec_stdin: writing %u bytes\n", stdin_len);
    uint32_t written = 0;
    uint32_t last_report = 0;
    while (written < stdin_len) {
        uint32_t chunk = stdin_len - written;
        if (chunk > 32768) chunk = 32768;

        ssize_t n = libssh2_channel_write(ch, (const char *)(stdin_data + written), chunk);
        if (n < 0) {
            fprintf(stderr, "[SSH] stdin write error at %u/%u: %zd\n", written, stdin_len, n);
            break;
        }
        if (n == 0) {
            fprintf(stderr, "[SSH] stdin write returned 0 at %u/%u\n", written, stdin_len);
            break;
        }
        written += (uint32_t)n;

        // Progress every 100KB
        if (written - last_report >= 102400) {
            fprintf(stderr, "[SSH] exec_stdin: %u/%u bytes written (%.0f%%)\n",
                    written, stdin_len, (double)written / stdin_len * 100);
            last_report = written;
        }
    }
    fprintf(stderr, "[SSH] exec_stdin: write complete (%u bytes), sending EOF\n", written);

    // Signal EOF on stdin
    libssh2_channel_send_eof(ch);

    // Switch to non-blocking for the read loop
    libssh2_session_set_blocking(s->ssh, 0);
    s->recv_timeout_ms = 100;

    // Read stdout + stderr
    size_t stdout_cap = 4096, stdout_len = 0;
    char *stdout_buf = malloc(stdout_cap);
    size_t stderr_cap = 4096, stderr_len = 0;
    char *stderr_buf = malloc(stderr_cap);

    char tmp[4096];
    uint64_t read_deadline = now_ms_ssh() + (uint64_t)timeout_ms;

    for (;;) {
        if (now_ms_ssh() > read_deadline) break;

        int got_data = 0;

        ssize_t n = libssh2_channel_read(ch, tmp, sizeof(tmp));
        if (n > 0) {
            if (stdout_len + n > stdout_cap) {
                stdout_cap = (stdout_len + n) * 2;
                stdout_buf = realloc(stdout_buf, stdout_cap);
            }
            memcpy(stdout_buf + stdout_len, tmp, n);
            stdout_len += n;
            got_data = 1;
        }

        n = libssh2_channel_read_stderr(ch, tmp, sizeof(tmp));
        if (n > 0) {
            if (stderr_len + n > stderr_cap) {
                stderr_cap = (stderr_len + n) * 2;
                stderr_buf = realloc(stderr_buf, stderr_cap);
            }
            memcpy(stderr_buf + stderr_len, tmp, n);
            stderr_len += n;
            got_data = 1;
        }

        if (libssh2_channel_eof(ch)) break;

        if (!got_data) {
            tcp_poll(s->tcp, 100);
        }
    }

    // Restore blocking mode and long recv timeout
    s->recv_timeout_ms = 30000;
    libssh2_session_set_blocking(s->ssh, 1);
    libssh2_session_set_timeout(s->ssh, 30000);

    stdout_buf = realloc(stdout_buf, stdout_len + 1);
    stdout_buf[stdout_len] = '\0';
    stderr_buf = realloc(stderr_buf, stderr_len + 1);
    stderr_buf[stderr_len] = '\0';

    result->stdout_buf = stdout_buf;
    result->stdout_len = (uint32_t)stdout_len;
    result->stderr_buf = stderr_buf;
    result->stderr_len = (uint32_t)stderr_len;
    result->exit_code = libssh2_channel_get_exit_status(ch);

    libssh2_channel_close(ch);
    libssh2_channel_free(ch);

    return 0;
}

void ssh_result_free(ssh_exec_result_t *result) {
    if (!result) return;
    free(result->stdout_buf);
    free(result->stderr_buf);
    memset(result, 0, sizeof(*result));
}

void ssh_session_close(ssh_session_t *s) {
    if (!s) return;

    if (s->ssh) {
        libssh2_session_disconnect(s->ssh, "Normal shutdown");
        libssh2_session_free(s->ssh);
    }
    if (s->dummy_sock >= 0) close(s->dummy_sock);
    if (s->tcp) tcp_close(s->tcp);
    if (s->rndis) rndis_close(s->rndis);

    free(s);
    libssh2_exit();
}

bool ssh_device_exists(void) {
    return rndis_device_exists(RNDIS_VID, RNDIS_PID);
}
