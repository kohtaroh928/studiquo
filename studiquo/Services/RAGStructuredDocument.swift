import Foundation
import CryptoKit
import CoreFoundation

/// A validated, PDF-bound developer-prepared document. This type neither uploads nor associates a notebook.
struct RAGStructuredDocument {
    struct Page: Codable, Equatable { let pageNumber: Int; let text: String }
    enum ValidationError: Error { case invalidPreparedDocument }
    let pages: [Page]
    let documentNamespace: String
    let pdfSHA256: String
    let sourceHash: String
    private let preparedBatches: [[String: Any]]
    var batches: [[String: Any]] { preparedBatches }
    var manifestData: Data { get throws { try Self.json(["version": 1, "integration": "prepared_only_no_upload", "batches": preparedBatches]) } }

    init(manifestData: Data, originalPDFData: Data) throws {
        guard !originalPDFData.isEmpty, originalPDFData.count <= 100 * 1024 * 1024,
              originalPDFData.starts(with: Data("%PDF-".utf8)) else { throw ValidationError.invalidPreparedDocument }
        try self.init(manifestData: manifestData, expectedPDFSHA256: Self.digest(originalPDFData))
    }

    /// Revalidates previously imported data against a retained fingerprint. A supplied hash alone does not prove PDF ownership or authenticity.
    init(manifestData: Data, expectedPDFSHA256: String) throws {
        guard manifestData.count <= 32 * 1024 * 1024 else { throw ValidationError.invalidPreparedDocument }
        let pdfHash = try Self.hex(expectedPDFSHA256)
        try Self.uniqueJSONKeys(manifestData)
        let root = try Self.object(JSONSerialization.jsonObject(with: manifestData), ["version", "integration", "batches"])
        try Self.equalInt(root["version"], 1)
        try Self.equal(root["integration"], "prepared_only_no_upload")
        let input = try Self.array(root["batches"], 1...1000)
        var allPages: [Page] = [], output: [[String: Any]] = []
        var common: [String: Any]?, expectedTotal: Int?, identities = Set<String>()
        for raw in input {
            let batch = try Self.object(raw, ["structure", "totalPages", "pages"])
            guard try Self.json(batch).count <= 240 * 1024 else { throw ValidationError.invalidPreparedDocument }
            let structure = try Self.object(batch["structure"], ["version", "document", "documentNamespace"])
            try Self.equalInt(structure["version"], 1)
            let document = try Self.validateDocument(structure["document"])
            let namespace = try Self.hex(structure["documentNamespace"])
            guard try Self.hex(document["pdfSha256"]) == pdfHash,
                  Self.digest(try Self.json(["parser": document["parser"]!, "pdfSha256": pdfHash])) == namespace else { throw ValidationError.invalidPreparedDocument }
            if let common { guard try Self.json(common) == Self.json(structure) else { throw ValidationError.invalidPreparedDocument } }
            else { common = structure }
            let total = try Self.integer(batch["totalPages"], 1...1000)
            if let expectedTotal { guard total == expectedTotal else { throw ValidationError.invalidPreparedDocument } }
            else { expectedTotal = total }
            for rawPage in try Self.array(batch["pages"], 1...5) {
                let page = try Self.object(rawPage, ["pageNumber", "text", "structured"])
                let number = try Self.integer(page["pageNumber"], 1...total)
                guard number == allPages.count + 1 else { throw ValidationError.invalidPreparedDocument }
                let text = try Self.string(page["text"], 1...100000)
                let structured = try Self.object(page["structured"], ["version", "records"])
                try Self.equalInt(structured["version"], 1)
                for rawRow in try Self.array(structured["records"], 1...100) {
                    let row = try Self.object(rawRow, ["text", "metadata"])
                    let body = try Self.string(row["text"], 1...6000)
                    guard Self.hasNonWhitespace(body), text.range(of: body) != nil, try Self.workerTokenCount(body) <= 500 else { throw ValidationError.invalidPreparedDocument }
                    let metadata = try Self.validateRecord(row["metadata"], page: number, namespace: namespace, body: body)
                    let identity = try Self.reference(metadata["localId"])
                    guard identities.insert(identity).inserted,
                          try Self.json(["version": 1, "documentNamespace": namespace, "document": document, "record": metadata]).count <= 16384 else { throw ValidationError.invalidPreparedDocument }
                }
                allPages.append(Page(pageNumber: number, text: text))
            }
            output.append(batch)
        }
        guard let common, allPages.count == expectedTotal else { throw ValidationError.invalidPreparedDocument }
        pages = allPages
        documentNamespace = try Self.hex(common["documentNamespace"])
        pdfSHA256 = pdfHash
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        sourceHash = Self.digest(try encoder.encode(allPages))
        preparedBatches = output
    }

