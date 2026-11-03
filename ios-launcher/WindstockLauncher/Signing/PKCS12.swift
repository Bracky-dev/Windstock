import CommonCrypto
import Foundation
import Security

/// A PKCS#12 reader for the files Apple's own importer refuses.
///
/// SecPKCS12Import only understands the legacy PBE ciphers. A .p12 written by
/// anything modern -- OpenSSL 3 defaults to AES-256-CBC with PBKDF2 -- comes
/// back as errSecDecode (-26275) even with the right password, which is
/// indistinguishable from "this is not a .p12" unless you go and look. A wrong
/// password gives errSecAuthFailed (-25293) instead, so the two cases can be
/// told apart.
///
/// So: parse the container, decrypt with CommonCrypto, and hand the key and
/// certificate to the keychain separately. The keychain pairs them into a
/// SecIdentity by public key hash on its own.
enum PKCS12 {
    enum Failure: LocalizedError {
        case notPKCS12
        case unsupportedCipher(String)
        case wrongPassword
        case noPrivateKey
        case noCertificate

        var errorDescription: String? {
            switch self {
            case .notPKCS12:
                return "That file is not a PKCS#12 archive."
            case .unsupportedCipher(let oid):
                return "That .p12 uses an encryption scheme this app cannot read (\(oid))."
            case .wrongPassword:
                return "Wrong password for that .p12."
            case .noPrivateKey:
                return "That .p12 has no private key in it — only a certificate."
            case .noCertificate:
                return "That .p12 has no certificate in it."
            }
        }
    }

    private enum OID {
        static let data = DERReader.oidBytes("1.2.840.113549.1.7.1")
        static let encryptedData = DERReader.oidBytes("1.2.840.113549.1.7.6")
        static let keyBag = DERReader.oidBytes("1.2.840.113549.1.12.10.1.1")
        static let shroudedKeyBag = DERReader.oidBytes("1.2.840.113549.1.12.10.1.2")
        static let certBag = DERReader.oidBytes("1.2.840.113549.1.12.10.1.3")
        static let pbes2 = DERReader.oidBytes("1.2.840.113549.1.5.13")
        static let pbkdf2 = DERReader.oidBytes("1.2.840.113549.1.5.12")
        static let aes128CBC = DERReader.oidBytes("2.16.840.1.101.3.4.1.2")
        static let aes192CBC = DERReader.oidBytes("2.16.840.1.101.3.4.1.22")
        static let aes256CBC = DERReader.oidBytes("2.16.840.1.101.3.4.1.42")
        static let hmacSHA1 = DERReader.oidBytes("1.2.840.113549.2.7")
        static let hmacSHA224 = DERReader.oidBytes("1.2.840.113549.2.8")
        static let hmacSHA256 = DERReader.oidBytes("1.2.840.113549.2.9")
        static let hmacSHA384 = DERReader.oidBytes("1.2.840.113549.2.10")
        static let hmacSHA512 = DERReader.oidBytes("1.2.840.113549.2.11")
    }

    struct Contents {
        /// PKCS#1 RSAPrivateKey, ready for SecKeyCreateWithData.
        var privateKey: Data
        /// DER certificates, leaf first as the file listed them.
        var certificates: [Data]
    }

    // MARK: - parsing

