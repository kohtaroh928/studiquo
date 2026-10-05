import SwiftUI

/// The "iCloud sync" switch in settings. One switch for the whole device;
/// a change takes effect when the app is next opened.
struct ICloudSyncSettingsSection: View {
    @ObservedObject private var monitor = ICloudSyncMonitor.shared
    @State private var isOn = ICloudSyncPreference.isEnabled

    var body: some View {
        Section {
            Toggle("iCloudで同期する", isOn: $isOn)
                .accessibilityIdentifier("icloud-sync-toggle")
                .onChange(of: isOn) { _, newValue in ICloudSyncPreference.setEnabled(newValue) }
            if isOn != ICloudSyncPreference.isEnabledAtLaunch {
                Label("アプリを完全に終了して開き直すと、切り替わります。", systemImage: "arrow.clockwise")
                    .font(.footnote)
                    .accessibilityIdentifier("icloud-sync-restart-note")
            }
            if ICloudSyncPreference.isEnabledAtLaunch && monitor.isQuotaExceeded {
                Label("iCloudの空き容量がありません。新しい内容は、このiPadにだけ保存されています。", systemImage: "exclamationmark.icloud")
                    .font(.footnote)
                    .foregroundStyle(.orange)
                    .accessibilityIdentifier("icloud-sync-quota-note")
            }
        } header: {
            Text("iCloud同期")
        } footer: {
            Text("ノート・暗記帳・文書・スライド・カレンダーなど、アプリ内のすべてのデータを、iCloudで他の端末と同期します。オフにすると、このiPadにだけ保存されます。設定は端末ごとです。オフにしても、iCloudにある分は消えません(削除はiPadの「設定」アプリから行えます)。Studiquo側の容量の上限はなく、使えるのはiCloudの空き容量までです。")
        }
    }
}

/// Shown when iCloud is full: notes still save on this device, they just are
/// not reaching the others. Offers to stop the retries.
struct ICloudQuotaBanner: View {
    @ObservedObject var monitor: ICloudSyncMonitor
    @State private var didStop = false

    var body: some View {
        Group { banner }
            .animation(.easeInOut, value: monitor.isQuotaExceeded && !monitor.isBannerDismissed)
    }

    @ViewBuilder
    private var banner: some View {
        if monitor.isQuotaExceeded && !monitor.isBannerDismissed && ICloudSyncPreference.isEnabledAtLaunch {
            VStack(alignment: .leading, spacing: 10) {
                Label("iCloudの空き容量がありません", systemImage: "exclamationmark.icloud")
                    .font(.headline)
                Text(didStop
                     ? "同期をオフにしました。アプリを開き直すと反映されます。"
                     : "新しい内容は、このiPadにだけ保存されます。iCloudに空きができると、自動で同期を再開します。")
                    .font(.footnote)
                HStack {
                    if !didStop {
                        Button("同期を止める") {
                            ICloudSyncPreference.setEnabled(false)
                            didStop = true
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("icloud-quota-stop")
                    }
                    Button("閉じる") { monitor.dismissBanner() }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("icloud-quota-dismiss")
                }
            }
            .padding(14)
            .frame(maxWidth: 460, alignment: .leading)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.top, 8)
            .accessibilityIdentifier("icloud-quota-banner")
        }
    }
}
