#include "usb_device.h"

#include <IOKit/IOKitLib.h>
#include <IOKit/usb/IOUSBLib.h>
#include <IOKit/IOCFPlugIn.h>
#include <CoreFoundation/CoreFoundation.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <mach/mach_port.h>

struct hakchi_usb_device {
    IOUSBDeviceInterface300    **device;
    IOUSBInterfaceInterface300 **interface;
    uint8_t pipe_out;
    uint8_t pipe_in;
};

// Find the pipe index for a given endpoint address
static bool find_pipe_for_endpoint(IOUSBInterfaceInterface300 **intf,
                                   uint8_t endpoint_addr, uint8_t *pipe_ref) {
    UInt8 num_endpoints = 0;
    (*intf)->GetNumEndpoints(intf, &num_endpoints);

    for (UInt8 i = 1; i <= num_endpoints; i++) {
        UInt8 direction, number, transferType, interval;
        UInt16 maxPacketSize;
        (*intf)->GetPipeProperties(intf, i, &direction, &number, &transferType,
                                   &maxPacketSize, &interval);

        uint8_t addr = number | (direction == kUSBIn ? 0x80 : 0x00);
        if (addr == endpoint_addr) {
            *pipe_ref = i;
            return true;
        }
    }
    return false;
}

hakchi_usb_device_t *hakchi_usb_open(uint16_t vid, uint16_t pid, hakchi_usb_error_t *error) {
    kern_return_t kr;
    io_iterator_t iterator = 0;
    io_service_t usb_service = 0;

    // Create matching dictionary for USB device
    CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchDict) {
        if (error) *error = HAKCHI_USB_ERROR_OTHER;
        return NULL;
    }

    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){vid}));
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){pid}));

    kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) {
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    usb_service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (!usb_service) {
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    // Get device interface
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score;
    kr = IOCreatePlugInInterfaceForService(usb_service, kIOUSBDeviceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plugIn, &score);
    IOObjectRelease(usb_service);

    if (kr != KERN_SUCCESS || !plugIn) {
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    IOUSBDeviceInterface300 **device = NULL;
    (*plugIn)->QueryInterface(plugIn, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                              (LPVOID *)&device);
    (*plugIn)->Release(plugIn);

    if (!device) {
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    // Open device
    kr = (*device)->USBDeviceOpen(device);
    if (kr != kIOReturnSuccess) {
        // Try with seize
        kr = (*device)->USBDeviceOpenSeize(device);
        if (kr != kIOReturnSuccess) {
            (*device)->Release(device);
            if (error) *error = HAKCHI_USB_ERROR_ACCESS;
            return NULL;
        }
    }

    // Set configuration (use first config)
    IOUSBConfigurationDescriptorPtr configDesc;
    kr = (*device)->GetConfigurationDescriptorPtr(device, 0, &configDesc);
    if (kr == kIOReturnSuccess) {
        (*device)->SetConfiguration(device, configDesc->bConfigurationValue);
    }

    // Find and open interface 0
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t intfIterator;
    kr = (*device)->CreateInterfaceIterator(device, &req, &intfIterator);
    if (kr != kIOReturnSuccess) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_OTHER;
        return NULL;
    }

    io_service_t intfService = IOIteratorNext(intfIterator);
    IOObjectRelease(intfIterator);

    if (!intfService) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    IOCFPlugInInterface **intfPlugIn = NULL;
    kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &intfPlugIn, &score);
    IOObjectRelease(intfService);

    if (kr != KERN_SUCCESS || !intfPlugIn) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    IOUSBInterfaceInterface300 **interface = NULL;
    (*intfPlugIn)->QueryInterface(intfPlugIn,
        CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
        (LPVOID *)&interface);
    (*intfPlugIn)->Release(intfPlugIn);

    if (!interface) {
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    kr = (*interface)->USBInterfaceOpen(interface);
    if (kr != kIOReturnSuccess) {
        (*interface)->Release(interface);
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    // Set alternate setting 1 (required by FEL protocol)
    (*interface)->SetAlternateInterface(interface, 1);

    // Find pipe indices for our endpoints
    hakchi_usb_device_t *dev = calloc(1, sizeof(hakchi_usb_device_t));
    dev->device = device;
    dev->interface = interface;

    if (!find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) ||
        !find_pipe_for_endpoint(interface, 0x82, &dev->pipe_in)) {
        // If alt setting 1 didn't work, try alt setting 0
        (*interface)->SetAlternateInterface(interface, 0);
        if (!find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) ||
            !find_pipe_for_endpoint(interface, 0x82, &dev->pipe_in)) {
            hakchi_usb_close(dev);
            if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
            return NULL;
        }
    }

    if (error) *error = HAKCHI_USB_OK;
    return dev;
}

int hakchi_usb_bulk_write(hakchi_usb_device_t *dev, uint8_t endpoint,
                          const uint8_t *data, int length, int timeout_ms) {
    if (!dev || !dev->interface) return HAKCHI_USB_ERROR_INVALID_PARAM;
    (void)endpoint; // We use the pre-resolved pipe index

    UInt32 bytes_written = (UInt32)length;
    IOReturn kr = (*dev->interface)->WritePipeTO(dev->interface, dev->pipe_out,
                                                  (void *)data, bytes_written,
                                                  timeout_ms, timeout_ms);

    if (kr == kIOUSBTransactionTimeout) return HAKCHI_USB_ERROR_TIMEOUT;
    if (kr == kIOUSBPipeStalled) return HAKCHI_USB_ERROR_PIPE;
    if (kr != kIOReturnSuccess) return HAKCHI_USB_ERROR_IO;

    return (int)bytes_written;
}

int hakchi_usb_bulk_read(hakchi_usb_device_t *dev, uint8_t endpoint,
                         uint8_t *data, int length, int timeout_ms) {
    if (!dev || !dev->interface) return HAKCHI_USB_ERROR_INVALID_PARAM;
    (void)endpoint;

    UInt32 bytes_read = (UInt32)length;
    IOReturn kr = (*dev->interface)->ReadPipeTO(dev->interface, dev->pipe_in,
                                                 data, &bytes_read,
                                                 timeout_ms, timeout_ms);

    if (kr == kIOUSBTransactionTimeout) return HAKCHI_USB_ERROR_TIMEOUT;
    if (kr == kIOUSBPipeStalled) return HAKCHI_USB_ERROR_PIPE;
    if (kr != kIOReturnSuccess) return HAKCHI_USB_ERROR_IO;

    return (int)bytes_read;
}

hakchi_usb_error_t hakchi_usb_clear_halt(hakchi_usb_device_t *dev, uint8_t endpoint) {
    if (!dev || !dev->interface) return HAKCHI_USB_ERROR_INVALID_PARAM;

    uint8_t pipe = (endpoint & 0x80) ? dev->pipe_in : dev->pipe_out;
    IOReturn kr = (*dev->interface)->ClearPipeStallBothEnds(dev->interface, pipe);

    return (kr == kIOReturnSuccess) ? HAKCHI_USB_OK : HAKCHI_USB_ERROR_IO;
}

hakchi_usb_error_t hakchi_usb_reset(hakchi_usb_device_t *dev) {
    if (!dev || !dev->device) return HAKCHI_USB_ERROR_INVALID_PARAM;

    IOReturn kr = (*dev->device)->ResetDevice(dev->device);
    return (kr == kIOReturnSuccess) ? HAKCHI_USB_OK : HAKCHI_USB_ERROR_IO;
}

void hakchi_usb_close(hakchi_usb_device_t *dev) {
    if (!dev) return;

    if (dev->interface) {
        (*dev->interface)->USBInterfaceClose(dev->interface);
        (*dev->interface)->Release(dev->interface);
    }
    if (dev->device) {
        (*dev->device)->USBDeviceClose(dev->device);
        (*dev->device)->Release(dev->device);
    }
    free(dev);
}

bool hakchi_usb_device_exists(uint16_t vid, uint16_t pid) {
    CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchDict) return false;

    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){vid}));
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){pid}));

    io_iterator_t iterator = 0;
    kern_return_t kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) return false;

    io_service_t service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (service) {
        IOObjectRelease(service);
        return true;
    }
    return false;
}
