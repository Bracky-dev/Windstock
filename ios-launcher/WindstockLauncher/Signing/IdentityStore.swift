import Foundation
import Security

/// Where the signing certificate lives between runs.
///
/// Not the keychain. The obvious design -- SecPKCS12Import, keep the
/// SecIdentity, query it back -- falls over twice: the importer cannot read a
/// modern .p12 at all (see PKCS12.swift), and `SecItemAdd` returns
/// errSecMissingEntitlement (-34018) whenever the process has no
/// keychain-access-group, which is the case for a build that has not been
/// through a signer yet. Neither failure is something the user can act on.
///
/// So the certificate and its key are kept as a file in the launcher's own
/// directory and rebuilt with SecKeyCreateWithData on demand. Signing never
/// needed a SecIdentity -- only SecKey and SecCertificate -- so nothing is
/// lost by not having one.
///
/// The key is stored unencrypted inside the app's container. That is the same
/// exposure as everything else the launcher keeps, and it is a free
/// development certificate that expires in a week; it is not an account
/// credential.
enum IdentityStore {
    private struct Stored: Codable {
        /// PKCS#1 RSAPrivateKey.
        var privateKey: Data
        /// DER certificates, leaf first.
        var certificates: [Data]
    }

    private static var url: URL {
        let directory = (WSPaths.launcherRoot as NSString)
            .appendingPathComponent("signing")
        try? FileManager.default.createDirectory(
            atPath: directory, withIntermediateDirectories: true)
        return URL(fileURLWithPath:
            (directory as NSString).appendingPathComponent("identity.json"))
    }

    static func save(privateKey: Data, certificates: [Data]) throws {
        let stored = Stored(privateKey: privateKey, certificates: certificates)
        let data = try JSONEncoder().encode(stored)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
    }

    /// Pulls the key and certificate out of an identity the system did manage
    /// to import, so both paths persist the same way.
    static func save(_ identity: SigningIdentity) throws {
        var error: Unmanaged<CFError>?
        guard let keyData = SecKeyCopyExternalRepresentation(
                identity.privateKey, &error) as Data? else {
            throw SigningIdentityError.noPrivateKey
        }
        let certificates = identity.chain.map { SecCertificateCopyData($0) as Data }
        try save(privateKey: keyData, certificates: certificates)
    }

    static func load() throws -> SigningIdentity {
        guard let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else {
            throw SigningIdentityError.notStored
        }
        return try identity(from: stored)
    }

    static var exists: Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    static func remove() {
        try? FileManager.default.removeItem(at: url)
    }

    private static func identity(from stored: Stored) throws -> SigningIdentity {
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateWithData(stored.privateKey as CFData,
                                             attributes as CFDictionary, &error) else {
            throw SigningIdentityError.noPrivateKey
        }
        let certificates = stored.certificates.compactMap {
            SecCertificateCreateWithData(nil, $0 as CFData)
        }
        guard let leaf = certificates.first else { throw SigningIdentityError.noIdentity }
        return SigningIdentity(certificate: leaf, privateKey: key, chain: certificates)
    }
}
