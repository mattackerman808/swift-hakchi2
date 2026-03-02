#ifndef SSH_BRIDGE_H
#define SSH_BRIDGE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to an SSH session over RNDIS
typedef struct ssh_session ssh_session_t;

/// Result of a command execution
typedef struct {
    char    *stdout_buf;
    uint32_t stdout_len;
    char    *stderr_buf;
    uint32_t stderr_len;
    int      exit_code;
} ssh_exec_result_t;

/// Open an SSH session: RNDIS init → TCP connect → SSH handshake → auth.
/// vid/pid: USB device to open (e.g., RNDIS_VID/RNDIS_PID)
/// host_ip: our IP (e.g., "169.254.13.38")
/// remote_ip: console IP (e.g., "169.254.13.37")
/// Returns NULL on failure.
ssh_session_t *ssh_session_open(uint16_t vid, uint16_t pid,
                                 const char *host_ip, const char *remote_ip);

/// Execute a command and capture stdout/stderr.
/// Caller must call ssh_result_free() on the result.
/// Returns 0 on success, negative on error.
int ssh_exec(ssh_session_t *s, const char *command, ssh_exec_result_t *result,
             int timeout_ms);

/// Execute a command with stdin data piped in (e.g., "cat > /path" or "tar -xvC /dir").
/// Returns 0 on success, negative on error.
int ssh_exec_stdin(ssh_session_t *s, const char *command,
                    const uint8_t *stdin_data, uint32_t stdin_len,
                    ssh_exec_result_t *result, int timeout_ms);

/// Free memory in an exec result.
void ssh_result_free(ssh_exec_result_t *result);

/// Close the SSH session, TCP connection, and RNDIS device.
void ssh_session_close(ssh_session_t *s);

/// Check if RNDIS device is present on USB.
bool ssh_device_exists(void);

#ifdef __cplusplus
}
#endif

#endif /* SSH_BRIDGE_H */
