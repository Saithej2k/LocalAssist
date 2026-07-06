import UIKit
import UniformTypeIdentifiers

/// Capture from anywhere: select text in Mail/Safari/Notes → Share →
/// LocalAssist. The text is appended to the app-group inbox file and the app
/// drains it into the capture box on next open. Nothing is uploaded — the
/// extension writes one string to shared local storage and closes.
/// A file, not group UserDefaults: touching a group preferences suite makes
/// cfprefsd log a kCFPreferencesAnyUser complaint on device. The path must
/// match `RunHistoryStore.pendingCaptureFileURL` in the app.
final class ShareViewController: UIViewController {
    private static let appGroupIdentifier = "group.com.saithej.localassist"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground

        let label = UILabel()
        label.text = "Captured to LocalAssist"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textAlignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let icon = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))
        icon.tintColor = .systemGreen
        icon.contentMode = .scaleAspectFit
        icon.translatesAutoresizingMaskIntoConstraints = false

        view.addSubview(icon)
        view.addSubview(label)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: -24),
            icon.widthAnchor.constraint(equalToConstant: 44),
            icon.heightAnchor.constraint(equalToConstant: 44),
            label.topAnchor.constraint(equalTo: icon.bottomAnchor, constant: 12),
            label.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            label.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
        ])

        Task {
            await captureSharedContent()
            try? await Task.sleep(nanoseconds: 700_000_000)
            extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func captureSharedContent() async {
        var pieces: [String] = []

        for item in extensionContext?.inputItems as? [NSExtensionItem] ?? [] {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await loadString(from: provider, type: UTType.plainText) {
                    pieces.append(text)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                          let url = try? await loadURL(from: provider) {
                    pieces.append(url.absoluteString)
                }
            }
        }

        let combined = pieces.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !combined.isEmpty,
              let container = FileManager.default.containerURL(
                  forSecurityApplicationGroupIdentifier: Self.appGroupIdentifier
              )
        else {
            return
        }

        let directory = container.appendingPathComponent("LocalAssist", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fileURL = directory.appendingPathComponent("pending-capture.txt")

        let existing = (try? String(contentsOf: fileURL, encoding: .utf8)) ?? ""
        let merged = existing.isEmpty ? combined : existing + "\n" + combined
        try? merged.write(to: fileURL, atomically: true, encoding: .utf8)
    }

    private func loadString(from provider: NSItemProvider, type: UTType) async throws -> String? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: type.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(from provider: NSItemProvider) async throws -> URL? {
        try await withCheckedThrowingContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item as? URL)
                }
            }
        }
    }
}
