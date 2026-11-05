import Foundation
import Darwin

/// Deterministic generator. The same seed and case index always give the same input,
/// so a crash found by a run can be rebuilt from two numbers instead of being stored.
struct FuzzRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64, index: Int, salt: UInt64 = 0) {
        state = seed &* 0x9E37_79B9_7F4A_7C15 ^ (UInt64(truncatingIfNeeded: index) &+ 1) &* 0xD6E8_FEB8_6659_FD93 ^ salt
        _ = next()
    }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func below(_ n: Int) -> Int { n <= 1 ? 0 : Int(next() % UInt64(n)) }
    mutating func chance(_ oneIn: Int) -> Bool { below(oneIn) == 0 }
    mutating func pick<T>(_ items: [T]) -> T { items[below(items.count)] }
}

enum FuzzEnv {
    static func string(_ key: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[key], !value.isEmpty else { return nil }
        return value
    }
    static func int(_ key: String) -> Int? { string(key).flatMap(Int.init) }
    /// Where journals, findings and summaries go. Unset means a quick smoke run that writes nowhere.
    static var directory: URL? { string("STUDIQUO_FUZZ_DIR").map { URL(fileURLWithPath: $0, isDirectory: true) } }
}

/// Process memory the way the system's jetsam counts it.
func currentFootprintBytes() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

/// Samples the footprint on its own thread, because a parser that allocates and frees
/// inside one call is invisible to a before/after reading.
final class FootprintSampler {
    private let lock = NSLock()
    private var peak: UInt64 = 0
    private var running = true
    private var thread: Thread?

    init() {
        let t = Thread { [weak self] in
            while let self, self.isRunning {
                self.record(currentFootprintBytes())
                usleep(2_000)
            }
        }
        t.qualityOfService = .userInteractive
        thread = t
        t.start()
    }
    private var isRunning: Bool { lock.lock(); defer { lock.unlock() }; return running }
    private func record(_ value: UInt64) { lock.lock(); peak = max(peak, value); lock.unlock() }
    func reset() { lock.lock(); peak = currentFootprintBytes(); lock.unlock() }
    var peakBytes: UInt64 { lock.lock(); defer { lock.unlock() }; return max(peak, currentFootprintBytes()) }
    func stop() { lock.lock(); running = false; lock.unlock() }
}

// MARK: Mutators

enum FuzzMutate {
    static let magic32: [UInt32] = [0, 1, 0xFF, 0xFFFF, 0x7FFF_FFFF, 0x8000_0000, 0xFFFF_FFFF, 0x0001_0000, 0x00FF_FFFF, 0x0400_0000, 0x0605_4B50, 0x0403_4B50, 0x0201_4B50]

    static func generic(_ bytes: inout [UInt8], _ rng: inout FuzzRNG) {
        for _ in 0..<(1 + rng.below(4)) {
            switch rng.below(9) {
            case 0 where !bytes.isEmpty:
                for _ in 0..<(1 + rng.below(8)) { bytes[rng.below(bytes.count)] ^= UInt8(1 << rng.below(8)) }
            case 1 where !bytes.isEmpty:
                bytes[rng.below(bytes.count)] = UInt8(truncatingIfNeeded: rng.next())
            case 2 where bytes.count > 2:
                let start = rng.below(bytes.count), length = min(bytes.count - start, 1 + rng.below(64))
                bytes.removeSubrange(start..<(start + length))
            case 3:
                let at = rng.below(bytes.count + 1)
                bytes.insert(contentsOf: (0..<(1 + rng.below(32))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, at: at)
            case 4 where bytes.count > 2:
                let start = rng.below(bytes.count), length = min(bytes.count - start, 1 + rng.below(256))
                let chunk = Array(bytes[start..<(start + length)])
                bytes.insert(contentsOf: chunk, at: rng.below(bytes.count + 1))
            case 5 where bytes.count > 1:
                bytes.removeLast(1 + rng.below(min(bytes.count - 1, 512)))
            case 6, 7 where bytes.count >= 4:
                let at = rng.below(bytes.count - 3)
                let value = rng.pick(magic32)
                for k in 0..<4 { bytes[at + k] = UInt8(truncatingIfNeeded: value >> UInt32(8 * k)) }
            default:
                if bytes.count > 8, rng.chance(3) { bytes.removeFirst(1 + rng.below(8)) }
            }
        }
    }

    private static func put16(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        guard at >= 0, at + 2 <= bytes.count else { return }
        bytes[at] = UInt8(truncatingIfNeeded: value); bytes[at + 1] = UInt8(truncatingIfNeeded: value >> 8)
    }
    private static func put32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        guard at >= 0, at + 4 <= bytes.count else { return }
        for k in 0..<4 { bytes[at + k] = UInt8(truncatingIfNeeded: value >> UInt32(8 * k)) }
    }

