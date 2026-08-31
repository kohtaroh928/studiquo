import CoreImage.CIFilterBuiltins
import PhotosUI
import SwiftUI

struct UserProfileView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("profileName") private var name = ""
    @AppStorage("profileOccupation") private var occupation = ""
    @AppStorage("profileBio") private var bio = ""
    @AppStorage("profileImage") private var imageData = Data()
    @State private var selectedPhoto: PhotosPickerItem?
    @State private var passkeyAdded = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 18) {
                        profileImage
                        PhotosPicker(selection: $selectedPhoto, matching: .images) {
                            Label("写真を選ぶ", systemImage: "photo")
                        }
                    }
                    TextField("名前", text: $name)
                    TextField("職業・身分", text: $occupation)
                    TextField("自己紹介", text: $bio, axis: .vertical).lineLimit(3...6)
                    LabeledContent("メールアドレス", value: authentication.email)
                }
                Section {
                    Button {
                        Task { passkeyAdded = await authentication.addPasskey() }
                    } label: {
                        Label(
                            passkeyAdded ? "パスキーを追加しました" : "パスキーを追加",
                            systemImage: passkeyAdded ? "checkmark.circle.fill" : "person.badge.key.fill"
                        )
                    }
                    .disabled(authentication.isPasskeyBusy || passkeyAdded)
                    if !authentication.errorMessage.isEmpty {
                        Text(authentication.errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                } header: {
                    Text("ログイン")
                } footer: {
                    Text("パスキーはiCloudキーチェーンに安全に保存され、次回からFace IDまたはTouch IDでログインできます。")
                }
                Section {
                    Button("ログアウト", role: .destructive) { authentication.logout(); dismiss() }
                }
            }
            .navigationTitle("プロフィール")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完了") { dismiss() } } }
            .onChange(of: selectedPhoto) { _, item in
                Task {
                    guard let data = try? await item?.loadTransferable(type: Data.self),
                          let image = UIImage(data: data),
                          let normalized = Self.profileImageData(from: image) else { return }
                    imageData = normalized
                }
            }
        }
    }

    @ViewBuilder private var profileImage: some View {
        if let image = UIImage(data: imageData) {
            Image(uiImage: image).resizable().scaledToFill().frame(width: 78, height: 78).clipShape(Circle())
        } else {
            Image(systemName: "person.crop.circle.fill").resizable().scaledToFit().frame(width: 78, height: 78).foregroundStyle(.secondary)
        }
    }

    /// Profile photos live in UserDefaults, so keep them small and strip the
    /// original file's metadata before persisting them.
    private static func profileImageData(from image: UIImage) -> Data? {
        let side: CGFloat = 512
        let scale = max(side / image.size.width, side / image.size.height)
        let scaled = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let origin = CGPoint(x: (side - scaled.width) / 2, y: (side - scaled.height) / 2)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: side, height: side), format: format).image { _ in
            image.draw(in: CGRect(origin: origin, size: scaled))
        }
        return rendered.jpegData(compressionQuality: 0.82)
    }
}

struct FriendRecord: Identifiable, Codable, Hashable {
    var id: UUID
    var name: String
    var code: String
    var todayStudySeconds: TimeInterval
    var roomID: String?
    var isDemo: Bool?
}

struct FriendMessage: Identifiable, Codable, Hashable {
    var id: UUID
    var friendID: UUID
    var text: String
    var sentAt: Date
    var isMine: Bool
}

@MainActor
final class FriendStore: ObservableObject {
    @Published var friends: [FriendRecord] = [] { didSet { persist(friends, key: friendsKey) } }
    @Published var messages: [FriendMessage] = [] { didSet { persist(messages, key: messagesKey) } }
    @Published var myCode: String
    @Published var errorMessage = ""
    private let friendsKey = "studiquoFriends"
    private let messagesKey = "studiquoFriendMessages"
    private static let codePattern = /^[A-Z0-9]{6,32}$/
    private static let maximumFriends = 500
    private static let maximumMessages = 10_000
    private static let maximumMessageLength = 2_000