    private static func validateDocument(_ raw: Any?) throws -> [String: Any] {
        let d = try object(raw, ["parser", "pdfSha256", "strategy", "semanticApplied", "semanticModel", "maxEstimatedTokens", "maxOverlapEstimatedTokens", "semanticDistanceThreshold", "semanticFallbackReason", "namespaceScope", "offsetUnit", "provenanceScope"])
        let p = try object(d["parser"], ["name", "version", "profile"])
        for key in ["name", "version", "profile"] { _ = try string(p[key], 1...128) }
        _ = try hex(d["pdfSha256"])
        try equal(d["strategy"], "structure-semantic-recursive-v1")
        try equal(d["namespaceScope"], "document_parser_only_not_authentication")
        try equal(d["offsetUnit"], "unicode_codepoint"); try equal(d["provenanceScope"], "element")
        let applied = try boolean(d["semanticApplied"])
        let model = d["semanticModel"] is NSNull ? nil : try string(d["semanticModel"], 1...128)
        if let model { guard hasNonWhitespace(model) else { throw ValidationError.invalidPreparedDocument } }
        let reason = d["semanticFallbackReason"] is NSNull ? nil : try choice(d["semanticFallbackReason"], ["no_vectors", "not_needed"])
        guard applied ? model != nil && reason == nil : reason != nil else { throw ValidationError.invalidPreparedDocument }
        let maximum = try integer(d["maxEstimatedTokens"], 1...400)
        guard try integer(d["maxOverlapEstimatedTokens"], 0...65) < maximum else { throw ValidationError.invalidPreparedDocument }
        _ = try number(d["semanticDistanceThreshold"], 0...2)
        return d
    }

