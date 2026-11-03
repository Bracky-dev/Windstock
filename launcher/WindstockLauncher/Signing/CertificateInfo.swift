import Foundation
import Security

/// Reads the two fields the launcher needs out of an X.509 certificate.
///
/// SecCertificateCopyValues would do this in one call, but it is macOS-only.
/// Walking the DER is a few dozen lines, works on both, and keeps the same
/// code path under test on the Mac.
enum CertificateInfo {
    /// Apple puts the Team ID in the subject's Organizational Unit, and the
    /// CodeDirectory has to carry the same string.
    static func teamID(of certificate: SecCertificate) -> String? {
        guard let subject = fields(of: certificate)?.subject else { return nil }
        return attribute(oid: Data([0x55, 0x04, 0x0B]), inName: subject)   // 2.5.4.11
    }

    static func notAfter(of certificate: SecCertificate) -> Date? {
        fields(of: certificate)?.notAfter
    }

    /// Everything we read, from one walk of the certificate.
    ///
    /// SecCertificateCopySubjectSequence exists but is iOS-only, the same way
    /// SecCertificateCopyValues is macOS-only; parsing the DER avoids having
    /// two code paths and keeps the Mac able to test what the phone will run.
    private static func fields(of certificate: SecCertificate)
        -> (subject: Data, notAfter: Date?)? {
        let der = SecCertificateCopyData(certificate) as Data

        var outer = Cursor(der)
        guard let certificateBody = outer.enter(0x30) else { return nil }
        var top = Cursor(certificateBody)
        guard let tbs = top.enter(0x30) else { return nil }

        // tbsCertificate ::= { [0] version OPTIONAL, serial, signature,
        //                      issuer, validity, subject, ... }
        var walker = Cursor(tbs)
        if walker.peek() == 0xA0 { _ = walker.next() }
        _ = walker.next()          // serialNumber
        _ = walker.next()          // signature algorithm
        _ = walker.next()          // issuer
        guard let validity = walker.next(), validity.tag == 0x30,
              let subject = walker.next(), subject.tag == 0x30 else { return nil }

        var times = Cursor(validity.content)
        _ = times.next()           // notBefore
        let notAfter = times.next().flatMap(parseTime)
        return (subject.content, notAfter)
    }

    // MARK: - DER walking

    private typealias Element = DERReader.Element
    private typealias Cursor = DERReader.Cursor

    /// Name ::= SEQUENCE OF SET OF SEQUENCE { type OID, value }
    private static func attribute(oid: Data, inName name: Data) -> String? {
        var rdns = Cursor(name)
        while let rdn = rdns.next() {
            guard rdn.tag == 0x31 else { continue }
            var pairs = Cursor(rdn.content)
            while let pair = pairs.next() {
                guard pair.tag == 0x30 else { continue }
                var parts = Cursor(pair.content)
                guard let type = parts.next(), type.tag == 0x06, type.content == oid,
                      let value = parts.next() else { continue }
                return String(data: value.content, encoding: .utf8)
                    ?? String(decoding: value.content, as: UTF8.self)
            }
        }
        return nil
    }

    /// UTCTime (YYMMDDHHMMSSZ) or GeneralizedTime (YYYYMMDDHHMMSSZ).
    private static func parseTime(_ element: Element) -> Date? {
        let text = String(decoding: element.content, as: UTF8.self)
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = element.tag == 0x18 ? "yyyyMMddHHmmss'Z'" : "yyMMddHHmmss'Z'"
        return formatter.date(from: text)
    }
}
