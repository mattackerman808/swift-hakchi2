#ifndef USB_DEVICE_H
#define USB_DEVICE_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle to a USB device
typedef struct hakchi_usb_device hakchi_usb_device_t;

/// Error codes
typedef enum {
    HAKCHI_USB_OK = 0,
    HAKCHI_USB_ERROR_NOT_FOUND = -1,
    HAKCHI_USB_ERROR_ACCESS = -2,
    HAKCHI_USB_ERROR_IO = -3,
    HAKCHI_USB_ERROR_TIMEOUT = -4,
    HAKCHI_USB_ERROR_PIPE = -5,
    HAKCHI_USB_ERROR_INVALID_PARAM = -6,
    HAKCHI_USB_ERROR_NO_DEVICE = -7,
    HAKCHI_USB_ERROR_OTHER = -99,
} hakchi_usb_error_t;

/// Open a USB device by vendor/product ID.
/// Returns NULL on failure; sets *error if non-NULL.
hakchi_usb_device_t *hakchi_usb_open(uint16_t vid, uint16_t pid, hakchi_usb_error_t *error);

/// Write data to a bulk OUT endpoint.
/// Returns number of bytes written, or negative error code.
int hakchi_usb_bulk_write(hakchi_usb_device_t *dev, uint8_t endpoint,
                          const uint8_t *data, int length, int timeout_ms);

/// Read data from a bulk IN endpoint.
/// Returns number of bytes read, or negative error code.
int hakchi_usb_bulk_read(hakchi_usb_device_t *dev, uint8_t endpoint,
                         uint8_t *data, int length, int timeout_ms);

/// Clear halt/stall on an endpoint.
hakchi_usb_error_t hakchi_usb_clear_halt(hakchi_usb_device_t *dev, uint8_t endpoint);

/// Reset the USB device.
hakchi_usb_error_t hakchi_usb_reset(hakchi_usb_device_t *dev);

/// Close the device and free resources.
void hakchi_usb_close(hakchi_usb_device_t *dev);

/// Check if a USB device with given VID/PID is currently connected.
bool hakchi_usb_device_exists(uint16_t vid, uint16_t pid);

#ifdef __cplusplus
}
#endif

#endif /* USB_DEVICE_H */
