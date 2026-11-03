import Compression
import CryptoKit
import Foundation
import SQLite3

/// Turns a raw OpenStreetMap extract (.osm.pbf, e.g. from Geofabrik) into a
/// world pack, on the phone.
///
/// This is the desktop pipeline -- fetch_pois_pbf._extract (osmium) followed by
/// tools/build_world_db.py -- redone in Swift, because osmium has no iOS build
/// and the embedded CPython is far too slow to decode hundreds of MB of
/// protobuf. The rules are copied, not approximated, so a pack built here
/// matches one built on a Mac from the same file:
///
///   * which features count     fetch_osm_pois.KEYS / BLOCK / _classify
///   * which ones are gyms      fetch_osm_pois._is_gym (LANDMARK, md5 % 6)
///   * where a way sits         centroid of its node locations, like
///                              osmium's with_locations(); relations skipped
///   * the cell index           s2sphere CellId.from_lat_lng(...).parent(15)
///   * the file                 build_world_db.build's schema and meta
///
/// Two passes over the file, because in a PBF the nodes come before the ways
/// that use them: pass 1 keeps the tagged nodes and the ways worth keeping
/// (and notes which nodes those ways need), pass 2 looks up just those node
/// locations. Memory stays proportional to the POIs, not the extract.
///
/// Nothing here touches UIKit, so tools can compile it on a Mac to check it
/// against the Python pipeline.
enum OSMImport {

    struct Summary {
        let forts: Int
        let gyms: Int
        let scanned: Int
    }

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    /// (fraction 0...1, what is happening) -- called from the converting thread.
    typealias Progress = (Double, String) -> Void

    /// Reads `pbf`, writes the pack to `out` (via a temporary file, so `out`
    /// never exists half-written). `isCancelled` is polled between blocks.
    static func convert(pbf: URL, to out: URL, name: String, region: String,
                        progress: Progress = { _, _ in },
                        isCancelled: () -> Bool = { false }) throws -> Summary {
        let data: Data
        do {
            data = try Data(contentsOf: pbf, options: .alwaysMapped)
        } catch {
            throw Failure("Could not open the file: \(error.localizedDescription)")
        }
        var extractor = Extractor()
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                throw Failure("The file is empty.")
            }
            let file = PBFFile(base: base, count: raw.count)
            try extractor.run(file, progress: progress, isCancelled: isCancelled)
        }
        progress(0.97, "Writing the pack…")
        try PackWriter.write(extractor.forts, to: out, name: name, region: region)
        let gyms = extractor.forts.reduce(0) { $0 + ($1.gym ? 1 : 0) }
        return Summary(forts: extractor.forts.count, gyms: gyms, scanned: extractor.scanned)
    }

    /// "texas-latest.osm.pbf" -> "Texas", for files imported without a name.
    static func displayName(forFile url: URL) -> String {
        var base = url.lastPathComponent
        for suffix in [".osm.pbf", ".pbf"] where base.lowercased().hasSuffix(suffix) {
            base = String(base.dropLast(suffix.count))
        }
        if base.hasSuffix("-latest") { base = String(base.dropLast("-latest".count)) }
        let words = base.split(whereSeparator: { $0 == "-" || $0 == "_" })
        let name = words.map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ")
        return name.isEmpty ? "OpenStreetMap import" : name
    }

    static let latestSuffix = "-latest.osm.pbf"

    /// The newest dated copy ("texas-261001.osm.pbf") of a "-latest" extract,
    /// looked for over the last two weeks; nil when none answers.
    static func datedExtract(for latest: URL) async -> URL? {
        let text = latest.absoluteString
        guard text.hasSuffix(latestSuffix) else { return nil }
        let stem = text.dropLast(latestSuffix.count)
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.timeZone = TimeZone(identifier: "UTC")
        stamp.dateFormat = "yyMMdd"
        for daysAgo in 0..<14 {
            let day = Date().addingTimeInterval(-86400 * Double(daysAgo))
            guard let url = URL(string: "\(stem)-\(stamp.string(from: day)).osm.pbf") else { continue }
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.setValue("Windstock-launcher/1.0", forHTTPHeaderField: "User-Agent")
            // A missing file fails here too (the same redirect loop).
            if let response = try? await URLSession.shared.data(for: request).1 as? HTTPURLResponse,
               response.statusCode == 200 {
                return url
            }
        }
        return nil
    }

    /// Pack id for a region ("north-america/us/texas") or a name: kept apart
    /// from catalog ids so an import never overwrites a downloaded pack.
    static func packID(for key: String) -> String {
        let slug = key.lowercased().map { ch -> Character in
            (ch.isASCII && (ch.isLetter || ch.isNumber)) ? ch : "-"
        }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "osm-" + (collapsed.isEmpty ? "import" : collapsed)
    }
}

