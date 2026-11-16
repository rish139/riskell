import AppKit
import SwiftUI
import Combine
import RiskellKit

/// A translucent veil over the main screen while edit mode is on, so the bars and the editor stand out from the windows behind them.
/// It sits just under the bars' level (above normal windows, below the bars and the settings panel) and lets every click through.
/// Created on the first edit, ordered out when editing ends: nothing is drawn or observed at rest beyond one subscription.
final class EditBackdrop {
    static let shared = EditBackdrop()
    private var window: NSPanel?
    private var watch: AnyCancellable?

    /// Follows `Config.shared.editing` (call once at launch).
    func start() {
        watch = Config.shared.$editing.sink { [weak self] on in on ? self?.show() : self?.hide() }
    }

    private func show() {
        let f = Display.current.frame
        if window == nil {
            let w = panel(f, hosting(Veil()), above: 2)      // above: 2 -> barBaseLevel - 1
            w.ignoresMouseEvents = true
            Sky.pin([w])
            window = w
        }
        guard let p = window else { return }
        p.setFrame(f, display: true)
        p.alphaValue = 0
        p.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { $0.duration = 0.15; p.animator().alphaValue = 1 }
    }

    private func hide() {
        guard let p = window, p.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15; p.animator().alphaValue = 0 }, completionHandler: {
            if !Config.shared.editing { p.orderOut(nil) }      // a quick re-open during the fade keeps the veil up
        })
    }

    /// The veil itself: the theme's text colour at low opacity (light on a dark theme, dark on a light one).
    private struct Veil: View {
        var body: some View { Rectangle().fill(Pal.text1.opacity(0.16)).ignoresSafeArea() }
    }
}
