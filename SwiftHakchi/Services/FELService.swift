import Foundation
import USBBridge

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
        guard let dev = fel_open() else {
            throw FELError.deviceNotFound
        }
        defer { fel_close(dev) }

        // Step 1: Init DRAM
        let initRet = fes1Data.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_init_dram(dev, baseAddr, UInt32(fes1Data.count))
        }
        guard initRet == 0 else {
            throw FELError.dramInitFailed(initRet)
        }

        // Step 2: Write U-Boot to DRAM
        let ubootRet = ubootData.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_write_memory(dev, UInt32(UBOOT_BASE_M), baseAddr,
                                    UInt32(ubootData.count), nil, nil)
        }
        guard ubootRet == 0 else {
            throw FELError.writeError(ubootRet)
        }

        // Step 3: Write boot.img to DRAM (at transfer area)
        let bootRet = bootImgData.withUnsafeBytes { ptr -> Int32 in
            guard let baseAddr = ptr.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return HAKCHI_USB_ERROR_INVALID_PARAM.rawValue
            }
            return fel_write_memory(dev, UInt32(TRANSFER_BASE_M), baseAddr,
                                    UInt32(bootImgData.count), nil, nil)
        }
        guard bootRet == 0 else {
            throw FELError.writeError(bootRet)
        }

        // Step 4: Execute U-Boot
        let execRet = fel_exec(dev, UInt32(UBOOT_BASE_M))
        guard execRet == 0 else {
            throw FELError.execError(execRet)
        }
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
        }
    }
}
