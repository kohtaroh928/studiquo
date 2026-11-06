import XCTest
import UIKit
import PDFKit
@testable import studiquo

/// Seeded fuzzing of the app's file and text parsers.
///
/// Without `STUDIQUO_FUZZ_DIR` this is a short smoke run (fixed seed, a few hundred cases).
/// A real campaign passes, through `TEST_RUNNER_`-prefixed variables:
///   STUDIQUO_FUZZ_SEED, STUDIQUO_FUZZ_CASES, STUDIQUO_FUZZ_START, STUDIQUO_FUZZ_BUDGET_SECONDS, STUDIQUO_FUZZ_DIR.
/// `scripts/app-file-fuzz` drives it and restarts after a crash from the journal.
final class AppFileFuzzTests: XCTestCase {
    private var seed: UInt64 { UInt64(FuzzEnv.int("STUDIQUO_FUZZ_SEED") ?? 20_261_105) }
    private var start: Int { FuzzEnv.int("STUDIQUO_FUZZ_START") ?? 0 }
    private func cases(smoke: Int) -> Int { FuzzEnv.int("STUDIQUO_FUZZ_CASES") ?? smoke }
    /// Seconds this invocation may run; the loop stops starting cases after it (the driver also kills a hung process).
    private var budgetSeconds: Double { Double(FuzzEnv.int("STUDIQUO_FUZZ_BUDGET_SECONDS") ?? 120) }

    // MARK: Loop

    @discardableResult
    private func campaign(_ target: String, smoke: Int, budget: FuzzRecorder.Budget,
                          make: (inout FuzzRNG, Int) -> Data,
                          exercise: (Data, Int, FuzzRecorder) -> Bool?) -> FuzzRecorder {
        let recorder = FuzzRecorder(target: target, seed: seed)
        let total = cases(smoke: smoke)
        var accepted = 0, rejected = 0, ran = 0
        let began = DispatchTime.now().uptimeNanoseconds
        let stopAt = DispatchTime.now() + .milliseconds(Int(budgetSeconds * 1000)) // fixed once: a computed property would move with every check
        var last = start - 1
        for index in start..<(start + total) {
            if DispatchTime.now() > stopAt { break }
            var rng = FuzzRNG(seed: seed, index: index, salt: UInt64(truncatingIfNeeded: target.hashValue &* 0) &+ UInt64(target.utf8.reduce(0) { $0 &* 31 &+ Int($1) }))
            let input = make(&rng, index)
            if FuzzEnv.string("STUDIQUO_FUZZ_DUMP_ONLY") != nil { // rebuild one case from its seed and index, without running the parser
                if let directory = FuzzEnv.directory {
                    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    try? input.write(to: directory.appendingPathComponent("dump-\(target)-\(seed)-\(index).bin"))
                }
                ran += 1; last = index; continue
            }
            let outcome = recorder.run(index: index, budget: budget, input: input) { exercise(input, index, recorder) }
            if let outcome { if outcome { accepted += 1 } else { rejected += 1 } }
            ran += 1; last = index
        }
        let seconds = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e9
        recorder.writeSummary(cases: ran, accepted: accepted, rejected: rejected, firstIndex: start, lastIndex: last, seconds: seconds)
        XCTAssertGreaterThan(ran, 0, "\(target): no case ran; an empty run is not a clean run")
        if FuzzEnv.directory == nil {
            // The plain test run (CI included) fails on a broken invariant, but not on time or memory: those budgets
            // were set for a quiet development machine, and a shared runner several times slower would fail a
            // healthy build. Slowness is judged by the regression tests (growth with input size) and by campaigns.
            let broken = recorder.findings.filter { $0.kind == "invariant" }
            XCTAssertTrue(broken.isEmpty, "\(target): \(broken)")
            let slow = recorder.findings.filter { $0.kind != "invariant" }
            if !slow.isEmpty { print("FUZZ-SMOKE \(target): \(slow.count) time/memory observations (not a failure in a plain run)") }
        }
        return recorder
    }

    // MARK: Corpus

    private static let documentXML = """
    <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
    <w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main"><w:body>
    <w:p><w:pPr><w:pStyle w:val="Heading1"/></w:pPr><w:r><w:t>見出し</w:t></w:r></w:p>
    <w:p><w:pPr><w:numPr><w:ilvl w:val="0"/><w:numId w:val="1"/></w:numPr></w:pPr><w:r><w:rPr><w:b/><w:i/></w:rPr><w:t>太字の項目</w:t></w:r></w:p>
    <w:tbl><w:tr><w:tc><w:p><w:r><w:t>A</w:t></w:r></w:p></w:tc><w:tc><w:p><w:r><w:t>B</w:t></w:r></w:p></w:tc></w:tr></w:tbl>
    <w:p><w:r><w:drawing/></w:r></w:p></w:body></w:document>
    """
    private static let numberingXML = """
    <?xml version="1.0" encoding="UTF-8"?><w:numbering xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">
    <w:abstractNum w:abstractNumId="0"><w:lvl w:ilvl="0"><w:numFmt w:val="decimal"/></w:lvl></w:abstractNum><w:num w:numId="1"><w:abstractNumId w:val="0"/></w:num></w:numbering>
    """
    private static let relsXML = """
    <?xml version="1.0" encoding="UTF-8"?><Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships"><Relationship Id="rId1" Type="x" Target="media/image1.png"/></Relationships>
    """

