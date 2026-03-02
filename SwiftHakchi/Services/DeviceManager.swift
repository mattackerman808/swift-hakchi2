import Foundation
import Combine
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "DeviceManager")

/// Manages console connection lifecycle: USB detection → SSH connect → device probe.
///
/// Watches two device types:
/// - FEL bootloader (VID 0x1F3A PID 0xEFE8) — for flashing
/// - RNDIS gadget (VID 0x04E8 PID 0x6863) — for SSH communication
///
/// When RNDIS appears:
/// 1. Wait for USB to stabilize
/// 2. Connect via SSH over RNDIS (user-space network stack)
/// 3. Probe device: read version info, detect console type
/// 4. Set isConnected = true
@MainActor
final class DeviceManager: ObservableObject {
    // MARK: - Published state
    @Published var isConnected: Bool = false
    @Published var felDevicePresent: Bool = false
    @Published var consoleType: ConsoleType = .unknown
    @Published var customFirmwareLoaded: Bool = false
    @Published var canSync: Bool = false
    @Published var canInteract: Bool = false

    // Version info
    @Published var bootVersion: String = ""
    @Published var kernelVersion: String = ""
    @Published var scriptVersion: String = ""
    @Published var uniqueId: String = ""

    // MARK: - Services
    let usbMonitor = USBMonitor()
    let felService = FELService()
    private(set) var sshService: SSHService?

    /// Set to true before flash operations to prevent DeviceManager from auto-connecting.
    /// When set, device appearance only sets felDevicePresent (no SSH probe).
    var suppressAutoConnect: Bool = false {
        didSet {
            if suppressAutoConnect {
                connectTask?.cancel()
                connectTask = nil
            } else if !suppressAutoConnect && oldValue {
                Self.debugLog("suppressAutoConnect cleared: rndis=\(usbMonitor.rndisDevicePresent)")
                if usbMonitor.rndisDevicePresent {
                    Self.debugLog("RNDIS device already present, triggering connect")
                    onRNDISDeviceAppeared()
                }
            }
        }
    }

    private var cancellables = Set<AnyCancellable>()
    private var connectTask: Task<Void, Never>?

    // Version minimums
    private let minBootVersion = VersionTuple(1, 0, 2)
    private let minKernelVersion = VersionTuple(3, 4, 113)
    private let minScriptVersion = VersionTuple(1, 0, 4, 118)

    init() {}

