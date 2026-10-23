import SwiftUI

/// The strip at the top of the app that says why the server is not answering.
/// It is placed as a safe-area inset, so it pushes the app down instead of covering
/// its toolbar, and notes keep working on the device.
struct ServerNoticeBanner: View {
    @ObservedObject private var center = ServerNoticeCenter.shared
    @Environment(\.openURL) private var openURL

    var body: some View {
        content
            .animation(.easeInOut(duration: 0.2), value: center.notice)
            .onChange(of: center.notice) { _, notice in
                // Tell VoiceOver when it appears; a banner nobody hears is no banner.
                if let notice { UIAccessibility.post(notification: .announcement, argument: notice.message) }
            }
    }

    @ViewBuilder
    private var content: some View {
        if let notice = center.notice {
            HStack(spacing: 12) {
                Image(systemName: notice == .updateRequired ? "arrow.down.app" : "exclamationmark.triangle")
                    .accessibilityHidden(true)
                Text(notice.message)
                    .font(.footnote)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if notice == .updateRequired, let url = ServerNoticeCenter.updateURL {
                    Button("アプリを更新") { openURL(url) }
                        .buttonStyle(.borderedProminent)
                }
                Button(notice == .updateRequired ? "あとで" : "閉じる") { center.dismiss() }
                    .buttonStyle(.bordered)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
            .overlay(alignment: .bottom) { Divider() }
            .accessibilityElement(children: .contain)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}
