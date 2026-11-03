import Compression
import Foundation

/// Just enough of the ZIP format to unpack an IPA.
///
/// iOS has no unzip and no public API for it -- AppleArchive reads .aar, not
/// .zip, and NSFileCoordinator only writes archives. So: read the central
/// directory, and inflate each entry with the Compression framework, whose
/// COMPRESSION_ZLIB is raw DEFLATE, which is exactly what ZIP stores.
///
/// Deliberately not a general ZIP library. It handles stored and deflated
/// entries and refuses anything else loudly rather than producing a half
/// unpacked app.
enum Zip {
    enum Failure: LocalizedError {
        case notAZip
        case zip64Unsupported
        case unsupportedCompression(UInt16, String)
        case inflateFailed(String)
        case unsafeEntry(String)

        var errorDescription: String? {
            switch self {
            case .notAZip:
                return "That file is not a zip archive (no end-of-central-directory record)."
            case .zip64Unsupported:
                return "That archive uses ZIP64. Re-export it as a normal zip."
            case .unsupportedCompression(let method, let name):
                return "\(name) uses compression method \(method), which is not supported."
            case .inflateFailed(let name):
                return "\(name) could not be decompressed."
            case .unsafeEntry(let name):
                return "Refusing to extract \(name): it points outside the destination."
            }
        }
    }

    static func extract(at source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source, options: .mappedIfSafe)
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        let (entryCount, directoryOffset) = try locateCentralDirectory(data)
        var offset = directoryOffset

        for _ in 0..<entryCount {
            guard offset + 46 <= data.count,
                  data.readLE(at: offset) as UInt32 == 0x0201_4B50 else { break }

            let method: UInt16 = data.readLE(at: offset + 10)
            let compressedSize: UInt32 = data.readLE(at: offset + 20)
            let uncompressedSize: UInt32 = data.readLE(at: offset + 24)
            let nameLength = Int(data.readLE(at: offset + 28) as UInt16)
            let extraLength = Int(data.readLE(at: offset + 30) as UInt16)
            let commentLength = Int(data.readLE(at: offset + 32) as UInt16)
            let externalAttributes: UInt32 = data.readLE(at: offset + 38)
            let localHeader = Int(data.readLE(at: offset + 42) as UInt32)

            let nameStart = offset + 46
            let name = String(decoding: data[nameStart..<(nameStart + nameLength)],
                              as: UTF8.self)
            offset = nameStart + nameLength + extraLength + commentLength

            if compressedSize == 0xFFFF_FFFF || uncompressedSize == 0xFFFF_FFFF {
                throw Failure.zip64Unsupported
            }

            // A "../.." entry would write outside the app's own directory.
            let target = destination.appendingPathComponent(name).standardized
            guard target.path.hasPrefix(destination.standardized.path) else {
                throw Failure.unsafeEntry(name)
            }

            if name.hasSuffix("/") {
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            try fm.createDirectory(at: target.deletingLastPathComponent(),
                                   withIntermediateDirectories: true)

            // The local header repeats the name and extra fields, and its
            // lengths are the ones that count for finding the data.
            guard localHeader + 30 <= data.count else { continue }
            let localNameLength = Int(data.readLE(at: localHeader + 26) as UInt16)
            let localExtraLength = Int(data.readLE(at: localHeader + 28) as UInt16)
            let dataStart = localHeader + 30 + localNameLength + localExtraLength
            let dataEnd = dataStart + Int(compressedSize)
            guard dataEnd <= data.count else { continue }
            let payload = data[dataStart..<dataEnd]

            let contents: Data
            switch method {
            case 0:
                contents = Data(payload)
            case 8:
                contents = try inflate(Data(payload),
                                       expecting: Int(uncompressedSize), name: name)
            default:
                throw Failure.unsupportedCompression(method, name)
            }

            let mode = mode_t((externalAttributes >> 16) & 0xFFFF)
            if mode & S_IFMT == S_IFLNK {
                let linkTarget = String(decoding: contents, as: UTF8.self)
                try? fm.removeItem(at: target)
                try fm.createSymbolicLink(atPath: target.path,
                                          withDestinationPath: linkTarget)
                continue
            }

            try contents.write(to: target, options: .atomic)
            if mode & 0o777 != 0 {
                try? fm.setAttributes([.posixPermissions: NSNumber(value: mode & 0o777)],
                                      ofItemAtPath: target.path)
            }
        }
    }

    // MARK: -

    private static func locateCentralDirectory(_ data: Data) throws -> (Int, Int) {
        // The record is at the end, behind a comment of up to 64 KB.
        let maximumComment = 0xFFFF + 22
        let start = max(0, data.count - maximumComment)
        var index = data.count - 22
        while index >= start {
            if data.readLE(at: index) as UInt32 == 0x0605_4B50 {
                let entries = Int(data.readLE(at: index + 10) as UInt16)
                let size: UInt32 = data.readLE(at: index + 12)
                let offset: UInt32 = data.readLE(at: index + 16)
                if entries == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
                    throw Failure.zip64Unsupported
                }
                return (entries, Int(offset))
            }
            index -= 1
        }
        throw Failure.notAZip
    }

    private static func inflate(_ input: Data, expecting size: Int,
                                name: String) throws -> Data {
        if size == 0 { return Data() }
        var output = Data(count: size)
        let written: Int = try output.withUnsafeMutableBytes { destination in
            try input.withUnsafeBytes { source -> Int in
                guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress,
                      let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else {
                    throw Failure.inflateFailed(name)
                }
                return compression_decode_buffer(
                    destinationBase, size, sourceBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw Failure.inflateFailed(name) }
        return output
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
}
