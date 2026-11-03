import Foundation

/// The build-time half of tools/patch_macho.py, for IPAs imported on device.
///
/// Two jobs: pick the arm64 slice out of a universal binary, and turn an
/// MH_EXECUTE into something dlopen will accept. dyld refuses an executable,
/// and it will not map a 4 GB __PAGEZERO into a live address space either.
///
/// The __PAGEZERO load command is *kept* and merely zeroed. Overwriting it
/// with LC_ID_DYLIB -- which fits exactly, and was the first thing tried --
/// makes dyld reject the result with
///
///     REBASE_OPCODE_DO_REBASE_ULEB_TIMES segment offset 0x000B0000
///     beyond segment '__LINKEDIT' size (0x000B0000)
///
/// because LC_DYLD_INFO's rebase and bind opcodes name segments by ordinal.
/// Drop the first segment and every later ordinal shifts down by one, so all
/// 256,000 fixups in this binary land in the wrong segment. LC_ID_DYLIB goes
/// in the padding after the last load command instead.
///
/// LC_MAIN is left alone; its entryoff is what the loader calls.
enum MachOPatcher {
    enum Failure: LocalizedError {
        case notMachO
        case noArm64Slice
        case encrypted

        var errorDescription: String? {
            switch self {
            case .notMachO:
                return "That is not a Mach-O binary."
            case .noArm64Slice:
                return "No arm64 slice in that binary — it will not run on this phone."
            case .encrypted:
                return "That IPA is still FairPlay-encrypted (LC_ENCRYPTION_INFO is set). "
                     + "It has to be a decrypted IPA."
            }
        }
    }

    private static let machoMagic64: UInt32 = 0xFEED_FACF
    private static let fatMagic: UInt32 = 0xCAFE_BABE
    private static let fatCigam: UInt32 = 0xBEBA_FECA
    private static let cpuTypeARM64: UInt32 = 0x0100_000C

    private static let mhExecute: UInt32 = 0x2
    private static let mhDylib: UInt32 = 0x6
    private static let lcSegment64: UInt32 = 0x19
    private static let lcIDDylib: UInt32 = 0xD
    private static let lcMain: UInt32 = 0x8000_0028
    private static let lcEncryptionInfo64: UInt32 = 0x2C

    struct Result {
        var data: Data
        var wasExecutable: Bool
        var hasEntryPoint: Bool
    }

    /// Returns the arm64 slice, converted to a loadable dylib.
    static func prepare(_ input: Data, installName: String) throws -> Result {
        var data = try thinToARM64(input)
        guard data.count > 32 else { throw Failure.notMachO }

        let filetype: UInt32 = data.readLE(at: 12)
        let ncmds: UInt32 = data.readLE(at: 16)

        let sizeOfCmds: UInt32 = data.readLE(at: 20)

        var offset = 32
        var pageZero: Int?
        var hasEntry = false
        var hasIDDylib = false
        var firstSection: Int?
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.readLE(at: offset)
            let size: Int = Int(data.readLE(at: offset + 4) as UInt32)
            switch cmd {
            case lcSegment64:
                let bytes = [UInt8](data[(offset + 8)..<min(offset + 24, data.count)])
                let name = String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
                if name == "__PAGEZERO" { pageZero = offset }
                let sectionCount: UInt32 = data.readLE(at: offset + 64)
                var section = offset + 72
                for _ in 0..<Int(sectionCount) {
                    guard section + 80 <= data.count else { break }
                    let sectionOffset: UInt32 = data.readLE(at: section + 48)
                    if sectionOffset != 0 {
                        firstSection = min(firstSection ?? Int.max, Int(sectionOffset))
                    }
                    section += 80
                }
            case lcIDDylib:
                hasIDDylib = true
            case lcMain:
                hasEntry = true
            case lcEncryptionInfo64:
                let cryptID: UInt32 = data.readLE(at: offset + 20)
                if cryptID != 0 { throw Failure.encrypted }
            default:
                break
            }
            offset += size
        }

        let wasExecutable = filetype == mhExecute
        if wasExecutable {
            data.writeLE(mhDylib, at: 12)
        }

        // Keep the segment, drop the reservation: vmaddr, vmsize, fileoff,
        // filesize and both protections all go to zero.
        if let pageZero {
            for field in 0..<4 {
                data.writeLE(UInt64(0), at: pageZero + 24 + field * 8)
            }
            data.writeLE(UInt32(0), at: pageZero + 56)
            data.writeLE(UInt32(0), at: pageZero + 60)
        }

        if !hasIDDylib, let firstSection {
            let name = Data(installName.utf8) + Data([0])
            let commandSize = (24 + name.count + 7) & ~7
            let end = 32 + Int(sizeOfCmds)
            if firstSection - end >= commandSize, end + commandSize <= data.count {
                var command = Data(count: commandSize)
                command.writeLE(lcIDDylib, at: 0)
                command.writeLE(UInt32(commandSize), at: 4)
                command.writeLE(UInt32(24), at: 8)      // name offset
                command.writeLE(UInt32(1), at: 12)      // timestamp
                command.writeLE(UInt32(0x1_0000), at: 16)
                command.writeLE(UInt32(0x1_0000), at: 20)
                command.replaceSubrange(24..<(24 + name.count), with: name)
                data.replaceSubrange(end..<(end + commandSize), with: command)
                data.writeLE(ncmds + 1, at: 16)
                data.writeLE(sizeOfCmds + UInt32(commandSize), at: 20)
            }
        }

        return Result(data: data, wasExecutable: wasExecutable, hasEntryPoint: hasEntry)
    }

    /// True for any Mach-O, thin or fat. Used to decide what to sign.
    static func isMachO(_ data: Data) -> Bool {
        guard data.count >= 4 else { return false }
        let magic: UInt32 = data.readLE(at: 0)
        return magic == machoMagic64 || magic == fatMagic || magic == fatCigam
    }

    static func thinToARM64(_ data: Data) throws -> Data {
        guard data.count >= 8 else { throw Failure.notMachO }
        let magic: UInt32 = data.readLE(at: 0)
        if magic == machoMagic64 { return data }
        guard magic == fatCigam || magic == fatMagic else { throw Failure.notMachO }

        // A fat header is big-endian whichever way the magic reads.
        let count: UInt32 = data.readBE(at: 4)
        for i in 0..<Int(count) {
            let entry = 8 + i * 20
            guard entry + 20 <= data.count else { break }
            let cpu: UInt32 = data.readBE(at: entry)
            let offset: UInt32 = data.readBE(at: entry + 8)
            let size: UInt32 = data.readBE(at: entry + 12)
            if cpu == cpuTypeARM64 {
                let start = Int(offset), end = Int(offset) + Int(size)
                guard end <= data.count else { break }
                return Data(data[start..<end])
            }
        }
        throw Failure.noArm64Slice
    }
}

private extension Data {
    func readLE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { raw in
            copyBytes(to: raw, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    func readBE<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { raw in
            copyBytes(to: raw, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(bigEndian: value)
    }

    mutating func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { raw in
            replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: raw)
        }
    }
}
