import Foundation
import USBBridge
import os

private let logger = Logger(subsystem: "com.swifthakchi.app", category: "FELService")

/// Swift wrapper for C FEL protocol operations
actor FELService {
    /// Verify that a FEL device is connected and return board info
    func verifyDevice() throws -> UInt32 {
        guard let dev = fel_open() else {
            throw FELError.deviceNotFound
        }
        defer { fel_close(dev) }

        var resp = aw_fel_verify_response_t()
        let ret = fel_verify_device(dev, &resp)
        guard ret == 0 else {
            throw FELError.communicationError(ret)
        }

        guard resp.board == EXPECTED_BOARD_ID else {
            throw FELError.wrongBoard(resp.board)
        }

        return resp.board
    }

    /// Initialize DRAM on the FEL device using the fes1 SPL binary
    func initDram(fes1Data: Data) throws {
        guard let dev = fel_open() else {
            throw FELError.deviceNotFound
        }
        defer { fel_close(dev) }

        let ret = fes1Data.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_init_dram(dev, baseAddr, UInt32(fes1Data.count))
        }

        guard ret == 0 else {
            throw FELError.dramInitFailed(ret)
        }
    }

    /// Write data to device memory and optionally execute
    func writeAndExec(address: UInt32, data: Data, exec: Bool = false,
                      progress: (@Sendable (Double) -> Void)? = nil) throws {
        guard let dev = fel_open() else {
            throw FELError.deviceNotFound
        }
        defer { fel_close(dev) }

        let ret = data.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }

            return fel_write_memory(dev, address, baseAddr, UInt32(data.count),
                { done, total, ctx in
                    // Progress callback - we can't easily bridge this to the Swift closure
                    // in an actor-safe way, so progress is best-effort
                    _ = ctx
                }, nil)
        }

        guard ret == 0 else {
            throw FELError.writeError(ret)
        }

        if exec {
            let execRet = fel_exec(dev, address)
            guard execRet == 0 else {
                throw FELError.execError(execRet)
            }
        }
    }

    /// Full memboot sequence: init DRAM, write U-Boot, execute
    func memboot(fes1Data: Data, ubootData: Data, bootImgData: Data,
                 progress: (@Sendable (String, Double) -> Void)? = nil) throws {
        logger.info("memboot: opening FEL device")
        guard let dev = fel_open() else {
            logger.error("memboot: FEL device not found")
            throw FELError.deviceNotFound
        }
        defer { fel_close(dev) }
        logger.info("memboot: FEL device opened")

        // Step 1: Init DRAM
        logger.info("memboot: initializing DRAM (fes1: \(fes1Data.count) bytes)")
        let initRet = fes1Data.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_init_dram(dev, baseAddr, UInt32(fes1Data.count))
        }
        guard initRet == 0 else {
            logger.error("memboot: DRAM init failed (code: \(initRet))")
            throw FELError.dramInitFailed(initRet)
        }
        logger.info("memboot: DRAM initialized")

        // Step 2: Write U-Boot to DRAM
        logger.info("memboot: writing U-Boot (\(ubootData.count) bytes) to 0x\(String(UInt32(UBOOT_BASE_M), radix: 16))")
        let ubootRet = ubootData.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_write_memory(dev, UInt32(UBOOT_BASE_M), baseAddr,
                                    UInt32(ubootData.count), nil, nil)
        }
        guard ubootRet == 0 else {
            logger.error("memboot: U-Boot write failed (code: \(ubootRet))")
            throw FELError.writeError(ubootRet)
        }
        logger.info("memboot: U-Boot written")

        // Step 3: Patch cmdline in boot.img BEFORE writing to DRAM.
        // Strip existing hakchi-* flags, add hakchi-shell. This tells the
        // init scripts to start the RNDIS USB gadget (same as upstream Windows client).
        // We handle RNDIS in user-space via our network stack.
        // NOTE: Do NOT include hakchi-memboot here — it causes the boot script
        // to strip all hakchi-* flags when writing to NAND.
        var bootImg = Array(bootImgData)
        Self.patchCmdlineInPlace(&bootImg, flags: "hakchi-shell")
        let patchedBootImg = Data(bootImg)

        logger.info("memboot: writing boot.img (\(patchedBootImg.count) bytes) to 0x\(String(UInt32(TRANSFER_BASE_M), radix: 16))")
        let bootRet = patchedBootImg.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_write_memory(dev, UInt32(TRANSFER_BASE_M), baseAddr,
                                    UInt32(patchedBootImg.count), nil, nil)
        }
        guard bootRet == 0 else {
            logger.error("memboot: boot.img write failed (code: \(bootRet))")
            throw FELError.writeError(bootRet)
        }
        logger.info("memboot: boot.img written (with patched cmdline)")

        // Step 4: Patch U-Boot's bootcmd to boot from the transfer address
        // U-Boot has "bootcmd=" embedded in its binary. We overwrite the value
        // with "boota <transfer_addr>" so U-Boot boots our kernel on startup.
        let bootCmd = "boota \(String(UInt32(TRANSFER_BASE_M), radix: 16))\0"
        let cmdOffset = Self.findBootcmdOffset(in: ubootData)
        guard let cmdOffset else {
            logger.error("memboot: could not find bootcmd= in U-Boot binary")
            throw FELError.bootcmdNotFound
        }
        logger.info("memboot: patching bootcmd at offset \(cmdOffset) with '\(bootCmd.dropLast())'")

        let patchAddr = UInt32(UBOOT_BASE_M) + UInt32(cmdOffset)
        let cmdData = Data(bootCmd.utf8)
        let patchRet = cmdData.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_write_memory(dev, patchAddr, baseAddr, UInt32(cmdData.count), nil, nil)
        }
        guard patchRet == 0 else {
            logger.error("memboot: bootcmd patch write failed (code: \(patchRet))")
            throw FELError.writeError(patchRet)
        }
        logger.info("memboot: bootcmd patched")

        // Step 5: Execute U-Boot
        logger.info("memboot: executing U-Boot at 0x\(String(UInt32(UBOOT_BASE_M), radix: 16))")
        let execRet = fel_exec(dev, UInt32(UBOOT_BASE_M))
        guard execRet == 0 else {
            logger.error("memboot: exec failed (code: \(execRet))")
            throw FELError.execError(execRet)
        }
        logger.info("memboot: U-Boot execution started, memboot complete")
    }

    /// Patch the kernel cmdline in-place in the boot.img byte array.
    /// Matches the .NET macOS port's InPlaceStringEdit approach:
    /// reads ASCII at offset 64 (512 bytes), strips hakchi-* flags, appends new flags,
    /// zero-fills the rest, writes back in-place.
    private static func patchCmdlineInPlace(_ buffer: inout [UInt8], flags: String) {
        let startOffset = 64
        let windowSize = 512
        guard buffer.count > startOffset + windowSize else { return }

        // Read existing cmdline as ASCII (null-terminated)
        let cmdlineBytes = Array(buffer[startOffset..<(startOffset + windowSize)])
        let nullIdx = cmdlineBytes.firstIndex(of: 0) ?? windowSize
        let existing = String(bytes: cmdlineBytes[0..<nullIdx], encoding: .ascii) ?? ""

        logger.info("boot.img original cmdline: '\(existing)'")

        // Strip existing hakchi flags, append new ones
        var patched = existing
            .replacingOccurrences(of: "hakchi-shell", with: "")
            .replacingOccurrences(of: "hakchi-clovershell", with: "")
            .replacingOccurrences(of: "hakchi-memboot", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        patched += " \(flags)"

        logger.info("boot.img patched cmdline: '\(patched)'")

        // Write back: fill window with zeros, then copy patched string
        for i in startOffset..<(startOffset + windowSize) {
            buffer[i] = 0
        }
        let patchedBytes = Array(patched.utf8)
        let copyLen = min(patchedBytes.count, windowSize - 1) // leave room for null terminator
        for i in 0..<copyLen {
            buffer[startOffset + i] = patchedBytes[i]
        }
    }

    /// Find the offset of the bootcmd value in the U-Boot binary.
    /// Searches for "bootcmd=" and returns the offset just past the "=".
    private static func findBootcmdOffset(in ubootData: Data) -> Int? {
        let prefix = Array("bootcmd=".utf8)
        let bytes = Array(ubootData)
        for i in 0...(bytes.count - prefix.count) {
            if bytes[i..<(i + prefix.count)].elementsEqual(prefix) {
                return i + prefix.count
            }
        }
        return nil
    }
}

enum FELError: Error, LocalizedError {
    case deviceNotFound
    case communicationError(Int32)
    case wrongBoard(UInt32)
    case dramInitFailed(Int32)
    case writeError(Int32)
    case readError(Int32)
    case execError(Int32)
    case bootcmdNotFound

    var errorDescription: String? {
        switch self {
        case .deviceNotFound:
            return "FEL device not found. Make sure the console is connected in FEL mode."
        case .communicationError(let code):
            return "USB communication error (code: \(code))"
        case .wrongBoard(let id):
            return "Unexpected board ID: 0x\(String(id, radix: 16))"
        case .dramInitFailed(let code):
            return "Failed to initialize DRAM (code: \(code))"
        case .writeError(let code):
            return "Failed to write to device memory (code: \(code))"
        case .readError(let code):
            return "Failed to read from device memory (code: \(code))"
        case .execError(let code):
            return "Failed to execute on device (code: \(code))"
        case .bootcmdNotFound:
            return "Could not find bootcmd in U-Boot binary — the hakchi.hmod may be corrupt"
        }
    }
}
