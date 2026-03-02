#include "clovershell.h"
#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <unistd.h>
#include <time.h>
#include <pthread.h>

// Internal state
struct clovershell_conn {
    hakchi_usb_device_t *usb;

    // Read thread
    pthread_t       read_thread;
    volatile bool   running;

    // Exec state (single-exec at a time)
    pthread_mutex_t exec_mutex;
    pthread_cond_t  exec_cond;
    volatile bool   exec_pending;
    volatile int    exec_conn_id;    // -1 = not assigned

    // Output buffers (protected by exec_mutex)
    char   *stdout_buf;
    int     stdout_len;
    int     stdout_cap;
    char   *stderr_buf;
    int     stderr_len;
    int     stderr_cap;
    int     exit_code;
    volatile bool stdout_done;
    volatile bool stderr_done;
    volatile bool result_done;
};

// ---------- Wire protocol ----------

static int clvs_write_frame(clovershell_conn_t *conn, uint8_t cmd,
                             uint8_t arg, const uint8_t *data, uint16_t len) {
    // ClusterM's client sends header+payload as ONE USB transfer.
    // The clovershell daemon expects a single packet per frame.
    uint8_t buf[4 + CLVS_MAX_PAYLOAD];
    buf[0] = cmd;
    buf[1] = arg;
    buf[2] = (uint8_t)(len & 0xFF);
    buf[3] = (uint8_t)(len >> 8);

    if (len > 0 && data) {
        memcpy(buf + 4, data, len);
    }

    fprintf(stderr, "[CLVS] write_frame: cmd=0x%02X arg=%d len=%d total=%d\n", cmd, arg, len, 4 + len);

    int ret = hakchi_usb_bulk_write(conn->usb, 0x01, buf, 4 + len, 1000);
    if (ret < 0) {
        fprintf(stderr, "[CLVS] write_frame: write failed: %d\n", ret);
        return ret;
    }

    return 0;
}

// Append data to a dynamic buffer
static void buf_append(char **buf, int *len, int *cap,
                       const uint8_t *data, int data_len) {
    if (*len + data_len > *cap) {
        int new_cap = (*cap == 0) ? 4096 : *cap * 2;
        while (new_cap < *len + data_len) new_cap *= 2;
        *buf = realloc(*buf, new_cap);
        *cap = new_cap;
    }
    memcpy(*buf + *len, data, data_len);
    *len += data_len;
}

// ---------- Read thread ----------

static void handle_frame(clovershell_conn_t *conn,
                          uint8_t cmd, uint8_t arg,
                          const uint8_t *payload, uint16_t len) {
    pthread_mutex_lock(&conn->exec_mutex);

    switch (cmd) {
    case CLVS_CMD_EXEC_NEW_RESP:
        if (conn->exec_pending && conn->exec_conn_id == -1) {
            conn->exec_conn_id = arg;
            pthread_cond_signal(&conn->exec_cond);
        }
        break;

    case CLVS_CMD_EXEC_STDOUT:
        if (arg == conn->exec_conn_id) {
            if (len == 0) {
                conn->stdout_done = true;
            } else {
                buf_append(&conn->stdout_buf, &conn->stdout_len,
                           &conn->stdout_cap, payload, len);
                // Log short stdout for debugging (skip large binary dumps)
                if (len < 512) {
                    char tmp[513];
                    int copy = len < 512 ? len : 512;
                    memcpy(tmp, payload, copy);
                    tmp[copy] = '\0';
                    fprintf(stderr, "[CLVS] STDOUT: %s\n", tmp);
                }
            }
            pthread_cond_signal(&conn->exec_cond);
        }
        break;

    case CLVS_CMD_EXEC_STDERR:
        if (arg == conn->exec_conn_id) {
            if (len == 0) {
                conn->stderr_done = true;
            } else {
                buf_append(&conn->stderr_buf, &conn->stderr_len,
                           &conn->stderr_cap, payload, len);
                // Log stderr content for debugging
                char tmp[256];
                int copy = len < 255 ? len : 255;
                memcpy(tmp, payload, copy);
                tmp[copy] = '\0';
                fprintf(stderr, "[CLVS] STDERR: %s\n", tmp);
            }
            pthread_cond_signal(&conn->exec_cond);
        }
        break;

    case CLVS_CMD_EXEC_RESULT:
        if (arg == conn->exec_conn_id) {
            conn->exit_code = (len >= 1) ? payload[0] : -1;
            conn->result_done = true;
            pthread_cond_signal(&conn->exec_cond);
        }
        break;

    case CLVS_CMD_PING:
        // Respond with PONG
        pthread_mutex_unlock(&conn->exec_mutex);
        clvs_write_frame(conn, CLVS_CMD_PONG, 0, payload, len);
        return;

    default:
        break;
    }

    pthread_mutex_unlock(&conn->exec_mutex);
}

