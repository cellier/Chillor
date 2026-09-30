import AppKit
import SwiftUI
import QuartzCore

enum WindowGeometry {
    static let inset:CGFloat = 8
    static let header:CGFloat = 48
    static let innerRadius:CGFloat = 48
    static let outerTopRadius:CGFloat = 32
    static let outerBottomRadius:CGFloat = 52
    static func topContains(_ point:NSPoint,in size:NSSize)->Bool {
        // The side resize rails never count as the header, even near its corners.
        point.x >= 18 && point.x <= size.width-18 && point.y >= 0 && point.y <= header+24
            && !(point.y >= header && (point.x < 40 || point.x > size.width-40))
    }
    struct ResizeEdges:OptionSet {
        let rawValue:Int
        static let left = Self(rawValue:1), right = Self(rawValue:2)
        static let top = Self(rawValue:4), bottom = Self(rawValue:8)
    }
    static func cornerZones(in size:NSSize,chromeVisible:Bool)->[(NSRect,ResizeEdges,NSCursor.FrameResizePosition)] {
        let w = size.width,h = size.height
        var zones:[(NSRect,ResizeEdges,NSCursor.FrameResizePosition)] = [
            (NSRect(x:0,y:0,width:32,height:32),[.left,.top],.topLeft),
            (NSRect(x:w-32,y:0,width:32,height:32),[.right,.top],.topRight),
            (NSRect(x:0,y:h-40,width:40,height:40),[.left,.bottom],.bottomLeft),
            (NSRect(x:w-40,y:h-40,width:40,height:40),[.right,.bottom],.bottomRight)]
        // With the chrome hidden, the visible top corners start 48 pt below
        // the frame's top. Include their rounded arcs, not just invisible corners.
        if !chromeVisible {
            zones += [
                (NSRect(x:0,y:header,width:40,height:40),[.left,.top],.topLeft),
                (NSRect(x:w-40,y:header,width:40,height:40),[.right,.top],.topRight)]
        }
        return zones
    }
    static func resizeEdges(at p:NSPoint,in size:NSSize,chromeVisible:Bool = false)->ResizeEdges {
        guard NSRect(origin:.zero,size:size).contains(p) else {return []}
        if let corner = cornerZones(in:size,chromeVisible:chromeVisible).first(where:{$0.0.contains(p)}) {return corner.1}
        var edges:ResizeEdges = []
        if p.x < 18 {edges.insert(.left)}
        if p.x > size.width-18 {edges.insert(.right)}
        if p.y < 8 {edges.insert(.top)}
        if p.y > size.height-18 {edges.insert(.bottom)}
        return edges
    }
    static func resizedFrame(_ initial:NSRect,delta:NSPoint,edges:ResizeEdges,minimum:NSSize)->NSRect {
        var frame = initial
        if edges.contains(.right) {frame.size.width = max(minimum.width,initial.width+delta.x)}
        if edges.contains(.left) {frame.size.width = max(minimum.width,initial.width-delta.x);frame.origin.x = initial.maxX-frame.width}
        if edges.contains(.top) {frame.size.height = max(minimum.height,initial.height+delta.y)}
        if edges.contains(.bottom) {frame.size.height = max(minimum.height,initial.height-delta.y);frame.origin.y = initial.maxY-frame.height}
        return frame
    }
    static func isDragEdge(_ p:NSPoint,in size:NSSize,chromeVisible:Bool = false)->Bool {
        p.y < header+24 || !resizeEdges(at:p,in:size,chromeVisible:chromeVisible).isEmpty
    }
    // True circular arcs, matching Figma's 32/52 pt outer corners (not quadratic approximations).
    static func outerPath(_ size:NSSize)->CGPath {
        shellPath(size,progress:1)
    }
    static func shellPath(_ size:NSSize,progress:CGFloat)->CGPath {
        let p = min(1,max(0,progress))
        let x = inset*(1-p), y = header*(1-p)
        let w = size.width-x, h = size.height-inset*(1-p)
        let t = innerRadius+(outerTopRadius-innerRadius)*p
        let b = innerRadius+(outerBottomRadius-innerRadius)*p
        let path = CGMutablePath()
        path.move(to:CGPoint(x:x+t,y:y))
        path.addArc(tangent1End:CGPoint(x:w,y:y),tangent2End:CGPoint(x:w,y:y+t),radius:t)
        path.addArc(tangent1End:CGPoint(x:w,y:h),tangent2End:CGPoint(x:w-b,y:h),radius:b)
        path.addArc(tangent1End:CGPoint(x:x,y:h),tangent2End:CGPoint(x:x,y:h-b),radius:b)
        path.addArc(tangent1End:CGPoint(x:x,y:y),tangent2End:CGPoint(x:x+t,y:y),radius:t)
        path.closeSubpath()
        return path
    }
}
extension Notification.Name {
    static let chillorWindowInteractionChanged = Notification.Name("chillor.window.interactionChanged")
}
final class ChillorWindow:NSWindow {
    var isUserManipulating = false {
        didSet {
            if oldValue != isUserManipulating {NotificationCenter.default.post(name:.chillorWindowInteractionChanged,object:self)}
        }
    }
    override var canBecomeKey:Bool {true}
    override var canBecomeMain:Bool {true}
}
@MainActor final class WindowRoot:NSView {
    var controller:MainWindowController?
    private var hoverTracking:NSTrackingArea?
    private struct ResizeGesture {
        let origin:NSPoint
        let frame:NSRect
        let edges:WindowGeometry.ResizeEdges
    }
    private var resizeGesture:ResizeGesture?
    override var isFlipped:Bool {true}
    override func acceptsFirstMouse(for event:NSEvent?) -> Bool {true}
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        let rect = NSRect(x:18,y:0,width:max(1,bounds.width-36),height:72)
        if hoverTracking?.rect == rect {return}
        if let hoverTracking {removeTrackingArea(hoverTracking)}
        let area = NSTrackingArea(rect:rect,options:[.mouseEnteredAndExited,.mouseMoved,.activeAlways,.enabledDuringMouseDrag],owner:self,userInfo:nil)
        addTrackingArea(area);hoverTracking = area
    }
    override func mouseEntered(with event:NSEvent) {
        // Child controls forward unhandled tracking events up the responder chain.
        // Ignore them (and queued events from a replaced area), then check position.
        guard let area = event.trackingArea, area === hoverTracking else {return}
        mouseMoved(with:event)
    }
    override func mouseExited(with event:NSEvent) {
        guard let area = event.trackingArea, area === hoverTracking else {return}
        mouseMoved(with:event)
    }
    override func mouseMoved(with event:NSEvent) {controller?.pointerInsideTop(WindowGeometry.topContains(convert(event.locationInWindow,from:nil),in:bounds.size))}
    override func hitTest(_ point:NSPoint)->NSView? {
        let local = convert(point,from:superview)
        guard bounds.contains(local) else {return nil}
        // Let actual buttons receive clicks; transparent header space and the content's
        // perimeter belong to the drag surface, even while the shell is hidden.
        if let controller, controller.visibleChrome, local.y < 48 {
            let hit = super.hitTest(point)
            if hit is NSButton {return hit}
        }
        if WindowGeometry.isDragEdge(local,in:bounds.size,chromeVisible:controller?.visibleChrome ?? false) {return self}
        return super.hitTest(point)
    }
    override func resetCursorRects() {
        super.resetCursorRects()
        let w = bounds.width,h = bounds.height
        let zones:[(NSRect,NSCursor.FrameResizePosition)] = [
            (NSRect(x:0,y:8,width:18,height:h-26),.left),
            (NSRect(x:w-18,y:8,width:18,height:h-26),.right),
            (NSRect(x:18,y:0,width:w-36,height:8),.top),
            (NSRect(x:18,y:h-18,width:w-36,height:18),.bottom),
            (NSRect(x:0,y:0,width:18,height:8),.topLeft),
            (NSRect(x:w-18,y:0,width:18,height:8),.topRight),
            (NSRect(x:0,y:h-18,width:18,height:18),.bottomLeft),
            (NSRect(x:w-18,y:h-18,width:18,height:18),.bottomRight)]
        for (rect,position) in zones {addCursorRect(rect,cursor:.frameResize(position:position,directions:.all))}
        for (rect,_,position) in WindowGeometry.cornerZones(in:bounds.size,chromeVisible:controller?.visibleChrome ?? false) {
            addCursorRect(rect,cursor:.frameResize(position:position,directions:.all))
        }
    }
    override func mouseDown(with event:NSEvent) {
        guard let window,let controller else {return}
        cancelResize()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
        (window as? ChillorWindow)?.isUserManipulating = true
        let p = convert(event.locationInWindow,from:nil)
        let edges = WindowGeometry.resizeEdges(at:p,in:bounds.size,chromeVisible:controller.visibleChrome)
        controller.interaction = true
        if !edges.isEmpty {
            resizeGesture = ResizeGesture(origin:NSEvent.mouseLocation,frame:window.frame,edges:edges)
        } else {
            // The header moves the window; perimeter drags always resize without modifiers.
            window.performDrag(with:event)
            (window as? ChillorWindow)?.isUserManipulating = false
            controller.interaction = false;controller.finishInteraction()
        }
    }
    override func mouseDragged(with event:NSEvent) {
        guard let window,let gesture = resizeGesture else {return}
        // Screen coordinates stay stable while dragging the bottom/left edges,
        // which change the window origin. Let AppKit dispatch events normally.
        let current = NSEvent.mouseLocation
        let frame = WindowGeometry.resizedFrame(gesture.frame,delta:NSPoint(x:current.x-gesture.origin.x,y:current.y-gesture.origin.y),edges:gesture.edges,minimum:window.minSize)
        if frame != window.frame {window.setFrame(frame,display:false)}
    }
    override func mouseUp(with event:NSEvent) {cancelResize()}
    func cancelResize() {
        guard resizeGesture != nil else {return}
        resizeGesture = nil
        (window as? ChillorWindow)?.isUserManipulating = false
        controller?.interaction = false
        controller?.finishInteraction()
    }
    override func layout() {super.layout();controller?.layout()}
}
final class FlippedControls:NSView {override var isFlipped:Bool {true}}
final class FlippedMaterial:NSVisualEffectView {override var isFlipped:Bool {true}}

