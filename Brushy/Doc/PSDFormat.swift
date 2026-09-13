import Compression
import Foundation

/// Shared PSD primitives: big-endian reading, the two compression schemes
/// Photoshop writes, and the blend-key table read backwards.
///
/// `PSDWriter` (write) and `PSDReader` (read) both lean on this; the writer's
/// own `Data.appendU16`-style helpers stay where they are, so the two
/// directions can't quietly drift into each other's assumptions.

enum PSDReadError: LocalizedError {
    case notAPSD
    case unsupportedVersion(Int)
    case truncated(String)
    case unsupportedLayout(String)
    case renderFailed(String)

    var errorDescription: String? {
        switch self {
        case .notAPSD:
            return "That file is not a Photoshop document."
        case .unsupportedVersion(let version):
            return version == 2
                ? "Large Document Format (.psb) files aren’t supported — save as .psd."
                : "Unsupported PSD version \(version)."
        case .truncated(let detail):
            return "The Photoshop file is damaged or truncated (\(detail))."
        case .unsupportedLayout(let detail):
            return "This PSD can’t be opened as layers: \(detail)."
        case .renderFailed(let detail):
            return "Could not build layer pixels from the PSD (\(detail))."
        }
    }
}

/// Bounds-checked big-endian cursor over a `Data`. Every read throws rather
/// than trapping, so a corrupt file surfaces as an error sheet instead of a
/// crash.
struct PSDByteReader {
    let data: Data
    private(set) var offset: Int

    init(_ data: Data, offset: Int = 0) {
        self.data = data
        self.offset = offset
    }

    var remaining: Int { data.count - offset }
    var isAtEnd: Bool { remaining <= 0 }

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw PSDReadError.truncated("seek past end")
        }
        offset = newOffset
    }

    mutating func skip(_ count: Int) throws {
        try seek(to: offset + count)
    }

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, remaining >= count else {
            throw PSDReadError.truncated("wanted \(count) bytes, \(remaining) left")
        }
        let start = data.startIndex + offset
        defer { offset += count }
        return data[start..<(start + count)]
    }

    mutating func u8() throws -> UInt8 {
        guard remaining >= 1 else { throw PSDReadError.truncated("u8") }
        defer { offset += 1 }
        return data[data.startIndex + offset]
    }

    mutating func u16() throws -> UInt16 {
        let high = UInt16(try u8()), low = UInt16(try u8())
        return (high << 8) | low
    }

    mutating func u32() throws -> UInt32 {
        let high = UInt32(try u16()), low = UInt32(try u16())
        return (high << 16) | low
    }

    mutating func i16() throws -> Int16 { Int16(bitPattern: try u16()) }
    mutating func i32() throws -> Int32 { Int32(bitPattern: try u32()) }

    mutating func fourCC() throws -> String {
        String(bytes: try bytes(4), encoding: .isoLatin1) ?? "????"
    }

    /// Pascal string; `padTo` rounds the total consumed length (length byte
    /// included) up to a multiple, as the layer name does with 4.
    mutating func pascalString(padTo multiple: Int = 1) throws -> String {
        let length = Int(try u8())
        let raw = try bytes(length)
        var consumed = 1 + length
        while multiple > 1 && consumed % multiple != 0 {
            _ = try u8()
            consumed += 1
        }
        return String(bytes: raw, encoding: .utf8)
            ?? String(bytes: raw, encoding: .isoLatin1) ?? ""
    }

    /// Adobe's Unicode string: UTF-16BE unit count, then the units. A trailing
    /// NUL is dropped (Photoshop writes one in some blocks, not in others).
    mutating func unicodeString() throws -> String {
        let count = Int(try u32())
        guard count >= 0, count <= remaining / 2 else {
            throw PSDReadError.truncated("unicode string of \(count) units")
        }
        var units: [UInt16] = []
        units.reserveCapacity(count)
        for _ in 0..<count { units.append(try u16()) }
        if units.last == 0 { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }
}

enum PSDCompression: UInt16 {
    case raw = 0
    case rle = 1
    case zip = 2
    case zipWithPrediction = 3
}

