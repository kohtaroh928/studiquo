import Foundation

/// Optional display provenance. It neither authorizes access nor changes navigation.
/// Ranges refer to the stored chunk within an element, not the visible excerpt;
/// bounding boxes refer to the whole original element, never a precise quote.
struct RAGCitationMetadata: Codable, Equatable {
    struct Parser: Codable, Equatable { let name: String; let version: String; let profile: String }
    struct BoundingBox: Codable, Equatable {
        let l: Double; let t: Double; let r: Double; let b: Double
        let coordOrigin: String?
        var hasKnownOrigin: Bool { coordOrigin == "TOPLEFT" || coordOrigin == "BOTTOMLEFT" }
    }
    struct Provenance: Codable, Equatable {
        let pageNumber: Int
        let bbox: BoundingBox?
        let charspan: [Int]?
        private enum CodingKeys: String, CodingKey { case pageNumber, bbox, charspan }
        func encode(to encoder: Encoder) throws {
            var values = encoder.container(keyedBy: CodingKeys.self)
            try values.encode(pageNumber, forKey: .pageNumber)
            try values.encode(bbox, forKey: .bbox) // Required wire key: preserve explicit null.
            try values.encodeIfPresent(charspan, forKey: .charspan)
        }
    }
    struct Segment: Codable, Equatable {
        let chunkId: String
        let elementId: String
        let kind: String
        let rangeScope: String
        let start: Int
        let end: Int
        let offsetUnit: String
        let provenance: [Provenance]
        let provenanceTruncated: Bool
    }
    let version: Int
    let documentNamespace: String
    let parser: Parser
    let provenanceScope: String
    let segments: [Segment]

    private enum Invalid: Error { case metadata }
    private static let kinds: Set<String> = ["text", "paragraph", "title", "section_header", "list_item", "footnote", "caption", "table", "formula"]
    private static func hex(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
    private static func reference(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 512 && value.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_/#:.-").contains($0)
        }
    }
    func isValid(pageNumber: Int, chunkId: String) -> Bool {
        (1...10_000).contains(pageNumber) && segments.contains { $0.chunkId == chunkId } &&
        segments.allSatisfy { segment in segment.provenance.allSatisfy { $0.pageNumber == pageNumber } }
    }

    init(from decoder: Decoder) throws {
        let root = try Wire.read(decoder, budget: Budget(), depth: 0)
        let object = try root.object(required: ["version", "documentNamespace", "parser", "provenanceScope", "segments"])
        guard try object["version"]!.integer() == 1,
              try object["provenanceScope"]!.string() == "element" else { throw Invalid.metadata }
        version = 1
        provenanceScope = "element"
        documentNamespace = try object["documentNamespace"]!.string()
        guard Self.hex(documentNamespace) else { throw Invalid.metadata }
        let provider = try object["parser"]!.object(required: ["name", "version", "profile"])
        let name = try provider["name"]!.string(), release = try provider["version"]!.string(), profile = try provider["profile"]!.string()
        guard [name, release, profile].allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else { throw Invalid.metadata }
        parser = Parser(name: name, version: release, profile: profile)
        let values = try object["segments"]!.array()
        guard (1...3).contains(values.count) else { throw Invalid.metadata }
        var identifiers = Set<String>()
        segments = try values.map { value in
            let row = try value.object(required: ["chunkId", "elementId", "kind", "rangeScope", "start", "end", "offsetUnit", "provenance", "provenanceTruncated"])
            let chunkId = try row["chunkId"]!.string(), elementId = try row["elementId"]!.string(), kind = try row["kind"]!.string()
            let start = try row["start"]!.integer(), end = try row["end"]!.integer()
            guard Self.hex(chunkId), identifiers.insert(chunkId).inserted, Self.reference(elementId), Self.kinds.contains(kind),
                  try row["rangeScope"]!.string() == "stored_chunk_not_excerpt",
                  try row["offsetUnit"]!.string() == "unicode_codepoint",
                  start >= 0, end > start, end <= 8_000_000 else { throw Invalid.metadata }
            let positions = try row["provenance"]!.array()
            guard (1...4).contains(positions.count) else { throw Invalid.metadata }
            let provenance = try positions.map { raw -> Provenance in
                let position = try raw.object(required: ["pageNumber", "bbox"], optional: ["charspan"])
                let page = try position["pageNumber"]!.integer()
                guard (1...10_000).contains(page) else { throw Invalid.metadata }
                var bounds: BoundingBox?
                if case .null = position["bbox"]! { bounds = nil }
                else {
                    let box = try position["bbox"]!.object(required: ["l", "t", "r", "b"], optional: ["coordOrigin"])
                    let l = try box["l"]!.number(), t = try box["t"]!.number(), r = try box["r"]!.number(), b = try box["b"]!.number()
                    guard [l, t, r, b].allSatisfy({ $0.isFinite && abs($0) <= 1e9 }) else { throw Invalid.metadata }
                    let origin = try box["coordOrigin"].map { try $0.string() }
                    guard origin.map({ $0.utf8.count <= 128 }) ?? true else { throw Invalid.metadata }
                    bounds = BoundingBox(l: l, t: t, r: r, b: b, coordOrigin: origin)
                }
                var span: [Int]?
                if let rawSpan = position["charspan"], case .null = rawSpan { span = nil }
                else if let rawSpan = position["charspan"] {
                    let values = try rawSpan.array().map { try $0.integer() }
                    guard values.count == 2, values[0] >= 0, values[1] >= values[0], values[1] <= 8_000_000 else { throw Invalid.metadata }
                    span = values
                }
                return Provenance(pageNumber: page, bbox: bounds, charspan: span)
            }
            return Segment(chunkId: chunkId, elementId: elementId, kind: kind, rangeScope: "stored_chunk_not_excerpt", start: start, end: end,
                           offsetUnit: "unicode_codepoint", provenance: provenance, provenanceTruncated: try row["provenanceTruncated"]!.boolean())
        }
        guard try JSONEncoder().encode(self).count <= 8192 else { throw Invalid.metadata }
    }

