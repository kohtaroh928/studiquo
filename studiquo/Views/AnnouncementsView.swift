import SwiftUI

enum AnnouncementScreenLogic {
    static func emptyMessageKey(loadFailed: Bool) -> String {
        loadFailed ? "announcements.loadFailed" : "announcements.empty"
    }

    static func showsMarkAllRead(unreadCount: Int) -> Bool {
        unreadCount > 0
    }
}

/// The その他 tab's お知らせ screen: the operators' notices, newest first.
/// Opening one marks it read; the unread count drives the badges on the row
/// and on the tab.
struct AnnouncementsView: View {
    @ObservedObject var store: AnnouncementStore

    var body: some View {
        List {
            if store.announcements.isEmpty {
                Section {
                    Text(AnnouncementScreenLogic.emptyMessageKey(loadFailed: store.loadFailed))
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("announcements-empty")
                }
            } else {
                Section {
                    ForEach(store.announcements) { announcement in
                        NavigationLink {
                            AnnouncementDetailView(announcement: announcement, store: store)
                        } label: {
                            AnnouncementRow(announcement: announcement, isUnread: !store.isRead(announcement))
                        }
                        .accessibilityIdentifier("announcement-row-\(announcement.id)")
                    }
                } footer: {
                    if store.loadFailed { Text("announcements.loadFailed") }
                }
            }
        }
        .navigationTitle(Text("announcements.title"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if AnnouncementScreenLogic.showsMarkAllRead(unreadCount: store.unreadCount) {
                ToolbarItem(placement: .primaryAction) {
                    Button("announcements.markAllRead") { store.markAllRead() }
                }
            }
        }
        .refreshable { await store.refresh() }
        .task { await store.refresh() }
    }
}

private struct AnnouncementRow: View {
    let announcement: Announcement
    let isUnread: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Circle()
                .fill(isUnread ? Color.red : Color.clear)
                .frame(width: 8, height: 8)
                .padding(.top, 7)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Label(LocalizedStringKey(announcement.kindValue.titleKey), systemImage: announcement.kindValue.systemImage)
                        .labelStyle(.titleAndIcon)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(announcement.kindValue == .important ? Color.red : Color.secondary)
                    Text(announcement.publishedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: announcement.title)
                    .font(.body.weight(isUnread ? .semibold : .regular))
                Text(verbatim: announcement.body)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}

private struct AnnouncementDetailView: View {
    let announcement: Announcement
    @ObservedObject var store: AnnouncementStore

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 8) {
                    Label(LocalizedStringKey(announcement.kindValue.titleKey), systemImage: announcement.kindValue.systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(announcement.kindValue == .important ? Color.red : Color.secondary)
                    Text(announcement.publishedAt, style: .date)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Text(verbatim: announcement.title)
                    .font(.title3.weight(.bold))
                Text(verbatim: announcement.body)
                    .font(.body)
                    .textSelection(.enabled)
                if let url = announcement.linkURL {
                    Link(destination: url) {
                        Label("announcements.openLink", systemImage: "arrow.up.right.square")
                    }
                    .padding(.top, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
        }
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.markRead(announcement) }
    }
}
