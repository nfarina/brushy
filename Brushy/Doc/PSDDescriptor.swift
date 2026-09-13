import Foundation

/// Adobe's descriptor format — the self-describing key/value tree Photoshop
/// uses for anything richer than a fixed struct. Layer effects (`lfx2`) are
/// stored as one, which is why this exists; the encoder and decoder are
/// symmetric so a style can survive a round trip through Photoshop.
///
/// Layout (Photoshop File Format spec, "Descriptor structure"): a Unicode
/// name, a class ID, an item count, then that many (key, OSType, value)
/// triples. Keys and class IDs share one encoding: a 4-byte length where 0
/// means "a four-character code follows", anything else means a string of
/// that many bytes.
indirect enum PSDDescriptorValue: Equatable {
    case descriptor(PSDDescriptor)
    case list([PSDDescriptorValue])
    case double(Double)
    /// A number carrying Adobe's unit tag: `#Prc` percent, `#Pxl` pixels,
    /// `#Ang` degrees, `#Nne` none.
    case unitFloat(unit: String, value: Double)
    case text(String)
    case enumerated(type: String, value: String)
    case integer(Int32)
    case largeInteger(Int64)
    case boolean(Bool)
    case classReference(name: String, classID: String)
    case rawData(Data)

    var doubleValue: Double? {
        switch self {
        case .double(let value): return value
        case .unitFloat(_, let value): return value
        case .integer(let value): return Double(value)
        case .largeInteger(let value): return Double(value)
        default: return nil
        }
    }

    var unit: String? {
        if case .unitFloat(let unit, _) = self { return unit }
        return nil
    }

    var boolValue: Bool? {
        if case .boolean(let value) = self { return value }
        return nil
    }

    var enumValue: String? {
        if case .enumerated(_, let value) = self { return value }
        return nil
    }

    var descriptorValue: PSDDescriptor? {
        if case .descriptor(let descriptor) = self { return descriptor }
        return nil
    }

    var listValue: [PSDDescriptorValue]? {
        if case .list(let values) = self { return values }
        return nil
    }
}

struct PSDDescriptor: Equatable {
    var name: String = ""
    var classID: String = "null"
    /// Ordered, because Photoshop writes a conventional order and matching it
    /// keeps round-tripped files diff-clean.
    var items: [(key: String, value: PSDDescriptorValue)] = []

    subscript(key: String) -> PSDDescriptorValue? {
        get { items.first(where: { $0.key == key })?.value }
        set {
            guard let newValue else {
                items.removeAll { $0.key == key }
                return
            }
            if let index = items.firstIndex(where: { $0.key == key }) {
                items[index].value = newValue
            } else {
                items.append((key, newValue))
            }
        }
    }

    static func == (lhs: PSDDescriptor, rhs: PSDDescriptor) -> Bool {
        lhs.name == rhs.name && lhs.classID == rhs.classID
            && lhs.items.count == rhs.items.count
            && zip(lhs.items, rhs.items).allSatisfy { $0.key == $1.key && $0.value == $1.value }
    }
}

// MARK: - Decoding

extension PSDDescriptor {
    /// How deep `Objc`/`VlLs` nesting may go before the file is rejected.
    /// Photoshop's own styles nest a handful of levels; 64 is far above
    /// anything real and far below what the stack can take.
    ///
    /// This bound is load-bearing, not defensive tidiness: descriptors and
    /// their values are mutually recursive, each nesting level costs only
    /// ~28 bytes in the file, and a stack overflow is a hard crash that no
    /// `try?` upstream can catch (`PSDReader.parseExtra` reads `lfx2`
    /// through exactly such a `try?`). Without the cap a ~1 MB effects block
    /// takes the process down.
    static let maxNestingDepth = 64

    /// Reads a descriptor body (everything after the version words a
    /// containing block may carry).
    init(reading reader: inout PSDByteReader, depth: Int = 0) throws {
        guard depth < Self.maxNestingDepth else {
            throw PSDReadError.unsupportedLayout(
                "descriptor nested deeper than \(Self.maxNestingDepth) levels")
        }
        name = try reader.unicodeString()
        classID = try Self.keyOrClassID(&reader)
        let count = Int(try reader.u32())
        guard count >= 0, count < 4096 else {
            throw PSDReadError.truncated("descriptor with \(count) items")
        }
        for _ in 0..<count {
            let key = try Self.keyOrClassID(&reader)
            let value = try PSDDescriptorValue(reading: &reader, depth: depth + 1)
            items.append((key, value))
        }
    }

    /// A 4-byte length, then either a four-character code (length 0) or a
    /// string of that length.
    static func keyOrClassID(_ reader: inout PSDByteReader) throws -> String {
        let length = Int(try reader.u32())
        if length == 0 { return try reader.fourCC() }
        guard length > 0, length <= reader.remaining else {
            throw PSDReadError.truncated("descriptor key of \(length) bytes")
        }
        return String(bytes: try reader.bytes(length), encoding: .isoLatin1) ?? ""
    }
}

