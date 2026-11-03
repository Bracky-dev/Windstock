import CryptoKit
import Foundation

/// Writes an embedded code signature into an arm64 Mach-O.
///
/// Only what a dlopen'd library needs, which is less than a full app:
///
///   * no bundle sealing -- the guest's .app is a resource directory we point
///     NSBundle at, not something iOS installs, so nothing reads CodeResources;
///   * entitlements copied verbatim from the launcher's own signature -- a
///     binary with none carries no application-identifier, so AMFI has no
///     provisioning profile to match it to and refuses the load;
///   * a SHA-256 CodeDirectory only, which every iOS version that can run this
///     app accepts.
///
/// What does matter is the team: iOS will not load a library whose team
/// differs from the process that loads it, which is why the certificate has to
/// be the one that signed the launcher.
enum MachOSigner {
    enum Failure: LocalizedError {
        case notMachO
        case fatBinary
        case noCodeSignatureCommand
        case noLinkedit
        case signatureTooLarge(Int, Int)

        var errorDescription: String? {
            switch self {
            case .notMachO: return "Not a 64-bit arm64 Mach-O."
            case .fatBinary: return "Universal binary — thin it to arm64 first."
            case .noCodeSignatureCommand:
                return "This binary has no LC_CODE_SIGNATURE to replace, and one "
                     + "cannot be added without rewriting the load commands."
            case .noLinkedit: return "No __LINKEDIT segment."
            case .signatureTooLarge(let got, let room):
                return "The signature came out at \(got) bytes but only \(room) were reserved."
            }
        }
    }

    // csblobs.h
    private static let magicEmbeddedSignature: UInt32 = 0xFADE_0CC0
    private static let magicCodeDirectory: UInt32 = 0xFADE_0C02
    private static let magicRequirements: UInt32 = 0xFADE_0C01
    private static let magicBlobWrapper: UInt32 = 0xFADE_0B01

    private static let slotCodeDirectory: UInt32 = 0
    private static let slotRequirements: UInt32 = 2
    private static let slotEntitlements: UInt32 = 5
    private static let slotDEREntitlements: UInt32 = 7
    private static let slotSignature: UInt32 = 0x1_0000

    private static let hashTypeSHA256: UInt8 = 2
    private static let hashSize = 32
    private static let pageShift: UInt8 = 12
    private static let pageSize = 4096

    private static let lcCodeSignature: UInt32 = 0x1D
    private static let lcSegment64: UInt32 = 0x19

    /// Signs in place and returns the signed bytes.
    ///
    /// `entitlements` and `derEntitlements` are whole blobs, headers included
    /// -- normally HostSignature's, copied unchanged.
    static func sign(_ input: Data, identifier: String,
                     identity: SigningIdentity,
                     entitlements: Data? = HostSignature.entitlements,
                     derEntitlements: Data? = HostSignature.derEntitlements) throws -> Data {
        var data = input
        guard data.count > 32 else { throw Failure.notMachO }
        let magic: UInt32 = data.read(at: 0)
        if magic == 0xCAFE_BABE || magic == 0xBEBA_FECA { throw Failure.fatBinary }
        guard magic == 0xFEED_FACF else { throw Failure.notMachO }

        let layout = try parse(data)
        let teamID = identity.teamID ?? ""

        // The signature's own size is baked into the load commands, which are
        // themselves hashed -- so reserve a fixed, generous slot first, write
        // the load commands, and only then hash and pad to fit.
        let signatureOffset = layout.signatureOffset
        let codeSlots = (signatureOffset + pageSize - 1) / pageSize
        let reserved = reservedSize(identifier: identifier, teamID: teamID,
                                    codeSlots: codeSlots,
                                    entitlements: entitlements,
                                    derEntitlements: derEntitlements)

        data.count = signatureOffset                       // drop the old signature
        data.write(UInt32(signatureOffset), at: layout.codeSignatureCommandOffset + 8)
        data.write(UInt32(reserved), at: layout.codeSignatureCommandOffset + 12)

        let linkeditEnd = UInt64(signatureOffset + reserved)
        let linkeditFileSize = linkeditEnd - layout.linkeditFileOffset
        data.write(linkeditFileSize, at: layout.linkeditCommandOffset + 48)   // filesize
        let vmSize = (linkeditFileSize + 0x3FFF) & ~0x3FFF
        data.write(vmSize, at: layout.linkeditCommandOffset + 32)             // vmsize

        // Everything below here hashes the bytes as they now stand.
        let requirements = emptyRequirements()
        let codeDirectory = buildCodeDirectory(
            over: data, identifier: identifier, teamID: teamID,
            codeLimit: signatureOffset, requirements: requirements,
            entitlements: entitlements, derEntitlements: derEntitlements,
            execSegBase: layout.execSegBase, execSegLimit: layout.execSegLimit)

        let cms = try CMS.sign(codeDirectory: codeDirectory, identity: identity)
        let wrapper = blob(magic: magicBlobWrapper, body: cms)

        var blobs: [(UInt32, Data)] = [
            (slotCodeDirectory, codeDirectory),
            (slotRequirements, requirements),
        ]
        if let entitlements { blobs.append((slotEntitlements, entitlements)) }
        if let derEntitlements { blobs.append((slotDEREntitlements, derEntitlements)) }
        blobs.append((slotSignature, wrapper))

        var superBlob = superBlob(blobs)
        guard superBlob.count <= reserved else {
            throw Failure.signatureTooLarge(superBlob.count, reserved)
        }
        superBlob.append(Data(count: reserved - superBlob.count))

        data.append(superBlob)
        return data
    }