// MARK: - POI rules (fetch_osm_pois.py)

extension OSMImport {
    static let keys = ["amenity", "shop", "tourism", "leisure", "historic", "office",
                       "craft", "club", "man_made"]
    static let block: Set<String> = [
        "parking", "parking_space", "parking_entrance", "bench", "waste_basket",
        "recycling", "bicycle_parking", "vending_machine", "drinking_water",
        "toilets", "fountain", "grit_bin", "hunting_stand", "shelter",
        "street_lamp", "clock", "telephone", "post_box", "atm", "bbq",
        "motorcycle_parking", "charging_station"]
    static let landmark: Set<String> = [
        "stadium", "townhall", "park", "monument", "memorial", "museum",
        "castle", "attraction", "sports_centre", "recreation_ground"]
    static let gymEvery = 6

    struct Fort {
        let id: String        // "OSMn123" / "OSMw456", like the desktop
        let lat: Double
        let lng: Double
        let gym: Bool
        let name: String
    }

    /// _classify: (keep, gym, name). `values` are the KEYS values present.
    static func classify(oid: String, name rawName: String?,
                         values: [String]) -> (gym: Bool, name: String)? {
        let name = (rawName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return nil }
        let vals = Set(values.filter { !$0.isEmpty })
        if !vals.isDisjoint(with: block) { return nil }
        let gym = !vals.isDisjoint(with: landmark) || md5Mod(oid, gymEvery) == 0
        // Python's name[:40] counts code points, not grapheme clusters.
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: name.unicodeScalars.prefix(40))
        return (gym, String(scalars))
    }

    /// int(md5(s).hexdigest(), 16) % m, without a 128-bit integer.
    static func md5Mod(_ s: String, _ m: Int) -> Int {
        var r = 0
        for byte in Insecure.MD5.hash(data: Data(s.utf8)) {
            r = (r * 256 + Int(byte)) % m
        }
        return r
    }
}

// MARK: - protobuf

/// A cursor over protobuf bytes. Unchecked beyond staying inside `end`: a
/// corrupt file produces garbage values, never a read past the buffer.
struct PBReader {
    var p: UnsafePointer<UInt8>
    let end: UnsafePointer<UInt8>

    init(_ p: UnsafePointer<UInt8>, _ count: Int) {
        self.p = p
        self.end = p + count
    }

    var more: Bool { p < end }

    mutating func varint() -> UInt64 {
        var result: UInt64 = 0
        var shift: UInt64 = 0
        while p < end {
            let b = p.pointee
            p += 1
            result |= UInt64(b & 0x7f) << shift
            if b < 0x80 { return result }
            shift += 7
        }
        return result
    }

    mutating func sint() -> Int64 {
        let v = varint()
        return Int64(bitPattern: (v >> 1) ^ (0 &- (v & 1)))
    }

    mutating func int() -> Int64 { Int64(bitPattern: varint()) }

    /// (field number, wire type)
    mutating func tag() -> (Int, Int) {
        let t = varint()
        return (Int(t >> 3), Int(t & 7))
    }

    /// A length-delimited field as its own reader.
    mutating func sub() -> PBReader {
        let n = Int(varint())
        let len = min(n, end - p)
        let r = PBReader(p, len)
        p += len
        return r
    }

    mutating func skip(_ wire: Int) {
        switch wire {
        case 0: _ = varint()
        case 1: p = min(p + 8, end)
        case 2: let n = Int(varint()); p = min(p + n, end)
        case 5: p = min(p + 4, end)
        default: p = end        // groups / unknown: give up on this message
        }
    }