extension PSDDescriptorValue {
    /// `depth` is the nesting level of the descriptor this value belongs to;
    /// see `PSDDescriptor.maxNestingDepth` for why it is carried at all.
    init(reading reader: inout PSDByteReader, depth: Int = 0) throws {
        guard depth < PSDDescriptor.maxNestingDepth else {
            throw PSDReadError.unsupportedLayout(
                "descriptor nested deeper than \(PSDDescriptor.maxNestingDepth) levels")
        }
        let osType = try reader.fourCC()
        switch osType {
        case "Objc", "GlbO":
            self = .descriptor(try PSDDescriptor(reading: &reader, depth: depth + 1))
        case "VlLs":
            let count = Int(try reader.u32())
            guard count >= 0, count < 65536 else {
                throw PSDReadError.truncated("descriptor list of \(count)")
            }
            var values: [PSDDescriptorValue] = []
            values.reserveCapacity(count)
            // A list does not open a new descriptor scope, but it IS a
            // recursion step: `VlLs` containing `VlLs` nests just as deep.
            for _ in 0..<count {
                values.append(try PSDDescriptorValue(reading: &reader, depth: depth + 1))
            }
            self = .list(values)
        case "doub":
            self = .double(try Self.readDouble(&reader))
        case "UntF":
            let unit = try reader.fourCC()
            self = .unitFloat(unit: unit, value: try Self.readDouble(&reader))
        case "TEXT":
            self = .text(try reader.unicodeString())
        case "enum":
            let type = try PSDDescriptor.keyOrClassID(&reader)
            let value = try PSDDescriptor.keyOrClassID(&reader)
            self = .enumerated(type: type, value: value)
        case "long":
            self = .integer(try reader.i32())
        case "comp":
            let high = Int64(try reader.u32()), low = Int64(try reader.u32())
            self = .largeInteger((high << 32) | low)
        case "bool":
            self = .boolean(try reader.u8() != 0)
        case "type", "GlbC":
            let name = try reader.unicodeString()
            self = .classReference(name: name, classID: try PSDDescriptor.keyOrClassID(&reader))
        case "tdta":
            let length = Int(try reader.u32())
            self = .rawData(try reader.bytes(length))
        case "alis":
            let length = Int(try reader.u32())
            self = .rawData(try reader.bytes(length))
        default:
            // 'obj ' references and any future type: there is no length to
            // skip by, so the rest of this descriptor is unreadable.
            throw PSDReadError.unsupportedLayout("descriptor OSType '\(osType)'")
        }
    }

    private static func readDouble(_ reader: inout PSDByteReader) throws -> Double {
        var bits: UInt64 = 0
        for _ in 0..<8 { bits = (bits << 8) | UInt64(try reader.u8()) }
        return Double(bitPattern: bits)
    }
}

// MARK: - Encoding

extension PSDDescriptor {
    /// The descriptor body, ready to sit behind whatever version words the
    /// containing block requires.
    func encoded() -> Data {
        var out = Data()
        out.appendUnicodeString(name)
        out.appendKeyOrClassID(classID)
        out.appendU32(UInt32(items.count))
        for item in items {
            out.appendKeyOrClassID(item.key)
            out.append(item.value.encoded())
        }
        return out
    }
}

extension PSDDescriptorValue {
    func encoded() -> Data {
        var out = Data()
        switch self {
        case .descriptor(let descriptor):
            out.appendFourCC("Objc")
            out.append(descriptor.encoded())
        case .list(let values):
            out.appendFourCC("VlLs")
            out.appendU32(UInt32(values.count))
            for value in values { out.append(value.encoded()) }
        case .double(let value):
            out.appendFourCC("doub")
            out.appendDouble(value)
        case .unitFloat(let unit, let value):
            out.appendFourCC("UntF")
            out.appendFourCC(unit)
            out.appendDouble(value)
        case .text(let string):
            out.appendFourCC("TEXT")
            out.appendUnicodeString(string)
        case .enumerated(let type, let value):
            out.appendFourCC("enum")
            out.appendKeyOrClassID(type)
            out.appendKeyOrClassID(value)
        case .integer(let value):
            out.appendFourCC("long")
            out.appendI32(value)
        case .largeInteger(let value):
            out.appendFourCC("comp")
            out.appendU32(UInt32(truncatingIfNeeded: value >> 32))
            out.appendU32(UInt32(truncatingIfNeeded: value))
        case .boolean(let value):
            out.appendFourCC("bool")
            out.appendU8(value ? 1 : 0)
        case .classReference(let name, let classID):
            out.appendFourCC("type")
            out.appendUnicodeString(name)
            out.appendKeyOrClassID(classID)
        case .rawData(let data):
            out.appendFourCC("tdta")
            out.appendU32(UInt32(data.count))
            out.append(data)
        }
        return out
    }
}

extension Data {
    /// Four-character codes go length-free; anything else is length-prefixed.
    mutating func appendKeyOrClassID(_ value: String) {
        let bytes = Array(value.utf8)
        if bytes.count == 4 {
            appendU32(0)
            append(contentsOf: bytes)
        } else {
            appendU32(UInt32(bytes.count))
            append(contentsOf: bytes)
        }
    }

    /// UTF-16BE unit count then units, with the trailing NUL Photoshop writes.
    mutating func appendUnicodeString(_ value: String) {
        let units = Array(value.utf16)
        appendU32(UInt32(units.count + 1))
        for unit in units { appendU16(unit) }
        appendU16(0)
    }

    mutating func appendDouble(_ value: Double) {
        let bits = value.bitPattern
        for shift in stride(from: 56, through: 0, by: -8) {
            append(UInt8((bits >> UInt64(shift)) & 0xFF))
        }
    }
}
