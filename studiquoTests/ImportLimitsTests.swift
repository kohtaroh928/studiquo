import XCTest
@testable import studiquo

final class ImportLimitsTests: XCTestCase {
    private var workDir: URL!

    override func setUp() {
        super.setUp()
        workDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try! FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: workDir)
        super.tearDown()
    }

    private func file(bytes: Int) -> URL {
        let url = workDir.appendingPathComponent(UUID().uuidString)
        try! Data(count: bytes).write(to: url)
        return url
    }

    func testFileAtTheLimitPassesAndOneByteOverIsRefused() {
        XCTAssertNil(ImportLimits.checkFileSize(of: file(bytes: 100), maxBytes: 100))
        XCTAssertEqual(ImportLimits.checkFileSize(of: file(bytes: 101), maxBytes: 100), .fileTooLarge(limitBytes: 100))
    }

    func testAnUnreadableFileIsNotRejectedHere() {
        XCTAssertNil(ImportLimits.fileSize(of: workDir.appendingPathComponent("missing")))
        XCTAssertNil(ImportLimits.checkFileSize(of: workDir.appendingPathComponent("missing"), maxBytes: 1))
    }

    func testImagePixelsAreCheckedWithoutOverflow() {
        XCTAssertNil(ImportLimits.checkImagePixels(width: 8_000, height: 8_000))
        XCTAssertEqual(ImportLimits.checkImagePixels(width: 60_000, height: 60_000), .imageTooLarge)
        XCTAssertEqual(ImportLimits.checkImagePixels(width: 4_000_000_000, height: 4_000_000_000), .imageTooLarge)
        XCTAssertNil(ImportLimits.checkImagePixels(width: 0, height: 100))
    }

    func testEveryRejectionHasAMessageThatSaysWhatToDo() {
        let all: [ImportLimits.Rejection] = [
            .fileTooLarge(limitBytes: 500_000_000), .tooManyPages(limit: 1_000), .imageTooLarge, .renderedPagesTooLarge, .archiveTooLarge,
        ]
        for rejection in all { XCTAssertFalse(rejection.message.isEmpty) }
        XCTAssertTrue(ImportLimits.Rejection.fileTooLarge(limitBytes: 500_000_000).message.contains("500 MB"))
        XCTAssertTrue(ImportLimits.Rejection.tooManyPages(limit: 1_000).message.contains("1000"))
    }

    /// A genuine PNG that is a few KB on disk and 9000×9000 pixels (81 MP) once
    /// decoded: 1-bit grayscale, all zeros, which deflates to almost nothing.
    /// This is the real shape of the attack; the pixel check must reject it from
    /// the header alone, before `UIImage(data:)` decodes anything.
    func testASmallPNGThatDeclaresEightyOneMegapixelsIsRejectedFromItsHeader() throws {
        let side: UInt32 = 9_000
        let be = { (v: UInt32) -> [UInt8] in [UInt8(v >> 24 & 255), UInt8(v >> 16 & 255), UInt8(v >> 8 & 255), UInt8(v & 255)] }
        func crc32(_ bytes: [UInt8]) -> UInt32 {
            var crc: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                crc ^= UInt32(byte)
                for _ in 0..<8 { crc = crc & 1 == 1 ? (crc >> 1) ^ 0xEDB8_8320 : crc >> 1 }
            }
            return crc ^ 0xFFFF_FFFF
        }
        func chunk(_ type: String, _ body: [UInt8]) -> [UInt8] {
            let payload = Array(type.utf8) + body
            return be(UInt32(body.count)) + payload + be(crc32(payload))
        }
        let rowBytes = 1 + Int((side + 7) / 8) // filter byte + packed 1-bit pixels
        let raw = Data(count: rowBytes * Int(side))
        let deflated = try (raw as NSData).compressed(using: .zlib) as Data // raw DEFLATE
        var a: UInt32 = 1, b: UInt32 = 0 // Adler-32 of all-zero data
        for _ in 0..<raw.count { b = (b + a) % 65_521 }
        let zlibStream = [0x78, 0x01] + [UInt8](deflated) + be((b << 16) | a)

        var png: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        png += chunk("IHDR", be(side) + be(side) + [1, 0, 0, 0, 0])
        png += chunk("IDAT", zlibStream)
        png += chunk("IEND", [])

        XCTAssertLessThan(png.count, 100_000, "the file itself must be small, or this is not the attack")
        let size = try XCTUnwrap(NoteImagePipeline.pixelSize(of: Data(png)))
        XCTAssertEqual(size.width, 9_000)
        XCTAssertEqual(ImportLimits.checkImagePixels(width: size.width, height: size.height), .imageTooLarge)
    }

    func testCheckImageFailsClosedOnBytesImageIOCannotRead() {
        XCTAssertEqual(ImportLimits.checkImage(data: Data("not an image".utf8)), .imageUnreadable)
        XCTAssertEqual(ImportLimits.checkImage(data: Data()), .imageUnreadable)
    }

    func testCheckImageAcceptsAnOrdinaryPhotoSizedImage() throws {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
        XCTAssertNil(ImportLimits.checkImage(data: renderer.pngData { $0.fill(CGRect(x: 0, y: 0, width: 64, height: 64)) }))
    }

    /// Frames count: a GIF with many frames is decoded whole by `UIImage(data:)`.
    func testCheckImageCountsEveryFrameOfAnAnimation() throws {
        let side = 2_000 // 4 MP per frame, 40 frames = 160 MP, past the 128 MP total
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "com.compuserve.gif" as CFString, 40, nil))
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: { let f = UIGraphicsImageRendererFormat(); f.scale = 1; return f }())
        let frame = try XCTUnwrap(renderer.image { $0.fill(CGRect(x: 0, y: 0, width: side, height: side)) }.cgImage)
        for _ in 0..<40 { CGImageDestinationAddImage(destination, frame, nil) }
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        XCTAssertEqual(ImportLimits.checkImage(data: data as Data), .imageTooLarge)
    }

    func testTheRenderBudgetStaysInsideTheBackupLimit() {
        // JSON + base64 makes a backup about 4/3 the size of its images.
        XCTAssertLessThan(Int64(Double(ImportLimits.maxRenderedPDFBytes) * 4 / 3), ImportLimits.maxBackupFileBytes)
    }
}
