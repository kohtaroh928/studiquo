#if DEBUG
import SwiftUI
import SwiftMath

// Step 1 spike: can SwiftMath render Japanese prose with inline math well
// enough to be the renderer? Throw-away code, written to be measured — the
// real segmenter and renderer come in steps 3 and 4.

enum MathSpikeSegment: Equatable {
    case text(String)
    case inline(String)
    case display(String)
}

enum MathSpikeSegmenter {
    static func segments(in source: String) -> [MathSpikeSegment] {
        let chars = Array(source)
        var result: [MathSpikeSegment] = []
        var text = ""
        var i = 0

        func flush() {
            if !text.isEmpty { result.append(.text(text)); text = "" }
        }
        func matches(_ s: String, at index: Int) -> Bool {
            let pattern = Array(s)
            guard index + pattern.count <= chars.count else { return false }
            return Array(chars[index..<index + pattern.count]) == pattern
        }
        func find(_ closing: String, from start: Int) -> Int? {
            var j = start
            while j < chars.count {
                if matches(closing, at: j) { return j }
                j += chars[j] == "\\" ? 2 : 1
            }
            return nil
        }
        func hasJapanese(_ s: String) -> Bool {
            s.unicodeScalars.contains { (0x3000...0x30FF).contains($0.value) || (0x4E00...0x9FFF).contains($0.value) || (0xFF00...0xFFEF).contains($0.value) }
        }

        while i < chars.count {
            if matches("\\$", at: i) { text.append("$"); i += 2; continue }
            if matches("$$", at: i), let end = find("$$", from: i + 2) {
                flush(); result.append(.display(String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines))); i = end + 2; continue
            }
            if matches("\\[", at: i), let end = find("\\]", from: i + 2) {
                flush(); result.append(.display(String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines))); i = end + 2; continue
            }
            if matches("\\(", at: i), let end = find("\\)", from: i + 2) {
                flush(); result.append(.inline(String(chars[(i + 2)..<end]).trimmingCharacters(in: .whitespacesAndNewlines))); i = end + 2; continue
            }
            if chars[i] == "$", let end = find("$", from: i + 1), end > i + 1 {
                let content = String(chars[(i + 1)..<end])
                let trimmed = content.trimmingCharacters(in: .whitespaces)
                let looksLikeMath = trimmed == content && !content.contains("\n") && (!hasJapanese(content) || content.contains("\\"))
                if looksLikeMath {
                    flush(); result.append(.inline(content)); i = end + 1; continue
                }
            }
            text.append(chars[i]); i += 1
        }
        flush()
        return result
    }

    /// Escapes plain text for `\text{...}`.
    static func escapedForTextMode(_ s: String) -> String {
        var out = ""
        for c in s {
            switch c {
            case "\\": out += "\\textbackslash "
            case "{": out += "\\{"
            case "}": out += "\\}"
            case "$": out += "\\$"
            case "%": out += "\\%"
            case "#": out += "\\#"
            case "&": out += "\\&"
            case "_": out += "\\_"
            case "^": out += "\\^{}"
            case "~": out += "\\textasciitilde "
            default: out.append(c)
            }
        }
        return out
    }

    /// One line of prose with inline math as a single expression: plain text
    /// wrapped in `\text{}`, math left as math. Display math is not included.
    static func mixedLaTeX(for inlineSegments: [MathSpikeSegment]) -> String {
        inlineSegments.map { segment in
            switch segment {
            case .text(let t): return "\\text{\(escapedForTextMode(t))}"
            case .inline(let m): return m
            case .display(let m): return m
            }
        }.joined()
    }

    /// What the screen shows for a source: lines of mixed prose, display
    /// blocks between them.
    enum Block: Equatable {
        case line(String)      // mixed LaTeX for one label
        case display(String)
        case gap
    }

    static func blocks(for source: String) -> [Block] {
        var blocks: [Block] = []
        for rawLine in source.components(separatedBy: "\n") {
            if rawLine.trimmingCharacters(in: .whitespaces).isEmpty {
                if blocks.last != .gap { blocks.append(.gap) }
                continue
            }
            var pending: [MathSpikeSegment] = []
            func flushLine() {
                if pending.isEmpty { return }
                blocks.append(.line(mixedLaTeX(for: pending)))
                pending = []
            }
            for segment in segments(in: rawLine) {
                if case .display(let math) = segment {
                    flushLine()
                    blocks.append(.display(math))
                } else {
                    pending.append(segment)
                }
            }
            flushLine()
        }
        return blocks
    }

    static func parseError(_ latex: String) -> String? {
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: latex, error: &error)
        if let error { return error.localizedDescription }
        return list == nil ? "unknown error" : nil
    }
}