    /// Write debug messages to a file since stdout isn't captured from GUI apps
    static func debugLog(_ msg: String) {
        let line = "[\(ISO8601DateFormatter().string(from: Date()))] \(msg)\n"
        let path = "/tmp/swifthakchi-debug.log"
        if let fh = FileHandle(forWritingAtPath: path) {
            fh.seekToEndOfFile()
            fh.write(Data(line.utf8))
            fh.closeFile()
        } else {
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    func start() {
        usbMonitor.start()

        // FEL device — just track presence
        usbMonitor.$felDevicePresent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] present in
                guard let self else { return }
                self.felDevicePresent = present
                if present {
                    logger.info("FEL device detected")
                }
            }
            .store(in: &cancellables)

        // RNDIS device — auto-connect via SSH
        usbMonitor.$rndisDevicePresent
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] present in
                guard let self else { return }
                if present {
                    self.onRNDISDeviceAppeared()
                } else {
                    self.onRNDISDeviceDisappeared()
                }
            }
            .store(in: &cancellables)
    }

    func stop() {
        usbMonitor.stop()
        connectTask?.cancel()
        disconnect()
    }

    // MARK: - USB Device Events

    private func onRNDISDeviceAppeared() {
        Self.debugLog("onRNDISDeviceAppeared: suppress=\(self.suppressAutoConnect)")
        if suppressAutoConnect { return }

        connectTask?.cancel()
        connectTask = Task { @MainActor in
            // Wait for USB gadget to stabilize
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else {
                Self.debugLog("Connect task cancelled during sleep")
                return
            }

            // Retry SSH connection indefinitely while RNDIS device is present.
            // The console's SSH server may take several seconds after RNDIS
            // appears, and previous stale TCP state can cause early failures.
            var attempt = 0
            while !Task.isCancelled && self.usbMonitor.rndisDevicePresent {
                attempt += 1
                Self.debugLog("SSH connect attempt \(attempt)")
                let success = await self.trySSHConnect()
                if success { return }
                try? await Task.sleep(for: .seconds(3))
            }
            Self.debugLog("SSH connect loop ended: cancelled=\(Task.isCancelled) rndis=\(self.usbMonitor.rndisDevicePresent)")
        }
    }

    private func onRNDISDeviceDisappeared() {
        Self.debugLog("onRNDISDeviceDisappeared")
        connectTask?.cancel()
        disconnect()
    }

    // MARK: - SSH Probe

    /// Try to connect via SSH over RNDIS. If it works, probe the device.
    /// Returns true on success.
    @discardableResult
    private func trySSHConnect() async -> Bool {
        Self.debugLog("trySSHConnect: starting")
        let shell = SSHService()
        do {
            try await shell.connect()
            Self.debugLog("trySSHConnect: connected, testing...")

            let testResult = try await shell.execute("echo ok", timeout: 5000)
            guard testResult.succeeded, testResult.output == "ok" else {
                Self.debugLog("trySSHConnect: test failed")
                await shell.disconnect()
                return false
            }

            Self.debugLog("trySSHConnect: test passed — probing device")
            sshService = shell
            await probeDevice()
            Self.debugLog("trySSHConnect: probe complete, isConnected=\(isConnected)")
            return isConnected
        } catch {
            Self.debugLog("trySSHConnect: error — \(error.localizedDescription)")
            await shell.disconnect()
            return false
        }
    }

    private func disconnect() {
        if let shell = sshService {
            Task { await shell.disconnect() }
        }
        sshService = nil
        isConnected = false
        canSync = false
        canInteract = false
        customFirmwareLoaded = false
        consoleType = .unknown
        bootVersion = ""
        kernelVersion = ""
        scriptVersion = ""
        uniqueId = ""
    }

    // MARK: - Device Probing

    private func probeDevice() async {
        guard let shell = sshService else {
            Self.debugLog("probeDevice: no sshService")
            return
        }
        Self.debugLog("probeDevice: starting")

        do {
            // Read unique ID
            let uidResult = try await shell.execute("cat /etc/clover/uid 2>/dev/null")
            if uidResult.succeeded {
                uniqueId = uidResult.output
            }

            // Read version info
            let hasVersion = try await shell.execute("[ -f /var/version ] && echo yes")
            if hasVersion.output == "yes" {
                let versionResult = try await shell.execute(
                    "source /var/version && echo \"$bootVersion $kernelVersion $hakchiVersion\""
                )
                let parts = versionResult.output.components(separatedBy: " ")
                if parts.count >= 3 {
                    bootVersion = parts[0]
                    kernelVersion = parts[1]
                    scriptVersion = parts[2]
                } else if parts.count >= 2 {
                    bootVersion = parts[0]
                    kernelVersion = parts[1]
                    let unameResult = try await shell.execute("uname -r")
                    if kernelVersion.isEmpty {
                        kernelVersion = unameResult.output
                    }
                }
            } else {
                bootVersion = "1.0.0"
                let unameResult = try await shell.execute("uname -r")
                kernelVersion = unameResult.output
                scriptVersion = "v1.0.0-000"
            }

            // Parse and check versions
            let bootVer = VersionTuple.parse(bootVersion)
            let kernelVer = VersionTuple.parse(kernelVersion)
            let scriptVer = VersionTuple.parse(scriptVersion)

            canInteract = bootVer >= minBootVersion
                && kernelVer >= minKernelVersion
                && scriptVer >= minScriptVersion

            // Detect console type (3-method cascade)
            var systemCode = ""

            let sysCodeResult = try await shell.execute("cat /etc/clover/system_code 2>/dev/null")
            if sysCodeResult.succeeded && !sysCodeResult.output.isEmpty {
                systemCode = sysCodeResult.output
            }

            if systemCode.isEmpty || ConsoleType.fromSystemCode(systemCode) == .unknown {
                let evalResult = try await shell.execute(
                    "hakchi eval 'echo \"$sftype-$sfregion\"' 2>/dev/null"
                )
                if evalResult.succeeded && !evalResult.output.isEmpty {
                    systemCode = evalResult.output
                }
            }

            if systemCode.isEmpty || ConsoleType.fromSystemCode(systemCode) == .unknown {
                let srcResult = try await shell.execute(
                    "source /var/version 2>/dev/null && echo \"$sftype-$sfregion\""
                )
                if srcResult.succeeded && !srcResult.output.isEmpty {
                    systemCode = srcResult.output
                }
            }

            consoleType = ConsoleType.fromSystemCode(systemCode)

            // Check if custom firmware is loaded
            if canInteract {
                let cfResult = try await shell.execute("ls /var/lib/hakchi/ 2>/dev/null")
                customFirmwareLoaded = cfResult.succeeded
                canSync = true
            }

            isConnected = true
            Self.debugLog("probeDevice: SUCCESS type=\(self.consoleType.rawValue) fw=\(self.customFirmwareLoaded) canInteract=\(self.canInteract)")

        } catch {
            Self.debugLog("probeDevice: FAILED \(error.localizedDescription)")
            isConnected = false
        }
    }
}

// MARK: - Version Parsing

struct VersionTuple: Comparable {
    let components: [Int]

    init(_ values: Int...) {
        components = values
    }

    static func parse(_ string: String) -> VersionTuple {
        let pattern = #"(?:\d+[\.-]){2,}(?:\d+)+"#
        guard let range = string.range(of: pattern, options: .regularExpression) else {
            return VersionTuple(0, 0, 0, 0)
        }
        let versionStr = String(string[range])
        let parts = versionStr
            .replacingOccurrences(of: "-", with: ".")
            .components(separatedBy: ".")
            .compactMap { Int($0) }
        return VersionTuple(parts: parts)
    }

    private init(parts: [Int]) {
        components = parts
    }

    static func < (lhs: VersionTuple, rhs: VersionTuple) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return l < r }
        }
        return false
    }

    static func == (lhs: VersionTuple, rhs: VersionTuple) -> Bool {
        let maxLen = max(lhs.components.count, rhs.components.count)
        for i in 0..<maxLen {
            let l = i < lhs.components.count ? lhs.components[i] : 0
            let r = i < rhs.components.count ? rhs.components[i] : 0
            if l != r { return false }
        }
        return true
    }
}
