import AuthenticationServices
import GoogleSignInSwift
import SwiftUI
import SwiftData

enum AccountFlowLogic {
    static func canSubmitCredentials(email: String, password: String, isBusy: Bool) -> Bool {
        !email.isEmpty && !password.isEmpty && !isBusy
    }

    static func verificationCode(from input: String) -> String {
        String(input.filter(\.isNumber).prefix(6))
    }

    static func nextOnboardingStep(current: Int, occupation: String) -> Int? {
        if current == 0 { return occupation == "大学生" ? 1 : 2 }
        if current == 1 { return 2 }
        return nil
    }
}

struct AccountGateView: View {
    @StateObject private var authentication = AuthenticationStore()
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var subscriptionStore: SubscriptionStore
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(AccountDeletionWorkflow.pendingLocalDeletionKey) private var cleanupPending = false
    @State private var cleanupError = ""

    var body: some View {
        Group {
            if cleanupPending {
                VStack(spacing: 20) {
                    Text("この端末のデータを削除しています")
                    Text("サーバーが削除依頼を受け付けました。外部サービスの削除は順次処理されます。")
                        .font(.footnote).foregroundStyle(.secondary)
                    if !cleanupError.isEmpty {
                        Text(cleanupError).foregroundStyle(Theme.Palette.danger)
                        Button("もう一度削除する") { Task { await finishLocalCleanup() } }
                    } else {
                        ProgressView()
                    }
                }.padding()
            } else {
            switch authentication.state {
            case .needsLogin:
                LoginView()
            case .verifyingEmail:
                EmailVerificationView()
            case .onboarding:
                OnboardingView()
            case .authenticated:
                ContentView().modifier(PaywallGate())
            }
            }
        }
        .overlay {
            // Covers everything until the account has a passkey.
            if authentication.needsPasskeyEnrollment && !cleanupPending
                && (authentication.state == .authenticated || authentication.state == .onboarding) {
                PasskeyEnrollmentView()
                    .transition(.opacity)
            }
        }
        .environmentObject(authentication)
        .animation(.easeInOut(duration: 0.2), value: authentication.state)
        .task(id: authentication.state) {
            guard !cleanupPending, authentication.state == .authenticated else { return }
            await PushNotificationRegistration.refreshIfAuthorized()
        }
        .task(id: authentication.state) {
            guard !cleanupPending else { return }
            await authentication.checkPasskeyRequirement()
        }
        // The Worker can only answer "which plan?" once there is a session.
        .task(id: authentication.state) {
            guard !cleanupPending else { return }
            guard authentication.state == .authenticated else {
                subscriptionStore.resetForSignOut()
                return
            }
            // The store waits for RevenueCat to know who this is before asking
            // what they own, on every path (launch, sign-in, foreground).
            subscriptionStore.waitForIdentity = { await authentication.waitForRevenueCatIdentity() }
            await subscriptionStore.refresh()
        }
        // A trial that lapsed, or a purchase made on another device, shows up
        // when the app comes back to the front.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active, !cleanupPending, authentication.state == .authenticated else { return }
            Task { await subscriptionStore.refreshIfStale() }
        }
        .task(id: cleanupPending) {
            if cleanupPending { await finishLocalCleanup() }
        }
    }

    @MainActor
    private func finishLocalCleanup() async {
        cleanupError = ""
        do {
            try AccountDataEraser.eraseAll(from: modelContext)
            try AccountFileEraser.erase()
            AccountLocalPreferences.clear()
            authentication.finishAccountDeletion()
            authentication.clearLocalDeletionPending()
        } catch {
            cleanupError = "端末のデータを削除できませんでした。もう一度お試しください。"
        }
    }
}

struct LoginView: View {
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
                        // Lets iOS offer saved credentials in the keyboard's
                        // AutoFill area while this field is being edited.
                        .textContentType(.username).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                        .accountFieldStyle()
                    SecureField("パスワード", text: $password)
                        .textContentType(.password)
                        .accountFieldStyle()
                    if !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Button {
                            Task { _ = await authentication.loginWithPasskey() }
                        } label: {
                            Label("パスキーを使用", systemImage: "key.fill")
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .disabled(authentication.isSignInBusy)
                    }
                    if !authentication.errorMessage.isEmpty {
                        Text(authentication.errorMessage).font(.footnote).foregroundStyle(Theme.Palette.danger).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Button("ログイン") { Task { _ = await authentication.login(email: email, password: password) } }
                        .buttonStyle(.themePrimary).controlSize(.large).frame(maxWidth: .infinity)
                        .disabled(!AccountFlowLogic.canSubmitCredentials(
                            email: email, password: password, isBusy: authentication.isSignInBusy
                        ))
                    SignInWithAppleButton(.signIn) { request in
                        // The scopes, and a nonce whose hash Apple puts in the ID token.
                        AppleSignInService.prepare(request)
                    } onCompletion: { result in
                        Task { await authentication.loginWithApple(result: result) }
                    }
                    .signInWithAppleButtonStyle(.black)
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)
                    .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
                    .disabled(authentication.isSignInBusy)
                    GoogleSignInButton {
                        Task { await authentication.loginWithGoogle() }
                    }
                    .frame(maxWidth: .infinity, minHeight: 50, maxHeight: 50)
                    .disabled(authentication.isSignInBusy)
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
                    Text(authentication.errorMessage).font(.footnote).foregroundStyle(Theme.Palette.danger).frame(maxWidth: .infinity, alignment: .leading)
                }
                Button("確認コードを送信") {
                    Task { _ = await authentication.beginAccountCreation(email: email, password: password) }
                }
                .buttonStyle(.themePrimary).controlSize(.large).frame(maxWidth: .infinity)
                .disabled(!AccountFlowLogic.canSubmitCredentials(
                    email: email, password: password, isBusy: authentication.isEmailVerifyBusy
                ))
            }
            .frame(maxWidth: 480)
            Spacer()
        }
        .padding(32)
    }
}

