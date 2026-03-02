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

/// Send a USB control transfer (for RNDIS CDC Encapsulated Command/Response).
/// bmRequestType, bRequest, wValue, wIndex per USB spec.
/// Returns number of bytes transferred, or negative error code.
int hakchi_usb_control_transfer(hakchi_usb_device_t *dev,
                                 uint8_t bmRequestType, uint8_t bRequest,
                                 uint16_t wValue, uint16_t wIndex,
                                 uint8_t *data, uint16_t wLength,
                                 int timeout_ms);

/// Open a USB device for RNDIS: claims both interface 0 (control) and
/// interface 1 (data with bulk endpoints). Returns NULL on failure.
hakchi_usb_device_t *hakchi_usb_open_rndis(uint16_t vid, uint16_t pid,
                                            hakchi_usb_error_t *error);

/// Bulk write on a specific interface pipe (for RNDIS data interface).
/// pipe_index is the IOKit pipe reference number.
int hakchi_usb_bulk_write_pipe(hakchi_usb_device_t *dev, uint8_t pipe_index,
                                const uint8_t *data, int length, int timeout_ms);

/// Bulk read on a specific interface pipe (for RNDIS data interface).
int hakchi_usb_bulk_read_pipe(hakchi_usb_device_t *dev, uint8_t pipe_index,
                               uint8_t *data, int length, int timeout_ms);

/// Get the bulk IN pipe index (for RNDIS data interface).
uint8_t hakchi_usb_get_pipe_in(hakchi_usb_device_t *dev);

/// Get the bulk OUT pipe index (for RNDIS data interface).
uint8_t hakchi_usb_get_pipe_out(hakchi_usb_device_t *dev);

#ifdef __cplusplus
}
#endif

#endif /* USB_DEVICE_H */