struct MathSpikeLabel: UIViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 17
    var mode: MTMathUILabelMode = .text
    var alignment: MTTextAlignment = .left
    var color: UIColor = .label

    func makeUIView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: MTMathUILabel, context: Context) {
        view.fontSize = fontSize
        view.font?.fallbackFont = CTFontCreateWithName("HiraginoSans-W3" as CFString, fontSize, nil)
        view.labelMode = mode
        view.textAlignment = alignment
        view.textColor = color
        view.latex = latex
        view.invalidateIntrinsicContentSize()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        uiView.preferredMaxLayoutWidth = width
        return uiView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
    }
}

struct MathSpikeView: View {
    /// `--math-spike-ids=a,b,c` picks the samples to show.
    static let galleryIDs: [String] = {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--math-spike-ids=") }) {
            return String(argument.dropFirst("--math-spike-ids=".count)).split(separator: ",").map(String.init)
        }
        return defaultGalleryIDs
    }()

    static let defaultGalleryIDs = [
        "quadratic-formula", "complete-the-square", "nested-fraction", "definite-integral",
        "taylor-series", "matrix-2x2", "piecewise-cases", "aligned-steps", "speed-formula",
        "induction-proof", "reply-quadratic-extremum", "reply-marking-report",
        "chemistry-ce", "boxed", "prices-then-real-math",
    ]

    @State private var width: CGFloat = {
        if let argument = ProcessInfo.processInfo.arguments.first(where: { $0.hasPrefix("--math-spike-width=") }),
           let value = Double(argument.dropFirst("--math-spike-width=".count)) { return CGFloat(value) }
        return 640
    }()
    @State private var dark = ProcessInfo.processInfo.arguments.contains("--math-spike-dark")
    @State private var fontSize: CGFloat = 17
    @State private var typesetMilliseconds: Double = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("SwiftMath 試作  /  タイプセット \(String(format: "%.0f", typesetMilliseconds)) ms").font(.headline)
                    .accessibilityIdentifier("math-spike-title")
                HStack {
                    Toggle("ダーク", isOn: $dark).fixedSize()
                    Text("幅 \(Int(width))")
                    Slider(value: $width, in: 260...760)
                    Text("文字 \(Int(fontSize))")
                    Slider(value: $fontSize, in: 12...26).frame(width: 120)
                }
                ForEach(Self.galleryIDs, id: \.self) { id in
                    if let sample = AIMathSamples.sample(id: id) {
                        card(for: sample)
                    }
                }
            }
            .padding(20)
        }
        .background(Color(.systemBackground))
        .preferredColorScheme(dark ? .dark : .light)
        .onAppear(perform: measure)
    }

    private func card(for sample: AIMathSample) -> some View {
        if ProcessInfo.processInfo.arguments.contains("--math-spike-rich") {
            return AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text(sample.id).font(.caption.bold()).foregroundStyle(.secondary)
                    Divider()
                    RichMessageView(source: sample.text, fontSize: fontSize)
                }
                .padding(12)
                .frame(width: width + 24, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            )
        }
        return AnyView(spikeCard(for: sample))
    }

    private func spikeCard(for sample: AIMathSample) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sample.id).font(.caption.bold()).foregroundStyle(.secondary)
            Text(sample.text)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(4)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(MathSpikeSegmenter.blocks(for: sample.text).enumerated()), id: \.offset) { _, block in
                    switch block {
                    case .line(let latex):
                        MathSpikeLabel(latex: latex, fontSize: fontSize)
                            .frame(width: width)
                    case .display(let latex):
                        MathSpikeLabel(latex: latex, fontSize: fontSize + 3, mode: .display, alignment: .center)
                            .frame(width: width)
                    case .gap:
                        Color.clear.frame(height: 6)
                    }
                }
            }
        }
        .padding(12)
        .frame(width: width + 24, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
    }

    private func measure() {
        let start = CFAbsoluteTimeGetCurrent()
        for id in Self.galleryIDs {
            guard let sample = AIMathSamples.sample(id: id) else { continue }
            for block in MathSpikeSegmenter.blocks(for: sample.text) {
                let label = MTMathUILabel()
                label.fontSize = fontSize
                label.preferredMaxLayoutWidth = width
                switch block {
                case .line(let latex): label.latex = latex
                case .display(let latex): label.latex = latex; label.labelMode = .display
                case .gap: continue
                }
                _ = label.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude))
            }
        }
        typesetMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
    }
}
#endif
