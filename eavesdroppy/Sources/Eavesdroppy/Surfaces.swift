import DroppyKit
import SwiftUI

// MARK: - Expanded surface: the meeting library

extension EavesdroppyDroplet: ExpandedSurfaceProviding {
    public var expandedSurfaces: [ExpandedSurfaceDescriptor] {
        // The user reads and types here (Ask, renames) with the pointer elsewhere, so the shelf must not auto-collapse.
        // Clicking outside still closes it, and browsing loses nothing.
        [ExpandedSurfaceDescriptor(id: Self.surfaceID, title: "Eavesdroppy", systemImage: "waveform",
                                   suppresses: [.shelfWidgets, .autoCollapse])]
    }

    public func makeExpandedSurfaceView(_ id: ExpandedSurfaceID, context: ExpandedSurfaceContext) -> AnyView {
        guard id == Self.surfaceID else { return AnyView(EmptyView()) }
        return AnyView(LibrarySurface(model: library))
    }

    public func expandedSurfaceSize(_ id: ExpandedSurfaceID, fitting proposal: ExpandedSurfaceSizeProposal) -> CGSize? {
        // The standard size is a 93-point strip; a browser needs a window. The host clamps to the display.
        CGSize(width: min(700, proposal.maximumSize.width), height: min(500, proposal.maximumSize.height))
    }

    public func expandedSurfaceDidDismiss(_ id: ExpandedSurfaceID, presentation dismissed: ExpandedSurfacePresentation,
                                          reason: ExpandedSurfaceDismissalReason) {
        // A delayed dismissal can arrive after the user already summoned the surface again: leave that one alone.
        if let live = host?.notchSurface.expandedState.current, live != dismissed, live.surfaceID == id { return }
        if presentation == dismissed { presentation = nil }
        library.surfaceClosed()
    }
}
