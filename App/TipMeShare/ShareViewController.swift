import UIKit
import SwiftUI
import UniformTypeIdentifiers
import LinkPresentation
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
            guard services.isSignedIn else {
                return present(message: "Open TipMe and sign in, then try again.")
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

    // MARK: - Matching the system's dimming above the sheet

    /// The system darkens everything except the strip above our sheet, which is
    /// what makes the top of the screen look lighter than the rest. Its own
    /// dimming can't be removed from here, so this darkens that strip by the
    /// same amount (measured from a real Instagram share: ~40%) to even it out.
    private let topDimStrip: UIView = {
        let strip = UIView()
        strip.backgroundColor = UIColor.black.withAlphaComponent(0.4)
        strip.isUserInteractionEnabled = false
        strip.alpha = 0
        return strip
    }()

    /// Estimated from a real screenshot of the system's dimming: the curve is
    /// continuous, reaches ~38pt down the edge, which fits a ~26pt radius.
    private static let systemSheetCornerRadius: CGFloat = 26
    private let stripMask = CAShapeLayer()

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard let window = view.window else { return }
        if topDimStrip.superview !== window { window.addSubview(topDimStrip) }
        let sheetTop = view.convert(view.bounds, to: window).minY
        // The system's dimming has rounded top corners, so the strip also
        // fills the small wedges outside them -- everything above the sheet
        // plus the corner areas, but not the sheet's own (already dimmed) body.
        let radius = Self.systemSheetCornerRadius
        let width = window.bounds.width
        // A continuous ("squircle") corner runs about 1.6x its radius along each
        // edge, so the strip reaches that far below the sheet's top.
        topDimStrip.frame = CGRect(x: 0, y: 0, width: width, height: max(0, sheetTop) + radius * 1.7)
        let path = UIBezierPath(rect: topDimStrip.bounds)
        let sheetShape = RoundedRectangle(cornerRadius: radius, style: .continuous)
            .path(in: CGRect(x: 0, y: sheetTop, width: width, height: radius * 6))
        path.append(UIBezierPath(cgPath: sheetShape.cgPath))
        stripMask.frame = topDimStrip.bounds
        stripMask.path = path.cgPath
        stripMask.fillRule = .evenOdd
        topDimStrip.layer.mask = stripMask
        window.bringSubviewToFront(topDimStrip)
        if topDimStrip.alpha == 0 {
            UIView.animate(withDuration: 0.25) { self.topDimStrip.alpha = 1 }
        }
    }

    // MARK: - No dimming behind the sheet

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        removeBackdropDimming()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        removeBackdropDimming()
    }

    /// Asks for the host app to show through undimmed above the sheet. Whether
    /// the system honours either request from inside an extension is up to iOS:
    /// the dimming view is drawn by the presentation, not by this process.
    private func removeBackdropDimming() {
        if let sheet = sheetPresentationController {
            sheet.detents = [.medium()]
            sheet.largestUndimmedDetentIdentifier = .medium
        }

        // Everything above us in this process, and every dimming/shadow/backdrop
        // sibling next to it. Only views in this process's own window can be
        // reached; anything the host draws is out of bounds.
        var child: UIView = view
        var ancestor = view.superview
        while let current = ancestor {
            current.backgroundColor = .clear
            for sibling in current.subviews where sibling !== child {
                let name = String(describing: type(of: sibling))
                if name.localizedCaseInsensitiveContains("dimming")
                    || name.localizedCaseInsensitiveContains("backdrop")
                    || name.localizedCaseInsensitiveContains("shadow") {
                    sibling.alpha = 0
                    sibling.backgroundColor = .clear
                }
            }
            child = current
            ancestor = current.superview
        }
    }

    // MARK: - Reading what was shared

    /// Pulls URLs, text and **titles** out of the extension context.
    ///
    /// All three are collected because the platforms are inconsistent:
    ///
    /// - Safari and Chrome hand over a clean `public.url`.
    /// - TikTok frequently provides `public.plain-text` with the link embedded
    ///   in marketing copy, so assuming the well-formed shape would drop a
    ///   large share of real TikTok shares on the floor.
    /// - **Instagram puts the creator in the title.** A Reel's URL is
    ///   shortcode-keyed and names nobody, but the share sheet header reads
    ///   "Reel from @username", and that string arrives here as the item's
    ///   `attributedTitle` or inside its `LPLinkMetadata`. It is the only place
    ///   the handle appears, so failing to read it is the difference between
    ///   identifying a Reel's creator and sending the user to manual entry.
    private func loadSharedPayload() async -> SharedPayload {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem] else {
            return .empty
        }

        var urls: [URL] = []
        var text: [String] = []
        var titles: [String] = []

        for item in items {
            if let title = item.attributedTitle?.string, !title.isEmpty {
                titles.append(title)
            }
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

                // Link metadata carries the title the share sheet header shows.
                if let metadata = await provider.loadLinkMetadata() {
                    if let title = metadata.title, !title.isEmpty { titles.append(title) }
                    if let url = metadata.originalURL { urls.append(url) }
                }
            }
        }

        return SharedPayload(urls: urls, text: text, titles: titles)
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
    /// Reads `LPLinkMetadata` if the provider carries any.
    ///
    /// Returns `nil` rather than throwing: link metadata is a bonus source for
    /// the creator's handle, and a share with none is entirely normal.
    func loadLinkMetadata() async -> LPLinkMetadata? {
        let identifier = "com.apple.linkpresentation.metadata"
        guard hasItemConformingToTypeIdentifier(identifier) else { return nil }
        return try? await loadItem(forTypeIdentifier: identifier) as? LPLinkMetadata
    }

    func loadItem(forTypeIdentifier identifier: String) async throws -> NSSecureCoding? {
        /// `NSItemProvider`'s completion handler is `@Sendable` on newer SDKs,
        /// but `NSSecureCoding` itself was never audited as `Sendable`. This
        /// is a one-shot handoff from that callback into the awaiting task —
        /// never shared or mutated concurrently — which is exactly the case
        /// `@unchecked Sendable` exists for.
        struct UncheckedBox: @unchecked Sendable {
            let value: NSSecureCoding?
        }
        let box: UncheckedBox = try await withCheckedThrowingContinuation { continuation in
            loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: UncheckedBox(value: item))
                }
            }
        }
        return box.value
    }
}
