#ifndef CLOVERSHELL_H
#define CLOVERSHELL_H

#include "usb_device.h"
#include <stdint.h>
#include <stdbool.h>

// Clovershell protocol commands
#define CLVS_CMD_PING                   0x00
#define CLVS_CMD_PONG                   0x01
#define CLVS_CMD_SHELL_NEW_REQ          0x02
#define CLVS_CMD_SHELL_NEW_RESP         0x03
#define CLVS_CMD_SHELL_IN              0x04
#define CLVS_CMD_SHELL_OUT             0x05
#define CLVS_CMD_SHELL_CLOSED          0x06
#define CLVS_CMD_SHELL_KILL            0x07
#define CLVS_CMD_SHELL_KILL_ALL        0x08
#define CLVS_CMD_EXEC_NEW_REQ          0x09
#define CLVS_CMD_EXEC_NEW_RESP         0x0A
#define CLVS_CMD_EXEC_PID             0x0B
#define CLVS_CMD_EXEC_STDIN           0x0C
#define CLVS_CMD_EXEC_STDOUT          0x0D
#define CLVS_CMD_EXEC_STDERR          0x0E
#define CLVS_CMD_EXEC_RESULT          0x0F
#define CLVS_CMD_EXEC_KILL            0x10
#define CLVS_CMD_EXEC_KILL_ALL        0x11
#define CLVS_CMD_EXEC_STDIN_FLOW_STAT     0x12
#define CLVS_CMD_EXEC_STDIN_FLOW_STAT_REQ 0x13

// Clovershell USB gadget VID/PID
// Same as FEL — both memboot and NAND-boot Clovershell use Allwinner VID/PID.
// (0x04E8:0x6863 is RNDIS, NOT Clovershell.)
#define CLVS_VID  0x1F3A
#define CLVS_PID  0xEFE8

// Max payload per frame
#define CLVS_MAX_PAYLOAD  65536

// Exec result buffer sizes
#define CLVS_STDOUT_BUF_SIZE  (256 * 1024)
#define CLVS_STDERR_BUF_SIZE  (64 * 1024)

/// Opaque Clovershell connection handle
typedef struct clovershell_conn clovershell_conn_t;

/// Result of an exec command
typedef struct {
    char    *stdout_buf;     // Caller must free()
    int      stdout_len;
    char    *stderr_buf;     // Caller must free()
    int      stderr_len;
    int      exit_code;      // -1 if not received
} clovershell_exec_result_t;

/// Open a Clovershell connection to the console.
/// Returns NULL if device not found or init fails.
clovershell_conn_t *clovershell_open(void);

/// Close connection and free resources.
void clovershell_close(clovershell_conn_t *conn);

/// Check if device with Clovershell VID/PID is present.
bool clovershell_device_exists(void);

/// Execute a command and collect stdout/stderr/exit code.
/// Blocks until command completes or timeout (in ms, 0 = no timeout).
/// Returns 0 on success, negative on error.
int clovershell_exec(clovershell_conn_t *conn,
                     const char *command,
                     clovershell_exec_result_t *result,
                     int timeout_ms);

/// Execute a command with stdin data (e.g., piping a file).
/// Sends stdin_data then EOF, then collects output.
/// Returns 0 on success, negative on error.
int clovershell_exec_stdin(clovershell_conn_t *conn,
                           const char *command,
                           const uint8_t *stdin_data,
                           int stdin_len,
                           clovershell_exec_result_t *result,
                           int timeout_ms);

/// Free the buffers in an exec result.
void clovershell_result_free(clovershell_exec_result_t *result);

#endif // CLOVERSHELL_H
