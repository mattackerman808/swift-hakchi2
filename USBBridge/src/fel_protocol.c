#include "fel_protocol.h"
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <stdio.h>

// ---------- Low-level USB transport ----------

static int fel_usb_write(fel_device_t *dev, const uint8_t *data, int length) {
    return hakchi_usb_bulk_write(dev->usb, FEL_EP_OUT, data, length, FEL_WRITE_TIMEOUT);
}

static int fel_usb_read(fel_device_t *dev, uint8_t *data, int length) {
    return hakchi_usb_bulk_read(dev->usb, FEL_EP_IN, data, length, FEL_READ_TIMEOUT);
}

// ---------- AW protocol wrappers ----------

/// Send an AWUC-wrapped write command, then the payload, then read AWUS response
static int aw_write(fel_device_t *dev, const uint8_t *data, uint32_t length) {
    aw_usb_request_t req;
    memset(&req, 0, sizeof(req));
    req.signature[0] = 'A'; req.signature[1] = 'W';
    req.signature[2] = 'U'; req.signature[3] = 'C';
    req.len = length;
    req.cmd_len = 0x0C;
    req.cmd = AW_USB_WRITE;
    req.len2 = length;

    int ret = fel_usb_write(dev, (const uint8_t *)&req, sizeof(req));
    if (ret < 0) return ret;

    ret = fel_usb_write(dev, data, (int)length);
    if (ret < 0) return ret;

    aw_usb_response_t resp;
    ret = fel_usb_read(dev, (uint8_t *)&resp, sizeof(resp));
    if (ret < 0) return ret;

    if (memcmp(resp.signature, "AWUS", 4) != 0 || resp.csw_status != 0) {
        return HAKCHI_USB_ERROR_IO;
    }

    return HAKCHI_USB_OK;
}

/// Send an AWUC-wrapped read command, read payload, then read AWUS response
static int aw_read(fel_device_t *dev, uint8_t *data, uint32_t length) {
    aw_usb_request_t req;
    memset(&req, 0, sizeof(req));
    req.signature[0] = 'A'; req.signature[1] = 'W';
    req.signature[2] = 'U'; req.signature[3] = 'C';
    req.len = length;
    req.cmd_len = 0x0C;
    req.cmd = AW_USB_READ;
    req.len2 = length;

    int ret = fel_usb_write(dev, (const uint8_t *)&req, sizeof(req));
    if (ret < 0) return ret;

    ret = fel_usb_read(dev, data, (int)length);
    if (ret < 0) return ret;

    aw_usb_response_t resp;
    ret = fel_usb_read(dev, (uint8_t *)&resp, sizeof(resp));
    if (ret < 0) return ret;

    if (memcmp(resp.signature, "AWUS", 4) != 0 || resp.csw_status != 0) {
        return HAKCHI_USB_ERROR_IO;
    }

    return HAKCHI_USB_OK;
}

// ---------- FEL commands ----------

/// Send a standard FEL request (no address/length)
static int fel_send_request(fel_device_t *dev, uint16_t cmd) {
    aw_fel_std_request_t req;
    memset(&req, 0, sizeof(req));
    req.cmd = cmd;
    return aw_write(dev, (const uint8_t *)&req, sizeof(req));
}

/// Send a FEL message with address and length
static int fel_send_message(fel_device_t *dev, uint16_t cmd, uint32_t address, uint32_t length) {
    aw_fel_message_t msg;
    memset(&msg, 0, sizeof(msg));
    msg.cmd = cmd;
    msg.address = address;
    msg.len = length;
    return aw_write(dev, (const uint8_t *)&msg, sizeof(msg));
}

/// Read and validate FEL status response
static int fel_read_status(fel_device_t *dev) {
    aw_fel_status_t status;
    int ret = aw_read(dev, (uint8_t *)&status, sizeof(status));
    if (ret < 0) return ret;
    if (status.state != 0) return HAKCHI_USB_ERROR_IO;
    return HAKCHI_USB_OK;
}

// ---------- Public API ----------

fel_device_t *fel_open(void) {
    hakchi_usb_error_t err;
    hakchi_usb_device_t *usb = hakchi_usb_open(FEL_VID, FEL_PID, &err);
    if (!usb) return NULL;

    // Reset device and clear halts
    hakchi_usb_reset(usb);
    hakchi_usb_clear_halt(usb, FEL_EP_OUT);
    hakchi_usb_clear_halt(usb, FEL_EP_IN);

    fel_device_t *dev = calloc(1, sizeof(fel_device_t));
    dev->usb = usb;
    dev->dram_initialized = false;

    return dev;
}

void fel_close(fel_device_t *dev) {
    if (!dev) return;
    if (dev->usb) hakchi_usb_close(dev->usb);
    free(dev);
}