    private static func validateRecord(_ raw: Any?, page: Int, namespace: String, body: String) throws -> [String: Any] {
        let m = try object(raw, ["documentNamespace", "kind", "elementId", "localId", "idSource", "pageNumbers", "provenanceScope", "provenance", "coordinateState", "headingPath", "contextRefs", "review", "source"], optional: ["tableStructureSha256"])
        guard try hex(m["documentNamespace"]) == namespace else { throw ValidationError.invalidPreparedDocument }
        _ = try choice(m["kind"], ["text", "paragraph", "title", "section_header", "list_item", "footnote", "caption", "table", "formula"])
        _ = try reference(m["elementId"]); _ = try reference(m["localId"])
        _ = try choice(m["idSource"], ["docling_self_ref", "synthetic_unknown", "unknown"])
        let numbers = try array(m["pageNumbers"], 1...1); try equalInt(numbers[0], page)
        try equal(m["provenanceScope"], "element")
        var known = true
        for rawP in try array(m["provenance"], 1...16) {
            let p = try object(rawP, ["pageNumber", "bbox"], optional: ["charspan"])
            try equalInt(p["pageNumber"], page)
            if p["bbox"] is NSNull { known = false }
            else {
                let box = try object(p["bbox"], ["l", "t", "r", "b"], optional: ["coordOrigin"])
                for key in ["l", "t", "r", "b"] { _ = try number(box[key], -1e9...1e9) }
                if let origin = box["coordOrigin"] {
                    let value = try string(origin, 0...128)
                    if !["TOPLEFT", "BOTTOMLEFT"].contains(value) { known = false }
                } else { known = false }
            }
            if let span = p["charspan"], !(span is NSNull) {
                let values = try array(span, 2...2)
                guard try integer(values[0], 0...8000000) <= integer(values[1], 0...8000000) else { throw ValidationError.invalidPreparedDocument }
            }
        }
        try equal(m["coordinateState"], known ? "known" : "unknown")
        let heading = try object(m["headingPath"], ["state", "reason", "items"])
        let state = try choice(heading["state"], ["explicit", "partial", "unknown"])
        let reason = try choice(heading["reason"], ["complete", "cycle", "missing_parent", "ancestry_limit", "no_explicit_heading"])
        let items = try array(heading["items"], 0...16)
        var titles: [String] = []
        for rawH in items {
            let h = try object(rawH, ["elementId", "text", "level"])
            _ = try reference(h["elementId"]); titles.append(try string(h["text"], 0...300))
            if !(h["level"] is NSNull) { _ = try integer(h["level"], 1...100) }
        }
        guard titles.joined(separator: " / ").utf16.count <= 1000,
              !(state == "unknown" && !items.isEmpty),
              !(state == "explicit" && (items.isEmpty || reason != "complete")),
              !(state == "partial" && (items.isEmpty || reason == "complete")) else { throw ValidationError.invalidPreparedDocument }
        for rawRef in try array(m["contextRefs"], 0...32) {
            let r = try object(rawRef, ["role", "elementId", "resolved"])
            _ = try choice(r["role"], ["parent", "child", "caption"]); _ = try reference(r["elementId"]); _ = try boolean(r["resolved"])
        }
        let review = try object(m["review"], ["needsReview", "needsOCR", "reviewRequired", "oversized"])
        for value in review.values { guard try boolean(value) == false else { throw ValidationError.invalidPreparedDocument } }
        let source = try object(m["source"], ["start", "end", "offsetUnit", "textSha256"])
        let start = try integer(source["start"], 0...8000000), end = try integer(source["end"], 0...8000000)
        try equal(source["offsetUnit"], "unicode_codepoint")
        guard end > start, end - start == body.unicodeScalars.count, try hex(source["textSha256"]) == digest(Data(body.utf8)) else { throw ValidationError.invalidPreparedDocument }
        if let table = m["tableStructureSha256"] { _ = try hex(table) }
        guard try json(m).count <= 16384 else { throw ValidationError.invalidPreparedDocument }
        return m
    }

