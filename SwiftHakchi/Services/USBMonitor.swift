import Foundation
import IOKit
import IOKit.usb

/// Monitors USB for device plug/unplug using IOKit notifications.
///
/// Watches two device types:
/// - FEL bootloader: VID 0x1F3A, PID 0xEFE8 (Full-Speed, 12 Mbps)
/// - RNDIS gadget: VID 0x04E8, PID 0x6863 (appears after memboot with hakchi-shell)
@MainActor
final class USBMonitor: ObservableObject {
    @Published var felDevicePresent: Bool = false
    @Published var rndisDevicePresent: Bool = false

    var devicePresent: Bool { felDevicePresent || rndisDevicePresent }

    // FEL notifications
    private var felNotifyPort: IONotificationPortRef?
    private var felAddedIterator: io_iterator_t = 0
    private var felRemovedIterator: io_iterator_t = 0

    // RNDIS notifications
    private var rndisNotifyPort: IONotificationPortRef?
    private var rndisAddedIterator: io_iterator_t = 0
    private var rndisRemovedIterator: io_iterator_t = 0

    // FEL: VID 0x1F3A, PID 0xEFE8
    private static let felVid: Int32 = 0x1F3A
    private static let felPid: Int32 = 0xEFE8

    // RNDIS: VID 0x04E8, PID 0x6863
    private static let rndisVid: Int32 = 0x04E8
    private static let rndisPid: Int32 = 0x6863

    nonisolated init() {}

    func start() {
        startFELMonitor()
        startRNDISMonitor()
    }

    // MARK: - FEL Monitor

    private func startFELMonitor() {
        felNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = felNotifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addDict = USBMonitor.matchDict(vid: Self.felVid, pid: Self.felPid)
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, addDict,
            { refCon, iterator in
                guard let refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                USBMonitor.drain(iterator)
                Task { @MainActor in monitor.updateFELState() }
            },
            selfPtr, &felAddedIterator
        )
        USBMonitor.drain(felAddedIterator)

        let removeDict = USBMonitor.matchDict(vid: Self.felVid, pid: Self.felPid)
        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, removeDict,
            { refCon, iterator in
                guard let refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                USBMonitor.drain(iterator)
                Task { @MainActor in monitor.updateFELState() }
            },
            selfPtr, &felRemovedIterator
        )
        USBMonitor.drain(felRemovedIterator)

        updateFELState()
    }

    // MARK: - RNDIS Monitor

    private func startRNDISMonitor() {
        rndisNotifyPort = IONotificationPortCreate(kIOMainPortDefault)
        guard let port = rndisNotifyPort else { return }

        let runLoopSource = IONotificationPortGetRunLoopSource(port).takeUnretainedValue()
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .defaultMode)

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let addDict = USBMonitor.matchDict(vid: Self.rndisVid, pid: Self.rndisPid)
        IOServiceAddMatchingNotification(
            port, kIOFirstMatchNotification, addDict,
            { refCon, iterator in
                guard let refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                USBMonitor.drain(iterator)
                Task { @MainActor in monitor.updateRNDISState() }
            },
            selfPtr, &rndisAddedIterator
        )
        USBMonitor.drain(rndisAddedIterator)

        let removeDict = USBMonitor.matchDict(vid: Self.rndisVid, pid: Self.rndisPid)
        IOServiceAddMatchingNotification(
            port, kIOTerminatedNotification, removeDict,
            { refCon, iterator in
                guard let refCon else { return }
                let monitor = Unmanaged<USBMonitor>.fromOpaque(refCon).takeUnretainedValue()
                USBMonitor.drain(iterator)
                Task { @MainActor in monitor.updateRNDISState() }
            },
            selfPtr, &rndisRemovedIterator
        )
        USBMonitor.drain(rndisRemovedIterator)

        updateRNDISState()
    }

    // MARK: - State Updates

    private func updateFELState() {
        felDevicePresent = USBMonitor.devicePresent(vid: Self.felVid, pid: Self.felPid)
    }

    private func updateRNDISState() {
        rndisDevicePresent = USBMonitor.devicePresent(vid: Self.rndisVid, pid: Self.rndisPid)
    }

    func stop() {
        if felAddedIterator != 0 { IOObjectRelease(felAddedIterator); felAddedIterator = 0 }
        if felRemovedIterator != 0 { IOObjectRelease(felRemovedIterator); felRemovedIterator = 0 }
        if let port = felNotifyPort { IONotificationPortDestroy(port); felNotifyPort = nil }

        if rndisAddedIterator != 0 { IOObjectRelease(rndisAddedIterator); rndisAddedIterator = 0 }
        if rndisRemovedIterator != 0 { IOObjectRelease(rndisRemovedIterator); rndisRemovedIterator = 0 }
        if let port = rndisNotifyPort { IONotificationPortDestroy(port); rndisNotifyPort = nil }
    }

    // MARK: - Helpers

    private nonisolated static func matchDict(vid: Int32, pid: Int32) -> NSMutableDictionary {
        let dict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        dict[kUSBVendorID] = vid
        dict[kUSBProductID] = pid
        return dict
    }

    private nonisolated static func drain(_ iterator: io_iterator_t) {
        while case let service = IOIteratorNext(iterator), service != 0 {
            IOObjectRelease(service)
        }
    }

    /// Check if a USB device with given VID/PID is present.
    private nonisolated static func devicePresent(vid: Int32, pid: Int32) -> Bool {
        let dict = IOServiceMatching(kIOUSBDeviceClassName) as NSMutableDictionary
        dict[kUSBVendorID] = vid
        dict[kUSBProductID] = pid

        var iterator: io_iterator_t = 0
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, dict, &iterator)
        guard kr == KERN_SUCCESS else { return false }
        defer { IOObjectRelease(iterator) }

        let service = IOIteratorNext(iterator)
        guard service != 0 else { return false }
        IOObjectRelease(service)
        return true
    }

    deinit {
        // Clean up happens in stop()
    }
}