    static func parse(_ data: Data, password: String) throws -> Contents {
        var outer = DERReader.Cursor(data)
        guard let pfx = outer.enter(0x30) else { throw Failure.notPKCS12 }

        var top = DERReader.Cursor(pfx)
        _ = top.next()                                   // version
        guard let authSafeInfo = top.next(), authSafeInfo.tag == 0x30 else {
            throw Failure.notPKCS12
        }

        guard let authSafe = contentOfInfo(authSafeInfo.content, expecting: OID.data) else {
            throw Failure.notPKCS12
        }
        var safes = DERReader.Cursor(authSafe)
        guard let safeSequence = safes.enter(0x30) else { throw Failure.notPKCS12 }

        var keyDER: Data?
        var certificates: [Data] = []
        // A wrong password shows up as a decryption failure on whichever bag
        // happens to be encrypted. Remember the first one: without it the
        // caller is told "no private key", which sends them looking in
        // entirely the wrong place.
        var firstDecryptionFailure: Error?

        var infos = DERReader.Cursor(safeSequence)
        while let info = infos.next() {
            guard info.tag == 0x30 else { continue }
            var typeCursor = DERReader.Cursor(info.content)
            guard let type = typeCursor.next(), type.tag == 0x06 else { continue }

            let safeContents: Data
            if type.content == OID.data {
                // contentOfInfo already peels the OCTET STRING off a `data`
                // ContentInfo; unwrapping a second time here was throwing the
                // key bag away and leaving only the certificates.
                guard let raw = contentOfInfo(info.content, expecting: OID.data)
                else { continue }
                safeContents = raw
            } else if type.content == OID.encryptedData {
                guard let encrypted = contentOfInfo(info.content,
                                                    expecting: OID.encryptedData)
                else { continue }
                do {
                    guard let decrypted = try decryptEncryptedData(encrypted,
                                                                   password: password)
                    else { continue }
                    safeContents = decrypted
                } catch {
                    firstDecryptionFailure = firstDecryptionFailure ?? error
                    continue
                }
            } else {
                continue
            }

            var bagSequence = DERReader.Cursor(safeContents)
            guard let bags = bagSequence.enter(0x30) else { continue }
            var bagCursor = DERReader.Cursor(bags)
            while let bag = bagCursor.next() {
                guard bag.tag == 0x30 else { continue }
                var fields = DERReader.Cursor(bag.content)
                guard let bagID = fields.next(), bagID.tag == 0x06,
                      let wrapped = fields.next(), wrapped.tag == 0xA0 else { continue }

                if bagID.content == OID.certBag {
                    if let certificate = parseCertBag(wrapped.content) {
                        certificates.append(certificate)
                    }
                } else if bagID.content == OID.shroudedKeyBag {
                    do {
                        if let pkcs8 = try decryptShroudedKey(wrapped.content,
                                                              password: password) {
                            do {
                                keyDER = try rsaKey(fromPKCS8: pkcs8)
                            } catch {
                                // The ciphertext was well-formed and the
                                // padding happened to check out, but what came
                                // out is not a PrivateKeyInfo. That only means
                                // the key was wrong, i.e. the password was.
                                throw Failure.wrongPassword
                            }
                        }
                    } catch {
                        firstDecryptionFailure = firstDecryptionFailure ?? error
                    }
                } else if bagID.content == OID.keyBag {
                    keyDER = try? rsaKey(fromPKCS8: wrapped.content)
                }
            }
        }

        if let privateKey = keyDER {
            guard !certificates.isEmpty else { throw Failure.noCertificate }
            return Contents(privateKey: privateKey, certificates: certificates)
        }
        if let failure = firstDecryptionFailure { throw failure }
        guard !certificates.isEmpty else { throw Failure.notPKCS12 }
        throw Failure.noPrivateKey
    }

    /// ContentInfo ::= SEQUENCE { contentType OID, content [0] EXPLICIT ANY }
    private static func contentOfInfo(_ info: Data, expecting oid: Data) -> Data? {
        var cursor = DERReader.Cursor(info)
        guard let type = cursor.next(), type.tag == 0x06, type.content == oid,
              let wrapped = cursor.next(), wrapped.tag == 0xA0 else { return nil }
        if oid == OID.data {
            return unwrapOctetString(wrapped.content) ?? wrapped.content
        }
        return wrapped.content
    }

    private static func unwrapOctetString(_ data: Data) -> Data? {
        var cursor = DERReader.Cursor(data)
        guard let element = cursor.next() else { return nil }
        return element.tag == 0x04 ? element.content : nil
    }