    private func docx(document: String? = nil) throws -> Data {
        try DocxZip.write([
            .init(path: "[Content_Types].xml", data: Data("<Types/>".utf8)),
            .init(path: "word/document.xml", data: Data((document ?? Self.documentXML).utf8)),
            .init(path: "word/numbering.xml", data: Data(Self.numberingXML.utf8)),
            .init(path: "word/_rels/document.xml.rels", data: Data(Self.relsXML.utf8)),
        ])
    }

    private func mutatedXML(_ rng: inout FuzzRNG) -> String {
        var xml = Self.documentXML
        switch rng.below(8) {
        case 0: // deep nesting
            let n = 1_000 + rng.below(rng.chance(5) ? 100_000 : 10_000)
            xml = xml.replacingOccurrences(of: "<w:body>", with: "<w:body>" + String(repeating: "<w:p>", count: n))
        case 1: // entity expansion and external entities must not be resolved
            let entities = (1...9).map { "<!ENTITY l\($0) \"" + String(repeating: "&l\($0 - 1);", count: 10) + "\">" }.joined()
            xml = "<?xml version=\"1.0\"?><!DOCTYPE w:document [<!ENTITY l0 \"lol\">\(entities)<!ENTITY xxe SYSTEM \"file:///etc/hosts\">]>" + xml.replacingOccurrences(of: "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>", with: "").replacingOccurrences(of: "<w:t>見出し</w:t>", with: "<w:t>&l9;&xxe;</w:t>")
        case 2: // huge attribute and text
            xml = xml.replacingOccurrences(of: "w:val=\"Heading1\"", with: "w:val=\"" + String(repeating: "h", count: 1 + rng.below(2_000_000)) + "\"")
        case 3:
            xml = xml.replacingOccurrences(of: "<w:t>A</w:t>", with: "<w:t>" + FuzzText.make(&rng).prefix(100_000) + "</w:t>")
        case 4: // many rows and cells
            let row = "<w:tr><w:tc><w:p/></w:tc></w:tr>"
            xml = xml.replacingOccurrences(of: "</w:tbl>", with: String(repeating: row, count: 1 + rng.below(50_000)) + "</w:tbl>")
        case 5: // numbering with absurd ids
            xml = xml.replacingOccurrences(of: "w:val=\"1\"", with: "w:val=\"\(rng.pick(["99999999999999999999", "-1", "0", "2147483648", "x"]))\"")
        default:
            var bytes = Array(xml.utf8); FuzzMutate.generic(&bytes, &rng); return String(decoding: bytes, as: UTF8.self)
        }
        return xml
    }

    // MARK: ZIP and DOCX

    /// The words of a read document: paragraph bodies and table cells. (A block's own description names only its type.)
    static func text(of blocks: [DocumentBlock]) -> String {
        blocks.map { block in
            if block.kind == .table {
                return (block.tableRows ?? []).flatMap { $0.cells ?? [] }.map(\.text).joined(separator: " ")
            }
            return DocumentBody.decode(block.bodyData).string
        }.joined(separator: "\n")
    }

    func testZip() throws {
        let valid = try docx()
        campaign("zip", smoke: 300, budget: .init(seconds: 4, megabytes: 450), make: { rng, _ in
            var bytes = Array(valid)
            if rng.chance(2) { FuzzMutate.zipFields(&bytes, &rng) } else { FuzzMutate.generic(&bytes, &rng) }
            return Data(bytes)
        }, exercise: { data, index, rec in
            do {
                let entries = try DocxZip.read(data)
                if entries.count > ImportLimits.maxZipEntries { rec.violation(index: index, "entry limit exceeded: \(entries.count)", input: data) }
                let total = entries.reduce(0) { $0 + $1.data.count }
                if total > ImportLimits.maxZipTotalUncompressedBytes { rec.violation(index: index, "inflated total limit exceeded: \(total)", input: data) }
                return true
            } catch { return false }
        })
    }