    // MARK: - Mach-O

    private struct Layout {
        var codeSignatureCommandOffset: Int
        var signatureOffset: Int
        var linkeditCommandOffset: Int
        var linkeditFileOffset: UInt64
        var execSegBase: UInt64
        var execSegLimit: UInt64
    }

    private static func parse(_ data: Data) throws -> Layout {
        let ncmds: UInt32 = data.read(at: 16)
        var offset = 32
        var codeSignature: Int?
        var signatureOffset: Int?
        var linkeditCommand: Int?
        var linkeditFileOffset: UInt64 = 0
        var execSegBase: UInt64 = 0
        var execSegLimit: UInt64 = 0

        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.read(at: offset)
            let size: UInt32 = data.read(at: offset + 4)
            if cmd == lcCodeSignature {
                codeSignature = offset
                signatureOffset = Int(data.read(at: offset + 8) as UInt32)
            } else if cmd == lcSegment64 {
                let name = segmentName(data, at: offset + 8)
                // segment_command_64: vmsize +32, fileoff +40, filesize +48
                if name == "__LINKEDIT" {
                    linkeditCommand = offset
                    linkeditFileOffset = data.read(at: offset + 40)
                } else if name == "__TEXT" {
                    execSegBase = data.read(at: offset + 40)
                    execSegLimit = data.read(at: offset + 48)
                }
            }
            offset += Int(size)
        }