@MainActor enum ChromeMotion {
    static func transform(for layer:CALayer,scale:CGFloat,x:CGFloat,y:CGFloat)->CATransform3D {
        // Keep the visual centre fixed even on AppKit backing layers with a zero anchor.
        let cx = layer.bounds.width*(0.5-layer.anchorPoint.x)
        let cy = layer.bounds.height*(0.5-layer.anchorPoint.y)
        var t = CATransform3DMakeScale(scale,scale,1)
        t.m41 = x+cx*(1-scale);t.m42 = y+cy*(1-scale)
        return t
    }
    // Critically damped spring: a soft settling tail without a visible bounce.
    // Sampled once into Core Animation so material and controls share the same clock.
    struct Spring {
        var position:Double = 0
        var velocity:Double = 0
        var target:Double = 0
        var start:Double = 0
        static let duration:Double = 0.5
        func value(at time:Double)->(position:Double,velocity:Double) {
            let t = max(0,time-start), omega = 26.0
            if t >= Self.duration {return (target,0)}
            let a = position-target, b = velocity+omega*a, decay = exp(-omega*t)
            return (target+(a+b*t)*decay,(b-omega*(a+b*t))*decay)
        }
        mutating func retarget(_ target:Double,at time:Double,animated:Bool) {
            let current = value(at:time)
            self = Spring(position:animated ? current.position:target,velocity:animated ? current.velocity:0,target:target,start:time)
        }
        func samples()->[CGFloat] {
            (0...60).map {CGFloat(value(at:start+Double($0)/120).position)}
        }
    }
    static func animate(_ layer:CALayer,keyPath:String,values:[Any],target:Any,at time:Double,animated:Bool) {
        let key = "chrome."+keyPath
        layer.removeAnimation(forKey:key)
        CATransaction.begin();CATransaction.setDisableActions(true)
        layer.setValue(target,forKeyPath:keyPath)
        CATransaction.commit()
        guard animated else {return}
        let animation = CAKeyframeAnimation(keyPath:keyPath)
        animation.values = values;animation.duration = Spring.duration
        animation.calculationMode = .linear
        animation.beginTime = layer.convertTime(time,from:nil)
        layer.add(animation,forKey:key)
    }
    static func control(_ view:NSView,progress:[CGFloat],target:CGFloat,at time:Double,animated:Bool) {
        guard let layer = view.layer else {return}
        func transform(_ p:CGFloat)->NSValue {
            NSValue(caTransform3D:ChromeMotion.transform(for:layer,scale:0.94+0.06*p,x:0,y:7*(1-p)))
        }
        // Controls fade sooner than the shell finishes closing, as in the reference.
        func opacity(_ p:CGFloat)->CGFloat {let p = min(1,max(0,p));return p*p}
        view.alphaValue = target
        animate(layer,keyPath:"transform",values:progress.map {transform($0)},target:transform(target),at:time,animated:animated)
        animate(layer,keyPath:"opacity",values:progress.map {opacity($0)},target:opacity(target),at:time,animated:animated)
    }
}
@MainActor final class MainWindowController:NSWindowController,NSWindowDelegate {
    let root = WindowRoot()
    let shell = FlippedMaterial()
    let content:NSHostingView<ConversationView>
    let controls = FlippedControls()
    let more = HoverFeedbackButton()
    let conversation:Conversation
    var interaction = false
    private(set) var visibleChrome = false
    private var mouseMonitor:Any?
    private var insideTop = false
    private var buttons:[NSButton] = []
    private var laidOutSize = NSSize.zero
    private var spring = ChromeMotion.Spring()
    var openSettings:()->Void = {}
    init(conversation:Conversation) {
        self.conversation = conversation
        content = NSHostingView(rootView:ConversationView(conversation:conversation))
        // This host is sized explicitly by layout(). Do not ask the transcript
        // for intrinsic/min/max sizes on every window resize.
        content.sizingOptions = []
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x:0,y:0,width:1440,height:900)
        let size = NSSize(width:640,height:min(680,screen.height-40))
        // Custom borderless perimeter hit areas provide unmodified resize gestures.
        let window = ChillorWindow(contentRect:NSRect(origin:.zero,size:size),styleMask:[.borderless,.miniaturizable,.closable,.resizable],backing:.buffered,defer:false)
        super.init(window:window)
        window.title = "Chillor";window.minSize = NSSize(width:400,height:560)
        window.isOpaque = false;window.backgroundColor = .clear;window.hasShadow = true
        window.isReleasedWhenClosed = false;window.collectionBehavior = [.fullScreenPrimary,.managed]
        window.delegate = self;window.acceptsMouseMovedEvents = true
        root.controller = self;root.wantsLayer = true;window.contentView = root
        // A minimally visible backing surface keeps transparent perimeter pixels
        // from routing a click to the application behind this borderless window.
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.001).cgColor
        shell.material = .hudWindow;shell.blendingMode = .behindWindow;shell.state = .active
        shell.wantsLayer = true;root.addSubview(shell)
        content.wantsLayer = true;content.layer?.cornerRadius = WindowGeometry.innerRadius
        content.layer?.cornerCurve = .circular;content.layer?.masksToBounds = true
        root.addSubview(content)
        controls.wantsLayer = true;root.addSubview(controls)
        for (i,type) in [NSWindow.ButtonType.closeButton,.miniaturizeButton,.zoomButton].enumerated() {
            if let button = NSWindow.standardWindowButton(type,for:[.titled,.closable,.miniaturizable,.resizable]) {
                button.frame = NSRect(x:21+23*i,y:21,width:14,height:14)
                button.target = self;button.action = i == 0 ? #selector(closeWindow) : i == 1 ? #selector(minimizeWindow):#selector(zoomWindow)
                button.wantsLayer = true;controls.addSubview(button);buttons.append(button)
            }
        }
        more.image = NSImage(systemSymbolName:"ellipsis",accessibilityDescription:"Settings")
        more.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:16,weight:.medium)
        more.isBordered = false;more.target = self;more.action = #selector(settings)
        more.toolTip = "Settings · ⌘,";more.setAccessibilityLabel("Settings");more.wantsLayer = true
        controls.addSubview(more)
        layout();updateMotion(animated:false);window.center()
        updateControlAccess()
        mouseMonitor = NSEvent.addLocalMonitorForEvents(matching:[.mouseMoved,.leftMouseDown,.leftMouseDragged,.leftMouseUp]) { [weak self] event in
            guard let self,event.window === self.window else {return event}
            let p = self.root.convert(event.locationInWindow,from:nil)
            self.pointerInsideTop(WindowGeometry.topContains(p,in:self.root.bounds.size))
            return event
        }
    }
    required init?(coder:NSCoder){fatalError()}
    func layout() {
        let b = root.bounds
        guard b.size != laidOutSize else {return}
        laidOutSize = b.size
        window?.invalidateCursorRects(for:root)
        // Remove presentation transforms before updating frames; otherwise a scaled
        // backing layer can feed the wrong size back into NSView layout.
        CATransaction.begin();CATransaction.setDisableActions(true)
        shell.layer?.removeAllAnimations();shell.layer?.transform = CATransform3DIdentity
        more.layer?.removeAllAnimations();more.layer?.transform = CATransform3DIdentity
        shell.frame = b
        let shape = CAShapeLayer();shape.frame = shell.bounds;shape.path = WindowGeometry.outerPath(b.size)
        shell.layer?.mask = shape
        content.frame = NSRect(x:8,y:48,width:max(1,b.width-16),height:max(1,b.height-56))
        controls.frame = NSRect(x:0,y:0,width:b.width,height:48)
        more.frame = NSRect(x:b.width-56,y:10,width:36,height:36)
        CATransaction.commit()
        updateMotion(animated:false)
    }
    func pointerInsideTop(_ inside:Bool) {
        insideTop = inside
        // Interaction holds only the current state: moving a hidden side edge never
        // reveals the shell. Releasing applies the top-zone state with zero delay.
        if !interaction {setChrome(inside)}
    }
    func finishInteraction() {setChrome(insideTop)}
    func setChrome(_ visible:Bool) {
        guard visible != visibleChrome else {return}
        visibleChrome = visible;updateControlAccess()
        window?.invalidateCursorRects(for:root)
        updateMotion(animated:!Preferences.shared.motionDisabled)
        window?.invalidateShadow()
    }
    private func updateControlAccess() {
        controls.setAccessibilityHidden(!visibleChrome)
        for button in buttons+[more] {button.isEnabled = visibleChrome;button.setAccessibilityHidden(!visibleChrome)}
    }
    private func updateMotion(animated:Bool) {
        let now = CACurrentMediaTime(), target:CGFloat = visibleChrome ? 1:0
        spring.retarget(Double(target),at:now,animated:animated)
        let progress = animated ? spring.samples():[]
        // The material remains opaque. Its mask retreats completely behind the
        // fixed conversation surface instead of fading the whole window surround.
        shell.alphaValue = 1
        if let mask = shell.layer?.mask {
            ChromeMotion.animate(mask,keyPath:"path",values:progress.map {WindowGeometry.shellPath(root.bounds.size,progress:$0)},target:WindowGeometry.shellPath(root.bounds.size,progress:target),at:now,animated:animated)
        }
        for button in buttons+[more] {
            ChromeMotion.control(button,progress:progress,target:target,at:now,animated:animated)
        }
    }
    @objc func settings(){openSettings()}
    @objc func closeWindow(){window?.close()}
    @objc func minimizeWindow(){window?.miniaturize(nil)}
    private var unzoomed:NSRect?
    @objc func zoomWindow(){
        guard let window else{return}
        if let old = unzoomed {window.setFrame(old,display:true,animate:!Preferences.shared.motionDisabled);unzoomed = nil}
        else {unzoomed = window.frame;if let screen = window.screen {window.setFrame(screen.visibleFrame.insetBy(dx:16,dy:16),display:true,animate:!Preferences.shared.motionDisabled)}}
    }
    func windowWillStartLiveResize(_ notification:Notification) {
        interaction = true;(window as? ChillorWindow)?.isUserManipulating = true
    }
    func windowDidEndLiveResize(_ notification:Notification) {
        (window as? ChillorWindow)?.isUserManipulating = false
        interaction = false;finishInteraction()
    }
    func windowDidResize(_ notification:Notification){layout()}
    func windowDidResignKey(_ notification:Notification){root.cancelResize();(window as? ChillorWindow)?.isUserManipulating = false;interaction = false}
    func windowWillClose(_ notification:Notification){root.cancelResize();conversation.persist()}
    func reveal(){
        conversation.latestPositionRequest = UUID()
        window?.deminiaturize(nil);window?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}