    private final class Budget { var nodes = 0; var bytes = 0 }
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }
    private indirect enum Wire {
        case objectValue([String: Wire]), arrayValue([Wire]), stringValue(String), integerValue(Int), numberValue(Double), boolValue(Bool), null
        static func read(_ decoder: Decoder, budget: Budget, depth: Int) throws -> Wire {
            budget.nodes += 1
            guard budget.nodes <= 512, depth <= 8 else { throw Invalid.metadata }
            if let object = try? decoder.container(keyedBy: Key.self) {
                guard object.allKeys.count <= 16 else { throw Invalid.metadata }
                var result: [String: Wire] = [:]
                for key in object.allKeys {
                    guard key.stringValue.utf8.count <= 64 else { throw Invalid.metadata }
                    budget.bytes += key.stringValue.utf8.count
                    result[key.stringValue] = try read(object.superDecoder(forKey: key), budget: budget, depth: depth + 1)
                }
                guard budget.bytes <= 8192 else { throw Invalid.metadata }
                return .objectValue(result)
            }
            if var array = try? decoder.unkeyedContainer() {
                guard array.count.map({ $0 <= 4 }) ?? true else { throw Invalid.metadata }
                var result: [Wire] = []
                while !array.isAtEnd {
                    guard result.count < 4 else { throw Invalid.metadata }
                    result.append(try read(array.superDecoder(), budget: budget, depth: depth + 1))
                }
                return .arrayValue(result)
            }
            let scalar = try decoder.singleValueContainer()
            if scalar.decodeNil() { return .null }
            if let bool = try? scalar.decode(Bool.self) { return .boolValue(bool) }
            if let text = try? scalar.decode(String.self) {
                guard text.utf8.count <= 512 else { throw Invalid.metadata }
                budget.bytes += text.utf8.count
                guard budget.bytes <= 8192 else { throw Invalid.metadata }
                return .stringValue(text)
            }
            if let integer = try? scalar.decode(Int.self) { return .integerValue(integer) }
            if let number = try? scalar.decode(Double.self), number.isFinite { return .numberValue(number) }
            throw Invalid.metadata
        }
        func object(required: Set<String>, optional: Set<String> = []) throws -> [String: Wire] {
            guard case .objectValue(let value) = self,
                  required.isSubset(of: Set(value.keys)), Set(value.keys).isSubset(of: required.union(optional)) else { throw Invalid.metadata }
            return value
        }
        func array() throws -> [Wire] { guard case .arrayValue(let value) = self else { throw Invalid.metadata }; return value }
        func string() throws -> String { guard case .stringValue(let value) = self else { throw Invalid.metadata }; return value }
        func integer() throws -> Int { guard case .integerValue(let value) = self else { throw Invalid.metadata }; return value }
        func number() throws -> Double {
            switch self { case .numberValue(let value): return value; case .integerValue(let value): return Double(value); default: throw Invalid.metadata }
        }
        func boolean() throws -> Bool { guard case .boolValue(let value) = self else { throw Invalid.metadata }; return value }
    }
}
