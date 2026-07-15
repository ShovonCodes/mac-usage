import Foundation
import IOKit

// ─────────────────────────────────────────────────────────────────
// Low-level connection to the SMC (System Management Controller).
//
// The SMC is a small chip that knows about fans, temperatures,
// voltages, etc. macOS exposes it through the "AppleSMC" kernel
// driver. Talking to it means exchanging a fixed 80-byte struct
// (SmcParamStruct below) whose layout must match the kernel exactly.
//
// Every sensor value lives behind a 4-character "key":
//   "FNum" = number of fans
//   "F0Ac" = fan 0 actual speed
//   "Tp01" = a CPU temperature sensor (Apple Silicon), etc.
//
// Reading is allowed without admin rights. Writing is not (and this
// file deliberately contains no write support).
// ─────────────────────────────────────────────────────────────────

// MARK: - Structs that must exactly match the kernel driver's layout

struct SmcVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

struct SmcPowerLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPowerLimit: UInt32 = 0
    var gpuPowerLimit: UInt32 = 0
    var memoryPowerLimit: UInt32 = 0
}

struct SmcKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0   // e.g. "flt ", "ui16" packed into 4 bytes
    var dataAttributes: UInt8 = 0
}

/// 32 raw data bytes. Swift represents fixed C arrays as tuples.
typealias SmcDataBytes = (
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
    UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8
)

/// The 80-byte message exchanged with the AppleSMC driver.
struct SmcParamStruct {
    var key: UInt32 = 0
    var version = SmcVersion()
    var powerLimitData = SmcPowerLimitData()
    var keyInfo = SmcKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var command: UInt8 = 0     // which operation we want (read key, get info, ...)
    var data32: UInt32 = 0
    var bytes: SmcDataBytes = (
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
    )
}

// MARK: - The connection itself

final class SmcConnection {

    // Commands understood by the AppleSMC driver.
    private enum SmcCommand: UInt8 {
        case readKey = 5
        case getKeyFromIndex = 8
        case getKeyInfo = 9
    }

    /// Selector for IOConnectCallStructMethod — always 2 for AppleSMC.
    private let kernelCallSelector: UInt32 = 2

    private var connectionPort: io_connect_t = 0
    private(set) var isOpen = false

    /// Cache of key → info, because key info never changes while running.
    private var keyInfoCache: [UInt32: SmcKeyInfoData] = [:]

    // MARK: Open / close

    func open() {
        guard !isOpen else { return }

        let smcService = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("AppleSMC")
        )
        guard smcService != 0 else { return }

        let openResult = IOServiceOpen(smcService, mach_task_self_, 0, &connectionPort)
        IOObjectRelease(smcService)

