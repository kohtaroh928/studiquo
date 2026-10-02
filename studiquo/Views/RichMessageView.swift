import SwiftUI

/// An AI reply laid out as a person would write it: Markdown structure, with
/// the math typeset.
///
/// Paragraphs are one `Text`, so Japanese wraps the way the system wraps it;
/// a formula in a sentence is an image placed on the text's baseline. A
/// formula that cannot be typeset appears as its plain-text form instead of
/// vanishing.
struct RichMessageView: View {
    let source: String
    var fontSize: CGFloat = 17
    var color: UIColor = .label

    private final class ParseCache {
        var source = ""
        var blocks: [RichBlock] = []
    }
    @State private var cache = ParseCache()

    private var blocks: [RichBlock] {
        if cache.source != source || (cache.blocks.isEmpty && !source.isEmpty) {
            cache.blocks = RichTextParser.parse(source)
            cache.source = source
        }
        return cache.blocks
    }

    var body: some View {
        RichBlocksView(blocks: blocks, style: RichStyle(fontSize: fontSize, color: color))
            .frame(maxWidth: .infinity, alignment: .leading)
            // One element read as plain words: the typeset formulas are images with no text of their own.
            .accessibilityRepresentation { Text(MathTextFormatter.plainText(from: source)) }
    }
}

struct RichStyle {
    var fontSize: CGFloat
    var color: UIColor

    var swiftUIColor: Color { Color(uiColor: color) }
    func scaled(_ factor: CGFloat) -> RichStyle { RichStyle(fontSize: fontSize * factor, color: color) }
}

private struct RichBlocksView: View {
    let blocks: [RichBlock]
    let style: RichStyle

    var body: some View {
        VStack(alignment: .leading, spacing: style.fontSize * 0.6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                RichBlockView(block: block, style: style)
            }
        }
    }
}

private struct RichBlockView: View {
    let block: RichBlock
    let style: RichStyle

    var body: some View {
        switch block {
        case .heading(let level, let spans):
            RichInlineText(spans: spans, style: style.scaled(Self.headingScale(level)), bold: true)
                .padding(.top, level <= 2 ? style.fontSize * 0.3 : 0)

        case .paragraph(let spans):
            RichInlineText(spans: spans, style: style)

        case .displayMath(let latex):
            DisplayMathBlock(latex: latex, style: style)

        case .incompleteMath(let raw):
            Text(verbatim: raw)
                .font(.system(size: style.fontSize * 0.9, design: .monospaced))
                .foregroundStyle(.secondary)

        case .codeBlock(let language, let code, _):
            CodeBlockView(language: language, code: code, style: style)

        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: style.fontSize * 0.35) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .firstTextBaseline, spacing: style.fontSize * 0.4) {
                        Text(verbatim: ordered ? "\(start + index)." : "•")
                            .font(.system(size: style.fontSize))
                            .foregroundStyle(style.swiftUIColor)
                            .frame(minWidth: style.fontSize * (ordered ? 1.4 : 0.8), alignment: .trailing)
                        RichBlocksView(blocks: item, style: style)
                    }
                }
            }

        case .quote(let inner):
            HStack(alignment: .top, spacing: style.fontSize * 0.6) {
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(Color.secondary.opacity(0.5))
                    .frame(width: 3)
                RichBlocksView(blocks: inner, style: style)
                    .foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)

        case .table(let header, let rows):
            TableBlockView(header: header, rows: rows, style: style)

        case .rule:
            Divider()
        }
    }

    private static func headingScale(_ level: Int) -> CGFloat {
        switch level {
        case 1: return 1.5
        case 2: return 1.3
        case 3: return 1.15
        default: return 1.05
        }
    }
}

/// A paragraph, heading or table cell: styled text with formulas in line.
struct RichInlineText: View {
    let spans: [RichSpan]
    let style: RichStyle
    var bold = false

    var body: some View {
        spans.reduce(Text(verbatim: "")) { $0 + text(for: $1) }
            .font(.system(size: style.fontSize, weight: bold ? .bold : .regular))
            .foregroundStyle(style.swiftUIColor)
            .lineSpacing(style.fontSize * 0.25)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func text(for span: RichSpan) -> Text {
        var result: Text
        switch span.content {
        case .text(let string):
            if let link = span.link, let url = URL(string: link) {
                var attributed = AttributedString(string)
                attributed.link = url
                attributed.underlineStyle = .single
                result = Text(attributed)
            } else {
                result = Text(verbatim: string)
            }
        case .code(let code):
            var attributed = AttributedString(code)
            attributed.font = .system(size: style.fontSize * 0.9, design: .monospaced)
            attributed.backgroundColor = Color(.secondarySystemBackground)
            result = Text(attributed)
        case .math(let latex):
            // `MainActor.assumeIsolated`: a view's body always runs on the main actor
            if let image = MainActor.assumeIsolated({
                MathRendering.inlineImage(latex: latex, fontSize: style.fontSize, color: style.color)
            }) {
                result = Text(Image(uiImage: image.image)).baselineOffset(-image.descent)
            } else {
                result = Text(verbatim: MathTextFormatter.readableMath(from: latex))
            }
        }
        if span.isBold { result = result.bold() }
        if span.isItalic { result = result.italic() }
        if span.isStrikethrough { result = result.strikethrough() }
        return result
    }
}

private struct DisplayMathBlock: View {
    let latex: String
    let style: RichStyle

    var body: some View {
        if MathRendering.isRenderable(latex) {
            MathLabel(latex: latex, fontSize: style.fontSize + 3, color: style.color)
                .frame(maxWidth: .infinity)
        } else {
            Text(verbatim: MathTextFormatter.readableMath(from: latex))
                .font(.system(size: style.fontSize))
                .foregroundStyle(style.swiftUIColor)
                .frame(maxWidth: .infinity)
        }
    }
}

private struct CodeBlockView: View {
    let language: String?
    let code: String
    let style: RichStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(verbatim: language)
                    .font(.system(size: style.fontSize * 0.7, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                Text(verbatim: code.isEmpty ? " " : code)
                    .font(.system(size: style.fontSize * 0.85, design: .monospaced))
                    .foregroundStyle(style.swiftUIColor)
                    .fixedSize(horizontal: true, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct TableBlockView: View {
    let header: [[RichSpan]]
    let rows: [[[RichSpan]]]
    let style: RichStyle

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            Grid(alignment: .leading, horizontalSpacing: 0, verticalSpacing: 0) {
                GridRow {
                    ForEach(Array(header.enumerated()), id: \.offset) { _, cell in
                        RichInlineText(spans: cell, style: style, bold: true)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                    }
                }
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    Divider().gridCellUnsizedAxes(.horizontal)
                    GridRow {
                        ForEach(Array(row.enumerated()), id: \.offset) { _, cell in
                            RichInlineText(spans: cell, style: style)
                                .padding(8)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
}
