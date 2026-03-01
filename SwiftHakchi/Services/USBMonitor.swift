import Foundation
import IOKit
import IOKit.usb

/// Monitors USB for FEL device plug/unplug using IOKit notifications
@MainActor
final class USBMonitor: ObservableObject {
    @Published var felDevicePresent: Bool = false

    private var notifyPort: IONotificationPortRef?
    private var addedIterator: io_iterator_t = 0
    private var removedIterator: io_iterator_t = 0
    private let vid: Int32 = 0x1F3A
    private let pid: Int32 = 0xEFE8

    nonisolated init() {}

    func start() {
        notifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let notifyPort = notifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(notifyPort).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let matchDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchDict[kUSBVendorID] = vid
        matchDict[kUSBProductID] = pid

        // We need two copies of the matching dictionary (IOKit consumes them)
        let matchDictAdd = matchDict.mutableCopy() as! NSMutableDictionary
        let matchDictRemove = matchDict.mutableCopy() as! NSMutableDictionary

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        // Register for device added
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOFirstMatchNotification,
            matchDictAdd,
            { refCon, iterator in
                guard let refCon = refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                // Drain the iterator
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                Task { @MainActor in
                    monitor.felDevicePresent = true
                }
            },
            selfPtr,
            &addedIterator
        )
        // Drain initial matches
        while case let service = IOIteratorNext(addedIterator), service != 0 {
            IOObjectRelease(service)
            Task { @MainActor in
                self.felDevicePresent = true
            }
        }

        // Register for device removed
        IOServiceAddMatchingNotification(
            notifyPort,
            kIOTerminatedNotification,
            matchDictRemove,
            { refCon, iterator in
                guard let refCon = refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                while case let service = IOIteratorNext(iterator), service != 0 {
                    IOObjectRelease(service)
                }
                Task { @MainActor in
                    monitor.felDevicePresent = false
                }
            },
            selfPtr,
            &removedIterator
        )
        // Drain initial
        while case let service = IOIteratorNext(removedIterator), service != 0 {
            IOObjectRelease(service)
        }

        // Check current state
        felDevicePresent = checkDeviceExists()
    }

    func stop() {
        if addedIterator != 0 {
            IOObjectRelease(addedIterator)
            addedIterator = 0
        }
        if removedIterator != 0 {
            IOObjectRelease(removedIterator)
            removedIterator = 0
        }
        if let port = notifyPort {
            IONotificationPortDestroy(port)
            notifyPort = nil
        }
    }

    private nonisolated func checkDeviceExists() -> Bool {
        let matchDict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        matchDict[kUSBVendorID] = Int32(0x1F3A)
        matchDict[kUSBProductID] = Int32(0xEFE8)

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matchDict, &iterator)
        guard kr == KERN_SUCCESS else { return false }

        let service = IOIteratorNext(iterator)
        IOObjectRelease(iterator)
        if service != 0 {
            IOObjectRelease(service)
            return true
        }
        return false
    }

    deinit {
        // Clean up happens in stop()
    }
}
