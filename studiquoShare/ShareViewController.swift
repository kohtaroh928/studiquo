import UIKit
import UniformTypeIdentifiers

/// The "studiquo" entry in the share sheet's app row.
///
/// It does the minimum: copy whatever was shared into the App Group inbox,
/// then bring studiquo to the front, where the destination picker takes over.
/// Converting a PDF into pages is far above an extension's memory limit, so
/// none of that happens here.
final class ShareViewController: UIViewController {
    private let spinner = UIActivityIndicatorView(style: .large)
    private let label = UILabel()
    private let doneButton = UIButton(type: .system)

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        buildInterface()
        showStatus("studiquoに追加しています…", busy: true)
        collectAttachments()
    }

    // MARK: Collecting

    private func collectAttachments() {
        guard let inbox = SharedInbox.sharedGroup(), let batch = inbox.makeBatch() else {
            showStatus("studiquoに追加できませんでした。アプリを一度開いてから、もう一度お試しください。", busy: false)
            return
        }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }

        let group = DispatchGroup()
        let lock = NSLock()
        var added = 0
        var failed = 0

        for provider in providers {
            guard let type = fileType(of: provider) else {
                failed += 1
                continue
            }
            group.enter()
            // The URL handed over here is deleted when this closure returns,
            // so the copy has to happen inside it.
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                let item = url.flatMap { inbox.add($0, to: batch) }
                lock.lock()
                if item != nil { added += 1 } else { failed += 1 }
                lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            inbox.discardIfEmpty(batch)
            self?.finish(added: added, failed: failed)
        }
    }

    /// The identifier to load a file under: the first registered type that is
    /// real file data (not a URL or plain-text wrapper around one).
    private func fileType(of provider: NSItemProvider) -> UTType? {
        provider.registeredContentTypes.first { $0.conforms(to: .data) && !$0.conforms(to: .url) }
    }

    // MARK: Finishing

    private func finish(added: Int, failed: Int) {
        guard added > 0 else {
            showStatus("この項目はstudiquoに取り込めません。PDF・Word・PowerPoint・画像・テキストに対応しています。", busy: false)
            return
        }
        let suffix = failed > 0 ? "(\(failed)件は追加できませんでした)" : ""
        showStatus("\(added)件を追加しました\(suffix)\nstudiquoを開いています…", busy: true)
        openHostApp { [weak self] opened in
            guard let self else { return }
            if opened {
                self.extensionContext?.completeRequest(returningItems: nil)
            } else {
                // Nothing is lost: the files wait in the inbox and the picker
                // appears the next time studiquo is opened.
                self.showStatus("\(added)件を追加しました\(suffix)\nstudiquoを開くと、保存先を選べます。", busy: false)
            }
        }
    }

    /// Share extensions have no sanctioned way to launch their app, so walk the
    /// responder chain to the host `UIApplication` and ask it to open the URL.
    /// If a system update ever stops this working, `completion(false)` leaves
    /// the student on a message instead of a dead end.
    private func openHostApp(completion: @escaping (Bool) -> Void) {
        guard let url = URL(string: "studiquo://import") else { return completion(false) }
        var responder: UIResponder? = self
        while let current = responder {
            if let application = current as? UIApplication {
                application.open(url, options: [:]) { success in
                    DispatchQueue.main.async { completion(success) }
                }
                return
            }
            responder = current.next
        }
        completion(false)
    }

    // MARK: Interface

    private func buildInterface() {
        label.numberOfLines = 0
        label.textAlignment = .center
        label.font = .preferredFont(forTextStyle: .headline)

        var configuration = UIButton.Configuration.filled()
        configuration.title = "完了"
        doneButton.configuration = configuration
        doneButton.addTarget(self, action: #selector(doneTapped), for: .touchUpInside)
        doneButton.isHidden = true

        let stack = UIStackView(arrangedSubviews: [spinner, label, doneButton])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = 20
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: view.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -32)
        ])
    }

    private func showStatus(_ text: String, busy: Bool) {
        label.text = text
        busy ? spinner.startAnimating() : spinner.stopAnimating()
        doneButton.isHidden = busy
    }

    @objc private func doneTapped() {
        extensionContext?.completeRequest(returningItems: nil)
    }
}
