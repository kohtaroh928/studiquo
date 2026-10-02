import SwiftUI
import SwiftMath

/// Typesets LaTeX with SwiftMath for the AI chat, and says when it cannot.
///
/// SwiftMath draws nothing — not even an error — for a formula it does not
/// understand, so every formula is parsed first and only drawn when that
/// succeeds. Anything else is shown as the plain-text form from
/// `MathTextFormatter`.
enum MathRendering {
    // MARK: Normalising

    /// LaTeX commands SwiftMath lacks that have a plain equivalent.
    static func normalized(_ latex: String) -> String {
        var s = latex
        let replacements: [(String, String)] = [
            (#"\\therefore(?![A-Za-z])"#, #"\\text{∴}"#),
            (#"\\because(?![A-Za-z])"#, #"\\text{∵}"#),
            (#"\\blacksquare(?![A-Za-z])"#, #"\\text{■}"#),
            (#"\\hline(?![A-Za-z])"#, ""),
            (#"\\cline\{[^}]*\}"#, ""),
            (#"\\mathscr(?![A-Za-z])"#, #"\\mathcal"#),
            (#"\\displaystyle(?![A-Za-z])"#, ""),
            (#"\\(begin|end)\{align\*?\}"#, #"\\$1{aligned}"#),
        ]
        for (pattern, template) in replacements {
            s = s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        // `array` is unknown to SwiftMath; a bare matrix is the closest layout (column rules are dropped).
        s = s.replacingOccurrences(of: #"\\begin\{array\}(\{[^}]*\})?"#, with: #"\\begin{matrix}"#, options: .regularExpression)
        s = s.replacingOccurrences(of: #"\\end\{array\}"#, with: #"\\end{matrix}"#, options: .regularExpression)
        return s
    }

    // MARK: Checking

    private static let renderableCache = NSCache<NSString, NSNumber>()

    /// Whether SwiftMath can typeset this formula (after normalising).
    static func isRenderable(_ latex: String) -> Bool {
        let key = latex as NSString
        if let cached = renderableCache.object(forKey: key) { return cached.boolValue }
        var error: NSError?
        let list = MTMathListBuilder.build(fromString: normalized(latex), error: &error)
        let ok = error == nil && list != nil
        renderableCache.setObject(NSNumber(value: ok), forKey: key)
        return ok
    }

    // MARK: Inline images

    struct InlineImage {
        let image: UIImage
        /// How far the formula reaches below its baseline.
        let descent: CGFloat
    }

    private final class CachedImage {
        let value: InlineImage?
        init(_ value: InlineImage?) { self.value = value }
    }

    private static let imageCache: NSCache<NSString, CachedImage> = {
        let cache = NSCache<NSString, CachedImage>()
        cache.countLimit = 400
        return cache
    }()

    /// The Japanese face used where the math font has no glyph.
    static func fallbackFont(size: CGFloat) -> CTFont {
        CTFontCreateWithName("HiraginoSans-W3" as CFString, size, nil)
    }

    /// A formula as an image sized for the middle of a line of text, or nil
    /// when it cannot be typeset.
    @MainActor
    static func inlineImage(latex: String, fontSize: CGFloat, color: UIColor) -> InlineImage? {
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let key = "\(fontSize)|\(red),\(green),\(blue),\(alpha)|\(latex)" as NSString
        if let cached = imageCache.object(forKey: key) { return cached.value }
        let value = makeInlineImage(latex: latex, fontSize: fontSize, color: color)
        imageCache.setObject(CachedImage(value), forKey: key)
        return value
    }

    @MainActor
    private static func makeInlineImage(latex: String, fontSize: CGFloat, color: UIColor) -> InlineImage? {
        guard isRenderable(latex) else { return nil }
        let label = MTMathUILabel()
        label.fontSize = fontSize
        label.font?.fallbackFont = fallbackFont(size: fontSize)
        label.labelMode = .text
        label.textColor = color
        label.backgroundColor = .clear
        label.contentInsets = MTEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
        label.latex = normalized(latex)
        let size = label.sizeThatFits(.zero)
        guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else { return nil }
        label.frame = CGRect(origin: .zero, size: size)
        label.layoutIfNeeded()
        guard label.error == nil, let display = label.displayList else { return nil }
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            // the label draws for a flipped (Core Graphics) context
            context.cgContext.translateBy(x: 0, y: size.height)
            context.cgContext.scaleBy(x: 1, y: -1)
            label.layer.render(in: context.cgContext)
        }
        return InlineImage(image: image, descent: max(0, display.descent))
    }
}

/// A display formula, typeset at the width it is given and wrapped there.
struct MathLabel: UIViewRepresentable {
    let latex: String
    var fontSize: CGFloat = 19
    var color: UIColor = .label
    var alignment: MTTextAlignment = .center

    func makeUIView(context: Context) -> MTMathUILabel {
        let view = MTMathUILabel()
        view.backgroundColor = .clear
        view.setContentHuggingPriority(.required, for: .vertical)
        view.setContentCompressionResistancePriority(.required, for: .vertical)
        return view
    }

    func updateUIView(_ view: MTMathUILabel, context: Context) {
        view.fontSize = fontSize
        // `fontSize` copies the font, so the fallback is set after it
        view.font?.fallbackFont = MathRendering.fallbackFont(size: fontSize)
        view.labelMode = .display
        view.textAlignment = alignment
        view.textColor = color
        view.latex = MathRendering.normalized(latex)
        view.invalidateIntrinsicContentSize()
    }

    /// Fills the width it is offered; returning the formula's own width would
    /// leave SwiftUI to centre it.
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTMathUILabel, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        uiView.preferredMaxLayoutWidth = width
        let size = uiView.sizeThatFits(CGSize(width: width, height: CGFloat.greatestFiniteMagnitude))
        return CGSize(width: width, height: size.height)
    }
}