    var count: Int { end - p }
}

// MARK: - PBF file

/// The blob stream: [4-byte length][BlobHeader][Blob] repeated.
struct PBFFile {
    let base: UnsafePointer<UInt8>
    let count: Int

    struct Block {
        let type: String          // "OSMHeader" / "OSMData"
        let offset: Int           // where the next block starts
        let raw: Data             // the decompressed payload
    }

    /// Calls `body` for each block in order; `body` returns false to stop.
    func forEachBlock(_ body: (Block) throws -> Bool) throws {
        var pos = 0
        while pos + 4 <= count {
            let hlen = Int(base[pos]) << 24 | Int(base[pos + 1]) << 16
                | Int(base[pos + 2]) << 8 | Int(base[pos + 3])
            pos += 4
            guard hlen > 0, hlen < 64 * 1024, pos + hlen <= count else {
                throw OSMImport.Failure("This isn't an .osm.pbf file (bad block header).")
            }
            var header = PBReader(base + pos, hlen)
            pos += hlen
            var type = ""
            var size = 0
            while header.more {
                let (field, wire) = header.tag()
                if field == 1, wire == 2 {
                    let s = header.sub()
                    type = String(decoding: UnsafeBufferPointer(start: s.p, count: s.count),
                                  as: UTF8.self)
                } else if field == 3, wire == 0 {
                    size = Int(header.varint())
                } else {
                    header.skip(wire)
                }
            }
            guard size >= 0, pos + size <= count else {
                throw OSMImport.Failure("The file is cut short -- was the download finished?")
            }
            let raw = try Self.decodeBlob(base + pos, size)
            pos += size
            if try !body(Block(type: type, offset: pos, raw: raw)) { return }
        }
    }

    private static func decodeBlob(_ p: UnsafePointer<UInt8>, _ n: Int) throws -> Data {
        var blob = PBReader(p, n)
        var rawSize = 0
        var plain: PBReader?
        var zlib: PBReader?
        while blob.more {
            let (field, wire) = blob.tag()
            switch (field, wire) {
            case (1, 2): plain = blob.sub()
            case (2, 0): rawSize = Int(blob.varint())
            case (3, 2): zlib = blob.sub()
            case (4, 2), (6, 2), (7, 2):
                throw OSMImport.Failure("This file uses a compression the app can't read "
                                        + "(only zlib is supported, which Geofabrik uses).")
            default: blob.skip(wire)
            }
        }
        if let plain {
            return Data(bytes: plain.p, count: plain.count)
        }
        guard let zlib, zlib.count > 2, rawSize > 0, rawSize < 64 * 1024 * 1024 else {
            throw OSMImport.Failure("This isn't an .osm.pbf file (empty block).")
        }
        // zlib = 2-byte header + raw deflate + adler32; Compression wants the deflate.
        var out = Data(count: rawSize)
        let got = out.withUnsafeMutableBytes { dst -> Int in
            compression_decode_buffer(dst.baseAddress!.assumingMemoryBound(to: UInt8.self),
                                      rawSize, zlib.p + 2, zlib.count - 2,
                                      nil, COMPRESSION_ZLIB)
        }
        guard got == rawSize else {
            throw OSMImport.Failure("A block of the file is damaged -- try downloading it again.")
        }
        return out
    }
}

// MARK: - extraction

extension OSMImport {

    /// Pass 1 + pass 2 over one file.
    struct Extractor {
        private(set) var forts: [Fort] = []
        /// Features that carried one of KEYS -- what osmium's KeyFilter passes.
        private(set) var scanned = 0

        private struct PendingWay {
            let oid: String
            let gym: Bool
            let name: String
            let refs: [Int64]
        }
        private var ways: [PendingWay] = []
        private var needed = Set<Int64>()
        private var located: [Int64: (Int64, Int64)] = [:]   // id -> fixed 1e-7 lat/lon
        private var sortedByType = false

