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

    setbuf(stderr, NULL);
    fprintf(stderr, "[USB] Opening device VID=0x%04X PID=0x%04X\n", vid, pid);

    // Create matching dictionary for USB device
    CFMutableDictionaryRef matchDict = IOServiceMatching(kIOUSBDeviceClassName);
    if (!matchDict) {
        fprintf(stderr, "[USB] IOServiceMatching returned NULL\n");
        if (error) *error = HAKCHI_USB_ERROR_OTHER;
        return NULL;
    }

    CFDictionarySetValue(matchDict, CFSTR(kUSBVendorID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){vid}));
    CFDictionarySetValue(matchDict, CFSTR(kUSBProductID),
        CFNumberCreate(kCFAllocatorDefault, kCFNumberSInt32Type, &(int32_t){pid}));

    kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator);
    if (kr != KERN_SUCCESS) {
        fprintf(stderr, "[USB] IOServiceGetMatchingServices failed: 0x%x\n", kr);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    usb_service = IOIteratorNext(iterator);
    IOObjectRelease(iterator);

    if (!usb_service) {
        fprintf(stderr, "[USB] No matching USB service found\n");
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }
    fprintf(stderr, "[USB] Found USB service\n");

    // Get device interface
    IOCFPlugInInterface **plugIn = NULL;
    SInt32 score;
    kr = IOCreatePlugInInterfaceForService(usb_service, kIOUSBDeviceUserClientTypeID,
                                           kIOCFPlugInInterfaceID, &plugIn, &score);
    IOObjectRelease(usb_service);

    if (kr != KERN_SUCCESS || !plugIn) {
        fprintf(stderr, "[USB] IOCreatePlugInInterface failed: 0x%x\n", kr);
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    IOUSBDeviceInterface300 **device = NULL;
    (*plugIn)->QueryInterface(plugIn, CFUUIDGetUUIDBytes(kIOUSBDeviceInterfaceID300),
                              (LPVOID *)&device);
    (*plugIn)->Release(plugIn);

    if (!device) {
        fprintf(stderr, "[USB] QueryInterface for device failed\n");
        if (error) *error = HAKCHI_USB_ERROR_ACCESS;
        return NULL;
    }

    // Open device
    kr = (*device)->USBDeviceOpen(device);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "[USB] USBDeviceOpen failed: 0x%x, trying seize\n", kr);
        // Try with seize
        kr = (*device)->USBDeviceOpenSeize(device);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "[USB] USBDeviceOpenSeize also failed: 0x%x\n", kr);
            (*device)->Release(device);
            if (error) *error = HAKCHI_USB_ERROR_ACCESS;
            return NULL;
        }
    }
    fprintf(stderr, "[USB] Device opened\n");

    // Set configuration (use first config)
    IOUSBConfigurationDescriptorPtr configDesc;
    kr = (*device)->GetConfigurationDescriptorPtr(device, 0, &configDesc);
    if (kr == kIOReturnSuccess) {
        (*device)->SetConfiguration(device, configDesc->bConfigurationValue);
    }

    // Iterate through all interfaces to find one with bulk endpoints
    IOUSBFindInterfaceRequest req;
    req.bInterfaceClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceSubClass = kIOUSBFindInterfaceDontCare;
    req.bInterfaceProtocol = kIOUSBFindInterfaceDontCare;
    req.bAlternateSetting = kIOUSBFindInterfaceDontCare;

    io_iterator_t intfIterator;
    kr = (*device)->CreateInterfaceIterator(device, &req, &intfIterator);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "[USB] CreateInterfaceIterator failed: 0x%x\n", kr);
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_OTHER;
        return NULL;
    }

    IOUSBInterfaceInterface300 **interface = NULL;
    io_service_t intfService;
    int intfIndex = 0;

    while ((intfService = IOIteratorNext(intfIterator)) != 0) {
        fprintf(stderr, "[USB] Trying interface %d\n", intfIndex);

        IOCFPlugInInterface **intfPlugIn = NULL;
        kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &intfPlugIn, &score);
        IOObjectRelease(intfService);

        if (kr != KERN_SUCCESS || !intfPlugIn) {
            fprintf(stderr, "[USB]   PlugIn creation failed for interface %d\n", intfIndex);
            intfIndex++;
            continue;
        }

        IOUSBInterfaceInterface300 **candidateIntf = NULL;
        (*intfPlugIn)->QueryInterface(intfPlugIn,
            CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
            (LPVOID *)&candidateIntf);
        (*intfPlugIn)->Release(intfPlugIn);

        if (!candidateIntf) {
            fprintf(stderr, "[USB]   QueryInterface failed for interface %d\n", intfIndex);
            intfIndex++;
            continue;
        }

        kr = (*candidateIntf)->USBInterfaceOpen(candidateIntf);
        if (kr != kIOReturnSuccess) {
            fprintf(stderr, "[USB]   USBInterfaceOpen failed for interface %d: 0x%x\n", intfIndex, kr);
            (*candidateIntf)->Release(candidateIntf);
            intfIndex++;
            continue;
        }

        // Check if this interface has bulk endpoints
        UInt8 numEp = 0;
        (*candidateIntf)->GetNumEndpoints(candidateIntf, &numEp);
        fprintf(stderr, "[USB]   Interface %d has %d endpoints\n", intfIndex, numEp);

        bool hasBulkOut = false, hasBulkIn = false;
        for (UInt8 i = 1; i <= numEp; i++) {
            UInt8 direction, number, transferType, interval;
            UInt16 maxPacketSize;
            (*candidateIntf)->GetPipeProperties(candidateIntf, i, &direction, &number,
                                                &transferType, &maxPacketSize, &interval);
            uint8_t addr = number | (direction == kUSBIn ? 0x80 : 0x00);
            fprintf(stderr, "[USB]     Pipe %d: addr=0x%02X dir=%s type=%d maxPkt=%d\n",
                    i, addr, direction == kUSBIn ? "IN" : "OUT", transferType, maxPacketSize);
            if (transferType == kUSBBulk) {
                if (direction == kUSBOut) hasBulkOut = true;
                if (direction == kUSBIn) hasBulkIn = true;
            }
        }

        if (hasBulkOut && hasBulkIn) {
            fprintf(stderr, "[USB]   Interface %d has bulk endpoints — using it\n", intfIndex);
            interface = candidateIntf;
            break;
        }

        // Not the right interface, close and try next
        (*candidateIntf)->USBInterfaceClose(candidateIntf);
        (*candidateIntf)->Release(candidateIntf);
        intfIndex++;
    }
    IOObjectRelease(intfIterator);

    if (!interface) {
        fprintf(stderr, "[USB] No interface with bulk endpoints found\n");
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }
    fprintf(stderr, "[USB] Interface opened (index %d)\n", intfIndex);

    // Find pipe indices for our endpoints.
    // Try alternate setting 0 first (Clovershell gadget), then 1 (FEL protocol).
    hakchi_usb_device_t *dev = calloc(1, sizeof(hakchi_usb_device_t));
    dev->device = device;
    dev->interface = interface;

    // Enumerate all endpoints to find bulk IN and OUT pipes
    UInt8 num_endpoints = 0;
    (*interface)->GetNumEndpoints(interface, &num_endpoints);
    fprintf(stderr, "[USB] Interface has %d endpoints (alt 0)\n", num_endpoints);

    // Log all available endpoints
    for (UInt8 i = 1; i <= num_endpoints; i++) {
        UInt8 direction, number, transferType, interval;
        UInt16 maxPacketSize;
        (*interface)->GetPipeProperties(interface, i, &direction, &number, &transferType,
                                       &maxPacketSize, &interval);
        uint8_t addr = number | (direction == kUSBIn ? 0x80 : 0x00);
        fprintf(stderr, "[USB]   Pipe %d: addr=0x%02X dir=%s type=%d maxPkt=%d\n",
                i, addr, direction == kUSBIn ? "IN" : "OUT", transferType, maxPacketSize);
    }

    // Try to find bulk endpoints — first try known addresses, then any bulk pair
    bool found = false;

    // Try 0x01/0x82 (FEL standard)
    if (find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) &&
        find_pipe_for_endpoint(interface, 0x82, &dev->pipe_in)) {
        found = true;
        fprintf(stderr, "[USB] Found endpoints 0x01/0x82\n");
    }

    // Try 0x01/0x81 (Clovershell may use this)
    if (!found && find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) &&
        find_pipe_for_endpoint(interface, 0x81, &dev->pipe_in)) {
        found = true;
        fprintf(stderr, "[USB] Found endpoints 0x01/0x81\n");
    }

    // If alt 0 didn't work, try alt 1
    if (!found) {
        fprintf(stderr, "[USB] Trying alternate setting 1\n");
        (*interface)->SetAlternateInterface(interface, 1);
        (*interface)->GetNumEndpoints(interface, &num_endpoints);
        fprintf(stderr, "[USB] Interface has %d endpoints (alt 1)\n", num_endpoints);

        for (UInt8 i = 1; i <= num_endpoints; i++) {
            UInt8 direction, number, transferType, interval;
            UInt16 maxPacketSize;
            (*interface)->GetPipeProperties(interface, i, &direction, &number, &transferType,
                                           &maxPacketSize, &interval);
            uint8_t addr = number | (direction == kUSBIn ? 0x80 : 0x00);
            fprintf(stderr, "[USB]   Pipe %d: addr=0x%02X dir=%s type=%d maxPkt=%d\n",
                    i, addr, direction == kUSBIn ? "IN" : "OUT", transferType, maxPacketSize);
        }

        if (find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) &&
            find_pipe_for_endpoint(interface, 0x82, &dev->pipe_in)) {
            found = true;
        } else if (find_pipe_for_endpoint(interface, 0x01, &dev->pipe_out) &&
                   find_pipe_for_endpoint(interface, 0x81, &dev->pipe_in)) {
            found = true;
        }
    }

    // Last resort: find any bulk OUT and bulk IN pair
    if (!found) {
        fprintf(stderr, "[USB] Searching for any bulk endpoint pair\n");
        for (UInt8 i = 1; i <= num_endpoints; i++) {
            UInt8 direction, number, transferType, interval;
            UInt16 maxPacketSize;
            (*interface)->GetPipeProperties(interface, i, &direction, &number, &transferType,
                                           &maxPacketSize, &interval);
            if (transferType == kUSBBulk) {
                if (direction == kUSBOut && dev->pipe_out == 0) dev->pipe_out = i;
                if (direction == kUSBIn && dev->pipe_in == 0) dev->pipe_in = i;
            }
        }
        found = (dev->pipe_out != 0 && dev->pipe_in != 0);
        if (found) {
            fprintf(stderr, "[USB] Found bulk pair: out=pipe%d in=pipe%d\n",
                    dev->pipe_out, dev->pipe_in);
        }
    }

    if (!found) {
        fprintf(stderr, "[USB] No suitable endpoints found\n");
        hakchi_usb_close(dev);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
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
    if (kr == kIOUSBPipeStalled) {
        fprintf(stderr, "[USB] Read: pipe stalled, clearing\n");
        (*dev->interface)->ClearPipeStallBothEnds(dev->interface, dev->pipe_in);
        return HAKCHI_USB_ERROR_PIPE;
    }
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "[USB] Read failed: IOReturn=0x%08X pipe=%d\n", kr, dev->pipe_in);
        return HAKCHI_USB_ERROR_IO;
    }

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

