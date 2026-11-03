import Foundation

/// A cursor over DER, shared by the certificate reader and the PKCS#12 parser.
///
/// Deliberately forgiving in one direction only: it never reads past the end
/// of its slice, and returns nil rather than trapping on anything malformed.
/// Every caller is parsing a file the user chose, so "give up cleanly" is the
/// required behaviour.
enum DERReader {
    struct Element {
        var tag: UInt8
        var content: Data

        var isConstructed: Bool { tag & 0x20 != 0 }
    }

    struct Cursor {
        let data: Data
        var offset: Int

        init(_ data: Data) {
            self.data = data
            offset = data.startIndex
        }

        var isAtEnd: Bool { offset >= data.endIndex }

        func peek() -> UInt8? {
            offset < data.endIndex ? data[offset] : nil
        }

        mutating func next() -> Element? {
            guard offset + 2 <= data.endIndex else { return nil }
            let tag = data[offset]
            var index = offset + 1
            var length = Int(data[index])
            index += 1
            if length & 0x80 != 0 {
                let byteCount = length & 0x7F
                guard byteCount > 0, byteCount <= 4, index + byteCount <= data.endIndex else {
                    return nil
                }
                length = 0
                for _ in 0..<byteCount {
                    length = (length << 8) | Int(data[index])
                    index += 1
                }
            }
            guard length >= 0, index + length <= data.endIndex else { return nil }
            let content = data[index..<(index + length)]
            offset = index + length
            return Element(tag: tag, content: Data(content))
        }

        /// The content of the next element, if it carries the expected tag.
        mutating func enter(_ tag: UInt8) -> Data? {
            guard let element = next(), element.tag == tag else { return nil }
            return element.content
        }

        /// Every remaining element.
        mutating func rest() -> [Element] {
            var out: [Element] = []
            while let element = next() { out.append(element) }
            return out
        }
    }

    /// "1.2.840.113549.1.5.13" -> the DER content bytes of that OID, so a
    /// parsed OID element can be compared without re-encoding.
    static func oidBytes(_ dotted: String) -> Data {
        let parts = dotted.split(separator: ".").compactMap { UInt64($0) }
        guard parts.count >= 2 else { return Data() }
        var bytes: [UInt8] = [UInt8(parts[0] * 40 + parts[1])]
        for part in parts.dropFirst(2) {
            if part == 0 { bytes.append(0); continue }
            var chunk: [UInt8] = []
            var value = part
            while value > 0 {
                chunk.insert(UInt8(value & 0x7F), at: 0)
                value >>= 7
            }
            for i in 0..<(chunk.count - 1) { chunk[i] |= 0x80 }
            bytes.append(contentsOf: chunk)
        }
        return Data(bytes)
    }

    /// An INTEGER's value, for the small ones (iteration counts, versions).
    static func integer(_ element: Element) -> Int? {
        guard element.tag == 0x02, !element.content.isEmpty else { return nil }
        var value = 0
        for byte in element.content {
            guard value < Int.max >> 8 else { return nil }
            value = (value << 8) | Int(byte)
        }
        return value
    }
}