        mutating func run(_ file: PBFFile, progress: Progress,
                          isCancelled: () -> Bool) throws {
            let total = Double(max(file.count, 1))
            var sawData = false
            var lastReport = -1.0

            // Pass 1: tagged nodes and ways (nodes 0...55%, since pass 2 is
            // usually cut short once the ways start).
            try file.forEachBlock { block in
                if isCancelled() { throw CancellationError() }
                let f = Double(block.offset) / total
                if f - lastReport > 0.005 {
                    lastReport = f
                    progress(f * 0.55, "Reading places… \(forts.count + ways.count) found")
                }
                if block.type == "OSMHeader" {
                    sortedByType = Self.headerSaysSorted(block.raw)
                } else if block.type == "OSMData" {
                    sawData = true
                    block.raw.withUnsafeBytes { raw in
                        let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                        self.pass1(PBReader(p, raw.count))
                    }
                }
                return true
            }
            guard sawData else {
                throw Failure("This isn't an .osm.pbf file (no map data in it).")
            }
            guard !ways.isEmpty else { return }

            // Pass 2: locations of the nodes the kept ways use.
            for way in ways { needed.formUnion(way.refs) }
            located.reserveCapacity(needed.count)
            lastReport = -1
            try file.forEachBlock { block in
                if isCancelled() { throw CancellationError() }
                let f = Double(block.offset) / total
                if f - lastReport > 0.005 {
                    lastReport = f
                    progress(0.55 + f * 0.4, "Placing parks and buildings…")
                }
                guard block.type == "OSMData" else { return true }
                var sawWays = false
                block.raw.withUnsafeBytes { raw in
                    let p = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                    sawWays = self.pass2(PBReader(p, raw.count))
                }
                // Sorted files put every node before the first way.
                return !(sortedByType && sawWays) && located.count < needed.count
            }

            for way in ways {
                var lat = 0.0, lng = 0.0, n = 0
                for ref in way.refs {
                    guard let (la, lo) = located[ref] else { continue }
                    lat += Double(la) / 1e7
                    lng += Double(lo) / 1e7
                    n += 1
                }
                guard n > 0 else { continue }
                forts.append(Fort(id: "OSM" + way.oid, lat: Self.round7(lat / Double(n)),
                                  lng: Self.round7(lng / Double(n)),
                                  gym: way.gym, name: way.name))
            }
            ways = []
            located = [:]
            needed = []
        }

        static func round7(_ x: Double) -> Double { (x * 1e7).rounded() / 1e7 }

        private static func headerSaysSorted(_ raw: Data) -> Bool {
            raw.withUnsafeBytes { buf -> Bool in
                var r = PBReader(buf.baseAddress!.assumingMemoryBound(to: UInt8.self), buf.count)
                while r.more {
                    let (field, wire) = r.tag()
                    if field == 5, wire == 2 {
                        let s = r.sub()
                        let str = String(decoding: UnsafeBufferPointer(start: s.p, count: s.count),
                                         as: UTF8.self)
                        if str == "Sort.Type_then_ID" { return true }
                    } else {
                        r.skip(wire)
                    }
                }
                return false
            }
        }

        // MARK: block structure

        /// What the block-level fields say about coordinates, plus the string
        /// table reduced to what we look up: which entries are a KEYS key or
        /// "name", and where each entry's bytes are.
        private struct BlockInfo {
            var strings: [(UnsafePointer<UInt8>, Int)] = []
            var role: [Int8] = []          // 0..8 = KEYS index, 9 = "name", -1 other
            var granularity: Int64 = 100
            var latOffset: Int64 = 0
            var lonOffset: Int64 = 0

            func string(_ i: Int) -> String {
                guard i >= 0, i < strings.count else { return "" }
                let (p, n) = strings[i]
                return String(decoding: UnsafeBufferPointer(start: p, count: n), as: UTF8.self)
            }

            func role(_ i: Int) -> Int8 { (i >= 0 && i < role.count) ? role[i] : -1 }

            /// Fixed 1e-7 degrees, as osmium stores a Location.
            func fixedLat(_ v: Int64) -> Int64 { (latOffset + granularity * v) / 100 }
            func fixedLon(_ v: Int64) -> Int64 { (lonOffset + granularity * v) / 100 }
        }

        private static let keyBytes: [[UInt8]] = OSMImport.keys.map { Array($0.utf8) }
        private static let nameBytes: [UInt8] = Array("name".utf8)