    func testDocx() throws {
        campaign("docx", smoke: 120, budget: .init(seconds: 8, megabytes: 450), make: { rng, _ in
            if rng.chance(3) {
                var bytes = Array((try? self.docx(document: self.mutatedXML(&rng))) ?? Data())
                if rng.chance(3) { FuzzMutate.zipFields(&bytes, &rng) }
                return Data(bytes)
            }
            var bytes = Array((try? self.docx(document: self.mutatedXML(&rng))) ?? Data())
            FuzzMutate.generic(&bytes, &rng)
            return Data(bytes)
        }, exercise: { data, index, rec in
            do {
                let result = try DocxReader.read(from: data)
                // External entities must never leak file contents into the document.
                let text = Self.text(of: result.blocks)
                if text.contains("localhost") && text.contains("127.0.0.1") { rec.violation(index: index, "external entity content (/etc/hosts) appeared in output", input: data) }
                return true
            } catch { return false }
        })
    }

    // MARK: Text, markup, math

    func testText() {
        campaign("text", smoke: 150, budget: .init(seconds: 6, megabytes: 300), make: { rng, _ in
            Data(FuzzText.make(&rng).utf8)
        }, exercise: { data, index, rec in
            let source = String(decoding: data, as: UTF8.self)
            let outputs: [(String, () -> Int)] = [
                ("RichTextParser.parse", { RichTextParser.parse(source).count }),
                ("MathSegmenter.segments", { MathSegmenter.segments(in: source).count }),
                ("readableText", { MathTextFormatter.readableText(from: source).count }),
                ("plainText", { MathTextFormatter.plainText(from: source).count }),
                ("readableMath", { MathTextFormatter.readableMath(from: source).count }),
                ("MathExpressionParser.parse", { _ = MathExpressionParser.parse(source); return 0 }),
            ]
            for (name, call) in outputs {
                let began = DispatchTime.now().uptimeNanoseconds
                _ = call()
                let ms = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
                if ms > 2_000 { // each function on its own, so the slow one is named
                    rec.record(FuzzFinding(target: "text", kind: "hang", seed: rec.seed, index: index, detail: "\(name) took \(Int(ms)) ms for \(data.count) bytes", milliseconds: ms, peakMB: 0), input: data)
                }
            }
            return true
        })
    }

    // MARK: Backup archive (JSON)

    func testBackupArchive() throws {
        let page = NotebookBackupService.PageArchive(
            drawingData: Data([1, 2, 3]), backgroundImageData: Data([4, 5]), width: 612, height: 792, template: "grid", bookmark: false,
            title: "p", paperColorHex: "#FFFFFF", recognizedText: "テキスト", backgroundPDFData: nil, flashcardQuestion: "q", flashcardAnswer: "a",
            flashcardMastery: 1, flashcardReviewCount: 2,
            elements: [.init(kind: "rectangle", text: "t", imageData: Data([9]), centerX: 1, centerY: 2, width: 3, height: 4, rotation: 0, colorHex: "#000000", isLocked: false, layerIndex: 0, lineWidth: 3)])
        let archive = NotebookBackupService.Archive(title: "nb", folderName: "f", tagsText: "a,b", createdAt: Date(timeIntervalSince1970: 0), pages: [page, page])
        let valid = try JSONEncoder().encode(archive)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-backup-\(ProcessInfo.processInfo.processIdentifier).json")
        defer { try? FileManager.default.removeItem(at: temp) }
        campaign("backup", smoke: 200, budget: .init(seconds: 8, megabytes: 700), make: { rng, _ in
            let json = String(decoding: valid, as: UTF8.self)
            switch rng.below(6) {
            case 0:
                let numbers = ["1e999", "-1", "0", "99999999999999999999", "4294967296", "0.0000000001", "null", "\"x\"", "[]", "{}", "NaN", "true"]
                return Data(FuzzMutate.textual(json, numbers: numbers, &rng).utf8)
            case 1:
                let n = 1_000 + rng.below(rng.chance(4) ? 400_000 : 20_000)
                return Data(("{\"title\":\"x\",\"pages\":" + String(repeating: "[", count: n) + String(repeating: "]", count: rng.chance(2) ? n : 0)).utf8)
            case 2: // many pages
                let copies = 1 + rng.below(rng.chance(6) ? 20_000 : 500)
                let one = String(decoding: (try? JSONEncoder().encode(page)) ?? Data(), as: UTF8.self)
                return Data("{\"title\":\"t\",\"folderName\":\"f\",\"tagsText\":\"\",\"pages\":[\(Array(repeating: one, count: copies).joined(separator: ","))]}".utf8)
            default:
                var bytes = Array(valid); FuzzMutate.generic(&bytes, &rng); return Data(bytes)
            }
        }, exercise: { data, index, rec in
            do { try data.write(to: temp) } catch { return nil }
            guard let notebook = NotebookBackupService.restore(from: temp) else { return false }
            if notebook.sortedPages.isEmpty { rec.violation(index: index, "restore returned a notebook with no pages", input: data) }
            return true
        })
    }

    // MARK: Images

