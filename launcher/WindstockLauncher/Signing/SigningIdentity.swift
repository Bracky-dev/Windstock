import Foundation
import Security

/// A certificate and private key the launcher can sign guest binaries with.
///
/// It has to be *your* Apple development certificate. iOS will only load a
/// Mach-O into this process if the signature is valid and its team matches the
/// team that signed the launcher, so a self-made certificate cannot work --
/// the same reason LiveContainer imports SideStore's certificate rather than
/// generating one.
///
/// Export it from AltStore/SideStore (Settings, export the certificate) as a
/// .p12 with its password, and import that here.
struct SigningIdentity {
    let certificate: SecCertificate
    let privateKey: SecKey
    /// Leaf first, then any intermediates the .p12 carried.
    let chain: [SecCertificate]

    var commonName: String? {
        var name: CFString?
        guard SecCertificateCopyCommonName(certificate, &name) == errSecSuccess else { return nil }
        return name as String?
    }

    /// The Team ID, which Apple puts in the certificate's Organizational Unit.
    /// The CodeDirectory has to carry the same one or library validation
    /// rejects the guest.
    var teamID: String? { CertificateInfo.teamID(of: certificate) }

    /// Normalized issuer, as the CMS SignerInfo has to name it.
    var issuerSequence: Data? {
        SecCertificateCopyNormalizedIssuerSequence(certificate) as Data?
    }

    var serialNumber: Data? {
        SecCertificateCopySerialNumberData(certificate, nil) as Data?
    }

    var notAfter: Date? { CertificateInfo.notAfter(of: certificate) }
}

enum SigningIdentityError: LocalizedError {
    case badPassword
    case unreadable(OSStatus)
    case noIdentity
    case notStored
    case noPrivateKey

    var errorDescription: String? {
        switch self {
        case .badPassword:
            return "Wrong password for that .p12."
        case .unreadable(let status):
            return "The .p12 could not be read (OSStatus \(status))."
        case .noIdentity:
            return "That file has no certificate-and-key pair in it."
        case .notStored:
            return "No signing certificate has been imported yet."
        case .noPrivateKey:
            return "The certificate imported without its private key."
        }
    }
}

/// Imports a .p12 and hands persistence to IdentityStore.
enum SigningIdentityStore {
    /// Reads a .p12 and remembers it, replacing any previous one. The password
    /// is used here and not kept.
    @discardableResult
    static func importP12(at url: URL, password: String) throws -> SigningIdentity {
        let needsStop = url.startAccessingSecurityScopedResource()
        defer { if needsStop { url.stopAccessingSecurityScopedResource() } }

        let data = try Data(contentsOf: url)
        var items: CFArray?
        let options = [kSecImportExportPassphrase as String: password] as CFDictionary
        let status = SecPKCS12Import(data as CFData, options, &items)

        switch status {
        case errSecSuccess:
            guard let entries = items as? [[String: Any]], let first = entries.first,
                  let rawIdentity = first[kSecImportItemIdentity as String]
            else { throw SigningIdentityError.noIdentity }
            let identity = rawIdentity as! SecIdentity

            var certificate: SecCertificate?
            var key: SecKey?
            guard SecIdentityCopyCertificate(identity, &certificate) == errSecSuccess,
                  let certificate,
                  SecIdentityCopyPrivateKey(identity, &key) == errSecSuccess,
                  let key else { throw SigningIdentityError.noIdentity }
            let chain = (first[kSecImportItemCertChain as String] as? [SecCertificate])
                ?? [certificate]

            let result = SigningIdentity(certificate: certificate, privateKey: key,
                                         chain: chain)
            try IdentityStore.save(result)
            return result

        case errSecAuthFailed, errSecPkcs12VerifyFailure:
            throw SigningIdentityError.badPassword

        case errSecDecode:
            // SecPKCS12Import only handles the legacy PBE ciphers, so anything
            // written by a modern tool (OpenSSL 3, and SideStore, default to
            // AES-256-CBC with PBKDF2) lands here even with the right
            // password. Parse it ourselves rather than making the user go and
            // re-wrap the file on a computer.
            WSLogMessage("signing", "SecPKCS12Import returned errSecDecode; "
                         + "falling back to the built-in PKCS#12 reader")
            let contents = try PKCS12.parse(data, password: password)
            try IdentityStore.save(privateKey: contents.privateKey,
                                   certificates: contents.certificates)
            return try IdentityStore.load()

        default:
            throw SigningIdentityError.unreadable(status)
        }
    }

    static func current() throws -> SigningIdentity {
        try IdentityStore.load()
    }

    static var hasIdentity: Bool { IdentityStore.exists }

    static func remove() { IdentityStore.remove() }
}