int hakchi_usb_control_transfer(hakchi_usb_device_t *dev,
                                 uint8_t bmRequestType, uint8_t bRequest,
                                 uint16_t wValue, uint16_t wIndex,
                                 uint8_t *data, uint16_t wLength,
                                 int timeout_ms) {
    if (!dev || !dev->device) return HAKCHI_USB_ERROR_INVALID_PARAM;
    (void)timeout_ms; // IOKit DeviceRequest doesn't have a separate timeout

    IOUSBDevRequest req;
    req.bmRequestType = bmRequestType;
    req.bRequest = bRequest;
    req.wValue = wValue;
    req.wIndex = wIndex;
    req.wLength = wLength;
    req.pData = data;
    req.wLenDone = 0;

    IOReturn kr = (*dev->device)->DeviceRequest(dev->device, &req);
    if (kr != kIOReturnSuccess) {
        fprintf(stderr, "[USB] Control transfer failed: 0x%08X\n", kr);
        return HAKCHI_USB_ERROR_IO;
    }
    return (int)req.wLenDone;
}

int hakchi_usb_bulk_write_pipe(hakchi_usb_device_t *dev, uint8_t pipe_index,
                                const uint8_t *data, int length, int timeout_ms) {
    if (!dev || !dev->interface) return HAKCHI_USB_ERROR_INVALID_PARAM;

    UInt32 bytes_written = (UInt32)length;
    IOReturn kr = (*dev->interface)->WritePipeTO(dev->interface, pipe_index,
                                                  (void *)data, bytes_written,
                                                  timeout_ms, timeout_ms);
    if (kr == kIOUSBTransactionTimeout) return HAKCHI_USB_ERROR_TIMEOUT;
    if (kr == kIOUSBPipeStalled) return HAKCHI_USB_ERROR_PIPE;
    if (kr != kIOReturnSuccess) return HAKCHI_USB_ERROR_IO;
    return (int)bytes_written;
}

