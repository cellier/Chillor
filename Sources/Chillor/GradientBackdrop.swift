import AppKit
import SwiftUI

// The window compositor samples the live content directly. There are no
// per-scroll CPU snapshots or asynchronous bitmap replacements.
struct GradientBlurContent<Content:View>:View {
    var bottomHeight:CGFloat
    @ViewBuilder var content:()->Content
    var body:some View {
        content()
            .overlay(alignment:.top) { NativeEdgeMaterial(isTop:true).frame(height:32).allowsHitTesting(false) }
            .overlay(alignment:.bottom) { NativeEdgeMaterial(isTop:false).frame(height:bottomHeight).allowsHitTesting(false) }
    }
}
private struct NativeEdgeMaterial:NSViewRepresentable {
    var isTop:Bool
    func makeNSView(context:Context)->EdgeMaterialView {EdgeMaterialView(isTop:isTop)}
    func updateNSView(_ view:EdgeMaterialView,context:Context) {}
}
final class EdgeMaterialView:NSVisualEffectView {
    let isTop:Bool
    private let fade = CAGradientLayer()
    init(isTop:Bool) {
        self.isTop = isTop
        super.init(frame:.zero)
        material = .headerView
        blendingMode = .withinWindow
        state = .active
        isEmphasized = false
        wantsLayer = true
        // Smoothstep gives a flat slope at both ends; no rectangular bitmap
        // join and no abrupt opacity jump where the body meets the material.
        fade.startPoint = CGPoint(x:0.5,y:0)
        fade.endPoint = CGPoint(x:0.5,y:1)
        let stops = (0...16).map {CGFloat($0)/16}
        fade.locations = stops.map {NSNumber(value:Double($0))}
        fade.colors = stops.map { t in
            let a = t*t*(3-2*t)
            return NSColor.white.withAlphaComponent(isTop ? a:1-a).cgColor
        }
        layer?.mask = fade
    }
    required init?(coder:NSCoder) {fatalError()}
    override func hitTest(_ point:NSPoint)->NSView? {nil}
    override func layout() {
        super.layout()
        CATransaction.begin();CATransaction.setDisableActions(true)
        fade.frame = bounds
        fade.contentsScale = window?.backingScaleFactor ?? 2
        CATransaction.commit()
    }
}