    /// Rewrites header fields of a ZIP: sizes, offsets, name lengths, entry counts, methods.
    static func zipFields(_ bytes: inout [UInt8], _ rng: inout FuzzRNG) {
        var sigs: [(Int, UInt32)] = []
        if bytes.count >= 4 {
            for i in 0...(bytes.count - 4) {
                let v = UInt32(bytes[i]) | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 3]) << 24
                if v == 0x0403_4B50 || v == 0x0201_4B50 || v == 0x0605_4B50 { sigs.append((i, v)) }
            }
        }
        guard !sigs.isEmpty else { return generic(&bytes, &rng) }
        for _ in 0..<(1 + rng.below(3)) {
            let (at, sig) = rng.pick(sigs)
            let value = rng.pick(magic32)
            switch sig {
            case 0x0201_4B50:
                switch rng.below(7) {
                case 0: put16(&bytes, at + 10, value)
                case 1: put32(&bytes, at + 20, value)
                case 2: put32(&bytes, at + 24, value)
                case 3: put16(&bytes, at + 28, value)
                case 4: put16(&bytes, at + 30, value)
                case 5: put16(&bytes, at + 32, value)
                default: put32(&bytes, at + 42, value)
                }
            case 0x0403_4B50:
                switch rng.below(4) {
                case 0: put32(&bytes, at + 18, value)
                case 1: put32(&bytes, at + 22, value)
                case 2: put16(&bytes, at + 26, value)
                default: put16(&bytes, at + 28, value)
                }
            default:
                switch rng.below(5) {
                case 0: put16(&bytes, at + 8, value)
                case 1: put16(&bytes, at + 10, value)
                case 2: put32(&bytes, at + 12, value)
                case 3: put32(&bytes, at + 16, value)
                default: put16(&bytes, at + 20, value)
                }
            }
        }
    }

    /// Declared width/height of PNG, JPEG and GIF headers: huge values, zero, and mismatches.
    static func imageDimensions(_ bytes: inout [UInt8], _ rng: inout FuzzRNG) {
        let big: [UInt32] = [0, 1, 65_535, 100_000, 8_000_000, 0x7FFF_FFFF, 0xFFFF_FFFF]
        if bytes.count > 24, bytes[1] == 0x50 { // PNG
            for offset in [16, 20] where rng.chance(2) { putBE32(&bytes, offset, rng.pick(big)) }
        } else if bytes.count > 10, bytes[0] == 0x47 { // GIF
            for offset in [6, 8] where rng.chance(2) { put16(&bytes, offset, rng.pick(big)) }
        } else if bytes.count > 12, bytes[0] == 0xFF { // JPEG: find a start-of-frame marker
            var i = 2
            while i + 9 < bytes.count {
                if bytes[i] == 0xFF, (0xC0...0xC3).contains(bytes[i + 1]) {
                    for offset in [i + 5, i + 7] where rng.chance(2) {
                        let v = rng.pick(big); bytes[offset] = UInt8(truncatingIfNeeded: v >> 8); bytes[offset + 1] = UInt8(truncatingIfNeeded: v)
                    }
                    return
                }
                i += 1
            }
        }
    }
    private static func putBE32(_ bytes: inout [UInt8], _ at: Int, _ value: UInt32) {
        guard at + 4 <= bytes.count else { return }
        for k in 0..<4 { bytes[at + k] = UInt8(truncatingIfNeeded: value >> UInt32(24 - 8 * k)) }
    }

    /// Text-level edits for formats that are text underneath (PDF syntax, JSON).
    static func textual(_ source: String, numbers: [String], _ rng: inout FuzzRNG) -> String {
        var s = source
        let digits = try! NSRegularExpression(pattern: "-?[0-9]+(\\.[0-9]+)?")
        for _ in 0..<(1 + rng.below(3)) {
            let ns = s as NSString
            let hits = digits.matches(in: s, range: NSRange(location: 0, length: ns.length))
            guard let hit = hits.isEmpty ? nil : hits[rng.below(hits.count)] else { break }
            s = ns.replacingCharacters(in: hit.range, with: rng.pick(numbers))
        }
        return s
    }
}

// MARK: Text generation

enum FuzzText {
    static let tokens: [String] = [
        "$", "$$", "\\(", "\\)", "\\[", "\\]", "```", "`", "\\begin{align}", "\\end{align}", "\\begin{cases}", "\\end{cases}",
        "\\frac{", "\\sqrt[", "\\left(", "\\right)", "\\text{", "\\mathbb{R}", "\\sum_{", "\\int^{", "^", "_", "{", "}", "[", "]", "(", ")",
        "&", "\\\\", "\\", "\n", "\n\n", "\r\n", "# ", "## ", "- ", "* ", "1. ", "> ", "| a | b |", "|---|---|", "---", "**", "*", "~~", "<", ">",
        "日本語", "数式", "😀", "👨‍👩‍👧", "\u{200D}", "\u{202E}", "\u{0301}", "\u{FEFF}", "\u{0}", "a", "x", "1", "0", " ", "\t", "=", "+", "\\alpha", "\\infty",
    ]