static void *read_thread_func(void *arg) {
    clovershell_conn_t *conn = (clovershell_conn_t *)arg;
    uint8_t buf[65536 + 4];

    fprintf(stderr, "[CLVS] Read thread started\n");
    while (conn->running) {
        // Read a full packet — ClusterM's client does large reads and parses
        // header+payload from the result. USB bulk transfers deliver complete packets.
        int ret = hakchi_usb_bulk_read(conn->usb, 0x81, buf, sizeof(buf), 500);
        if (ret < 0) {
            if (ret == HAKCHI_USB_ERROR_TIMEOUT) continue;
            fprintf(stderr, "[CLVS] Read thread: read error %d, exiting\n", ret);
            break;
        }
        if (ret < 4) {
            fprintf(stderr, "[CLVS] Read thread: short read %d bytes\n", ret);
            continue;
        }

        uint8_t cmd = buf[0];
        uint8_t cmdarg = buf[1];
        uint16_t payload_len = (uint16_t)buf[2] | ((uint16_t)buf[3] << 8);
        fprintf(stderr, "[CLVS] Read frame: cmd=0x%02X arg=%d payload_len=%d read=%d\n",
                cmd, cmdarg, payload_len, ret);

        // Payload is in buf[4..]. If the full payload wasn't in this read,
        // do additional reads to get the rest.
        uint8_t *payload = (payload_len > 0) ? buf + 4 : NULL;
        int got = ret - 4;
        while (got < payload_len && conn->running) {
            ret = hakchi_usb_bulk_read(conn->usb, 0x81,
                                        buf + 4 + got, payload_len - got, 1000);
            if (ret < 0) {
                if (ret == HAKCHI_USB_ERROR_TIMEOUT) continue;
                goto exit_thread;
            }
            got += ret;
        }

        handle_frame(conn, cmd, cmdarg, payload, payload_len);
    }

exit_thread:
    conn->running = false;
    // Wake up anyone waiting
    pthread_mutex_lock(&conn->exec_mutex);
    conn->result_done = true;
    pthread_cond_signal(&conn->exec_cond);
    pthread_mutex_unlock(&conn->exec_mutex);
    return NULL;
}

// ---------- Public API ----------

bool clovershell_device_exists(void) {
    return hakchi_usb_device_exists(CLVS_VID, CLVS_PID);
}

clovershell_conn_t *clovershell_open(void) {
    setbuf(stderr, NULL); // Ensure unbuffered output
    hakchi_usb_error_t err;
    fprintf(stderr, "[Clovershell] Opening VID=0x%04X PID=0x%04X\n", CLVS_VID, CLVS_PID);
    hakchi_usb_device_t *usb = hakchi_usb_open(CLVS_VID, CLVS_PID, &err);
    if (!usb) {
        fprintf(stderr, "[Clovershell] USB open failed: err=%d\n", err);
        return NULL;
    }

    // Clear stale state
    hakchi_usb_clear_halt(usb, 0x01);
    hakchi_usb_clear_halt(usb, 0x81);

    clovershell_conn_t *conn = calloc(1, sizeof(clovershell_conn_t));
    conn->usb = usb;
    conn->exec_conn_id = -1;
    conn->exit_code = -1;
    pthread_mutex_init(&conn->exec_mutex, NULL);
    pthread_cond_init(&conn->exec_cond, NULL);

    // Kill all existing sessions
    clvs_write_frame(conn, CLVS_CMD_SHELL_KILL_ALL, 0, NULL, 0);
    clvs_write_frame(conn, CLVS_CMD_EXEC_KILL_ALL, 0, NULL, 0);

    // Drain any stale data (short reads with timeout)
    uint8_t drain[65536];
    for (int i = 0; i < 3; i++) {
        int ret = hakchi_usb_bulk_read(usb, 0x81, drain, sizeof(drain), 100);
        if (ret <= 0) break;
    }

    // Start read thread
    conn->running = true;
    if (pthread_create(&conn->read_thread, NULL, read_thread_func, conn) != 0) {
        fprintf(stderr, "[Clovershell] Failed to start read thread\n");
        hakchi_usb_close(usb);
        free(conn);
        return NULL;
    }

    fprintf(stderr, "[Clovershell] Connected\n");
    return conn;
}

void clovershell_close(clovershell_conn_t *conn) {
    if (!conn) return;

    conn->running = false;
    pthread_join(conn->read_thread, NULL);

    if (conn->usb) hakchi_usb_close(conn->usb);

    free(conn->stdout_buf);
    free(conn->stderr_buf);
    pthread_mutex_destroy(&conn->exec_mutex);
    pthread_cond_destroy(&conn->exec_cond);
    free(conn);

    fprintf(stderr, "[Clovershell] Disconnected\n");
}

static void reset_exec_state(clovershell_conn_t *conn) {
    free(conn->stdout_buf);
    free(conn->stderr_buf);
    conn->stdout_buf = NULL;
    conn->stdout_len = 0;
    conn->stdout_cap = 0;
    conn->stderr_buf = NULL;
    conn->stderr_len = 0;
    conn->stderr_cap = 0;
    conn->exit_code = -1;
    conn->exec_conn_id = -1;
    conn->exec_pending = false;
    conn->stdout_done = false;
    conn->stderr_done = false;
    conn->result_done = false;
}

