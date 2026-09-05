import AuthenticationServices
import GoogleSignInSwift
import SwiftUI

struct AccountGateView: View {
    @StateObject private var authentication = AuthenticationStore()

    var body: some View {
        Group {
            switch authentication.state {
            case .needsLogin:
                LoginView()
            case .verifyingEmail:
                EmailVerificationView()
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

private struct LoginView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var email = ""
    @State private var password = ""
    @State private var showsReset = false
    @State private var showsCreateAccount = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()
                Image(systemName: "book.pages.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("Studiquo").font(.largeTitle.bold())
                    Text("おかえりなさい").foregroundStyle(.secondary)
                }
                VStack(spacing: 14) {
                    TextField("メールアドレス", text: $email)
                        .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .accountFieldStyle()
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                        .accountFieldStyle()
                    if !authentication.errorMessage.isEmpty {
                        Text(authentication.errorMessage).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("ログイン") { Task { _ = await authentication.login(email: email, password: password) } }
                        .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(email.isEmpty || password.isEmpty || authentication.isLoginBusy)
                    Button {
                        Task { await authentication.loginWithPasskey() }
                    } label: {
                        Label("パスキーでログイン", systemImage: "person.badge.key.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(authentication.isPasskeyBusy)
                    SignInWithAppleButton(.signIn) { request in
                        request.requestedScopes = [.email]
                    } onCompletion: { result in
                        Task { await authentication.loginWithApple(result: result) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .disabled(authentication.isAppleSignInBusy)
                    GoogleSignInButton {
                        Task { await authentication.loginWithGoogle() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .disabled(authentication.isGoogleSignInBusy)
                    Button("パスワードを忘れた場合") { showsReset = true }.font(.subheadline)
                    Button("アカウントをお持ちでない方はこちら") { showsCreateAccount = true }.font(.subheadline)
                }
                .frame(maxWidth: 480)
                Spacer()
            }
            .padding(32)
            .navigationDestination(isPresented: $showsReset) { CreateAccountView(isPasswordReset: true) }
            .navigationDestination(isPresented: $showsCreateAccount) { CreateAccountView() }
        }
    }
}

private struct CreateAccountView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @Environment(\.dismiss) private var dismiss
    var isPasswordReset = false
    @State private var email = ""
    @State private var password = ""

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: isPasswordReset ? "key.fill" : "person.crop.circle.badge.plus")
                .font(.system(size: 54))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text(isPasswordReset ? "パスワードを再設定" : "アカウントを作成").font(.largeTitle.bold())
                Text(isPasswordReset ? "登録済みのメールアドレスと新しいパスワードを入力" : "学習を始めるためのアカウントを作成").foregroundStyle(.secondary)
            }
            VStack(spacing: 14) {
                TextField("メールアドレス", text: $email)
                    .textContentType(.emailAddress).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    .accountFieldStyle()
                SecureField(isPasswordReset ? "新しいパスワード（8文字以上）" : "パスワード（8文字以上）", text: $password)
                    .textContentType(.newPassword)
                    .accountFieldStyle()
                if !authentication.errorMessage.isEmpty {
                    Text(authentication.errorMessage).font(.footnote).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("確認コードを送信") {
                    Task { _ = await authentication.beginAccountCreation(email: email, password: password) }
                }
                .buttonStyle(.borderedProminent).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(email.isEmpty || password.isEmpty || authentication.isEmailVerifyBusy)
            }
            .frame(maxWidth: 480)
            Spacer()
        }
        .padding(32)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("キャンセル") { dismiss() } } }
    }
}

private struct EmailVerificationView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var code = ""
    @State private var didResend = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                Image(systemName: "envelope.badge.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(.tint)
                VStack(spacing: 8) {
                    Text("メールアドレスを確認").font(.title2.bold())
                    Text("\(authentication.pendingSignUpEmail) に届いた6桁のコードを入力してください。")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                TextField("確認コード", text: $code)
                    .keyboardType(.numberPad)
                    .multilineTextAlignment(.center)
                    .font(.title2.monospacedDigit())
                    .accountFieldStyle()
                    .frame(maxWidth: 240)
                    .onChange(of: code) { _, newValue in
                        code = String(newValue.filter(\.isNumber).prefix(6))
                    }
                if !authentication.errorMessage.isEmpty {
                    Text(authentication.errorMessage).font(.footnote).foregroundStyle(.red)
                } else if didResend {
                    Text("コードを再送信しました。").font(.footnote).foregroundStyle(.secondary)
                }
                Button("確認") {
                    Task {
                        didResend = false
                        if await authentication.confirmEmailVerification(code: code) { code = "" }
                    }
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(code.count != 6 || authentication.isEmailVerifyBusy)
                Button("コードを再送信") {
                    Task {
                        didResend = await authentication.requestEmailVerification()
                    }
                }
                .font(.subheadline)
                .disabled(authentication.isEmailVerifyBusy)
                Button("キャンセル", role: .destructive) { authentication.cancelAccountCreation() }
                    .font(.subheadline)
                Spacer()
            }
            .padding(32)
            .frame(maxWidth: 480)
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
