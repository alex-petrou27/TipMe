import SwiftUI
import UniformTypeIdentifiers
import TipMeCore

/// "You copied a link — tip the creator?"
///
/// Presented on the home screen when the clipboard probably holds a link. The
/// content itself only arrives when the user taps the system paste button, so
/// nothing is read behind their back.
struct PasteTipCard: View {
    let services: TipMeServices

    @State private var hasProbableLink = false
    @State private var payload: SharedPayload?
    @State private var notTippable = false

    var body: some View {
        Group {
            if hasProbableLink {
                VStack(alignment: .leading, spacing: 10) {
                    Label("You've copied a link", systemImage: "link")
                        .font(.callout.weight(.medium))
                    Text("Tip the creator without going back to the app.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    // The system paste button: the user hands over the content
                    // explicitly, so no "pasted from" banner appears and we
                    // never touch the pasteboard uninvited.
                    PasteButton(payloadType: URL.self) { urls in
                        accept(SharedPayload(urls: urls, text: []))
                    }
                    .buttonBorderShape(.capsule)

                    if notTippable {
                        Text("That link isn't a TikTok or Instagram post we recognise.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task { hasProbableLink = await ClipboardLinkDetector.containsProbableLink() }
        .sheet(item: $payload) { payload in
            TipSheetHost(services: services, payload: payload) { self.payload = nil }
        }
    }

    private func accept(_ pasted: SharedPayload) {
        guard ClipboardLinkDetector.looksTippable(pasted) else {
            notTippable = true
            return
        }
        notTippable = false
        payload = pasted
    }
}

/// Runs the same `TipSheetView` the share extension uses, so the paste path and
/// the share path cannot drift apart. Origin is `.hostApp`, which is what the
/// audit log records.
struct TipSheetHost: View {
    let services: TipMeServices
    let payload: SharedPayload
    let onFinish: () -> Void

    @StateObject private var viewModel: TipSheetViewModel

    init(services: TipMeServices, payload: SharedPayload, onFinish: @escaping () -> Void) {
        self.services = services
        self.payload = payload
        self.onFinish = onFinish
        _viewModel = StateObject(wrappedValue: TipSheetViewModel(services: services,
                                                                 origin: .hostApp,
                                                                 onFinish: onFinish))
    }

    var body: some View {
        TipSheetView(viewModel: viewModel)
            .presentationDetents([.medium, .large])
            .task { await viewModel.start(with: payload) }
    }
}

extension SharedPayload: Identifiable {
    var id: String {
        (urls.map(\.absoluteString) + text).joined(separator: "|")
    }
}