        private static func roleOf(_ p: UnsafePointer<UInt8>, _ n: Int) -> Int8 {
            func eq(_ b: [UInt8]) -> Bool {
                guard b.count == n else { return false }
                for k in 0..<n where p[k] != b[k] { return false }
                return true
            }
            if eq(nameBytes) { return 9 }
            for (i, k) in keyBytes.enumerated() where eq(k) { return Int8(i) }
            return -1
        }

        /// Splits a PrimitiveBlock into its info and its groups.
        private static func parseBlock(_ reader: PBReader) -> (BlockInfo, [PBReader]) {
            var r = reader
            var info = BlockInfo()
            var groups: [PBReader] = []
            while r.more {
                let (field, wire) = r.tag()
                switch (field, wire) {
                case (1, 2):
                    var st = r.sub()
                    while st.more {
                        let (f, w) = st.tag()
                        if f == 1, w == 2 {
                            let s = st.sub()
                            info.strings.append((s.p, s.count))
                            info.role.append(roleOf(s.p, s.count))
                        } else {
                            st.skip(w)
                        }
                    }
                case (2, 2): groups.append(r.sub())
                case (17, 0): info.granularity = r.int()
                case (19, 0): info.latOffset = r.int()
                case (20, 0): info.lonOffset = r.int()
                default: r.skip(wire)
                }
            }
            return (info, groups)
        }

        /// Keep/drop one feature from its (key, value) string indices.
        private func judge(_ oid: String, _ pairs: [(Int, Int)],
                           _ info: BlockInfo) -> (gym: Bool, name: String)? {
            var hasKey = false
            var name: String?
            var values: [String] = []
            for (k, v) in pairs {
                let role = info.role(k)
                if role == 9 {
                    name = info.string(v)
                } else if role >= 0 {
                    hasKey = true
                    values.append(info.string(v))
                }
            }
            guard hasKey else { return nil }
            return OSMImport.classify(oid: oid, name: name, values: values)
        }

        private static func hasKey(_ pairs: [(Int, Int)], _ info: BlockInfo) -> Bool {
            pairs.contains { k, _ in
                let role = info.role(k)
                return role >= 0 && role < 9
            }
        }

        // MARK: pass 1

        private mutating func pass1(_ reader: PBReader) {
            let (info, groups) = Self.parseBlock(reader)
            // Nothing in this block names a KEYS key: no feature here can pass.
            guard info.role.contains(where: { $0 >= 0 && $0 < 9 }) else { return }
            for var g in groups {
                while g.more {
                    let (field, wire) = g.tag()
                    switch (field, wire) {
                    case (1, 2): node(g.sub(), info)
                    case (2, 2): dense(g.sub(), info)
                    case (3, 2): way(g.sub(), info)
                    case (4, 2):
                        // Relations pass osmium's KeyFilter but have no location.
                        var rel = g.sub()
                        var keys: [Int] = []
                        var vals: [Int] = []
                        Self.readKV(&rel, &keys, &vals)
                        if Self.hasKey(Array(zip(keys, vals)), info) { scanned += 1 }
                    default: g.skip(wire)
                    }
                }
            }
        }

        /// keys = 2, vals = 3 (packed) for Node / Way / Relation; skips the rest.
        private static func readKV(_ r: inout PBReader, _ keys: inout [Int], _ vals: inout [Int]) {
            while r.more {
                let (field, wire) = r.tag()
                if field == 2, wire == 2 {
                    var s = r.sub(); while s.more { keys.append(Int(s.varint())) }
                } else if field == 3, wire == 2 {
                    var s = r.sub(); while s.more { vals.append(Int(s.varint())) }
                } else {
                    r.skip(wire)
                }
            }
        }

        private mutating func node(_ reader: PBReader, _ info: BlockInfo) {
            var r = reader
            var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
            var keys: [Int] = [], vals: [Int] = []
            while r.more {
                let (field, wire) = r.tag()
                switch (field, wire) {
                case (1, 0): id = r.sint()
                case (2, 2): var s = r.sub(); while s.more { keys.append(Int(s.varint())) }
                case (3, 2): var s = r.sub(); while s.more { vals.append(Int(s.varint())) }
                case (8, 0): lat = r.sint()
                case (9, 0): lon = r.sint()
                default: r.skip(wire)
                }
            }
            addNode(id, info.fixedLat(lat), info.fixedLon(lon), Array(zip(keys, vals)), info)
        }

