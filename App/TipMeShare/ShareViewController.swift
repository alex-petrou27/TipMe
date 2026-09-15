import UIKit
import SwiftUI
import UniformTypeIdentifiers
import TipMeCore

/// Entry point for the OS share sheet.
///
/// Renders as a sheet over the host app (TikTok, Instagram, Safari) rather than
/// switching apps — that is the native behaviour of a
/// `com.apple.share-services` extension, and it is the whole product.
///
/// ## Constraints this class is shaped by
///
/// An iOS share extension runs under a hard jetsam memory cap — far tighter
/// than an app — and the OS will kill it without warning if it gets slow or
/// greedy. Three consequences:
///
/// 1. Work starts immediately on appearance. There is no splash, no warm-up.
/// 2. The wallet opens a working directory the host app has already synced
///    (shared App Group), so this process does an incremental sync rather than
///    a cold one. See docs/SHARE_EXTENSION.md.
/// 3. `completeRequest` is called on every exit path, including failures. An
///    extension that forgets this leaves the host app's share sheet wedged.
final class ShareViewController: UIViewController {

    private var hostingController: UIHostingController<AnyView>?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear

        do {
            let services = try TipMeServices.make(origin: .shareExtension)
            guard services.isWalletReady else {
                return present(message: "Open TipMe once to set up your wallet, then try again.")
            }
            let viewModel = TipSheetViewModel(services: services,
                                              origin: .shareExtension,
                                              onFinish: { [weak self] in self?.finish() })
            embed(AnyView(TipSheetView(viewModel: viewModel)))
            Task { await viewModel.start(with: await loadSharedPayload()) }
        } catch {
            // Configuration failures are a developer error, not a user error,
            // but the user still has to get out of the sheet gracefully.
            present(message: "TipMe isn't configured correctly. \(error)")
        }
    }

    // MARK: - Reading what was shared

    /// Pulls URLs and text out of the extension context.
    ///
    /// Both are collected because the platforms are inconsistent: Safari and
    /// Chrome hand over a clean `public.url`, while TikTok frequently provides
    /// `public.plain-text` with the link embedded in marketing copy. Assuming
    /// only the well-formed shape would drop a large share of real TikTok
    /// shares on the floor.
    private func loadSharedPayload() async -> SharedPayload {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return SharedPayload(urls: [], text: [])
        }

        var urls: [URL] = []
        var text: [String] = []

        for item in items {
            if let attributed = item.attributedContentText?.string, !attributed.isEmpty {
                text.append(attributed)
            }
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    urls.append(url)
                } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                          let string = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    text.append(string)
                }
            }
        }

        return SharedPayload(urls: urls, text: text)
    }

    // MARK: - Presentation

    private func embed(_ content: AnyView) {
        let controller = UIHostingController(rootView: content)
        controller.view.backgroundColor = .clear
        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor)
        ])
        controller.didMove(toParent: self)
        hostingController = controller
    }

    private func present(message: String) {
        embed(AnyView(ShareBlockedView(message: message) { [weak self] in self?.finish() }))
    }

    /// Returns control to the host app. Called on every exit path — success,
    /// failure, and cancel — so the user lands back in their feed.
    private func finish() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

/// Shown when we cannot proceed at all (no wallet, bad configuration).
struct ShareBlockedView: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "bolt.slash.fill")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .multilineTextAlignment(.center)
                .font(.callout)
            Button("Close", action: onDismiss)
                .buttonStyle(.borderedProminent)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
    }
}

/// `NSItemProvider.loadItem` is callback-based; this keeps the call sites above
/// readable without pulling in a helper library.
private extension NSItemProvider {
    func loadItem(forTypeIdentifier identifier: String) async throws -> NSSecureCoding? {
        try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: item)
                }
            }
        }
    }
}