enum PSDDecoder {
    /// PackBits, the RLE scheme PSD uses — and the one Photoshop actually
    /// writes, so this path matters far more than `raw`. `rowByteCounts` are
    /// the per-row compressed lengths from the table that precedes the data.
    static func unpackBits(_ data: Data, rowByteCounts: [Int],
                           bytesPerRow: Int) throws -> [UInt8] {
        var output = [UInt8]()
        // Callers bound `bytesPerRow`; reserving the product unchecked would
        // still trap on overflow, and reserving is only a hint, so a failed
        // multiply just means growing on demand.
        let (reservation, overflow) = bytesPerRow.multipliedReportingOverflow(
            by: rowByteCounts.count)
        if !overflow { output.reserveCapacity(reservation) }
        var reader = PSDByteReader(data)
        for rowLength in rowByteCounts {
            let row = try reader.bytes(rowLength)
            var decoded = [UInt8]()
            decoded.reserveCapacity(bytesPerRow)
            var index = row.startIndex
            while index < row.endIndex && decoded.count < bytesPerRow {
                let control = Int8(bitPattern: row[index])
                index += 1
                if control >= 0 {
                    let count = Int(control) + 1
                    guard index + count <= row.endIndex else {
                        throw PSDReadError.truncated("RLE literal run")
                    }
                    decoded.append(contentsOf: row[index..<(index + count)])
                    index += count
                } else if control != -128 {
                    let count = 1 - Int(control)
                    guard index < row.endIndex else {
                        throw PSDReadError.truncated("RLE repeat run")
                    }
                    decoded.append(contentsOf: repeatElement(row[index], count: count))
                    index += 1
                }
                // -128 is a no-op byte, per the PackBits definition.
            }
            // A short row means a damaged file; pad rather than lose the rest.
            if decoded.count < bytesPerRow {
                decoded.append(contentsOf: repeatElement(0, count: bytesPerRow - decoded.count))
            }
            output.append(contentsOf: decoded.prefix(bytesPerRow))
        }
        return output
    }

    /// ZIP channels (16- and 32-bit files). PSD stores a zlib stream; the
    /// Compression framework wants raw deflate, so the 2-byte zlib header
    /// comes off first and the trailing Adler-32 is simply ignored.
    static func inflate(_ data: Data, expectedSize: Int) -> [UInt8]? {
        guard data.count > 2, expectedSize > 0 else { return nil }
        let body = data.dropFirst(2)
        var output = [UInt8](repeating: 0, count: expectedSize)
        let written = body.withUnsafeBytes { (source: UnsafeRawBufferPointer) -> Int in
            guard let base = source.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return 0
            }
            return output.withUnsafeMutableBytes { (destination: UnsafeMutableRawBufferPointer) -> Int in
                guard let target = destination.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                    return 0
                }
                return compression_decode_buffer(target, expectedSize, base, body.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { return nil }
        return output
    }

    /// Undoes the per-row delta encoding of "ZIP with prediction" (16-bit
    /// only; 8-bit prediction is a byte-wise variant Photoshop doesn't emit
    /// for layer data, and 32-bit isn't supported here).
    static func undoPrediction16(_ bytes: inout [UInt8], width: Int, height: Int) {
        guard width > 1 else { return }
        let rowBytes = width * 2
        for row in 0..<height {
            let base = row * rowBytes
            guard base + rowBytes <= bytes.count else { return }
            var previous = (UInt16(bytes[base]) << 8) | UInt16(bytes[base + 1])
            for column in 1..<width {
                let index = base + column * 2
                let delta = (UInt16(bytes[index]) << 8) | UInt16(bytes[index + 1])
                let value = previous &+ delta
                bytes[index] = UInt8(value >> 8)
                bytes[index + 1] = UInt8(value & 0xFF)
                previous = value
            }
        }
    }
}

extension BlendMode {
    /// The inverse of `psdKey`. Unknown keys (Photoshop modes this app doesn't
    /// model — Divide, Subtract, Linear Burn, …) degrade to Normal, matching
    /// how the `.brushy` reader treats unrecognised tokens.
    init(psdKey: String) {
        let match = BlendMode.allCases.first { $0.psdKey == psdKey }
        self = match ?? .normal
    }

    /// Photoshop's group-only "Pass Through" key, which no layer mode uses.
    static let psdPassThroughKey = "pass"
}