    /// CertBag ::= SEQUENCE { certId OID, certValue [0] EXPLICIT OCTET STRING }
    private static func parseCertBag(_ bag: Data) -> Data? {
        var cursor = DERReader.Cursor(bag)
        guard let sequence = cursor.enter(0x30) else { return nil }
        var fields = DERReader.Cursor(sequence)
        _ = fields.next()                                // certId
        guard let wrapped = fields.next(), wrapped.tag == 0xA0 else { return nil }
        return unwrapOctetString(wrapped.content)
    }

    // MARK: - decryption

    /// EncryptedData ::= SEQUENCE { version, EncryptedContentInfo }
    /// EncryptedContentInfo ::= SEQUENCE { contentType, algorithm,
    ///                                     [0] IMPLICIT encryptedContent }
    private static func decryptEncryptedData(_ data: Data, password: String) throws -> Data? {
        var cursor = DERReader.Cursor(data)
        guard let sequence = cursor.enter(0x30) else { return nil }
        var fields = DERReader.Cursor(sequence)
        _ = fields.next()                                // version
        guard let info = fields.next(), info.tag == 0x30 else { return nil }

        var parts = DERReader.Cursor(info.content)
        _ = parts.next()                                 // contentType
        guard let algorithm = parts.next(), algorithm.tag == 0x30,
              let encrypted = parts.next() else { return nil }
        // [0] IMPLICIT, so the content is the ciphertext directly.
        return try decrypt(encrypted.content, algorithm: algorithm.content, password: password)
    }

    /// EncryptedPrivateKeyInfo ::= SEQUENCE { algorithm, encryptedData OCTET STRING }
    private static func decryptShroudedKey(_ bag: Data, password: String) throws -> Data? {
        var cursor = DERReader.Cursor(bag)
        guard let sequence = cursor.enter(0x30) else { return nil }
        var fields = DERReader.Cursor(sequence)
        guard let algorithm = fields.next(), algorithm.tag == 0x30,
              let encrypted = fields.next(), encrypted.tag == 0x04 else { return nil }
        return try decrypt(encrypted.content, algorithm: algorithm.content, password: password)
    }

