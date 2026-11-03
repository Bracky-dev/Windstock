import Foundation
import Security

/// Completes the certificate chain that goes into a signature's CMS.
///
/// A .p12 exported from AltStore or SideStore generally contains only the leaf
/// — your "iPhone Developer: ..." certificate — and nothing above it. Signing
/// with just that produces a signature Apple's own codesign reports as
/// `Authority=(unavailable)` / `CSSMERR_TP_NOT_TRUSTED`, and which the device
/// rejects at dlopen with
///
///     code signature invalid ... (errno=1)
///
/// because AMFI cannot build a path from the leaf to a root it trusts. The
/// device has Apple's roots but not the Worldwide Developer Relations
/// intermediate that sits between, so the signature has to carry it.
///
/// The intermediates ship in the app bundle as .cer files and are matched to
/// the leaf by issuer, rather than assumed: a certificate issued by a
/// different generation of the WWDR CA needs a different one, and appending
/// the wrong intermediate is no better than appending none.
enum CertificateChain {
    /// Leaf first, then whatever intermediates are needed and available.
    static func complete(_ chain: [SecCertificate]) -> [SecCertificate] {
        guard var current = chain.last else { return chain }
        var result = chain
        let available = bundled()

        // Walk up until something is self-issued or nothing matches.
        for _ in 0..<4 {
            guard let issuer = SecCertificateCopyNormalizedIssuerSequence(current) as Data?,
                  let subject = SecCertificateCopyNormalizedSubjectSequence(current) as Data?,
                  issuer != subject                      // self-signed: done
            else { break }

            guard let next = available.first(where: { candidate in
                (SecCertificateCopyNormalizedSubjectSequence(candidate) as Data?) == issuer
            }) else { break }

            // Guard against a loop and against adding one already present.
            let already = result.contains {
                (SecCertificateCopyData($0) as Data) == (SecCertificateCopyData(next) as Data)
            }
            if already { break }

            result.append(next)
            current = next
        }

        if result.count > chain.count {
            let added = result.count - chain.count
            WSLog("signing", "chain completed with \(added) bundled intermediate"
                  + (added == 1 ? "" : "s"))
        } else if result.count == 1 {
            WSLog("signing", "no intermediate found for this certificate — the "
                  + "signature will not chain to an Apple root")
        }
        return result
    }

    /// Certificates shipped in the app. Read from the launcher's own bundle
    /// path rather than NSBundle.mainBundle, which is swizzled onto the guest
    /// once a game starts.
    private static func bundled() -> [SecCertificate] {
        let fm = FileManager.default
        let root = WSPaths.hostBundlePath
        let names = (try? fm.contentsOfDirectory(atPath: root)) ?? []
        return names
            .filter { $0.hasSuffix(".cer") }
            .compactMap { fm.contents(atPath: (root as NSString).appendingPathComponent($0)) }
            .compactMap { SecCertificateCreateWithData(nil, $0 as CFData) }
    }
}