        private mutating func addNode(_ id: Int64, _ lat: Int64, _ lon: Int64,
                                      _ pairs: [(Int, Int)], _ info: BlockInfo) {
            guard Self.hasKey(pairs, info) else { return }
            scanned += 1
            let oid = "n\(id)"
            guard let (gym, name) = judge(oid, pairs, info) else { return }
            forts.append(Fort(id: "OSM" + oid, lat: Self.round7(Double(lat) / 1e7),
                              lng: Self.round7(Double(lon) / 1e7), gym: gym, name: name))
        }

        private mutating func dense(_ reader: PBReader, _ info: BlockInfo) {
            var r = reader
            var ids: [Int64] = [], lats: [Int64] = [], lons: [Int64] = []
            var kv: PBReader?
            while r.more {
                let (field, wire) = r.tag()
                switch (field, wire) {
                case (1, 2):
                    var s = r.sub(); var acc: Int64 = 0
                    while s.more { acc &+= s.sint(); ids.append(acc) }
                case (8, 2):
                    var s = r.sub(); var acc: Int64 = 0
                    while s.more { acc &+= s.sint(); lats.append(acc) }
                case (9, 2):
                    var s = r.sub(); var acc: Int64 = 0
                    while s.more { acc &+= s.sint(); lons.append(acc) }
                case (10, 2): kv = r.sub()
                default: r.skip(wire)
                }
            }
            guard var kv, ids.count == lats.count, ids.count == lons.count else { return }
            // keys_vals: k v k v ... 0 per node, in node order.
            var pairs: [(Int, Int)] = []
            var i = 0
            while kv.more, i < ids.count {
                let k = Int(kv.varint())
                if k == 0 {
                    if !pairs.isEmpty {
                        addNode(ids[i], info.fixedLat(lats[i]), info.fixedLon(lons[i]), pairs, info)
                        pairs.removeAll(keepingCapacity: true)
                    }
                    i += 1
                } else {
                    pairs.append((k, Int(kv.varint())))
                }
            }
        }

        private mutating func way(_ reader: PBReader, _ info: BlockInfo) {
            var r = reader
            var id: Int64 = 0
            var keys: [Int] = [], vals: [Int] = []
            var refs: PBReader?
            while r.more {
                let (field, wire) = r.tag()
                switch (field, wire) {
                case (1, 0): id = r.int()
                case (2, 2): var s = r.sub(); while s.more { keys.append(Int(s.varint())) }
                case (3, 2): var s = r.sub(); while s.more { vals.append(Int(s.varint())) }
                case (8, 2): refs = r.sub()
                default: r.skip(wire)
                }
            }
            let pairs = Array(zip(keys, vals))
            guard Self.hasKey(pairs, info) else { return }
            scanned += 1
            let oid = "w\(id)"
            guard let (gym, name) = judge(oid, pairs, info), var refs else { return }
            var list: [Int64] = []
            var acc: Int64 = 0
            while refs.more { acc &+= refs.sint(); list.append(acc) }
            guard !list.isEmpty else { return }
            ways.append(PendingWay(oid: oid, gym: gym, name: name, refs: list))
        }

        // MARK: pass 2

