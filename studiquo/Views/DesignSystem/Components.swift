import SwiftUI

// Shared building blocks for the minimal look (docs/UI_DESIGN_TOKENS.md §8).
// Not yet used by screens; they are adopted screen by screen.

// MARK: Buttons

struct PrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyStrong)
            .foregroundStyle(Theme.Palette.onAccent)
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(minHeight: 44)
            .background(
                Theme.Palette.accent.opacity(isEnabled ? (configuration.isPressed ? 0.85 : 1) : 0.4),
                in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.bodyStrong)
            .foregroundStyle(Theme.Palette.accent.opacity(isEnabled ? 1 : 0.4))
            .padding(.horizontal, Theme.Spacing.lg)
            .frame(minHeight: 44)
            .background(
                configuration.isPressed ? Theme.Palette.accentSoft : Theme.Palette.surface,
                in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
                    .strokeBorder(Theme.Palette.line, lineWidth: Theme.Stroke.hairline)
            )
            .contentShape(RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous))
    }
}

/// Text-only button for low-emphasis actions.
struct QuietButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(Theme.Typography.label)
            .foregroundStyle(Theme.Palette.textSecondary.opacity(isEnabled ? (configuration.isPressed ? 0.6 : 1) : 0.4))
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

extension ButtonStyle where Self == PrimaryButtonStyle {
    static var themePrimary: PrimaryButtonStyle { PrimaryButtonStyle() }
}

extension ButtonStyle where Self == SecondaryButtonStyle {
    static var themeSecondary: SecondaryButtonStyle { SecondaryButtonStyle() }
}

extension ButtonStyle where Self == QuietButtonStyle {
    static var themeQuiet: QuietButtonStyle { QuietButtonStyle() }
}

// MARK: Surfaces

struct CardModifier: ViewModifier {
    var radius: CGFloat = Theme.Radius.m
    var padding: CGFloat = Theme.Spacing.lg

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Theme.Palette.line, lineWidth: Theme.Stroke.hairline)
            )
    }
}

struct SunkenFieldModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Theme.Spacing.md)
            .frame(minHeight: 44)
            .background(
                Theme.Palette.surfaceSunken,
                in: RoundedRectangle(cornerRadius: Theme.Radius.m, style: .continuous)
            )
    }
}

extension View {
    /// Flat card: surface fill, hairline border, no shadow.
    func themeCard(radius: CGFloat = Theme.Radius.m, padding: CGFloat = Theme.Spacing.lg) -> some View {
        modifier(CardModifier(radius: radius, padding: padding))
    }

    /// Recessed background for text inputs.
    func themeField() -> some View {
        modifier(SunkenFieldModifier())
    }
}

// MARK: Rows and sections

struct SectionHeader: View {
    let title: LocalizedStringKey
    var trailing: AnyView?

    init(_ title: LocalizedStringKey) {
        self.title = title
        self.trailing = nil
    }

    init<Trailing: View>(_ title: LocalizedStringKey, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.trailing = AnyView(trailing())
    }

    var body: some View {
        HStack {
            Text(title)
                .font(Theme.Typography.title)
                .foregroundStyle(Theme.Palette.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: Theme.Spacing.md)
            trailing
        }
    }
}

/// Icon, title, optional subtitle and a trailing accessory.
struct ListRow<Trailing: View>: View {
    let systemImage: String?
    let title: LocalizedStringKey
    var subtitle: LocalizedStringKey?
    let trailing: Trailing

    init(
        systemImage: String? = nil,
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey? = nil,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.systemImage = systemImage
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: Theme.Spacing.md) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .frame(width: 24)
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.xs) {
                Text(title)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.Palette.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Theme.Typography.caption)
                        .foregroundStyle(Theme.Palette.textSecondary)
                }
            }
            Spacer(minLength: Theme.Spacing.md)
            trailing
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

extension ListRow where Trailing == EmptyView {
    init(systemImage: String? = nil, title: LocalizedStringKey, subtitle: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, title: title, subtitle: subtitle) { EmptyView() }
    }
}

struct EmptyState<Action: View>: View {
    let systemImage: String
    let title: LocalizedStringKey
    var message: LocalizedStringKey?
    let action: Action

    init(
        systemImage: String,
        title: LocalizedStringKey,
        message: LocalizedStringKey? = nil,
        @ViewBuilder action: () -> Action
    ) {
        self.systemImage = systemImage
        self.title = title
        self.message = message
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Theme.Spacing.md) {
            Image(systemName: systemImage)
                .font(.largeTitle)
                .foregroundStyle(Theme.Palette.textTertiary)
                .accessibilityHidden(true)
            Text(title)
                .font(Theme.Typography.headline)
                .foregroundStyle(Theme.Palette.textPrimary)
                .multilineTextAlignment(.center)
            if let message {
                Text(message)
                    .font(Theme.Typography.label)
                    .foregroundStyle(Theme.Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            action
        }
        .padding(Theme.Spacing.xl)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity)
    }
}

extension EmptyState where Action == EmptyView {
    init(systemImage: String, title: LocalizedStringKey, message: LocalizedStringKey? = nil) {
        self.init(systemImage: systemImage, title: title, message: message) { EmptyView() }
    }
}

#Preview("Components") {
    ScrollView {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            SectionHeader("Section")
            VStack(alignment: .leading, spacing: 0) {
                ListRow(systemImage: "book", title: "Title", subtitle: "Subtitle") {
                    Image(systemName: "chevron.right").foregroundStyle(Theme.Palette.textTertiary)
                }
            }
            .themeCard()
            HStack {
                Button("Primary") {}.buttonStyle(.themePrimary)
                Button("Secondary") {}.buttonStyle(.themeSecondary)
                Button("Quiet") {}.buttonStyle(.themeQuiet)
            }
            TextField("Field", text: .constant("")).themeField()
            EmptyState(systemImage: "tray", title: "Nothing here", message: "Message")
        }
        .padding(Theme.Spacing.lg)
    }
    .background(Theme.Palette.canvas)
}
