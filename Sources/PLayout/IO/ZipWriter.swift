import Foundation
import Compression

/// Minimal ZIP container writer. An .xlsx file is just a zip of XML parts, so this
/// keeps the app dependency-free rather than pulling in a compression package.
enum ZipWriter {
    struct Entry {
        let path: String
        let data: Data
    }

    static func archive(entries: [Entry], modified: Date = Date()) -> Data {
        var output = Data()
        var central = Data()
        let (dosTime, dosDate) = dosTimestamp(modified)

        for entry in entries {
            let nameBytes = Array(entry.path.utf8)
            let crc = crc32(entry.data)
            let uncompressedSize = UInt32(entry.data.count)

            var method: UInt16 = 0
            var payload = entry.data
            if let deflated = deflate(entry.data), deflated.count < entry.data.count {
                method = 8
                payload = deflated
            }
            let compressedSize = UInt32(payload.count)
            let localOffset = UInt32(output.count)

            output.appendUInt32(0x0403_4B50)
            output.appendUInt16(20)              // version needed
            output.appendUInt16(0)               // general purpose flags
            output.appendUInt16(method)
            output.appendUInt16(dosTime)
            output.appendUInt16(dosDate)
            output.appendUInt32(crc)
            output.appendUInt32(compressedSize)
            output.appendUInt32(uncompressedSize)
            output.appendUInt16(UInt16(nameBytes.count))
            output.appendUInt16(0)               // extra field length
            output.append(contentsOf: nameBytes)
            output.append(payload)

            central.appendUInt32(0x0201_4B50)
            central.appendUInt16(20)             // version made by
            central.appendUInt16(20)             // version needed
            central.appendUInt16(0)
            central.appendUInt16(method)
            central.appendUInt16(dosTime)
            central.appendUInt16(dosDate)
            central.appendUInt32(crc)
            central.appendUInt32(compressedSize)
            central.appendUInt32(uncompressedSize)
            central.appendUInt16(UInt16(nameBytes.count))
            central.appendUInt16(0)              // extra
            central.appendUInt16(0)              // comment
            central.appendUInt16(0)              // disk number
            central.appendUInt16(0)              // internal attributes
            central.appendUInt32(0)              // external attributes
            central.appendUInt32(localOffset)
            central.append(contentsOf: nameBytes)
        }

        let centralOffset = UInt32(output.count)
        output.append(central)
        output.appendUInt32(0x0605_4B50)
        output.appendUInt16(0)                   // this disk
        output.appendUInt16(0)                   // disk with central directory
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt16(UInt16(entries.count))
        output.appendUInt32(UInt32(central.count))
        output.appendUInt32(centralOffset)
        output.appendUInt16(0)                   // comment length
        return output
    }

    /// Apple's COMPRESSION_ZLIB emits a raw DEFLATE stream, which is what ZIP method 8 wants.
    private static func deflate(_ input: Data) -> Data? {
        guard !input.isEmpty else { return nil }
        let capacity = input.count + 4096
        var destination = Data(count: capacity)
        let written = destination.withUnsafeMutableBytes { dst -> Int in
            guard let dstBase = dst.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return input.withUnsafeBytes { src -> Int in
                guard let srcBase = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(dstBase, capacity, srcBase, input.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        destination.removeSubrange(written..<capacity)
        return destination
    }

    private static let crcTable: [UInt32] = {
        (0..<256).map { i -> UInt32 in
            var c = UInt32(i)
            for _ in 0..<8 {
                c = (c & 1) == 1 ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
            }
            return c
        }
    }()

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFF_FFFF
        for byte in data {
            c = crcTable[Int((c ^ UInt32(byte)) & 0xFF)] ^ (c >> 8)
        }
        return c ^ 0xFFFF_FFFF
    }

    private static func dosTimestamp(_ date: Date) -> (time: UInt16, date: UInt16) {
        let parts = Calendar(identifier: .gregorian).dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        let year = max(1980, parts.year ?? 1980)
        let time = UInt16(((parts.hour ?? 0) << 11) | ((parts.minute ?? 0) << 5) | ((parts.second ?? 0) / 2))
        let day = UInt16(((year - 1980) << 9) | ((parts.month ?? 1) << 5) | (parts.day ?? 1))
        return (time, day)
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