        /// Records needed node locations. Returns true if the block had ways
        /// or relations (so, in a sorted file, there are no more nodes).
        private mutating func pass2(_ reader: PBReader) -> Bool {
            let (info, groups) = Self.parseBlock(reader)
            var sawWays = false
            for var g in groups {
                while g.more {
                    let (field, wire) = g.tag()
                    switch (field, wire) {
                    case (1, 2):
                        var r = g.sub()
                        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
                        while r.more {
                            let (f, w) = r.tag()
                            switch (f, w) {
                            case (1, 0): id = r.sint()
                            case (8, 0): lat = r.sint()
                            case (9, 0): lon = r.sint()
                            default: r.skip(w)
                            }
                        }
                        if needed.contains(id) {
                            located[id] = (info.fixedLat(lat), info.fixedLon(lon))
                        }
                    case (2, 2):
                        var r = g.sub()
                        var ids: PBReader?, lats: PBReader?, lons: PBReader?
                        while r.more {
                            let (f, w) = r.tag()
                            switch (f, w) {
                            case (1, 2): ids = r.sub()
                            case (8, 2): lats = r.sub()
                            case (9, 2): lons = r.sub()
                            default: r.skip(w)
                            }
                        }
                        guard var ids, var lats, var lons else { break }
                        var id: Int64 = 0, lat: Int64 = 0, lon: Int64 = 0
                        while ids.more, lats.more, lons.more {
                            id &+= ids.sint(); lat &+= lats.sint(); lon &+= lons.sint()
                            if needed.contains(id) {
                                located[id] = (info.fixedLat(lat), info.fixedLon(lon))
                            }
                        }
                    case (3, 2), (4, 2):
                        sawWays = true
                        g.skip(wire)
                    default:
                        g.skip(wire)
                    }
                }
            }
            return sawWays
        }
    }
}

// MARK: - S2 (s2sphere's CellId.from_lat_lng, quadratic projection)

enum S2Cell {
    private static let lookupBits = 4
    private static let swapMask = 1
    private static let invertMask = 2
    private static let maxLevel = 30
    private static let posToIJ = [[0, 1, 3, 2], [0, 2, 3, 1], [3, 2, 0, 1], [3, 1, 0, 2]]
    private static let posToOrientation = [1, 0, 0, 3]   // SWAP, 0, 0, INVERT|SWAP

    private static let lookupPos: [Int] = {
        var table = [Int](repeating: 0, count: 1 << (2 * lookupBits + 2))
        func fill(_ level: Int, _ i: Int, _ j: Int, _ origOrientation: Int,
                  _ pos: Int, _ orientation: Int) {
            if level == lookupBits {
                let ij = (i << lookupBits) + j
                table[(ij << 2) + origOrientation] = (pos << 2) + orientation
                return
            }
            let r = posToIJ[orientation]
            for index in 0..<4 {
                fill(level + 1, (i << 1) + (r[index] >> 1), (j << 1) + (r[index] & 1),
                     origOrientation, (pos << 2) + index,
                     orientation ^ posToOrientation[index])
            }
        }
        for o in [0, swapMask, invertMask, swapMask | invertMask] {
            fill(0, 0, 0, o, 0, o)
        }
        return table
    }()

    /// The level-`level` cell id containing (lat, lng), as a signed 64-bit
    /// value -- how build_world_db.s64 stores it.
    static func id(lat: Double, lng: Double, level: Int = 15) -> Int64 {
        let phi = lat * (Double.pi / 180)
        let theta = lng * (Double.pi / 180)
        let cosphi = cos(phi)
        let x = cos(theta) * cosphi, y = sin(theta) * cosphi, z = sin(phi)

        let ax = abs(x), ay = abs(y), az = abs(z)
        var face = ax > ay ? (ax > az ? 0 : 2) : (ay > az ? 1 : 2)
        if [x, y, z][face] < 0 { face += 3 }
        let (u, v): (Double, Double)
        switch face {
        case 0: (u, v) = (y / x, z / x)
        case 1: (u, v) = (-x / y, z / y)
        case 2: (u, v) = (-x / z, -y / z)
        case 3: (u, v) = (z / x, y / x)
        case 4: (u, v) = (z / y, -x / y)
        default: (u, v) = (-y / z, -x / z)
        }
        let i = stToIJ(uvToST(u)), j = stToIJ(uvToST(v))

        var n = UInt64(face) << UInt64(2 * maxLevel)     // face << (POS_BITS - 1)
        var bits = face & swapMask
        let mask = (1 << lookupBits) - 1
        for k in stride(from: 7, through: 0, by: -1) {
            bits += ((i >> (k * lookupBits)) & mask) << (lookupBits + 2)
            bits += ((j >> (k * lookupBits)) & mask) << 2
            bits = lookupPos[bits]
            n |= UInt64(bits >> 2) << UInt64(k * 2 * lookupBits)
            bits &= swapMask | invertMask
        }
        let leaf = n &* 2 &+ 1
        let lsb = UInt64(1) << UInt64(2 * (maxLevel - level))
        return Int64(bitPattern: (leaf & (0 &- lsb)) | lsb)
    }