    private static func object(_ raw: Any?, _ required: Set<String>, optional: Set<String> = []) throws -> [String: Any] {
        guard let value = raw as? [String: Any], required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)) else { throw ValidationError.invalidPreparedDocument }; return value
    }
    private static func array(_ raw: Any?, _ bounds: ClosedRange<Int>) throws -> [Any] {
        guard let value = raw as? [Any], bounds.contains(value.count) else { throw ValidationError.invalidPreparedDocument }; return value
    }
    private static func string(_ raw: Any?, _ bounds: ClosedRange<Int>) throws -> String {
        guard let value = raw as? String, bounds.contains(value.utf16.count) else { throw ValidationError.invalidPreparedDocument }; return value
    }
    private static func boolean(_ raw: Any?) throws -> Bool {
        guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else { throw ValidationError.invalidPreparedDocument }; return value.boolValue
    }
    private static func number(_ raw: Any?, _ bounds: ClosedRange<Double>) throws -> Double {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(), value.doubleValue.isFinite, bounds.contains(value.doubleValue) else { throw ValidationError.invalidPreparedDocument }; return value.doubleValue
    }
    private static func integer(_ raw: Any?, _ bounds: ClosedRange<Int>) throws -> Int {
        let value = try number(raw, Double(bounds.lowerBound)...Double(bounds.upperBound))
        guard value.rounded() == value else { throw ValidationError.invalidPreparedDocument }; return Int(value)
    }
    private static func equalInt(_ raw: Any?, _ expected: Int) throws { guard try integer(raw, expected...expected) == expected else { throw ValidationError.invalidPreparedDocument } }
    private static func equal(_ raw: Any?, _ expected: String) throws { guard try string(raw, 0...max(128, expected.utf16.count)) == expected else { throw ValidationError.invalidPreparedDocument } }
    private static func choice(_ raw: Any?, _ values: Set<String>) throws -> String { let value = try string(raw, 0...128); guard values.contains(value) else { throw ValidationError.invalidPreparedDocument }; return value }
    private static func hex(_ raw: Any?) throws -> String { let value = try string(raw, 64...64); guard value.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil else { throw ValidationError.invalidPreparedDocument }; return value }
    private static func reference(_ raw: Any?) throws -> String { let value = try string(raw, 1...512); guard value.range(of: "^[A-Za-z0-9_/#:.\\-]+$", options: .regularExpression) != nil else { throw ValidationError.invalidPreparedDocument }; return value }
    private static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private static func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]) }
    // Explicit ECMAScript whitespace differs from ICU's \\s (e.g. U+0085).
    private static let whitespace = "\\u0009-\\u000d\\u0020\\u00a0\\u1680\\u2000-\\u200a\\u2028\\u2029\\u202f\\u205f\\u3000\\ufeff"
    private static func hasNonWhitespace(_ text: String) -> Bool { text.range(of: "[^" + whitespace + "]", options: .regularExpression) != nil }
    static func workerTokenCount(_ text: String) throws -> Int {
        let pattern = "[\\p{script=Han}\\p{script=Hiragana}\\p{script=Katakana}]|[\\p{L}\\p{N}]+|[^\\p{L}\\p{N}" + whitespace + "]|[" + whitespace + "]+"
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reduce(0) { count, match in
            let value = (text as NSString).substring(with: match.range)
            return count + (hasNonWhitespace(value) ? 1 : 0)
        }
    }

    /// Reject duplicate object keys before JSONSerialization can silently keep the last one.
    private static func uniqueJSONKeys(_ data: Data) throws {
        let bytes = Array(data)
        struct Container { var object: Bool; var expectsKey: Bool; var keys = Set<String>() }
        var stack: [Container] = [], index = 0, tokens = 0
        while index < bytes.count {
            if [UInt8(34), 44, 58, 91, 93, 123, 125].contains(bytes[index]) { tokens += 1 }
            guard stack.count <= 64, tokens <= 300_000 else { throw ValidationError.invalidPreparedDocument }
            switch bytes[index] {
            case 123: stack.append(Container(object: true, expectsKey: true)); index += 1
            case 91: stack.append(Container(object: false, expectsKey: false)); index += 1
            case 125, 93: guard !stack.isEmpty else { throw ValidationError.invalidPreparedDocument }; stack.removeLast(); index += 1
            case 44: if !stack.isEmpty && stack[stack.count - 1].object { stack[stack.count - 1].expectsKey = true }; index += 1
            case 34:
                let start = index; index += 1
                while index < bytes.count {
                    if bytes[index] == 92 { index += 2; continue }
                    if bytes[index] == 34 { break }; index += 1
                }
                guard index < bytes.count else { throw ValidationError.invalidPreparedDocument }; index += 1
                if !stack.isEmpty && stack[stack.count - 1].object && stack[stack.count - 1].expectsKey {
                    guard let key = try JSONSerialization.jsonObject(with: Data(bytes[start..<index]), options: [.fragmentsAllowed]) as? String,
                          stack[stack.count - 1].keys.insert(key).inserted else { throw ValidationError.invalidPreparedDocument }
                    stack[stack.count - 1].expectsKey = false
                }
            default: index += 1
            }
        }
        guard stack.isEmpty else { throw ValidationError.invalidPreparedDocument }
    }
}