int clovershell_exec(clovershell_conn_t *conn,
                     const char *command,
                     clovershell_exec_result_t *result,
                     int timeout_ms) {
    return clovershell_exec_stdin(conn, command, NULL, 0, result, timeout_ms);
}

int clovershell_exec_stdin(clovershell_conn_t *conn,
                           const char *command,
                           const uint8_t *stdin_data,
                           int stdin_len,
                           clovershell_exec_result_t *result,
                           int timeout_ms) {
    if (!conn || !conn->running) return -1;

    pthread_mutex_lock(&conn->exec_mutex);
    reset_exec_state(conn);
    conn->exec_pending = true;
    pthread_mutex_unlock(&conn->exec_mutex);

    // Send exec request
    uint16_t cmd_len = (uint16_t)strlen(command);
    int ret = clvs_write_frame(conn, CLVS_CMD_EXEC_NEW_REQ, 0,
                                (const uint8_t *)command, cmd_len);
    if (ret < 0) return ret;

    // Wait for connection ID
    struct timespec ts;
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += (timeout_ms > 0) ? (timeout_ms / 1000) : 30;

    pthread_mutex_lock(&conn->exec_mutex);
    while (conn->exec_conn_id == -1 && conn->running) {
        if (pthread_cond_timedwait(&conn->exec_cond, &conn->exec_mutex, &ts) != 0) {
            pthread_mutex_unlock(&conn->exec_mutex);
            fprintf(stderr, "[Clovershell] Timeout waiting for exec response\n");
            return -2;
        }
    }
    int conn_id = conn->exec_conn_id;
    pthread_mutex_unlock(&conn->exec_mutex);

    if (conn_id == -1) return -3;

    fprintf(stderr, "[Clovershell] Exec '%s' → conn_id=%d\n", command, conn_id);

    // Send stdin data if any — use 8KB chunks to match .NET client.
    // The Clovershell daemon on the console has limited buffers;
    // 65KB chunks cause data loss ("tar: short read").
    if (stdin_data && stdin_len > 0) {
        int offset = 0;
        while (offset < stdin_len) {
            int chunk = stdin_len - offset;
            if (chunk > 8192) chunk = 8192;
            ret = clvs_write_frame(conn, CLVS_CMD_EXEC_STDIN, (uint8_t)conn_id,
                                    stdin_data + offset, (uint16_t)chunk);
            if (ret < 0) return ret;
            offset += chunk;
        }
    }

    // Send stdin EOF
    if (stdin_data || stdin_len == 0) {
        clvs_write_frame(conn, CLVS_CMD_EXEC_STDIN, (uint8_t)conn_id, NULL, 0);
    }

    // Wait for result
    clock_gettime(CLOCK_REALTIME, &ts);
    ts.tv_sec += (timeout_ms > 0) ? (timeout_ms / 1000) : 300;

    pthread_mutex_lock(&conn->exec_mutex);
    while (!conn->result_done && conn->running) {
        if (pthread_cond_timedwait(&conn->exec_cond, &conn->exec_mutex, &ts) != 0) {
            pthread_mutex_unlock(&conn->exec_mutex);
            fprintf(stderr, "[Clovershell] Timeout waiting for exec result\n");
            return -4;
        }
    }

    // Copy results
    if (result) {
        result->exit_code = conn->exit_code;

        if (conn->stdout_len > 0) {
            result->stdout_buf = malloc(conn->stdout_len + 1);
            memcpy(result->stdout_buf, conn->stdout_buf, conn->stdout_len);
            result->stdout_buf[conn->stdout_len] = '\0';
            result->stdout_len = conn->stdout_len;
        } else {
            result->stdout_buf = calloc(1, 1);
            result->stdout_len = 0;
        }

        if (conn->stderr_len > 0) {
            result->stderr_buf = malloc(conn->stderr_len + 1);
            memcpy(result->stderr_buf, conn->stderr_buf, conn->stderr_len);
            result->stderr_buf[conn->stderr_len] = '\0';
            result->stderr_len = conn->stderr_len;
        } else {
            result->stderr_buf = calloc(1, 1);
            result->stderr_len = 0;
        }
    }

    pthread_mutex_unlock(&conn->exec_mutex);

    fprintf(stderr, "[Clovershell] Exec done, exit=%d, stdout=%d bytes, stderr=%d bytes\n",
            result ? result->exit_code : -1,
            result ? result->stdout_len : 0,
            result ? result->stderr_len : 0);

    return 0;
}

void clovershell_result_free(clovershell_exec_result_t *result) {
    if (!result) return;
    free(result->stdout_buf);
    free(result->stderr_buf);
    result->stdout_buf = NULL;
    result->stderr_buf = NULL;
    result->stdout_len = 0;
    result->stderr_len = 0;
}