    private func imageSeeds() -> [Data] {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30))
        let image = renderer.image { ctx in UIColor.red.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30)) }
        let types: [Data?] = [image.pngData(), image.jpegData(compressionQuality: 0.7), Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7")]
        return types.compactMap { $0 }
    }

    func testImages() {
        let seeds = imageSeeds()
        XCTAssertEqual(seeds.count, 3)
        campaign("image", smoke: 200, budget: .init(seconds: 8, megabytes: 500), make: { rng, _ in
            var bytes = Array(rng.pick(seeds))
            if rng.chance(2) { FuzzMutate.imageDimensions(&bytes, &rng) }
            if rng.chance(2) { FuzzMutate.generic(&bytes, &rng) }
            return Data(bytes)
        }, exercise: { data, _, _ in
            guard ImportLimits.checkImage(data: data) == nil else { return false }
            // The app decodes only what the header check let through; this is that decode.
            guard let image = UIImage(data: data) else { return false }
            let size = CGSize(width: min(image.size.width, 64), height: min(image.size.height, 64))
            _ = UIGraphicsImageRenderer(size: CGSize(width: max(size.width, 1), height: max(size.height, 1))).image { _ in image.draw(at: .zero) }
            return true
        })
    }

    // MARK: PDF

    private func pdfSeed() -> Data {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        return renderer.pdfData { ctx in
            for n in 1...3 {
                ctx.beginPage()
                ("ページ \(n) テキスト" as NSString).draw(at: CGPoint(x: 20, y: 20), withAttributes: [.font: UIFont.systemFont(ofSize: 14)])
            }
        }
    }

    func testPDF() {
        let seed = pdfSeed()
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("fuzz-\(ProcessInfo.processInfo.processIdentifier).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        campaign("pdf", smoke: 40, budget: .init(seconds: 20, megabytes: 900), make: { rng, _ in
            if rng.chance(2) {
                let latin = String(seed.map { Character(UnicodeScalar($0)) })
                var edited = FuzzMutate.textual(latin, numbers: ["0", "-1", "1", "999999", "2147483647", "4294967296", "1e9", "0.001"], &rng)
                if rng.chance(4) { edited = edited.replacingOccurrences(of: "/Kids [", with: "/Kids [1 0 R ") }
                var bytes = edited.unicodeScalars.map { UInt8(truncatingIfNeeded: $0.value) }
                if rng.chance(3) { FuzzMutate.generic(&bytes, &rng) }
                return Data(bytes)
            }
            var bytes = Array(seed); FuzzMutate.generic(&bytes, &rng); return Data(bytes)
        }, exercise: { data, _, _ in
            do { try data.write(to: temp) } catch { return nil }
            let extraction = PDFImportService.extractPagesChecked(from: temp, scale: 0.5)
            return !extraction.pages.isEmpty
        })
    }

    // MARK: The harness must be able to fail

    /// Defective parsers that exist only here. If an oracle does not fire on its canary, a clean campaign means nothing.
    func testCanaryHangAndMemoryAreDetected() throws {
        try XCTSkipUnless(FuzzEnv.string("STUDIQUO_FUZZ_CANARY") != nil || FuzzEnv.directory == nil)
        let recorder = FuzzRecorder(target: "canary", seed: 1)
        _ = recorder.run(index: 0, budget: .init(seconds: 0.05, megabytes: 10_000), input: Data()) { usleep(200_000); return true }
        XCTAssertEqual(recorder.findings.last?.kind, "hang", "hang oracle did not fire")
        _ = recorder.run(index: 1, budget: .init(seconds: 60, megabytes: 100), input: Data()) {
            var block = [UInt8](repeating: 1, count: 400_000_000)
            block[block.count - 1] = 2
            usleep(30_000)
            return block.last == 2
        }
        XCTAssertEqual(recorder.findings.last?.kind, "memory", "memory oracle did not fire")
        recorder.violation(index: 2, "returned a traversal path ../x", input: nil)
        XCTAssertEqual(recorder.findings.last?.kind, "invariant")
    }

    /// Run only by the driver, which expects the process to die at case 5 and the journal to name it.
    func testCanaryCrash() throws {
        try XCTSkipUnless(FuzzEnv.string("STUDIQUO_FUZZ_CANARY") == "crash")
        let recorder = FuzzRecorder(target: "canary-crash", seed: seed)
        for index in start..<(start + cases(smoke: 10)) {
            _ = recorder.run(index: index, budget: .init(seconds: 5, megabytes: 100), input: Data()) {
                let values: [Int] = []
                return index == 5 ? values[index] == 0 : true
            }
        }
        recorder.writeSummary(cases: cases(smoke: 10), accepted: cases(smoke: 10), rejected: 0, firstIndex: start, lastIndex: start + cases(smoke: 10) - 1, seconds: 0)
    }
}