    init() {
        myCode = UserDefaults.standard.string(forKey: "studiquoFriendCode") ?? "準備中"
        if let data = UserDefaults.standard.data(forKey: friendsKey) {
            friends = (try? JSONDecoder().decode([FriendRecord].self, from: data)) ?? []
        }
        if let data = UserDefaults.standard.data(forKey: messagesKey) {
            messages = (try? JSONDecoder().decode([FriendMessage].self, from: data)) ?? []
        }
        Task { await refresh() }
    }

    var invitationURL: URL { URL(string: "studiquo://friend/add?code=\(myCode)")! }

    func refresh() async {
        do {
            let name = UserDefaults.standard.string(forKey: "profileName") ?? "Studiquoユーザー"
            let identity = try await FriendChatService.register(name: name)
            myCode = identity.code
            UserDefaults.standard.set(myCode, forKey: "studiquoFriendCode")
            let remote = try await FriendChatService.friends()
            let demos = friends.filter { $0.isDemo == true }
            friends = demos + remote.map {
                FriendRecord(id: UUID(), name: $0.name, code: $0.code, todayStudySeconds: 0, roomID: $0.roomID, isDemo: false)
            }
            errorMessage = ""
        } catch {
            errorMessage = "フレンドサーバーに接続できません。"
        }
    }

    func add(code raw: String) {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.wholeMatch(of: Self.codePattern) != nil,
              code != myCode,
              friends.count < Self.maximumFriends,
              !friends.contains(where: { $0.code == code }) else { return }
        Task {
            do {
                let friend = try await FriendChatService.add(code: code)
                friends.append(FriendRecord(id: UUID(), name: friend.name, code: friend.code, todayStudySeconds: 0, roomID: friend.roomID, isDemo: false))
                errorMessage = ""
            } catch {
                errorMessage = "フレンドコードが見つかりません。"
            }
        }
    }

    func addDemoFriend() {
        guard !friends.contains(where: { $0.isDemo == true }) else { return }
        friends.append(FriendRecord(id: UUID(), name: "デモフレンド", code: "DEMO123", todayStudySeconds: 3_600, roomID: nil, isDemo: true))
    }

    func add(url: URL) {
        guard url.scheme?.lowercased() == "studiquo",
              url.host?.lowercased() == "friend",
              url.path == "/add",
              let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value else { return }
        add(code: code)
    }

    func send(_ text: String, to friend: FriendRecord) {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard friends.contains(where: { $0.id == friend.id }), !cleaned.isEmpty else { return }
        messages.append(FriendMessage(
            id: UUID(), friendID: friend.id,
            text: String(cleaned.prefix(Self.maximumMessageLength)), sentAt: Date(), isMine: true
        ))
        if messages.count > Self.maximumMessages {
            messages.removeFirst(messages.count - Self.maximumMessages)
        }
        if friend.isDemo == true {
            Task {
                try? await Task.sleep(for: .seconds(1))
                messages.append(FriendMessage(id: UUID(), friendID: friend.id, text: "メッセージを受け取りました！これはデモ返信です。", sentAt: Date(), isMine: false))
            }
        } else if let roomID = friend.roomID {
            Task {
                do { _ = try await FriendChatService.send(cleaned, roomID: roomID) }
                catch { errorMessage = "メッセージを送信できませんでした。" }
            }
        }
    }

    private func persist<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

}

struct FriendsHomeView: View {
    @ObservedObject var store: FriendStore
    let myStudySeconds: TimeInterval
    @State private var showsAdd = false

