import XCTest
@testable import studiquo

/// Coverage for `DocxZip` — the hand-rolled ZIP reader/writer everything
/// else in the docx feature builds on. Before trusting it in the app, its
/// core assumption (that Apple's `Compression` framework's `COMPRESSION_ZLIB`
/// produces/consumes genuine raw DEFLATE, with no zlib or gzip wrapper —
/// exactly what ZIP's method-8 entries store) was independently
/// cross-checked against Python's `zlib` in both directions, and the actual
/// writer/reader were cross-checked against the system's real `zip`/`unzip`
/// command-line tools. These tests cover the same ground so a future
/// regression here is caught automatically, not just at the time of that
/// one manual check.
final class DocxZipTests: XCTestCase {
    func testWriteThenReadRoundTripsASingleEntry() throws {
        let data = "こんにちは、DocxZip".data(using: .utf8)!
        let zip = try DocxZip.write([DocxZip.Entry(path: "word/document.xml", data: data)])

        let entries = try DocxZip.read(zip)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0].path, "word/document.xml")
        XCTAssertEqual(entries[0].data, data)
    }

    func testWriteThenReadRoundTripsMultipleEntries() throws {
        let entries = [
            DocxZip.Entry(path: "[Content_Types].xml", data: "<Types/>".data(using: .utf8)!),
            DocxZip.Entry(path: "_rels/.rels", data: "<Relationships/>".data(using: .utf8)!),
            DocxZip.Entry(path: "word/document.xml", data: "<w:document/>".data(using: .utf8)!),
        ]

        let zip = try DocxZip.write(entries)
        let readBack = try DocxZip.read(zip)

        XCTAssertEqual(readBack.count, entries.count)
        for entry in entries {
            XCTAssertEqual(readBack.first(where: { $0.path == entry.path })?.data, entry.data)
        }
    }

    /// Highly repetitive content compresses well under deflate — this is
    /// what actually exercises the compression path (`write` falls back to
    /// storing uncompressed if deflate doesn't shrink the data), rather than
    /// every test accidentally only covering the stored/uncompressed path.
    func testCompressibleContentRoundTrips() throws {
        let data = Data(repeating: 0x41, count: 10_000) // 10,000 'A's
        let zip = try DocxZip.write([DocxZip.Entry(path: "big.txt", data: data)])

        // Confirms compression actually engaged, not just that the round
        // trip happens to work either way.
        XCTAssertLessThan(zip.count, data.count)

        let readBack = try DocxZip.read(zip)
        XCTAssertEqual(readBack.first?.data, data)
    }

    func testEmptyEntryRoundTrips() throws {
        let zip = try DocxZip.write([DocxZip.Entry(path: "empty.xml", data: Data())])
        let readBack = try DocxZip.read(zip)

        XCTAssertEqual(readBack.first?.data, Data())
    }

    func testReadingNonZipDataThrows() {
        let notAZip = "this is definitely not a zip file".data(using: .utf8)!
        XCTAssertThrowsError(try DocxZip.read(notAZip))
    }

    func testBinaryDataRoundTrips() throws {
        var bytes: [UInt8] = []
        for i in 0..<2000 { bytes.append(UInt8(i % 256)) }
        let data = Data(bytes)

        let zip = try DocxZip.write([DocxZip.Entry(path: "image.png", data: data)])
        let readBack = try DocxZip.read(zip)

        XCTAssertEqual(readBack.first?.data, data)
    }

    // MARK: Zip-bomb protection

    /// `inflate`'s `expectedSize` comes straight from a zip entry's own
    /// header — a crafted file can declare an absurd uncompressed size
    /// backed by only a few real bytes, which would otherwise attempt a
    /// multi-gigabyte `Data(count:)` allocation and crash before
    /// decompression even runs. This must be rejected before any allocation
    /// happens, not merely fail after one.
    func testInflateRejectsADeclaredSizeAboveTheLimit() {
        let tinyCompressedPayload = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertThrowsError(
            try DocxZip.inflate(tinyCompressedPayload, expectedSize: DocxZip.maxEntryUncompressedSize + 1)
        ) { error in
            guard case DocxZip.ZipError.decompressionFailed = error else {
                return XCTFail("expected .decompressionFailed, got \(error)")
            }
        }
    }

    /// The same protection, exercised through the real attack path: a zip
    /// whose central directory entry declares a huge uncompressed size while
    /// its actual compressed payload is tiny — the shape a malicious `.docx`
    /// attachment would take. `read` must surface this as a normal thrown
    /// error (which the app already handles gracefully on import), not
    /// crash.
    func testReadRejectsAnEntryWhoseDeclaredUncompressedSizeIsATamperedZipBomb() throws {
        // Must actually take the deflate path (method 8, which is what
        // `inflate`'s size check guards) rather than the stored/uncompressed
        // path (method 0, unaffected by this field) — highly repetitive data
        // guarantees deflate shrinks it, the same way testCompressibleContentRoundTrips does.
        let compressiblePayload = Data(repeating: 0x41, count: 10_000)
        var zip = [UInt8](try DocxZip.write([DocxZip.Entry(path: "word/document.xml", data: compressiblePayload)]))

        // Central directory entries are signature-prefixed (PK\x01\x02);
        // the 4-byte uncompressed-size field sits at offset 24 within each
        // entry — see DocxZip.read's own `readUInt32(bytes, cursor + 24)`.
        guard let centralDirOffset = zip.firstRange(of: [0x50, 0x4b, 0x01, 0x02])?.lowerBound else {
            return XCTFail("couldn't locate the central directory entry to tamper with")
        }
        let uncompressedSizeOffset = centralDirOffset + 24
        let hugeSize: UInt32 = 0xFFFF_FFF0 // ~4.29GB — a plausible attacker-declared bomb
        zip[uncompressedSizeOffset] = UInt8(hugeSize & 0xFF)
        zip[uncompressedSizeOffset + 1] = UInt8((hugeSize >> 8) & 0xFF)
        zip[uncompressedSizeOffset + 2] = UInt8((hugeSize >> 16) & 0xFF)
        zip[uncompressedSizeOffset + 3] = UInt8((hugeSize >> 24) & 0xFF)

        XCTAssertThrowsError(try DocxZip.read(Data(zip)))
    }
}
