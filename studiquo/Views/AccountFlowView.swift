import SwiftUI

struct AccountGateView: View {
    @StateObject private var authentication = AuthenticationStore()

    var body: some View {
        Group {
            switch authentication.state {
            case .needsAccount:
                AccountFormView(mode: .create)
            case .needsLogin:
                AccountFormView(mode: .login)
            case .onboarding:
                OnboardingView()
            case .authenticated:
                ContentView()
            }
        }
        .environmentObject(authentication)
        .animation(.easeInOut(duration: 0.2), value: authentication.state)
    }
}

private struct AccountFormView: View {
    enum Mode { case create, login }
    let mode: Mode
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""
    @State private var showsReset = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Studiquo").font(.largeTitle.bold())
                    Text(mode == .create ? "学習を始めるためのアカウントを作成" : "おかえりなさい")
                        .foregroundStyle(.secondary)
                }
                VStack(spacing: 14) {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .accountFieldStyle()
                    SecureField("パスワード（8文字以上）", text: $password)
                        .textContentType(mode == .create ? .newPassword : .password)
                        .accountFieldStyle()
                    if mode == .create {
                        SecureField("パスワードをもう一度入力", text: $confirmation)
                            .textContentType(.newPassword).accountFieldStyle()
                    }
                    if !authentication.errorMessage.isEmpty {
                        Text(authentication.errorMessage).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button(mode == .create ? "アカウントを作成" : "ログイン") { submit() }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(email.isEmpty || password.isEmpty || (mode == .create && confirmation.isEmpty))
                    Button {
                        Task { await authentication.loginWithPasskey() }
                    } label: {
                        Label("パスキーでログイン", systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(authentication.isPasskeyBusy)
                    if mode == .login {
                        Button("パスワードを忘れた場合") { showsReset = true }.font(.subheadline)
                    }
                }
                .frame(maxWidth: 480)
                Spacer()
            }
            .padding(32)
            .sheet(isPresented: $showsReset) { PasswordResetView() }
        }
    }

    private func submit() {
        if mode == .create {
            guard password == confirmation else {
                authentication.errorMessage = "確認用パスワードが一致しません。"
                return
            }
            _ = authentication.createAccount(email: email, password: password)
        } else {
            _ = authentication.login(email: email, password: password)
        }
    }
}

private struct PasswordResetView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @Environment(\.dismiss) private var dismiss
    @State private var email = ""
    @State private var password = ""
    @State private var confirmation = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("本人確認") {
                    TextField("登録したメールアドレス", text: $email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                }
                Section("新しいパスワード") {
                    SecureField("8文字以上", text: $password)
                    SecureField("もう一度入力", text: $confirmation)
                }
                if !authentication.errorMessage.isEmpty { Text(authentication.errorMessage).foregroundStyle(.red) }
                Button("パスワードを再設定") {
                    guard password == confirmation else {
                        authentication.errorMessage = "確認用パスワードが一致しません。"
                        return
                    }
                    if authentication.resetPassword(email: email, newPassword: password) { dismiss() }
                }
                .disabled(email.isEmpty || password.isEmpty || confirmation.isEmpty)
            }
            .navigationTitle("パスワード再設定")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
        }
    }
}

private extension View {
    func accountFieldStyle() -> some View {
        padding(14).background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct OnboardingView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @AppStorage("profileName") private var name = ""
    @AppStorage("profileOccupation") private var occupation = ""
    @State private var step = 0
    @State private var universityURL = ""
    @State private var googleURL = ""

    private let occupations = ["大学生", "高校生", "中学生", "専門学生", "社会人", "教員", "その他"]

    var body: some View {
        NavigationStack {
            Form {
                if step == 0 {
                    Section("基本情報") {
                        TextField("名前", text: $name)
                        Picker("職業・身分", selection: $occupation) {
                            Text("選択してください").tag("")
                            ForEach(occupations, id: \.self) { Text($0).tag($0) }
                        }
                    }
                } else if step == 1 && occupation == "大学生" {
                    calendarURLSection(title: "大学カレンダーを連携", detail: "大学やLMSが発行するカレンダーURLを入力してください。", text: $universityURL)
                } else {
                    calendarURLSection(title: "Googleカレンダーを連携", detail: "Googleカレンダーの非公開iCal URLを入力してください。", text: $googleURL)
                }
            }
            .navigationTitle("はじめの設定")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step > 0 { Button("スキップ") { advance() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(step == 0 ? "次へ" : "連携して次へ") { saveAndAdvance() }
                        .disabled(step == 0 ? (name.isEmpty || occupation.isEmpty) : false)
                }
            }
        }
    }

    @ViewBuilder private func calendarURLSection(title: String, detail: String, text: Binding<String>) -> some View {
        Section { SecureField("カレンダーURL", text: text).keyboardType(.URL).textInputAutocapitalization(.never) }
            header: { Text(title) } footer: { Text(detail) }
    }

    private func saveAndAdvance() {
        if step == 1 && occupation == "大学生" && !universityURL.isEmpty { UniversityCalendar.saveURL(universityURL) }
        if (step == 2 || occupation != "大学生") && !googleURL.isEmpty { GoogleCalendar.saveURL(googleURL) }
        advance()
    }

    private func advance() {
        if step == 0 { step = occupation == "大学生" ? 1 : 2 }
        else if step == 1 { step = 2 }
        else { authentication.finishOnboarding() }
    }
}
