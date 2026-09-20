import Foundation
import Compression

/// A minimal ZIP reader/writer — just enough to read and write the entries
/// inside a `.docx` file (a handful of small XML parts plus media). Not a
/// general-purpose ZIP library: no multi-disk archives, no ZIP64, no
/// encryption. `.docx` files in practice don't use any of those.
///
/// Chosen over adding a third-party ZIP package (e.g. ZIPFoundation, the
/// original design's plan) specifically to avoid hand-editing this Xcode
/// project's Swift Package Manager references in `project.pbxproj`. This
/// project has no `PBXFileSystemSynchronizedRootGroup`, so every new file
/// (handled one at a time, by hand, throughout this whole document feature)
/// and every *package* reference needs its own manual pbxproj surgery — a
/// wrong edit to the package-resolution graph risks breaking the whole
/// project's build, not just one file. A self-contained ZIP implementation
/// is a smaller, more contained risk, at the cost of being narrower than a
/// real ZIP library.
enum DocxZip {
    struct Entry {
        let path: String
        let data: Data
    }

    enum ZipError: Error {
        case notAZipFile
        case corruptEntry(String)
        case decompressionFailed(String)
        case compressionFailed(String)
    }

    // MARK: Reading

    static func read(_ data: Data) throws -> [Entry] {
        let bytes = [UInt8](data)
        guard let eocdOffset = findEndOfCentralDirectory(bytes) else {
            throw ZipError.notAZipFile
        }
        // EOCD: sig(4) diskNum(2) cdDisk(2) diskEntries(2) totalEntries(2) cdSize(4) cdOffset(4) commentLen(2)
        guard eocdOffset + 22 <= bytes.count else { throw ZipError.notAZipFile }
        let totalEntries = Int(readUInt16(bytes, eocdOffset + 10))
        let centralDirOffset = Int(readUInt32(bytes, eocdOffset + 16))

        var entries: [Entry] = []
        var cursor = centralDirOffset
        for _ in 0..<totalEntries {
            guard cursor + 46 <= bytes.count, readUInt32(bytes, cursor) == 0x0201_4b50 else {
                throw ZipError.corruptEntry("central directory entry")
            }
            let compressionMethod = readUInt16(bytes, cursor + 10)
            let compressedSize = Int(readUInt32(bytes, cursor + 20))
            let uncompressedSize = Int(readUInt32(bytes, cursor + 24))
            let nameLength = Int(readUInt16(bytes, cursor + 28))
            let extraLength = Int(readUInt16(bytes, cursor + 30))
            let commentLength = Int(readUInt16(bytes, cursor + 32))
            let localHeaderOffset = Int(readUInt32(bytes, cursor + 42))
            guard cursor + 46 + nameLength <= bytes.count else { throw ZipError.corruptEntry("name") }
            let name = String(decoding: bytes[(cursor + 46)..<(cursor + 46 + nameLength)], as: UTF8.self)

            // Directory entries (path ends in "/") carry no useful data.
            if !name.hasSuffix("/") {
                let entryData = try readLocalEntry(
                    bytes, at: localHeaderOffset,
                    compressionMethod: compressionMethod,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize
                )
                entries.append(Entry(path: name, data: entryData))
            }

            cursor += 46 + nameLength + extraLength + commentLength
        }
        return entries
    }