int fel_verify_device(fel_device_t *dev, aw_fel_verify_response_t *resp) {
    int ret = fel_send_request(dev, FEL_VERIFY_DEVICE);
    if (ret < 0) return ret;

    ret = aw_read(dev, (uint8_t *)resp, sizeof(*resp));
    if (ret < 0) return ret;

    // Discard status response
    aw_fel_status_t status;
    aw_read(dev, (uint8_t *)&status, sizeof(status));

    // Validate magic
    if (memcmp(resp->magic, "AWUSBFEX", 8) != 0) {
        return HAKCHI_USB_ERROR_IO;
    }

    return HAKCHI_USB_OK;
}

int fel_write_memory(fel_device_t *dev, uint32_t address,
                     const uint8_t *data, uint32_t length,
                     void (*progress)(uint32_t done, uint32_t total, void *ctx),
                     void *ctx) {
    // 4-byte align length
    uint32_t aligned_len = (length + 3) & ~3u;

    // If data isn't aligned, we need a padded copy
    uint8_t *padded = NULL;
    if (aligned_len != length) {
        padded = calloc(1, aligned_len);
        memcpy(padded, data, length);
        data = padded;
    }

    uint32_t pos = 0;
    while (pos < aligned_len) {
        uint32_t chunk = aligned_len - pos;
        if (chunk > FEL_MAX_BULK_SIZE) chunk = FEL_MAX_BULK_SIZE;

        int ret = fel_send_message(dev, FEL_DOWNLOAD, address + pos, chunk);
        if (ret < 0) { free(padded); return ret; }

        ret = aw_write(dev, data + pos, chunk);
        if (ret < 0) { free(padded); return ret; }

        ret = fel_read_status(dev);
        if (ret < 0) { free(padded); return ret; }

        pos += chunk;
        if (progress) progress(pos, aligned_len, ctx);
    }

    free(padded);
    return HAKCHI_USB_OK;
}

int fel_read_memory(fel_device_t *dev, uint32_t address,
                    uint8_t *buffer, uint32_t length,
                    void (*progress)(uint32_t done, uint32_t total, void *ctx),
                    void *ctx) {
    uint32_t aligned_len = (length + 3) & ~3u;
    uint32_t pos = 0;

    while (pos < aligned_len) {
        uint32_t chunk = aligned_len - pos;
        if (chunk > FEL_MAX_BULK_SIZE) chunk = FEL_MAX_BULK_SIZE;

        int ret = fel_send_message(dev, FEL_UPLOAD, address + pos, chunk);
        if (ret < 0) return ret;

        // Read into buffer if within requested range, otherwise temp buffer
        if (pos + chunk <= length) {
            ret = aw_read(dev, buffer + pos, chunk);
        } else {
            uint8_t *tmp = malloc(chunk);
            ret = aw_read(dev, tmp, chunk);
            if (ret >= 0) {
                uint32_t copy_len = length - pos;
                if (copy_len > 0) memcpy(buffer + pos, tmp, copy_len);
            }
            free(tmp);
        }
        if (ret < 0) return ret;

        ret = fel_read_status(dev);
        if (ret < 0) return ret;

        pos += chunk;
        if (progress) progress(pos < length ? pos : length, length, ctx);
    }

    return HAKCHI_USB_OK;
}

int fel_exec(fel_device_t *dev, uint32_t address) {
    int ret = fel_send_message(dev, FEL_RUN, address, 0);
    if (ret < 0) return ret;
    return fel_read_status(dev);
}

int fel_init_dram(fel_device_t *dev, const uint8_t *fes1_data, uint32_t fes1_length) {
    if (dev->dram_initialized) return HAKCHI_USB_OK;
    if (!fes1_data || fes1_length < 0x80) return HAKCHI_USB_ERROR_INVALID_PARAM;

    // Check if fes1 is already loaded by reading tail end from SRAM
    uint32_t test_size = 0x80;
    uint32_t probe_addr = FES1_BASE_M + fes1_length - test_size;

    uint8_t probe_buf[0x80];
    int ret = fel_read_memory(dev, probe_addr, probe_buf, test_size, NULL, NULL);
    if (ret == HAKCHI_USB_OK) {
        if (memcmp(probe_buf, fes1_data + fes1_length - test_size, test_size) == 0) {
            dev->dram_initialized = true;
            return HAKCHI_USB_OK;
        }
    }

    // Load fes1 to SRAM and execute
    ret = fel_write_memory(dev, FES1_BASE_M, fes1_data, fes1_length, NULL, NULL);
    if (ret < 0) return ret;

    ret = fel_exec(dev, FES1_BASE_M);
    if (ret < 0) return ret;

    // Wait for DRAM initialization
    usleep(2000000); // 2 seconds

    dev->dram_initialized = true;
    return HAKCHI_USB_OK;
}