    private static func uvToST(_ u: Double) -> Double {
        u >= 0 ? 0.5 * (1 + 3 * u).squareRoot() : 1 - 0.5 * (1 - 3 * u).squareRoot()
    }

    private static func stToIJ(_ s: Double) -> Int {
        let size = 1 << maxLevel
        return max(0, min(size - 1, Int((Double(size) * s).rounded(.down))))
    }
}

// MARK: - pack file (tools/build_world_db.py)

enum PackWriter {
    static func write(_ forts: [OSMImport.Fort], to out: URL,
                      name: String, region: String) throws {
        let fm = FileManager.default
        let tmp = out.appendingPathExtension("tmp")
        try? fm.removeItem(at: tmp)
        try fm.createDirectory(at: out.deletingLastPathComponent(),
                               withIntermediateDirectories: true)

        var db: OpaquePointer?
        guard sqlite3_open(tmp.path, &db) == SQLITE_OK, let db else {
            throw OSMImport.Failure("Could not create the pack file.")
        }
        var closed = false
        defer { if !closed { sqlite3_close(db) } }

        func exec(_ sql: String) throws {
            var err: UnsafeMutablePointer<CChar>?
            if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
                let msg = err.map { String(cString: $0) } ?? "unknown"
                sqlite3_free(err)
                throw OSMImport.Failure("Writing the pack failed: \(msg)")
            }
        }

        try exec("""
            PRAGMA journal_mode = OFF;
            PRAGMA synchronous = OFF;
            CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE forts (cell INTEGER NOT NULL, id TEXT, lat REAL, lng REAL,
                                kind INTEGER, name TEXT, image TEXT);
            CREATE TABLE biome_cells (cell INTEGER PRIMARY KEY, biome TEXT)
                WITHOUT ROWID;
            BEGIN;
            """)

        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT INTO forts VALUES (?,?,?,?,?,?,NULL)",
                                 -1, &stmt, nil) == SQLITE_OK else {
            throw OSMImport.Failure("Writing the pack failed.")
        }
        for f in forts {
            sqlite3_bind_int64(stmt, 1, S2Cell.id(lat: f.lat, lng: f.lng))
            sqlite3_bind_text(stmt, 2, f.id, -1, transient)
            sqlite3_bind_double(stmt, 3, f.lat)
            sqlite3_bind_double(stmt, 4, f.lng)
            sqlite3_bind_int(stmt, 5, f.gym ? 1 : 0)
            sqlite3_bind_text(stmt, 6, f.name, -1, transient)
            guard sqlite3_step(stmt) == SQLITE_DONE else {
                sqlite3_finalize(stmt)
                throw OSMImport.Failure("Writing the pack failed.")
            }
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        try exec("CREATE INDEX forts_cell ON forts(cell);")

        let built: String = {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.string(from: Date())
        }()
        let meta: [(String, String)] = [
            ("name", name), ("region", region), ("fort_count", String(forts.count)),
            ("biome_count", "0"), ("biome_level", "12"), ("terrain_points", "[]"),
            ("built", built), ("source", "osm.pbf, converted on device"),
        ]
        guard sqlite3_prepare_v2(db, "INSERT INTO meta VALUES (?,?)", -1, &stmt, nil) == SQLITE_OK
        else { throw OSMImport.Failure("Writing the pack failed.") }
        for (k, v) in meta {
            sqlite3_bind_text(stmt, 1, k, -1, transient)
            sqlite3_bind_text(stmt, 2, v, -1, transient)
            _ = sqlite3_step(stmt)
            sqlite3_reset(stmt)
        }
        sqlite3_finalize(stmt)
        try exec("COMMIT;")
        try exec("VACUUM;")
        sqlite3_close(db)
        closed = true

        // The server opens packs immutable: replace, never rewrite in place.
        if fm.fileExists(atPath: out.path) {
            _ = try fm.replaceItemAt(out, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: out)
        }
    }
}