    var body: some View {
        NavigationStack {
            List {
                Section("今日の勉強時間") {
                    LabeledContent("あなた", value: duration(myStudySeconds))
                }
                Section("フレンド") {
                    ForEach(store.friends) { friend in
                        NavigationLink {
                            FriendChatView(friend: friend, store: store)
                        } label: {
                            HStack {
                                Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint)
                                VStack(alignment: .leading) {
                                    Text(friend.name)
                                    Text("今日 \(duration(friend.todayStudySeconds))").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    if store.friends.isEmpty {
                        ContentUnavailableView("フレンドがいません", systemImage: "person.2", description: Text("右上の追加ボタンから招待できます。"))
                    }
                }
            }
            .navigationTitle("フレンド")
            .toolbar { ToolbarItem(placement: .primaryAction) { Button { showsAdd = true } label: { Image(systemName: "person.badge.plus") } } }
            .sheet(isPresented: $showsAdd) { AddFriendView(store: store) }
        }
    }

    private func duration(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds) / 60
        return minutes >= 60 ? "\(minutes / 60)時間\(minutes % 60)分" : "\(minutes)分"
    }
}

private struct AddFriendView: View {
    @ObservedObject var store: FriendStore
    @Environment(\.dismiss) private var dismiss
    @State private var code = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("あなたのQRコード") {
                    QRCodeView(text: store.invitationURL.absoluteString).frame(width: 210, height: 210).frame(maxWidth: .infinity)
                    Text(store.myCode).font(.title3.monospaced().bold()).frame(maxWidth: .infinity)
                    ShareLink(item: store.invitationURL, subject: Text("Studiquoでフレンドになろう"), message: Text("このリンクからStudiquoのフレンドに追加できます。")) {
                        Label("LINE・Snapchatなどで共有", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                }
                Section("コードで追加") {
                    TextField("フレンドコード", text: $code)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .onChange(of: code) { _, value in
                            code = String(value.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }.prefix(32))
                        }
                    Button("追加") { store.add(code: code); dismiss() }.disabled(code.isEmpty)
                }
                Section {
                    NavigationLink { QRScannerView { value in store.add(code: value); dismiss() } } label: {
                        Label("QRコードを読み取る", systemImage: "qrcode.viewfinder")
                    }
                }
                Section("1台で画面を確認") {
                    Button { store.addDemoFriend(); dismiss() } label: {
                        Label("デモ用フレンドを追加", systemImage: "person.crop.circle.badge.plus")
                    }
                }
            }
            .navigationTitle("フレンドを追加")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("閉じる") { dismiss() } } }
        }
    }
}

private struct FriendChatView: View {
    let friend: FriendRecord
    @ObservedObject var store: FriendStore
    @State private var draft = ""

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(store.messages.filter { $0.friendID == friend.id }) { message in
                        Text(message.text).padding(10).background(message.isMine ? Color.accentColor : Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
                            .foregroundStyle(message.isMine ? .white : .primary)
                            .frame(maxWidth: .infinity, alignment: message.isMine ? .trailing : .leading)
                    }
                }.padding()
            }
            Divider()
            HStack {
                TextField("メッセージ", text: $draft, axis: .vertical).textFieldStyle(.roundedBorder)
                Button { store.send(draft, to: friend); draft = "" } label: { Image(systemName: "arrow.up.circle.fill").font(.title2) }.disabled(draft.isEmpty)
            }.padding()
        }
        .navigationTitle(friend.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard friend.isDemo != true, let roomID = friend.roomID else { return }
            while !Task.isCancelled {
                if let remote = try? await FriendChatService.messages(roomID: roomID), !remote.isEmpty {
                    store.messages.removeAll { $0.friendID == friend.id }
                    store.messages.append(contentsOf: remote.map {
                        FriendMessage(id: UUID(), friendID: friend.id, text: $0.text, sentAt: Date(timeIntervalSince1970: $0.sentAt / 1_000), isMine: $0.isMine)
                    })
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }
}

private struct QRCodeView: View {
    let text: String
    var body: some View {
        if let image = makeImage() { Image(uiImage: image).interpolation(.none).resizable().scaledToFit() }
    }
    private func makeImage() -> UIImage? {
        let filter = CIFilter.qrCodeGenerator(); filter.message = Data(text.utf8); filter.correctionLevel = "M"
        guard let output = filter.outputImage else { return nil }
        let context = CIContext(); guard let cgImage = context.createCGImage(output.transformed(by: .init(scaleX: 12, y: 12)), from: output.transformed(by: .init(scaleX: 12, y: 12)).extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }
}