    static func make(_ rng: inout FuzzRNG) -> String {
        var out = ""
        let mode = rng.below(10)
        if mode == 0 { // raw bytes decoded as UTF-8: lone surrogates, overlongs
            return String(decoding: (0..<(1 + rng.below(2_000))).map { _ in UInt8(truncatingIfNeeded: rng.next()) }, as: UTF8.self)
        }
        let pieces = 1 + rng.below(mode < 6 ? 60 : 400)
        for _ in 0..<pieces {
            let token = rng.pick(tokens)
            if rng.chance(25) { out += String(repeating: token, count: 1 + rng.below(rng.chance(8) ? 20_000 : 300)) } else { out += token }
        }
        if rng.chance(60) { // deep nesting and very long single lines
            let opener = rng.pick(["{", "(", "[", "\\frac{", "$", "> ", "- ", "  - ", "**", "\\left(", "\\begin{align}"])
            out += String(repeating: opener, count: 1_000 + rng.below(rng.chance(4) ? 200_000 : 20_000))
        }
        if rng.chance(80) { out += String(repeating: "a", count: 1 + rng.below(1_000_000)) }
        return out
    }
}

// MARK: Findings and journal

struct FuzzFinding: Codable {
    var target: String
    var kind: String
    var seed: UInt64
    var index: Int
    var detail: String
    var milliseconds: Double
    var peakMB: Double
}

final class FuzzRecorder {
    let target: String
    let seed: UInt64
    private let directory: URL?
    private(set) var findings: [FuzzFinding] = []
    private let sampler = FootprintSampler()

    init(target: String, seed: UInt64) {
        self.target = target; self.seed = seed
        directory = FuzzEnv.directory
        if let directory { try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
    }
    deinit { sampler.stop() }

    /// Written before the parser runs, so a process that dies leaves the exact case behind.
    func journal(index: Int) {
        guard let directory else { return }
        try? "\(target) \(seed) \(index)\n".write(to: directory.appendingPathComponent("journal-\(target).txt"), atomically: true, encoding: .utf8)
    }

    func record(_ finding: FuzzFinding, input: Data?) {
        findings.append(finding)
        guard let directory else { return }
        if let line = try? JSONEncoder().encode(finding), var text = String(data: line, encoding: .utf8) {
            text += "\n"
            let url = directory.appendingPathComponent("findings-\(target).jsonl")
            if let handle = try? FileHandle(forWritingTo: url) {
                handle.seekToEndOfFile(); handle.write(Data(text.utf8)); try? handle.close()
            } else { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
        if let input, input.count < 50_000_000 {
            try? input.write(to: directory.appendingPathComponent("repro-\(target)-\(finding.kind)-\(finding.seed)-\(finding.index).bin"))
        }
    }

    struct Budget { var seconds: Double; var megabytes: Double }

    /// Runs one case under the time and memory budgets. `body` returns true when the parser accepted the input.
    func run(index: Int, budget: Budget, input: @autoclosure () -> Data?, _ body: () -> Bool?) -> Bool? {
        journal(index: index)
        sampler.reset()
        let baseline = currentFootprintBytes()
        let started = DispatchTime.now().uptimeNanoseconds
        let accepted = body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - started) / 1_000_000
        let peakMB = Double(sampler.peakBytes &- min(sampler.peakBytes, baseline)) / 1_048_576
        if accepted == nil { // body reported an invariant violation through `violation`
            return nil
        }
        if ms > budget.seconds * 1000 {
            record(FuzzFinding(target: target, kind: "hang", seed: seed, index: index, detail: "took \(Int(ms)) ms (budget \(Int(budget.seconds * 1000)) ms)", milliseconds: ms, peakMB: peakMB), input: input())
        }
        if peakMB > budget.megabytes {
            record(FuzzFinding(target: target, kind: "memory", seed: seed, index: index, detail: "peak +\(Int(peakMB)) MB (budget \(Int(budget.megabytes)) MB)", milliseconds: ms, peakMB: peakMB), input: input())
        }
        return accepted
    }

    func violation(index: Int, _ detail: String, input: Data?) {
        record(FuzzFinding(target: target, kind: "invariant", seed: seed, index: index, detail: detail, milliseconds: 0, peakMB: 0), input: input)
    }

    func writeSummary(cases: Int, accepted: Int, rejected: Int, firstIndex: Int, lastIndex: Int, seconds: Double) {
        guard let directory else { return }
        let object: [String: Any] = ["target": target, "seed": seed, "cases": cases, "accepted": accepted, "rejected": rejected,
                                     "firstIndex": firstIndex, "lastIndex": lastIndex, "seconds": seconds, "findings": findings.count,
                                     "status": "completed"]
        if let data = try? JSONSerialization.data(withJSONObject: object) {
            try? data.write(to: directory.appendingPathComponent("summary-\(target)-\(seed)-\(firstIndex).json"))
        }
    }
}
