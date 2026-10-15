import DroppyKit
import SwiftUI

/// What the notch prompt says and does. One prompt at a time: an event prompt (D11), "Recording a call?" (D12), or
/// the auto-stop countdown (D13). The HUD card observes this, so a ticking count never re-presents the HUD.
@MainActor final class PromptModel: ObservableObject {
    enum Kind { case event, call, ending }

    static let hudID = "eavesdroppy.prompt"

    @Published private(set) var kind: Kind?
    @Published private(set) var title = ""
    @Published private(set) var subtitle = ""
    @Published private(set) var primary = ""
    @Published private(set) var secondary = ""
    @Published private(set) var symbol = "record.circle"
    var onPrimary: () -> Void = {}
    var onSecondary: () -> Void = {}

    var active: Bool { kind != nil }

    /// The card's last line: how to take the primary action without clicking the card.
    var hint: String { kind == .ending ? "Press ⌥⌘N to keep recording" : "Press ⌥⌘N, or Record on the shelf" }

    func show(_ kind: Kind, title: String, subtitle: String, primary: String, secondary: String, symbol: String,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.primary = primary; self.secondary = secondary
        self.symbol = symbol; self.onPrimary = onPrimary; self.onSecondary = onSecondary
    }

    func update(subtitle: String) { self.subtitle = subtitle }

    func clear() { kind = nil; onPrimary = {}; onSecondary = {} }

    /// Card height for the HUD request.
    static let cardHeight: CGFloat = 70
}

/// The HUD card: glyph, title and detail on top, how to act underneath.
struct PromptCard: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        VStack(alignment: .leading, spacing: DroppySpacing.sm) {
            HStack(alignment: .top, spacing: DroppySpacing.sm) {
                Image(systemName: model.symbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(model.kind == .ending ? Color.orange : Color.red)
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: model.title).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
                    Text(verbatim: model.subtitle).font(.system(size: 11)).monospacedDigit().lineLimit(1)
                        .foregroundStyle(AdaptiveColors.notchSurfaceSecondaryText)
                }
                .accessibilityElement(children: .ignore)  // so VoiceOver reads the countdown as the value, not as new text each second
                .accessibilityLabel(model.title).accessibilityValue(model.subtitle)
                Spacer(minLength: 0)
            }
            // Buttons in the HUD card did not receive clicks in Droppy 16.0.2-nightly, so the card says
            // how to act instead, and the shortcut and the shelf's Record button carry the action.
            Text(verbatim: model.hint).font(.system(size: 11)).lineLimit(1)
                .foregroundStyle(AdaptiveColors.notchSurfaceTertiaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The strip form (a card is always requested, but a request needs both shapes): the glyph at the far left. The
/// middle of a strip is the camera housing and each wing holds a glyph, not words.
struct PromptStrip: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: model.symbol).font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}
