import SwiftUI
import AppKit

struct ChillorButtonStyle:ButtonStyle {
    func makeBody(configuration:Configuration)->some View {
        configuration.label
            .frame(minWidth:28,minHeight:28)
            .modifier(ButtonHoverFeedback(pressed:configuration.isPressed))
    }
}
struct ButtonHoverFeedback:ViewModifier {
    var pressed = false
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func body(content:Content)->some View {
        content
            .background(Color.primary.opacity(enabled ? (pressed ? 0.10:hovering ? 0.05:0):0),in:Capsule())
            .contentShape(Capsule())
            .onContinuousHover {phase in
                switch phase {case .active: hovering = true;case .ended: hovering = false}
            }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didResignKeyNotification)) {_ in hovering = false}
            .onDisappear {hovering = false}
    }
}

// Track the complete native control bounds, never just the SF Symbol pixels.
class HoverFeedbackButton:NSButton {
    var feedbackOnDarkFill = false
    private var hoverArea:NSTrackingArea?
    private var hovered = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea {removeTrackingArea(hoverArea)}
        let area = NSTrackingArea(rect:.zero,options:[.mouseEnteredAndExited,.activeInKeyWindow,.inVisibleRect],owner:self,userInfo:nil)
        addTrackingArea(area);hoverArea = area
        hovered = window?.isKeyWindow == true && bounds.contains(convert(window!.mouseLocationOutsideOfEventStream,from:nil))
        needsDisplay = true
    }
    override func mouseEntered(with event:NSEvent) {hovered = true;needsDisplay = true}
    override func mouseExited(with event:NSEvent) {hovered = false;needsDisplay = true}
    override func draw(_ dirtyRect:NSRect) {
        if isEnabled && window?.isKeyWindow == true && (hovered || isHighlighted) {
            let color:NSColor = feedbackOnDarkFill ? .textBackgroundColor:.labelColor
            color.withAlphaComponent(isHighlighted ? 0.16:feedbackOnDarkFill ? 0.12:0.05).setFill()
            NSBezierPath(ovalIn:bounds).fill()
        }
        super.draw(dirtyRect)
    }
}