        isOpen = (openResult == kIOReturnSuccess)
    }

    func close() {
        guard isOpen else { return }
        IOServiceClose(connectionPort)
        connectionPort = 0
        isOpen = false
    }

    deinit {
        close()
    }

    // MARK: Public reading API

    /// Read a key like "FNum" and decode it into a Double.
    /// Returns nil if the key doesn't exist on this Mac.
    func readNumericValue(forKey keyName: String) -> Double? {
        guard let keyCode = Self.keyCode(from: keyName) else { return nil }
        return readNumericValue(forKeyCode: keyCode)
    }

    /// Same as above but takes the already-packed 4-byte key code.
    func readNumericValue(forKeyCode keyCode: UInt32) -> Double? {
        guard let keyInfo = fetchKeyInfo(forKeyCode: keyCode) else { return nil }

        var request = SmcParamStruct()
        request.key = keyCode
        request.keyInfo.dataSize = keyInfo.dataSize
        request.command = SmcCommand.readKey.rawValue

        guard let response = callDriver(with: request), response.result == 0 else {
            return nil
        }

        return Self.decodeNumericValue(
            bytes: response.bytes,
            dataSize: keyInfo.dataSize,
            dataType: keyInfo.dataType
        )
    }

    /// How many keys does this Mac's SMC expose in total?
    func readTotalKeyCount() -> Int {
        guard let count = readNumericValue(forKey: "#KEY") else { return 0 }
        return Int(count)
    }

    /// Get the key name at a given index (0 ..< totalKeyCount).
    /// Used to discover which sensors exist on this particular Mac.
    func keyName(atIndex index: Int) -> String? {
        var request = SmcParamStruct()
        request.data32 = UInt32(index)
        request.command = SmcCommand.getKeyFromIndex.rawValue

        guard let response = callDriver(with: request), response.result == 0 else {
            return nil
        }
        return Self.keyName(from: response.key)
    }

    // MARK: Talking to the kernel driver

    private func fetchKeyInfo(forKeyCode keyCode: UInt32) -> SmcKeyInfoData? {
        if let cached = keyInfoCache[keyCode] {
            return cached
        }

        var request = SmcParamStruct()
        request.key = keyCode
        request.command = SmcCommand.getKeyInfo.rawValue

        guard let response = callDriver(with: request), response.result == 0 else {
            return nil
        }

        keyInfoCache[keyCode] = response.keyInfo
        return response.keyInfo
    }

    private func callDriver(with request: SmcParamStruct) -> SmcParamStruct? {
        guard isOpen else { return nil }

        var input = request
        var output = SmcParamStruct()
        var outputSize = MemoryLayout<SmcParamStruct>.stride

        let callResult = IOConnectCallStructMethod(
            connectionPort,
            kernelCallSelector,
            &input,
            MemoryLayout<SmcParamStruct>.stride,
            &output,
            &outputSize
        )

        guard callResult == kIOReturnSuccess else { return nil }
        return output
    }

    // MARK: Helpers for keys and value decoding

    /// Pack a 4-character key like "FNum" into the UInt32 the driver expects.
    static func keyCode(from keyName: String) -> UInt32? {
        guard keyName.utf8.count == 4 else { return nil }
        var code: UInt32 = 0
        for character in keyName.utf8 {
            code = (code << 8) | UInt32(character)
        }
        return code
    }

    /// Unpack a UInt32 key code back into its 4-character name.
    static func keyName(from keyCode: UInt32) -> String {
        let characters: [Character] = [
            Character(UnicodeScalar((keyCode >> 24) & 0xFF)!),
            Character(UnicodeScalar((keyCode >> 16) & 0xFF)!),
            Character(UnicodeScalar((keyCode >> 8) & 0xFF)!),
            Character(UnicodeScalar(keyCode & 0xFF)!)
        ]
        return String(characters)
    }

    /// Convert the raw bytes into a Double based on the SMC data type.
    /// Different Macs use different encodings for the same kind of sensor:
    ///   "flt " — plain 32-bit float (Apple Silicon)
    ///   "fpe2" — big-endian fixed point, value = raw / 4 (Intel fans)
    ///   "sp78" — big-endian signed fixed point, value = raw / 256 (Intel temps)
    ///   "ui8 " / "ui16" / "ui32" — plain unsigned integers
    static func decodeNumericValue(bytes: SmcDataBytes, dataSize: UInt32, dataType: UInt32) -> Double? {
        let typeName = keyName(from: dataType)
        let byteArray = [
            bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6, bytes.7,
            bytes.8, bytes.9, bytes.10, bytes.11, bytes.12, bytes.13, bytes.14, bytes.15,
            bytes.16, bytes.17, bytes.18, bytes.19, bytes.20, bytes.21, bytes.22, bytes.23,
            bytes.24, bytes.25, bytes.26, bytes.27, bytes.28, bytes.29, bytes.30, bytes.31
        ]

        switch typeName {
        case "flt ":
            guard dataSize == 4 else { return nil }
            let bits = UInt32(byteArray[0])
                | (UInt32(byteArray[1]) << 8)
                | (UInt32(byteArray[2]) << 16)
                | (UInt32(byteArray[3]) << 24)
            return Double(Float(bitPattern: bits))

        case "fpe2":
            guard dataSize == 2 else { return nil }
            let raw = (UInt16(byteArray[0]) << 8) | UInt16(byteArray[1])
            return Double(raw) / 4.0

        case "sp78":
            guard dataSize == 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(byteArray[0]) << 8) | UInt16(byteArray[1]))
            return Double(raw) / 256.0

        case "ui8 ":
            guard dataSize >= 1 else { return nil }
            return Double(byteArray[0])

        case "ui16":
            guard dataSize == 2 else { return nil }
            return Double((UInt16(byteArray[0]) << 8) | UInt16(byteArray[1]))

        case "ui32":
            guard dataSize == 4 else { return nil }
            let value = (UInt32(byteArray[0]) << 24)
                | (UInt32(byteArray[1]) << 16)
                | (UInt32(byteArray[2]) << 8)
                | UInt32(byteArray[3])
            return Double(value)

        default:
            return nil
        }
    }
}