private struct EmailVerificationView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var code = ""
    @State private var didResend = false
    @State private var newPassword = ""

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
                        code = AccountFlowLogic.verificationCode(from: newValue)
                    }
                if !authentication.errorMessage.isEmpty {
                    Text(authentication.errorMessage).font(.footnote).foregroundStyle(Theme.Palette.danger)
                } else if didResend {
                    Text("コードを再送信しました。").font(.footnote).foregroundStyle(.secondary)
                }
                if authentication.needsNewPassword {
                    // The server refused the password (it appears in a known
                    // breach) but kept the code valid: ask for another one here.
                    SecureField("新しいパスワード(8文字以上)", text: $newPassword)
                        .textContentType(.newPassword)
                        .accountFieldStyle()
                        .frame(maxWidth: 320)
                    Button("パスワードを変更して続ける") {
                        Task {
                            didResend = false
                            if await authentication.changePendingPassword(newPassword, code: code) {
                                code = ""
                                newPassword = ""
                            }
                        }
                    }
                    .buttonStyle(.themePrimary)
                    .controlSize(.large)
                    .disabled(code.count != 6 || newPassword.count < 8 || authentication.isEmailVerifyBusy)
                } else {
                    Button("確認") {
                        Task {
                            didResend = false
                            if await authentication.confirmEmailVerification(code: code) { code = "" }
                        }
                    }
                    .buttonStyle(.themePrimary)
                    .controlSize(.large)
                    .disabled(code.count != 6 || authentication.isEmailVerifyBusy)
                }
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
        padding(14).background(Theme.Palette.surface, in: RoundedRectangle(cornerRadius: Theme.Radius.s, style: .continuous))
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
                .themeScreenBackground()
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
        if let next = AccountFlowLogic.nextOnboardingStep(current: step, occupation: occupation) {
            step = next
        } else {
            authentication.finishOnboarding()
        }
    }
}


/// Asked of every signed-in account that has no passkey yet. A password or an
/// e-mailed code can be handed over to a look-alike site that relays it; a
/// passkey is checked by the device against the real site's domain and cannot.
/// Face ID / Touch ID is what confirms it is the owner.
struct PasskeyEnrollmentView: View {
    @EnvironmentObject private var authentication: AuthenticationStore
    @State private var emailCode = ""

    var body: some View {
        ZStack {
            Theme.Palette.canvas.ignoresSafeArea()
            VStack(spacing: 20) {
                Image(systemName: "person.badge.key.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.tint)
                Text("パスキーを設定してください")
                    .font(.title2.bold())
                Text("偽のログイン画面にパスワードやコードを入力させて、アカウントを乗っ取る手口があります。パスキーなら、Face IDまたはTouch IDだけでログインでき、偽のサイトでは使えません。")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                Text("設定すると、次回からはパスキーでのみログインできます(パスワード、メールのコード、Apple、Googleでは入れなくなります)。最初の設定では、メールに届くコードで本人確認をします。iCloudキーチェーンがオンになっている必要があります。")
                    .font(.footnote)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 480)
                if !authentication.errorMessage.isEmpty {
                    Text(authentication.errorMessage)
                        .font(.footnote)
                        .foregroundStyle(Theme.Palette.danger)
                        .multilineTextAlignment(.center)
                }
                if authentication.passkeyNeedsEmailCode {
                    Text("本人確認のため、\(authentication.email)にコードを送りました。コードを入力してください。")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 480)
                    TextField("6桁のコード", text: $emailCode)
                        .keyboardType(.numberPad)
                        .textContentType(.oneTimeCode)
                        .multilineTextAlignment(.center)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 240)
                        .accessibilityIdentifier("passkey-email-code")
                    Button {
                        Task { _ = await authentication.confirmPasskeyEmailCode(emailCode) }
                    } label: {
                        Label("確認してパスキーを設定する", systemImage: "faceid")
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.themePrimary)
                    .controlSize(.large)
                    .disabled(authentication.isPasskeyBusy || emailCode.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityIdentifier("passkey-confirm-code")
                    Button("コードを再送する") { Task { await authentication.sendPasskeyEmailCode() } }
                        .disabled(authentication.isPasskeyBusy)
                        .accessibilityIdentifier("passkey-resend-code")
                } else {
                    Button {
                        Task { _ = await authentication.addPasskey() }
                    } label: {
                        Label("パスキーを設定する", systemImage: "faceid")
                            .frame(maxWidth: 320)
                    }
                    .buttonStyle(.themePrimary)
                    .controlSize(.large)
                    .disabled(authentication.isPasskeyBusy)
                    .accessibilityIdentifier("passkey-enroll")
                }
                if authentication.passkeyEnrollmentFailed {
                    Button("今回はスキップ") { authentication.skipPasskeyEnrollmentForNow() }
                        .accessibilityIdentifier("passkey-skip")
                }
                Button("ログアウト", role: .destructive) { authentication.logout() }
            }
            .padding(32)
            .onAppear { authentication.errorMessage = "" }
        }
    }
}
