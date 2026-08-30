import SwiftUI

struct PageTemplatePickerSheet: View {
    let title: String
    let subtitle: String?
    let selectedTemplate: PageTemplate
    let selectedPaperColorHex: String
    let confirmTitle: String
    let onCancel: () -> Void
    let onSelect: (PageTemplate, String) -> Void

    @State private var draftTemplate: PageTemplate
    @State private var draftPaperColorHex: String

    init(
        title: String,
        subtitle: String? = nil,
        selectedTemplate: PageTemplate,
        selectedPaperColorHex: String = PaperColorChoice.white.hex,
        confirmTitle: String,
        onCancel: @escaping () -> Void,
        onSelect: @escaping (PageTemplate, String) -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.selectedTemplate = selectedTemplate
        self.selectedPaperColorHex = selectedPaperColorHex
        self.confirmTitle = confirmTitle
        self.onCancel = onCancel
        self.onSelect = onSelect
        _draftTemplate = State(initialValue: selectedTemplate)
        _draftPaperColorHex = State(initialValue: selectedPaperColorHex)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                TemplatePickerContent(
                    selection: $draftTemplate,
                    paperColorHex: $draftPaperColorHex,
                    subtitle: subtitle
                )
                .padding(.horizontal, 26)
                .padding(.vertical, 20)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(confirmTitle) { onSelect(draftTemplate, draftPaperColorHex) }
                        .fontWeight(.semibold)
                }
            }
        }
        // A fixed sheet in the middle of the screen. It used to open at a
        // medium detent the student could drag between sizes, which on an
        // iPad meant a small panel with two rows of thumbnails showing and
        // the rest hidden behind a scroll.
        .modifier(FixedSheetSize(shape: .page))
        .presentationDragIndicator(.hidden)
        .interactiveDismissDisabled()
        .onChange(of: selectedTemplate) { _, value in
            draftTemplate = value
        }
    }
}

/// The paper colours offered when a page is created.
///
/// Deliberately three. The full palette lives in the 用紙 menu for changing a
/// page later; picking one at creation time is a quick choice, not a
/// decision worth a colour wheel.
enum PaperColorChoice: String, CaseIterable, Identifiable {
    case white, skin, sky

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: "白"
        case .skin: "肌色"
        case .sky: "水色"
        }
    }

    var hex: String {
        switch self {
        case .white: "#FFFFFF"
        case .skin: "#FBEEE3"
        case .sky: "#E8F4FD"
        }
    }
}

struct NewNotebookSheet: View {
    @Binding var name: String
    @Binding var selectedTemplate: PageTemplate
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("名前")
                            .font(.headline)
                        TextField("名称未設定のノート", text: $name)
                            .textFieldStyle(.roundedBorder)
                    }

                    TemplatePickerContent(
                        selection: $selectedTemplate,
                        subtitle: "最初のページの用紙を選んでください。"
                    )
                }
                .padding(22)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("新規ノート")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("作成", action: onCreate)
                        .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

private struct TemplatePickerContent: View {
    @Binding var selection: PageTemplate
    /// Optional: the new-notebook sheet reuses this content without one.
    var paperColorHex: Binding<String>?
    let subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    if let paperColorHex {
                        TemplateSection(title: "紙の色", templates: []) { _ in
                            HStack(spacing: 14) {
                                ForEach(PaperColorChoice.allCases) { choice in
                                    PaperColorButton(
                                        choice: choice,
                                        isSelected: paperColorHex.wrappedValue == choice.hex
                                    ) {
                                        paperColorHex.wrappedValue = choice.hex
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                        }
                    }

                    TemplateSection(title: "基本", templates: [.blank, .dotted, .grid, .ruled]) {
                        templateGrid($0)
                    }

                    TemplateSection(title: "学習", templates: [.cornell, .checklist]) {
                        templateGrid($0)
                    }

                    TemplateSection(title: "予定", templates: [.weekly, .monthly]) {
                        templateGrid($0)
                    }

                    TemplateSection(title: "音楽", templates: [.musicStaff]) {
                        templateGrid($0)
                    }
        }
    }

    private func templateGrid(_ templates: [PageTemplate]) -> some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 14)], spacing: 14) {
            ForEach(templates) { template in
                PageTemplatePreviewButton(
                    template: template,
                    paperColorHex: paperColorHex?.wrappedValue,
                    isSelected: selection == template
                ) {
                    selection = template
                }
            }
        }
    }
}

private struct TemplateSection<Content: View>: View {
    let title: String
    let templates: [PageTemplate]
    @ViewBuilder var content: ([PageTemplate]) -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)
            content(templates)
        }
    }
}

private struct PageTemplatePreviewButton: View {
    let template: PageTemplate
    let paperColorHex: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack(alignment: .bottomTrailing) {
                    PageTemplateBackground(
                        template: template,
                        isDark: false,
                        paperColorHex: paperColorHex ?? PaperColorChoice.white.hex
                    )
                    .aspectRatio(0.72, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(isSelected ? Color.accentColor : Color.black.opacity(0.10), lineWidth: isSelected ? 2.5 : 1)
                    }
                    .shadow(color: .black.opacity(0.10), radius: 4, y: 2)

                    if isSelected {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 19, height: 19)
                            .background(Color.accentColor, in: Circle())
                            .padding(4)
                    }
                }

                Text(template.name)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(template.name)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

private struct PaperColorButton: View {
    let choice: PaperColorChoice
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Circle()
                    .fill(Color(uiColor: UIColor(inkHex: choice.hex)))
                    .frame(width: 38, height: 38)
                    .overlay(Circle().strokeBorder(Color.black.opacity(0.12), lineWidth: 1))
                    .overlay {
                        if isSelected {
                            Circle().strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                Text(choice.title)
                    .font(.caption.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(.primary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(choice.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

/// A sheet pinned to one fixed size in the middle of the screen, which the
/// student cannot drag larger or smaller.
///
/// `presentationSizing` does this properly but needs iOS 18; on 17 a single
/// large detent is the closest the platform gets — one detent means there is
/// nothing to drag between.
struct FixedSheetSize: ViewModifier {
    enum Shape {
        /// Wide, for a grid of thumbnails.
        case page
        /// Tall and narrow, for a list.
        case portrait
    }

    let shape: Shape

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            switch shape {
            case .page: content.presentationSizing(.page)
            case .portrait: content.presentationSizing(.form)
            }
        } else {
            content.presentationDetents([.large])
        }
    }
}
