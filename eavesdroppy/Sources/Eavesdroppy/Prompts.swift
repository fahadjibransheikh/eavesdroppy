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

    func show(_ kind: Kind, title: String, subtitle: String, primary: String, secondary: String, symbol: String,
              onPrimary: @escaping () -> Void, onSecondary: @escaping () -> Void) {
        self.kind = kind; self.title = title; self.subtitle = subtitle; self.primary = primary; self.secondary = secondary
        self.symbol = symbol; self.onPrimary = onPrimary; self.onSecondary = onSecondary
    }

    func update(subtitle: String) { self.subtitle = subtitle }

    func clear() { kind = nil; onPrimary = {}; onSecondary = {} }

    /// Card height for the HUD request.
    static let cardHeight: CGFloat = 78
}

/// The HUD card: glyph, title and detail on top, the two buttons on the right underneath.
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
                Spacer(minLength: 0)
            }
            HStack(spacing: DroppySpacing.sm) {
                Spacer(minLength: 0)
                Button(model.secondary) { model.onSecondary() }.buttonStyle(DroppyQuietButtonStyle(size: .small))
                Button(model.primary) { model.onPrimary() }.buttonStyle(DroppyAccentButtonStyle(color: model.kind == .ending ? .orange : .red, size: .small))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The strip form (a card is always requested, but a request needs both shapes): glyph at the far left, text at the far right.
struct PromptStrip: View {
    @ObservedObject var model: PromptModel

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: model.symbol).font(.system(size: DroppyLiveActivityMetrics.iconSize, weight: .semibold))
            Spacer(minLength: 0)
            Text(verbatim: model.title).font(.system(size: DroppyLiveActivityMetrics.labelFontSize, weight: .semibold)).lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .foregroundStyle(AdaptiveColors.notchSurfacePrimaryText)
    }
}
