import AppKit
import QuartzCore

@MainActor final class ComposerActionButton:HoverFeedbackButton {
    private var shown = false
    private var revision = 0
    private var layoutFrame = NSRect.zero
    override init(frame:NSRect) {
        super.init(frame:NSRect(x:0,y:0,width:32,height:32))
        feedbackOnDarkFill = true
        wantsLayer = true;isBordered = false;isHidden = true
        layer?.cornerRadius = 16
        layer?.opacity = 0
        if let layer {layer.transform = ChromeMotion.transform(for:layer,scale:0.01,x:0,y:0)}
    }
    required init?(coder:NSCoder) {fatalError()}
    override func hitTest(_ point:NSPoint)->NSView? {shown ? super.hitTest(point):nil}
    func place(in rect:NSRect) {
        guard rect != layoutFrame else {return}
        layoutFrame = rect
        CATransaction.begin();CATransaction.setDisableActions(true)
        let transform = layer?.transform ?? CATransform3DIdentity
        layer?.transform = CATransform3DIdentity
        frame = rect
        layer?.transform = transform
        CATransaction.commit()
    }
    func show(_ visible:Bool,enabled:Bool,animated:Bool) {
        isEnabled = visible && enabled
        setAccessibilityHidden(!visible)
        guard visible != shown else {return}
        shown = visible;revision += 1
        let currentRevision = revision
        guard let layer else {isHidden = !visible;return}
        let from = layer.presentation()?.transform ?? layer.transform
        let opacity = layer.presentation()?.opacity ?? layer.opacity
        let target = ChromeMotion.transform(for:layer,scale:visible ? 1:0.01,x:0,y:0)
        layer.removeAllAnimations()
        isHidden = false
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.transform = target;layer.opacity = visible ? 1:0
        CATransaction.commit()
        guard animated else {isHidden = !visible;return}
        let spring = CASpringAnimation(keyPath:"transform")
        spring.mass = 1;spring.stiffness = 380;spring.damping = 27
        spring.fromValue = NSValue(caTransform3D:from)
        spring.toValue = NSValue(caTransform3D:target)
        spring.duration = spring.settlingDuration
        let fade = CABasicAnimation(keyPath:"opacity")
        fade.fromValue = opacity;fade.toValue = visible ? 1:0
        fade.duration = visible ? 0.16:0.20
        fade.timingFunction = CAMediaTimingFunction(name:.easeOut)
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self] in
            guard let self,self.revision == currentRevision else {return}
            self.isHidden = !visible
        }
        layer.add(spring,forKey:"action.scale")
        layer.add(fade,forKey:"action.opacity")
        CATransaction.commit()
    }
}