    private static func readLocalEntry(_ bytes: [UInt8], at offset: Int, compressionMethod: UInt16, compressedSize: Int, uncompressedSize: Int) throws -> Data {
        guard offset + 30 <= bytes.count, readUInt32(bytes, offset) == 0x0403_4b50 else {
            throw ZipError.corruptEntry("local file header")
        }
        let nameLength = Int(readUInt16(bytes, offset + 26))
        let extraLength = Int(readUInt16(bytes, offset + 28))
        let dataStart = offset + 30 + nameLength + extraLength
        guard dataStart + compressedSize <= bytes.count else { throw ZipError.corruptEntry("data") }
        let compressed = Data(bytes[dataStart..<(dataStart + compressedSize)])

        switch compressionMethod {
        case 0:
            return compressed
        case 8:
            return try inflate(compressed, expectedSize: uncompressedSize)
        default:
            throw ZipError.decompressionFailed("unsupported compression method \(compressionMethod)")
        }
    }

    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) -> Int? {
        guard bytes.count >= 22 else { return nil }
        // The EOCD's comment field (up to 65535 bytes) can push it earlier
        // than the very end of the file, so search backward across that
        // whole possible range rather than assuming it's the last 22 bytes.
        let searchFloor = max(0, bytes.count - 22 - 65536)
        var i = bytes.count - 22
        while i >= searchFloor {
            if readUInt32(bytes, i) == 0x0605_4b50 { return i }
            i -= 1
        }
        return nil
    }

    // MARK: Writing

    static func write(_ entries: [Entry]) throws -> Data {
        var output = Data()
        struct WrittenEntry {
            let name: String
            let crc: UInt32
            let compressedSize: Int
            let uncompressedSize: Int
            let offset: Int
            let method: UInt16
        }
        var written: [WrittenEntry] = []

        for entry in entries {
            let nameData = Data(entry.path.utf8)
            let crc = crc32(entry.data)
            // Falls back to storing uncompressed if deflate somehow doesn't
            // shrink this particular entry (or fails) — either is a valid
            // ZIP entry, so this never blocks writing the archive.
            let (method, payload): (UInt16, Data) = {
                if let compressed = try? deflate(entry.data), compressed.count < entry.data.count {
                    return (8, compressed)
                }
                return (0, entry.data)
            }()

            let offset = output.count
            output.append(contentsOf: uint32Bytes(0x0403_4b50))
            output.append(contentsOf: uint16Bytes(20)) // version needed
            output.append(contentsOf: uint16Bytes(0)) // flags
            output.append(contentsOf: uint16Bytes(method))
            output.append(contentsOf: uint16Bytes(0)) // mod time
            output.append(contentsOf: uint16Bytes(0)) // mod date
            output.append(contentsOf: uint32Bytes(crc))
            output.append(contentsOf: uint32Bytes(UInt32(payload.count)))
            output.append(contentsOf: uint32Bytes(UInt32(entry.data.count)))
            output.append(contentsOf: uint16Bytes(UInt16(nameData.count)))
            output.append(contentsOf: uint16Bytes(0)) // extra field length
            output.append(nameData)
            output.append(payload)

            written.append(WrittenEntry(
                name: entry.path, crc: crc, compressedSize: payload.count,
                uncompressedSize: entry.data.count, offset: offset, method: method
            ))
        }

        let centralDirStart = output.count
        for entry in written {
            let nameData = Data(entry.name.utf8)
            output.append(contentsOf: uint32Bytes(0x0201_4b50))
            output.append(contentsOf: uint16Bytes(20)) // version made by
            output.append(contentsOf: uint16Bytes(20)) // version needed
            output.append(contentsOf: uint16Bytes(0)) // flags
            output.append(contentsOf: uint16Bytes(entry.method))
            output.append(contentsOf: uint16Bytes(0)) // mod time
            output.append(contentsOf: uint16Bytes(0)) // mod date
            output.append(contentsOf: uint32Bytes(entry.crc))
            output.append(contentsOf: uint32Bytes(UInt32(entry.compressedSize)))
            output.append(contentsOf: uint32Bytes(UInt32(entry.uncompressedSize)))
            output.append(contentsOf: uint16Bytes(UInt16(nameData.count)))
            output.append(contentsOf: uint16Bytes(0)) // extra field length
            output.append(contentsOf: uint16Bytes(0)) // comment length
            output.append(contentsOf: uint16Bytes(0)) // disk number
            output.append(contentsOf: uint16Bytes(0)) // internal attrs
            output.append(contentsOf: uint32Bytes(0)) // external attrs
            output.append(contentsOf: uint32Bytes(UInt32(entry.offset)))
            output.append(nameData)
        }
        let centralDirSize = output.count - centralDirStart

        output.append(contentsOf: uint32Bytes(0x0605_4b50))
        output.append(contentsOf: uint16Bytes(0)) // disk number
        output.append(contentsOf: uint16Bytes(0)) // central dir disk
        output.append(contentsOf: uint16Bytes(UInt16(written.count)))
        output.append(contentsOf: uint16Bytes(UInt16(written.count)))
        output.append(contentsOf: uint32Bytes(UInt32(centralDirSize)))
        output.append(contentsOf: uint32Bytes(UInt32(centralDirStart)))
        output.append(contentsOf: uint16Bytes(0)) // comment length

        return output
    }

    // MARK: Little-endian byte helpers

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }

    private static func uint16Bytes(_ value: UInt16) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    private static func uint32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 24) & 0xFF)]
    }

    // MARK: Compression (raw DEFLATE, RFC 1951 — what ZIP's method 8 stores,
    // no zlib or gzip wrapper — via Apple's Compression framework)

    /// The largest single entry this reader will attempt to decompress.
    /// `expectedSize` below comes straight from the archive's own header —
    /// nothing checks it against the entry's actual compressed size, so a
    /// crafted `.docx` can declare an absurd uncompressed size (a "zip
    /// bomb") backed by only a few real bytes of compressed data, and crash
    /// the app on `Data(count: expectedSize)` before decompression even
    /// starts. 100MB is far past any real document this app produces or
    /// reasonably expects to import — including ones with several embedded
    /// images — while still refusing an attacker-declared multi-gigabyte
    /// allocation outright.
    static let maxEntryUncompressedSize = 100_000_000

    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize > 0 else { return Data() }
        guard expectedSize <= maxEntryUncompressedSize else {
            throw ZipError.decompressionFailed("declared uncompressed size (\(expectedSize) bytes) exceeds the \(maxEntryUncompressedSize)-byte limit")
        }
        var output = Data(count: expectedSize)
        let resultSize = output.withUnsafeMutableBytes { outputPtr -> Int in
            data.withUnsafeBytes { inputPtr -> Int in
                compression_decode_buffer(
                    outputPtr.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                    inputPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard resultSize == expectedSize else {
            throw ZipError.decompressionFailed("expected \(expectedSize) bytes, got \(resultSize)")
        }
        return output
    }

    static func deflate(_ data: Data) throws -> Data {
        guard !data.isEmpty else { return Data() }
        let destinationCapacity = data.count + (data.count / 2) + 64
        var output = Data(count: destinationCapacity)
        let resultSize = output.withUnsafeMutableBytes { outputPtr -> Int in
            data.withUnsafeBytes { inputPtr -> Int in
                compression_encode_buffer(
                    outputPtr.bindMemory(to: UInt8.self).baseAddress!, destinationCapacity,
                    inputPtr.bindMemory(to: UInt8.self).baseAddress!, data.count,
                    nil, COMPRESSION_ZLIB
                )
            }
        }
        guard resultSize > 0 else { throw ZipError.compressionFailed("compression_encode_buffer returned 0") }
        return output.prefix(resultSize)
    }

    // MARK: CRC-32 (required in both the local and central-directory headers)

    private static let crcTable: [UInt32] = (0...255).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 {
            c = (c & 1 != 0) ? (0xEDB8_8320 ^ (c >> 1)) : (c >> 1)
        }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}
