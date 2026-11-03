import CryptoKit
import Foundation
import Security

/// The PKCS#7 SignedData that goes in a code signature's CMS slot.
///
/// Detached: the content is absent, and what is actually signed is the set of
/// authenticated attributes, one of which is the digest of the CodeDirectory.
/// Apple adds two attributes of its own carrying the cdhash, and amfid looks
/// at 1.2.840.113635.100.9.2 -- omit it and the signature verifies as
/// structurally fine and is still rejected.
enum CMS {
    enum Failure: LocalizedError {
        case signingFailed(String)
        case certificateUnreadable

        var errorDescription: String? {
            switch self {
            case .signingFailed(let why): return "Could not sign: \(why)"
            case .certificateUnreadable: return "The certificate's issuer and serial could not be read."
            }
        }
    }

    /// - Parameter codeDirectory: the CodeDirectory blob, exactly as it will
    ///   appear in the SuperBlob. Its SHA-256 is what gets signed.
    static func sign(codeDirectory: Data, identity: SigningIdentity,
                     date: Date = Date()) throws -> Data {
        let cdHash = Data(SHA256.hash(data: codeDirectory))

        guard let issuer = identity.issuerSequence,
              let serial = identity.serialNumber else {
            throw Failure.certificateUnreadable
        }

        // --- authenticated attributes
        let attributes: [Data] = [
            attribute(DER.OID.contentType, [DER.oid(DER.OID.data)]),
            attribute(DER.OID.signingTime, [DER.utcTime(date)]),
            attribute(DER.OID.messageDigest, [DER.octetString(cdHash)]),
            attribute(DER.OID.cdHashPlist, [DER.octetString(cdHashPlist(cdHash))]),
            // SEQUENCE { OID, OCTET STRING } -- a bare OID, not an
            // AlgorithmIdentifier: no NULL parameter. Verified against the
            // signature on a shipping Apple binary; the wrapped form makes
            // codesign report "Unable to decode the provided data".
            attribute(DER.OID.cdHashes, [
                DER.sequence([DER.oid(DER.OID.sha256), DER.octetString(cdHash)])
            ]),
        ]

        // DER requires the members of a SET OF to be sorted by their encoding.
        // Apple's verifier re-encodes the attributes before checking the
        // signature, so an unsorted set verifies fine under OpenSSL (which
        // uses the bytes as given) and is reported by codesign as "code or
        // signature have been modified". Sort once, and sign and embed the
        // same order.
        let sorted = attributes.sorted(by: derLess)

        // What is signed is the attributes as an explicit SET OF, even though
        // they travel in the message tagged [0] IMPLICIT.
        let signedAttributesForDigest = DER.set(sorted)
        let signature = try rsaSign(signedAttributesForDigest, key: identity.privateKey)
        let signedAttributesInMessage = DER.encode(tag: DER.Tag.context(0), sorted)

        let signerInfo = DER.sequence([
            DER.integer(1),
            DER.sequence([                       // issuerAndSerialNumber
                Data(issuer),
                DER.integer(rawBytes: serial),
            ]),
            DER.algorithm(DER.OID.sha256),
            signedAttributesInMessage,
            DER.algorithm(DER.OID.rsaEncryption),
            DER.octetString(signature),
        ])

        // The .p12 usually carries the leaf alone; AMFI needs the chain.
        var certificates = Data()
        for certificate in CertificateChain.complete(identity.chain) {
            certificates.append(SecCertificateCopyData(certificate) as Data)
        }

        let signedData = DER.sequence([
            DER.integer(1),
            DER.set([DER.algorithm(DER.OID.sha256)]),
            DER.sequence([DER.oid(DER.OID.data)]),          // detached content
            DER.encode(tag: DER.Tag.context(0), certificates),
            DER.set([signerInfo]),
        ])

        return DER.sequence([
            DER.oid(DER.OID.signedData),
            DER.encode(tag: DER.Tag.context(0), signedData),
        ])
    }

    // MARK: -

    /// Lexicographic byte order, shorter first when one is a prefix of the
    /// other -- the ordering DER specifies for SET OF.
    private static func derLess(_ a: Data, _ b: Data) -> Bool {
        for (x, y) in zip(a, b) where x != y { return x < y }
        return a.count < b.count
    }

    private static func attribute(_ oid: String, _ values: [Data]) -> Data {
        DER.sequence([DER.oid(oid), DER.set(values)])
    }

    /// Apple's 9.1 attribute is an XML plist: { cdhashes: [<hash>] }, and the
    /// hash in it is the 20-byte truncation -- the same value codesign prints
    /// as CandidateCDHash, not the full SHA-256.
    private static func cdHashPlist(_ cdHash: Data) -> Data {
        let plist: [String: Any] = ["cdhashes": [cdHash.prefix(20)]]
        return (try? PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0)) ?? Data()
    }

    private static func rsaSign(_ message: Data, key: SecKey) throws -> Data {
        var error: Unmanaged<CFError>?
        guard let signature = SecKeyCreateSignature(
                key, .rsaSignatureMessagePKCS1v15SHA256, message as CFData, &error) else {
            let why = error?.takeRetainedValue().localizedDescription ?? "unknown"
            throw Failure.signingFailed(why)
        }
        return signature as Data
    }
}
