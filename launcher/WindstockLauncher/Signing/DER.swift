import Foundation

/// The smallest DER writer that can express a PKCS#7 SignedData.
///
/// This exists because the code signature's CMS blob has to be built by hand.
/// Security.framework will parse a PKCS#12 and perform the RSA signature, but
/// CMSEncoder is macOS-only, and the OpenSSL that ships inside CPython's _ssl
/// is built with OPENSSL_NO_CMS. Writing the structure out is a few hundred
/// lines of well-specified ASN.1 and avoids vendoring a crypto library.
enum DER {
    /// Tags live in their own namespace so `DER.sequence(...)` the builder and
    /// `Tag.sequence` the byte never shadow each other.
    enum Tag {
        static let boolean: UInt8 = 0x01
        static let integer: UInt8 = 0x02
        static let bitString: UInt8 = 0x03
        static let octetString: UInt8 = 0x04
        static let null: UInt8 = 0x05
        static let objectIdentifier: UInt8 = 0x06
        static let utf8String: UInt8 = 0x0C
        static let utcTime: UInt8 = 0x17
        static let sequence: UInt8 = 0x30
        static let set: UInt8 = 0x31

        /// Context-specific tag, e.g. `[0] IMPLICIT`.
        static func context(_ number: UInt8, constructed: Bool = true) -> UInt8 {
            0x80 | (constructed ? 0x20 : 0) | number
        }
    }

    // MARK: - primitives

    /// DER length: short form below 128, long form above.
    static func length(_ count: Int) -> Data {
        if count < 0x80 { return Data([UInt8(count)]) }
        var bytes: [UInt8] = []
        var value = count
        while value > 0 {
            bytes.insert(UInt8(value & 0xFF), at: 0)
            value >>= 8
        }
        return Data([0x80 | UInt8(bytes.count)] + bytes)
    }

    static func encode(tag: UInt8, _ content: Data) -> Data {
        var out = Data([tag])
        out.append(length(content.count))
        out.append(content)
        return out
    }

    static func encode(tag: UInt8, _ parts: [Data]) -> Data {
        encode(tag: tag, parts.reduce(into: Data()) { $0.append($1) })
    }

    // MARK: - types

    static func sequence(_ parts: [Data]) -> Data { encode(tag: Tag.sequence, parts) }
    static func set(_ parts: [Data]) -> Data { encode(tag: Tag.set, parts) }

    static func integer(_ value: Int) -> Data {
        if value == 0 { return encode(tag: Tag.integer, Data([0])) }
        var bytes: [UInt8] = []
        var v = value
        while v > 0 {
            bytes.insert(UInt8(v & 0xFF), at: 0)
            v >>= 8
        }
        // A leading bit of 1 would read as negative.
        if bytes[0] & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(tag: Tag.integer, Data(bytes))
    }

    /// An INTEGER whose value is already in big-endian bytes -- certificate
    /// serial numbers, which are far too large for Int.
    static func integer(rawBytes: Data) -> Data {
        var bytes = [UInt8](rawBytes)
        while bytes.count > 1 && bytes[0] == 0 && bytes[1] & 0x80 == 0 {
            bytes.removeFirst()
        }
        if let first = bytes.first, first & 0x80 != 0 { bytes.insert(0, at: 0) }
        return encode(tag: Tag.integer, Data(bytes))
    }

    static func octetString(_ data: Data) -> Data { encode(tag: Tag.octetString, data) }
    static func utf8String(_ string: String) -> Data {
        encode(tag: Tag.utf8String, Data(string.utf8))
    }
    static func null() -> Data { Data([Tag.null, 0x00]) }

    /// "1.2.840.113549.1.7.2" -> DER OBJECT IDENTIFIER.
    static func oid(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return encode(tag: Tag.objectIdentifier, Data()) }
        var bytes: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            bytes.append(contentsOf: base128(part))
        }
        return encode(tag: Tag.objectIdentifier, Data(bytes))
    }

    private static func base128(_ value: UInt64) -> [UInt8] {
        if value == 0 { return [0] }
        var out: [UInt8] = []
        var v = value
        while v > 0 {
            out.insert(UInt8(v & 0x7F), at: 0)
            v >>= 7
        }
        for i in 0..<(out.count - 1) { out[i] |= 0x80 }
        return out
    }

    /// UTCTime as X.509 writes it: YYMMDDHHMMSSZ, always UTC.
    static func utcTime(_ date: Date) -> Data {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date)
        let text = String(format: "%02d%02d%02d%02d%02d%02dZ",
                          (c.year ?? 2000) % 100, c.month ?? 1, c.day ?? 1,
                          c.hour ?? 0, c.minute ?? 0, c.second ?? 0)
        return encode(tag: Tag.utcTime, Data(text.utf8))
    }

    /// AlgorithmIdentifier with an explicit NULL parameter, which is what the
    /// RSA and SHA OIDs carry in a code signature.
    static func algorithm(_ dotted: String, parameters: Data? = nil) -> Data {
        sequence([oid(dotted), parameters ?? null()])
    }

    // MARK: - object identifiers used by code signing

    enum OID {
        static let data = "1.2.840.113549.1.7.1"
        static let signedData = "1.2.840.113549.1.7.2"
        static let contentType = "1.2.840.113549.1.9.3"
        static let messageDigest = "1.2.840.113549.1.9.4"
        static let signingTime = "1.2.840.113549.1.9.5"
        static let sha256 = "2.16.840.1.101.3.4.2.1"
        static let rsaEncryption = "1.2.840.113549.1.1.1"
        /// Apple's "plist of cdhashes" attribute.
        static let cdHashPlist = "1.2.840.113635.100.9.1"
        /// Apple's structured cdhash attribute.
        static let cdHashes = "1.2.840.113635.100.9.2"
    }
}
