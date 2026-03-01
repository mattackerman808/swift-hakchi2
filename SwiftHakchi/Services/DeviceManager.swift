import Foundation
import Combine

/// Manages console connection lifecycle: USB FEL detection, Bonjour discovery, SSH probe
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
    private var bonjourBrowser: BonjourBrowser?

    private var cancellables = Set<AnyCancellable>()

    // Version minimums
    private let minBootVersion = VersionTuple(1, 0, 2)
    private let minKernelVersion = VersionTuple(3, 4, 113)
    private let minScriptVersion = VersionTuple(1, 0, 4, 118)

    init() {}

    func start() {
        // Start USB monitoring
        usbMonitor.start()

        // Forward FEL state
        usbMonitor.$felDevicePresent
            .receive(on: DispatchQueue.main)
            .sink { [weak self] present in
                self?.felDevicePresent = present
            }
            .store(in: &cancellables)

        // Start Bonjour discovery
        bonjourBrowser = BonjourBrowser()
        bonjourBrowser?.onServiceFound = { [weak self] host, port in
            Task { @MainActor in
                await self?.connectSSH(host: host, port: port)
            }
        }
        bonjourBrowser?.onServiceLost = { [weak self] in
            Task { @MainActor in
                self?.disconnect()
            }
        }
        bonjourBrowser?.start()
    }

    func stop() {
        usbMonitor.stop()
        bonjourBrowser?.stop()
        disconnect()
    }

    // MARK: - SSH Connection

    private func connectSSH(host: String, port: Int) async {
        let ssh = SSHService()
        do {
            try await ssh.connect(host: host, port: port)
            sshService = ssh
            await probeDevice()
        } catch {
            sshService = nil
            isConnected = false
        }
    }

    private func disconnect() {
        Task {
            await sshService?.disconnect()
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
        guard let ssh = sshService else { return }

        do {
            // Read unique ID
            let uidResult = try await ssh.execute("cat /etc/clover/uid 2>/dev/null")
            if uidResult.succeeded {
                uniqueId = uidResult.output
            }

            // Read version info
            let hasVersion = try await ssh.execute("[ -f /var/version ] && echo yes")
            if hasVersion.output == "yes" {
                let versionResult = try await ssh.execute(
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
                    let unameResult = try await ssh.execute("uname -r")
                    if kernelVersion.isEmpty {
                        kernelVersion = unameResult.output
                    }
                }
            } else {
                bootVersion = "1.0.0"
                let unameResult = try await ssh.execute("uname -r")
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

            let sysCodeResult = try await ssh.execute("cat /etc/clover/system_code 2>/dev/null")
            if sysCodeResult.succeeded && !sysCodeResult.output.isEmpty {
                systemCode = sysCodeResult.output
            }

            if systemCode.isEmpty || ConsoleType.fromSystemCode(systemCode) == .unknown {
                let evalResult = try await ssh.execute(
                    "hakchi eval 'echo \"$sftype-$sfregion\"' 2>/dev/null"
                )
                if evalResult.succeeded && !evalResult.output.isEmpty {
                    systemCode = evalResult.output
                }
            }

            if systemCode.isEmpty || ConsoleType.fromSystemCode(systemCode) == .unknown {
                let srcResult = try await ssh.execute(
                    "source /var/version 2>/dev/null && echo \"$sftype-$sfregion\""
                )
                if srcResult.succeeded && !srcResult.output.isEmpty {
                    systemCode = srcResult.output
                }
            }

            consoleType = ConsoleType.fromSystemCode(systemCode)

            // Check if custom firmware is loaded
            if canInteract {
                let cfResult = try await ssh.execute("ls /var/lib/hakchi/ 2>/dev/null")
                customFirmwareLoaded = cfResult.succeeded
                canSync = true
            }

            isConnected = true

        } catch {
            isConnected = false
        }
    }
}

// MARK: - Bonjour Discovery

/// Discovers hakchi SSH services on the local network
class BonjourBrowser: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    private let browser = NetServiceBrowser()
    private var resolving: NetService?
    var onServiceFound: ((String, Int) -> Void)?
    var onServiceLost: (() -> Void)?

    override init() {
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: "_ssh._tcp.", inDomain: "local.")
    }

    func stop() {
        browser.stop()
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        if service.name == "hakchi" {
            resolving = service
            service.delegate = self
            service.resolve(withTimeout: 10)
        }
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didRemove service: NetService, moreComing: Bool) {
        if service.name == "hakchi" {
            onServiceLost?()
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard let hostName = sender.hostName else { return }
        let host = hostName.hasSuffix(".") ? String(hostName.dropLast()) : hostName
        onServiceFound?(host, sender.port)
    }
}

// MARK: - Version Parsing

struct VersionTuple: Comparable {
    let components: [Int]

    init(_ values: Int...) {
        components = values
    }

    static func parse(_ string: String) -> VersionTuple {
        // Extract first numeric version pattern: (\d+[.-]){2,}\d+
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