        guard let codeSignature, let signatureOffset else {
            throw Failure.noCodeSignatureCommand
        }
        guard let linkeditCommand else { throw Failure.noLinkedit }
        return Layout(codeSignatureCommandOffset: codeSignature,
                      signatureOffset: signatureOffset,
                      linkeditCommandOffset: linkeditCommand,
                      linkeditFileOffset: linkeditFileOffset,
                      execSegBase: execSegBase,
                      execSegLimit: execSegLimit)
    }

    private static func segmentName(_ data: Data, at offset: Int) -> String {
        let bytes = [UInt8](data[offset..<min(offset + 16, data.count)])
        let trimmed = bytes.prefix { $0 != 0 }
        return String(decoding: trimmed, as: UTF8.self)
    }

    // MARK: - blobs

    private static func blob(magic: UInt32, body: Data) -> Data {
        var out = Data()
        out.appendBig(magic)
        out.appendBig(UInt32(body.count + 8))
        out.append(body)
        return out
    }

    /// An empty requirements set. Apple's tooling always emits one; the hash of
    /// it goes in special slot -2, so leaving it out would mean a slot count
    /// that disagrees with the contents.
    private static func emptyRequirements() -> Data {
        var body = Data()
        body.appendBig(UInt32(0))          // count
        return blob(magic: magicRequirements, body: body)
    }

    private static func superBlob(_ blobs: [(UInt32, Data)]) -> Data {
        let headerSize = 12 + blobs.count * 8
        var index = Data()
        var body = Data()
        var offset = headerSize
        for (type, blob) in blobs {
            index.appendBig(type)
            index.appendBig(UInt32(offset))
            body.append(blob)
            offset += blob.count
        }
        var out = Data()
        out.appendBig(magicEmbeddedSignature)
        out.appendBig(UInt32(headerSize + body.count))
        out.appendBig(UInt32(blobs.count))
        out.append(index)
        out.append(body)
        return out
    }

    private static func reservedSize(identifier: String, teamID: String,
                                     codeSlots: Int, entitlements: Data?,
                                     derEntitlements: Data?) -> Int {
        let identifierBytes = identifier.utf8.count + 1
        let teamBytes = teamID.isEmpty ? 0 : teamID.utf8.count + 1
        let specialSlots = (entitlements == nil && derEntitlements == nil) ? 2 : 7
        let codeDirectory = 88 + identifierBytes + teamBytes
            + (specialSlots + codeSlots) * hashSize
        // The CMS is a certificate chain plus a 256-byte RSA signature; 12 KB
        // is comfortably more than a three-certificate chain needs, and the
        // slot is zero-padded to whatever is left over.
        let total = 12 + 5 * 8 + codeDirectory + 12
            + (entitlements?.count ?? 0) + (derEntitlements?.count ?? 0) + 12_288
        return (total + 15) & ~15
    }

    // MARK: - CodeDirectory

    private static func buildCodeDirectory(
        over data: Data, identifier: String, teamID: String, codeLimit: Int,
        requirements: Data, entitlements: Data?, derEntitlements: Data?,
        execSegBase: UInt64, execSegLimit: UInt64) -> Data {

        let identifierBytes = Data(identifier.utf8) + Data([0])
        let teamBytes = teamID.isEmpty ? Data() : Data(teamID.utf8) + Data([0])
        // The slot count has to reach the highest one in use: -5 and -7 are
        // the entitlements, so all seven exist once either is present.
        let specialSlots = (entitlements == nil && derEntitlements == nil) ? 2 : 7
        let codeSlots = (codeLimit + pageSize - 1) / pageSize

        let headerSize = 88                     // through execSegFlags, version 0x20400
        let identifierOffset = headerSize
        let teamOffset = teamBytes.isEmpty ? 0 : identifierOffset + identifierBytes.count
        let hashesStart = identifierOffset + identifierBytes.count + teamBytes.count
        let hashOffset = hashesStart + specialSlots * hashSize

        var header = Data()
        header.appendBig(magicCodeDirectory)
        header.appendBig(UInt32(hashOffset + codeSlots * hashSize))    // length
        header.appendBig(UInt32(0x0002_0400))                          // version
        header.appendBig(UInt32(0))                                    // flags
        header.appendBig(UInt32(hashOffset))
        header.appendBig(UInt32(identifierOffset))
        header.appendBig(UInt32(specialSlots))
        header.appendBig(UInt32(codeSlots))
        header.appendBig(UInt32(codeLimit))
        header.append(contentsOf: [UInt8(hashSize), hashTypeSHA256, 0, pageShift])
        header.appendBig(UInt32(0))                                    // spare2
        header.appendBig(UInt32(0))                                    // scatterOffset
        header.appendBig(UInt32(teamOffset))
        header.appendBig(UInt32(0))                                    // spare3
        header.appendBig(UInt64(0))                                    // codeLimit64
        header.appendBig(execSegBase)
        header.appendBig(execSegLimit)
        header.appendBig(UInt64(0))                                    // execSegFlags

        var out = header
        out.append(identifierBytes)
        out.append(teamBytes)

        // Special slots run backwards from the hash offset, so they are
        // written most-negative first: -7, -6, ... -1.
        func hash(_ blob: Data?) -> Data {
            blob.map { Data(SHA256.hash(data: $0)) } ?? Data(count: hashSize)
        }
        if specialSlots >= 7 {
            out.append(hash(derEntitlements))                          // slot -7
            out.append(Data(count: hashSize))                          // slot -6
            out.append(hash(entitlements))                             // slot -5
            out.append(Data(count: hashSize))                          // slot -4
            out.append(Data(count: hashSize))                          // slot -3, no CodeResources
        }
        out.append(Data(SHA256.hash(data: requirements)))              // slot -2
        out.append(Data(count: hashSize))                              // slot -1, no Info.plist

        for page in 0..<codeSlots {
            let start = page * pageSize
            let end = min(start + pageSize, codeLimit)
            out.append(Data(SHA256.hash(data: data[start..<end])))
        }
        return out
    }
}

// MARK: - little helpers

private extension Data {
    func read<T: FixedWidthInteger>(at offset: Int) -> T {
        var value: T = 0
        _ = Swift.withUnsafeMutableBytes(of: &value) { raw in
            copyBytes(to: raw, from: offset..<(offset + MemoryLayout<T>.size))
        }
        return T(littleEndian: value)
    }

    mutating func write<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { raw in
            replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: raw)
        }
    }

    /// Code signature blobs are big-endian, unlike everything else in a Mach-O.
    mutating func appendBig<T: FixedWidthInteger>(_ value: T) {
        var big = value.bigEndian
        Swift.withUnsafeBytes(of: &big) { append(contentsOf: $0) }
    }
}