    private static func decrypt(_ ciphertext: Data, algorithm: Data,
                                password: String) throws -> Data {
        var cursor = DERReader.Cursor(algorithm)
        guard let scheme = cursor.next(), scheme.tag == 0x06 else {
            throw Failure.unsupportedCipher("unreadable")
        }
        guard scheme.content == OID.pbes2 else {
            // The legacy PBE schemes are exactly the ones SecPKCS12Import
            // already handles, so reaching here means the file is odd.
            throw Failure.unsupportedCipher(describe(scheme.content))
        }
        guard let parameters = cursor.next(), parameters.tag == 0x30 else {
            throw Failure.unsupportedCipher("PBES2 without parameters")
        }

        var pbes2 = DERReader.Cursor(parameters.content)
        guard let kdf = pbes2.next(), kdf.tag == 0x30,
              let encryption = pbes2.next(), encryption.tag == 0x30 else {
            throw Failure.unsupportedCipher("PBES2 malformed")
        }

        // --- key derivation
        var kdfCursor = DERReader.Cursor(kdf.content)
        guard let kdfOID = kdfCursor.next(), kdfOID.content == OID.pbkdf2,
              let kdfParameters = kdfCursor.next(), kdfParameters.tag == 0x30 else {
            throw Failure.unsupportedCipher("only PBKDF2 is supported")
        }
        var kdfFields = DERReader.Cursor(kdfParameters.content)
        guard let salt = kdfFields.next(), salt.tag == 0x04,
              let iterationsElement = kdfFields.next(),
              let iterations = DERReader.integer(iterationsElement) else {
            throw Failure.unsupportedCipher("PBKDF2 malformed")
        }
        var declaredKeyLength: Int?
        var prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
        for element in kdfFields.rest() {
            if element.tag == 0x02 {
                declaredKeyLength = DERReader.integer(element)
            } else if element.tag == 0x30 {
                var prfCursor = DERReader.Cursor(element.content)
                if let oid = prfCursor.next() {
                    switch oid.content {
                    case OID.hmacSHA1: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA1)
                    case OID.hmacSHA224: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA224)
                    case OID.hmacSHA256: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256)
                    case OID.hmacSHA384: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA384)
                    case OID.hmacSHA512: prf = CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA512)
                    default: throw Failure.unsupportedCipher(describe(oid.content))
                    }
                }
            }
        }

        // --- cipher
        var encryptionCursor = DERReader.Cursor(encryption.content)
        guard let cipherOID = encryptionCursor.next(), cipherOID.tag == 0x06,
              let iv = encryptionCursor.next(), iv.tag == 0x04 else {
            throw Failure.unsupportedCipher("cipher malformed")
        }
        let keyLength: Int
        switch cipherOID.content {
        case OID.aes128CBC: keyLength = kCCKeySizeAES128
        case OID.aes192CBC: keyLength = kCCKeySizeAES192
        case OID.aes256CBC: keyLength = kCCKeySizeAES256
        default: throw Failure.unsupportedCipher(describe(cipherOID.content))
        }

        let derivedLength = declaredKeyLength ?? keyLength
        let key = try derive(password: password, salt: salt.content,
                             iterations: iterations, length: derivedLength, prf: prf)
        return try aesCBCDecrypt(ciphertext, key: key, iv: iv.content)
    }

    private static func derive(password: String, salt: Data, iterations: Int,
                               length: Int, prf: CCPseudoRandomAlgorithm) throws -> Data {
        var derived = Data(count: length)
        let passwordBytes = Array(password.utf8)
        let status: Int32 = derived.withUnsafeMutableBytes { output in
            salt.withUnsafeBytes { saltBytes in
                CCKeyDerivationPBKDF(
                    CCPBKDFAlgorithm(kCCPBKDF2),
                    passwordBytes, passwordBytes.count,
                    saltBytes.bindMemory(to: UInt8.self).baseAddress, salt.count,
                    prf, UInt32(iterations),
                    output.bindMemory(to: UInt8.self).baseAddress, length)
            }
        }
        guard status == kCCSuccess else { throw Failure.wrongPassword }
        return derived
    }

    private static func aesCBCDecrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        let capacity = ciphertext.count + kCCBlockSizeAES128
        var output = Data(count: capacity)
        var moved = 0
        let status: CCCryptorStatus = output.withUnsafeMutableBytes { out in
            ciphertext.withUnsafeBytes { input in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES),
                                CCOptions(kCCOptionPKCS7Padding),
                                keyBytes.baseAddress, key.count,
                                ivBytes.baseAddress,
                                input.baseAddress, ciphertext.count,
                                out.baseAddress, capacity, &moved)
                    }
                }
            }
        }
        // A wrong password decrypts to noise, and the padding check is what
        // notices -- so this is the error the user actually sees most often.
        guard status == kCCSuccess else { throw Failure.wrongPassword }
        output.count = moved
        return output
    }

    /// PrivateKeyInfo ::= SEQUENCE { version, algorithm, privateKey OCTET STRING }
    /// The OCTET STRING holds the PKCS#1 RSAPrivateKey the keychain wants.
    private static func rsaKey(fromPKCS8 data: Data) throws -> Data {
        var cursor = DERReader.Cursor(data)
        guard let sequence = cursor.enter(0x30) else { throw Failure.noPrivateKey }
        var fields = DERReader.Cursor(sequence)
        _ = fields.next()                                // version
        _ = fields.next()                                // algorithm
        guard let key = fields.next(), key.tag == 0x04 else { throw Failure.noPrivateKey }
        return key.content
    }

    private static func describe(_ oid: Data) -> String {
        oid.map { String(format: "%02x", $0) }.joined()
    }
}