int hakchi_usb_bulk_read_pipe(hakchi_usb_device_t *dev, uint8_t pipe_index,
                               uint8_t *data, int length, int timeout_ms) {
    if (!dev || !dev->interface) return HAKCHI_USB_ERROR_INVALID_PARAM;

    UInt32 bytes_read = (UInt32)length;
    IOReturn kr = (*dev->interface)->ReadPipeTO(dev->interface, pipe_index,
                                                 data, &bytes_read,
                                                 timeout_ms, timeout_ms);
    if (kr == kIOUSBTransactionTimeout) return HAKCHI_USB_ERROR_TIMEOUT;
    if (kr == kIOUSBPipeStalled) {
        (*dev->interface)->ClearPipeStallBothEnds(dev->interface, pipe_index);
        return HAKCHI_USB_ERROR_PIPE;
    }
    if (kr != kIOReturnSuccess) return HAKCHI_USB_ERROR_IO;
    return (int)bytes_read;
}

uint8_t hakchi_usb_get_pipe_in(hakchi_usb_device_t *dev) {
    return dev ? dev->pipe_in : 0;
}

uint8_t hakchi_usb_get_pipe_out(hakchi_usb_device_t *dev) {
    return dev ? dev->pipe_out : 0;
}

hakchi_usb_device_t *hakchi_usb_open_rndis(uint16_t vid, uint16_t pid,
                                            hakchi_usb_error_t *error) {
    kern_return_t kr;
    io_iterator_t iterator = 0;
    io_service_t usb_service = 0;

    fprintf(stderr, "[USB-RNDIS] Opening RNDIS device VID=0x%04X PID=0x%04X\n", vid, pid);

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

    kr = (*device)->USBDeviceOpen(device);
    if (kr != kIOReturnSuccess) {
        kr = (*device)->USBDeviceOpenSeize(device);
        if (kr != kIOReturnSuccess) {
            (*device)->Release(device);
            if (error) *error = HAKCHI_USB_ERROR_ACCESS;
            return NULL;
        }
    }

    // Set configuration
    IOUSBConfigurationDescriptorPtr configDesc;
    kr = (*device)->GetConfigurationDescriptorPtr(device, 0, &configDesc);
    if (kr == kIOReturnSuccess) {
        (*device)->SetConfiguration(device, configDesc->bConfigurationValue);
    }

    // RNDIS: interface 0 = control (CDC), interface 1 = data (bulk IN/OUT)
    // We need to claim both, but only open/use interface 1 for bulk transfers.
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

    IOUSBInterfaceInterface300 **dataInterface = NULL;
    io_service_t intfService;
    int intfIndex = 0;

    while ((intfService = IOIteratorNext(intfIterator)) != 0) {
        IOCFPlugInInterface **intfPlugIn = NULL;
        kr = IOCreatePlugInInterfaceForService(intfService, kIOUSBInterfaceUserClientTypeID,
                                               kIOCFPlugInInterfaceID, &intfPlugIn, &score);
        IOObjectRelease(intfService);

        if (kr != KERN_SUCCESS || !intfPlugIn) { intfIndex++; continue; }

        IOUSBInterfaceInterface300 **intf = NULL;
        (*intfPlugIn)->QueryInterface(intfPlugIn,
            CFUUIDGetUUIDBytes(kIOUSBInterfaceInterfaceID300),
            (LPVOID *)&intf);
        (*intfPlugIn)->Release(intfPlugIn);

        if (!intf) { intfIndex++; continue; }

        kr = (*intf)->USBInterfaceOpen(intf);
        if (kr != kIOReturnSuccess) {
            (*intf)->Release(intf);
            intfIndex++;
            continue;
        }

        // Interface 0 = control (no bulk endpoints, just claim it)
        // Interface 1 = data (bulk endpoints)
        UInt8 numEp = 0;
        (*intf)->GetNumEndpoints(intf, &numEp);
        fprintf(stderr, "[USB-RNDIS] Interface %d has %d endpoints\n", intfIndex, numEp);

        bool hasBulk = false;
        for (UInt8 i = 1; i <= numEp; i++) {
            UInt8 direction, number, transferType, interval;
            UInt16 maxPacketSize;
            (*intf)->GetPipeProperties(intf, i, &direction, &number, &transferType,
                                       &maxPacketSize, &interval);
            fprintf(stderr, "[USB-RNDIS]   Pipe %d: addr=0x%02X dir=%s type=%d maxPkt=%d\n",
                    i, number | (direction == kUSBIn ? 0x80 : 0x00),
                    direction == kUSBIn ? "IN" : "OUT", transferType, maxPacketSize);
            if (transferType == kUSBBulk) hasBulk = true;
        }

        if (hasBulk && !dataInterface) {
            dataInterface = intf;
            fprintf(stderr, "[USB-RNDIS] Using interface %d as data interface\n", intfIndex);
        } else {
            // Keep interface 0 open (claimed) but don't store it — we use control transfers
            // via the device interface for RNDIS control messages. Close interfaces we don't need.
            if (!hasBulk) {
                fprintf(stderr, "[USB-RNDIS] Interface %d claimed (control)\n", intfIndex);
                // Don't close it — keep it claimed so macOS doesn't grab it
                (*intf)->Release(intf); // Release our ref, kernel keeps interface claimed
            } else {
                (*intf)->USBInterfaceClose(intf);
                (*intf)->Release(intf);
            }
        }
        intfIndex++;
    }
    IOObjectRelease(intfIterator);

    if (!dataInterface) {
        fprintf(stderr, "[USB-RNDIS] No data interface with bulk endpoints found\n");
        (*device)->USBDeviceClose(device);
        (*device)->Release(device);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    hakchi_usb_device_t *dev = calloc(1, sizeof(hakchi_usb_device_t));
    dev->device = device;
    dev->interface = dataInterface;

    // Find bulk IN and OUT pipes on the data interface
    UInt8 numEp = 0;
    (*dataInterface)->GetNumEndpoints(dataInterface, &numEp);
    for (UInt8 i = 1; i <= numEp; i++) {
        UInt8 direction, number, transferType, interval;
        UInt16 maxPacketSize;
        (*dataInterface)->GetPipeProperties(dataInterface, i, &direction, &number,
                                            &transferType, &maxPacketSize, &interval);
        if (transferType == kUSBBulk) {
            if (direction == kUSBIn && dev->pipe_in == 0) dev->pipe_in = i;
            if (direction == kUSBOut && dev->pipe_out == 0) dev->pipe_out = i;
        }
    }

    if (dev->pipe_in == 0 || dev->pipe_out == 0) {
        fprintf(stderr, "[USB-RNDIS] Could not find bulk endpoints\n");
        hakchi_usb_close(dev);
        if (error) *error = HAKCHI_USB_ERROR_NOT_FOUND;
        return NULL;
    }

    fprintf(stderr, "[USB-RNDIS] Ready: bulk_in=pipe%d bulk_out=pipe%d\n",
            dev->pipe_in, dev->pipe_out);
    if (error) *error = HAKCHI_USB_OK;
    return dev;
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
