import SwiftUI

/// Explains where TipMe actually appears, because it is not where people first
/// look.
///
/// TikTok's and Instagram's share pop-ups show a row of their own choosing —
/// Repost, WhatsApp, Messenger, Telegram, SMS, Copy link. Those are hardcoded
/// first-party integrations; no third-party app can appear among them, and
/// there is no API to apply for. TipMe lives one tap further along, behind
/// **More** / **Share to…**, which is what opens the iOS system share sheet.
///
/// On first use iOS often hides new extensions behind another **More**, so
/// without this screen a new user taps Share, does not see TipMe, and
/// reasonably concludes it is broken.
struct HowToTipView: View {
    var body: some View {
        List {
            Section("On TikTok") {
                step(1, "Tap the arrow (Share) on any video.")
                step(2, "In the row of icons, swipe to the end and tap **More**.")
                step(3, "Tap **Tip via TipMe**.")
            }

            Section("On Instagram") {
                step(1, "Open a creator's profile or a story.")
                step(2, "Tap the menu, then **Share to…**.")
                step(3, "Tap **Tip via TipMe**.")
            }

            Section("If you don't see TipMe") {
                Text("The first time, iOS hides new apps at the end of the share row.")
                    .font(.callout)
                step(1, "In the share sheet, scroll the app row to the end.")
                step(2, "Tap **More**, then **Edit**.")
                step(3, "Turn on **TipMe** and drag it to the top so it's there next time.")
            }

            Section("Quicker: copy the link") {
                Text("**Copy link** is already in TikTok's and Instagram's own share row. Tap it, open TipMe, and the tip is waiting for you on the home screen.")
                    .font(.callout)
            }

            Section("Instagram posts and Reels") {
                Text("Instagram post and Reel links don't include the creator's username, so we can't identify them yet. Share their **profile** or a **story** instead — those work.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("How to tip")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text("\(number)")
                .font(.caption.weight(.bold).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: 20, height: 20)
                .background(Color.accentColor, in: Circle())
            Text(.init(text))
                .font(.callout)
        }
    }
}
