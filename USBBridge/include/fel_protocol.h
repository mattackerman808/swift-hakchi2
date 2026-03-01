#ifndef FEL_PROTOCOL_H
#define FEL_PROTOCOL_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>
#include "usb_device.h"

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Constants ----------

#define FEL_VID             0x1F3A
#define FEL_PID             0xEFE8

#define FEL_EP_OUT          0x01
#define FEL_EP_IN           0x82

#define FEL_READ_TIMEOUT    1000
#define FEL_WRITE_TIMEOUT   1000
#define FEL_MAX_BULK_SIZE   0x10000  // 64KB

// Memory addresses
#define FES1_BASE_M         0x00002000u
#define DRAM_BASE           0x40000000u
#define UBOOT_BASE_M        0x47000000u
#define UBOOT_BASE_F        0x00100000u
#define SECTOR_SIZE         0x00020000u   // 128KB
#define UBOOT_MAXSIZE_F     (SECTOR_SIZE * 0x10)      // 2MB
#define KERNEL_BASE_F       (SECTOR_SIZE * 0x30)      // 0x600000
#define KERNEL_MAX_SIZE     (SECTOR_SIZE * 0x20)      // 0x400000
#define TRANSFER_BASE_M     0x47400000u
#define TRANSFER_MAX_SIZE   (SECTOR_SIZE * 0x100)     // 32MB

#define EXPECTED_BOARD_ID   0x00166700u

// ---------- FEL command types ----------

typedef enum {
    FEL_VERIFY_DEVICE   = 0x0001,
    FEL_SWITCH_ROLE     = 0x0002,
    FEL_IS_READY        = 0x0003,
    FEL_GET_CMD_SET_VER = 0x0004,
    FEL_DISCONNECT      = 0x0010,
    FEL_DOWNLOAD        = 0x0101,  // write memory
    FEL_RUN             = 0x0102,  // execute
    FEL_UPLOAD          = 0x0103,  // read memory
} fel_request_type_t;

typedef enum {
    AW_USB_READ  = 0x11,
    AW_USB_WRITE = 0x12,
} aw_usb_direction_t;

// ---------- Wire structures (all little-endian, packed) ----------

#pragma pack(push, 1)

/// AWUSBRequest — 32 bytes, "AWUC" signature
typedef struct {
    uint8_t  signature[4];   // "AWUC"
    uint32_t tag;
    uint32_t len;
    uint8_t  pad1;
    uint8_t  pad2;
    uint8_t  pad3;
    uint8_t  cmd_len;        // always 0x0C
    uint8_t  cmd;            // AW_USB_READ or AW_USB_WRITE
    uint8_t  pad4;
    uint32_t len2;           // same as len
    uint8_t  pad5[10];
} aw_usb_request_t;

/// AWUSBResponse — 13 bytes, "AWUS" signature
typedef struct {
    uint8_t  signature[4];   // "AWUS"
    uint32_t tag;
    uint32_t residue;
    uint8_t  csw_status;     // 0 = success
} aw_usb_response_t;

/// AWFELMessage — 16 bytes, used for DOWNLOAD/UPLOAD/RUN
typedef struct {
    uint16_t cmd;
    uint16_t tag;
    uint32_t address;
    uint32_t len;
    uint32_t flags;
} aw_fel_message_t;

/// AWFELStandardRequest — 16 bytes, used for VERIFY_DEVICE etc.
typedef struct {
    uint16_t cmd;
    uint16_t tag;
    uint8_t  pad[12];
} aw_fel_std_request_t;

/// AWFELStatusResponse — 8 bytes
typedef struct {
    uint16_t mark;
    uint16_t tag;
    uint8_t  state;         // 0 = success
    uint8_t  pad[3];
} aw_fel_status_t;

/// AWFELVerifyDeviceResponse — 32 bytes, "AWUSBFEX" magic
typedef struct {
    uint8_t  magic[8];       // "AWUSBFEX"
    uint32_t board;
    uint32_t fw;
    uint16_t mode;
    uint8_t  data_flag;
    uint8_t  data_length;
    uint32_t data_start_addr;
    uint8_t  pad[8];
} aw_fel_verify_response_t;

#pragma pack(pop)

// ---------- FEL device handle ----------

typedef struct {
    hakchi_usb_device_t *usb;
    bool dram_initialized;
} fel_device_t;

// ---------- High-level FEL operations ----------

/// Open a FEL device (VID=0x1F3A, PID=0xEFE8).
/// Resets device and clears endpoint halts.
/// Returns NULL on failure.
fel_device_t *fel_open(void);

/// Close FEL device and free resources.
void fel_close(fel_device_t *dev);

/// Verify the connected device. Returns 0 on success.
/// Populates `resp` with the verify response.
int fel_verify_device(fel_device_t *dev, aw_fel_verify_response_t *resp);

/// Write data to device memory at `address`.
/// For DRAM addresses (>= 0x40000000), DRAM must be initialized first.
/// Calls progress callback with (bytes_done, total_bytes) if non-NULL.
int fel_write_memory(fel_device_t *dev, uint32_t address,
                     const uint8_t *data, uint32_t length,
                     void (*progress)(uint32_t done, uint32_t total, void *ctx),
                     void *ctx);

/// Read data from device memory at `address`.
int fel_read_memory(fel_device_t *dev, uint32_t address,
                    uint8_t *buffer, uint32_t length,
                    void (*progress)(uint32_t done, uint32_t total, void *ctx),
                    void *ctx);

/// Execute code at `address`.
int fel_exec(fel_device_t *dev, uint32_t address);

/// Initialize DRAM by loading and executing fes1 binary.
/// `fes1_data` and `fes1_length` provide the SPL binary.
int fel_init_dram(fel_device_t *dev, const uint8_t *fes1_data, uint32_t fes1_length);

#ifdef __cplusplus
}
#endif

#endif /* FEL_PROTOCOL_H */
