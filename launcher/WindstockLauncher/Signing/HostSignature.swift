import MachO
import Foundation

/// The launcher's own code signature, read back out of its own Mach-O.
///
/// A signature with no entitlements carries no `application-identifier`, so
/// AMFI has no provisioning profile to match the binary against and rejects
/// the load — which is what `code signature invalid ... (errno=1)` means when
/// the certificate chain is already good.
///
/// Rather than construct entitlements (the DER form in slot 7 is required
/// alongside the XML form since iOS 15, and getting its ASN.1 wrong is another
/// silent rejection), the guest is given the *host's* blobs verbatim. They are
/// already well-formed, they already name an application-identifier that a
/// profile on this device authorises, and the guest runs inside the host's
/// process and its sandbox anyway. Whatever makes the launcher acceptable
/// makes the guest acceptable.
enum HostSignature {
    /// CSMAGIC_EMBEDDED_ENTITLEMENTS — the XML plist blob, slot 5.
    static let entitlements: Data? = blob(forSlot: 5)
    /// CSMAGIC_EMBEDDED_DER_ENTITLEMENTS — slot 7.
    static let derEntitlements: Data? = blob(forSlot: 7)

    static func describe() -> String {
        let xml = entitlements.map { "\($0.count) bytes" } ?? "none"
        let der = derEntitlements.map { "\($0.count) bytes" } ?? "none"
        return "entitlements \(xml), DER \(der)"
    }

    /// The whole blob for a SuperBlob slot, header included, ready to be
    /// copied into the guest's signature unchanged.
    private static func blob(forSlot slot: UInt32) -> Data? {
        guard let data = executable() else { return nil }
        guard let signature = signatureOffset(in: data) else { return nil }
        guard signature + 12 <= data.count else { return nil }

        let magic: UInt32 = data.readBE(at: signature)
        guard magic == 0xFADE_0CC0 else { return nil }
        let count: UInt32 = data.readBE(at: signature + 8)

        for index in 0..<Int(count) {
            let entry = signature + 12 + index * 8
            guard entry + 8 <= data.count else { break }
            let type: UInt32 = data.readBE(at: entry)
            let offset: UInt32 = data.readBE(at: entry + 4)
            guard type == slot else { continue }
            let start = signature + Int(offset)
            guard start + 8 <= data.count else { return nil }
            let length: UInt32 = data.readBE(at: start + 4)
            guard length >= 8, start + Int(length) <= data.count else { return nil }
            return data[start..<(start + Int(length))]
        }
        return nil
    }

    private static func executable() -> Data? {
        var buffer = [CChar](repeating: 0, count: 4096)
        var size = UInt32(buffer.count)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        let path = String(cString: buffer)
        return FileManager.default.contents(atPath: path)
    }

    private static func signatureOffset(in data: Data) -> Int? {
        guard data.count > 32 else { return nil }
        let magic: UInt32 = data.readLE(at: 0)
        guard magic == 0xFEED_FACF else { return nil }
        let ncmds: UInt32 = data.readLE(at: 16)
        var offset = 32
        for _ in 0..<Int(ncmds) {
            guard offset + 8 <= data.count else { break }
            let cmd: UInt32 = data.readLE(at: offset)
            let size: Int = Int(data.readLE(at: offset + 4) as UInt32)
            if cmd == 0x1D { return Int(data.readLE(at: offset + 8) as UInt32) }
            offset += size
        }
        return nil
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
}
