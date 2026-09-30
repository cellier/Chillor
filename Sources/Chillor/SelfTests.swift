import Foundation
import AppKit
import QuartzCore
import SwiftUI

@MainActor enum SelfTests {
    static func check(_ condition:Bool,_ message:String)throws {if !condition {throw ModelFailure(message:message)}}
    static func runWindowTests() throws {
        let wide = CGSize(width:1600,height:400)
        let converted = ScreenContextGeometry.rect(CGRect(x:0.25,y:0.5,width:0.5,height:0.1),in:wide)
        try check(converted == CGRect(x:400,y:160,width:800,height:40),"OCR/window coordinate conversion failed")
        try check(ScreenContextGeometry.quartzPoint(CGPoint(x:-500,y:1200),primaryHeight:900) == CGPoint(x:-500,y:-300),"Secondary-display pointer conversion failed")
        let lines:[ScreenContextGeometry.Line] = [
            .init(text:"Wrong horizontal neighbour",rect:CGRect(x:120,y:95,width:100,height:10)),
            .init(text:"Correct vertical neighbour",rect:CGRect(x:95,y:110,width:200,height:10))]
        try check(ScreenContextGeometry.target(in:lines,at:CGPoint(x:100,y:100)) == 1,"OCR distance must use points, not normalized aspect-distorted coordinates")
        try check(ScreenContextGeometry.target(in:lines,at:CGPoint(x:1000,y:300)) == nil,"Far-away text was incorrectly selected")
        let paragraph:[ScreenContextGeometry.Line] = [
            .init(text:"First line",rect:CGRect(x:100,y:100,width:250,height:16)),
            .init(text:"Second line",rect:CGRect(x:100,y:121,width:220,height:16)),
            .init(text:"Sidebar",rect:CGRect(x:0,y:121,width:75,height:16)),
            .init(text:"Different message",rect:CGRect(x:100,y:165,width:220,height:16))]
        try check(ScreenContextGeometry.paragraph(in:paragraph,target:1) == "First line\nSecond line","Paragraph grouping crossed columns or message gaps")
        print("PASS: window-local OCR, multi-display pointer, aspect-correct targeting, rejection distance and paragraph boundaries")
        try runDetectionTests()
        try MarkdownChecks.run()
        for isTop in [true,false] {
            let edge = EdgeMaterialView(isTop:isTop)
            edge.frame = NSRect(x:0,y:0,width:640,height:isTop ? 32:104)
            edge.layout()
            try check(edge.blendingMode == .withinWindow && edge.state == .active,"Edge must sample live window content")
            try check(edge.hitTest(.zero) == nil,"Edge intercepts scrolling")
            let colors = (edge.layer?.mask as? CAGradientLayer)?.colors as? [CGColor]
            try check((isTop ? colors?.first:colors?.last)?.alpha == 0,"Content boundary is not fully transparent")
            try check(edge.layer?.filters == nil && edge.layer?.shouldRasterize == false,"Edge forces filtered rasterization")
        }
        print("PASS: native live edge material, clear content boundary, non-intercepting hit testing")
        var calendar = Calendar(identifier:.gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT:0)!
        let now = calendar.date(from:DateComponents(year:2026,month:9,day:13,hour:20,minute:58))!
        func ago(_ component:Calendar.Component,_ value:Int)->Date {calendar.date(byAdding:component,value:-value,to:now)!}
        try check(MessageTimestamp.string(now,now:now,calendar:calendar) == "8:58 PM","Same-day time format")
        try check(MessageTimestamp.string(ago(.day,1),now:now,calendar:calendar) == "Saturday 8:58 PM","Weekday time format")
        try check(MessageTimestamp.string(ago(.day,7),now:now,calendar:calendar) == "Sep 6 8:58 PM","Seven-day boundary")
        try check(MessageTimestamp.string(ago(.year,1),now:now,calendar:calendar) == "Sep 13, 2025 8:58 PM","Year boundary")
        print("PASS: message time formats and week/year boundaries")
        let composer = ComposerView(frame:NSRect(x:0,y:0,width:364,height:56))
        composer.editor.setMarkedText("ni",selectedRange:NSRange(location:2,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        try check(composer.placeholder.isHidden,"IME preedit overlaps placeholder before layout")
        composer.update(text:"",enabled:true)
        try check(composer.editor.hasMarkedText() && composer.editor.string == "ni","SwiftUI update destroys IME preedit")
        composer.editor.insertText("你",replacementRange:NSRange(location:NSNotFound,length:0))
        try check(composer.placeholder.isHidden && composer.editor.string == "你","IME commit restores placeholder incorrectly")
        composer.update(text:"",enabled:true)
        try check(!composer.placeholder.isHidden,"Empty editor did not restore placeholder")
        composer.editor.setMarkedText("n",selectedRange:NSRange(location:1,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        composer.editor.setMarkedText("",selectedRange:NSRange(location:0,length:0),replacementRange:NSRange(location:NSNotFound,length:0))
        composer.editor.unmarkText()
        try check(!composer.placeholder.isHidden,"Cancelled composition did not restore placeholder")
        print("PASS: immediate IME placeholder hiding, preedit preservation, commit and cancellation")
        var stopped = false, sent = false
        composer.onStop = {stopped = true};composer.onSend = {sent = true}
        composer.update(text:"",enabled:true,generating:true);composer.layout()
        try check(!composer.send.isHidden && composer.send.frame == NSRect(x:320,y:12,width:32,height:32),"Stop missing from right side of empty composer")
        composer.submit()
        try check(stopped && !sent,"Stop invoked send")
        composer.update(text:"Next draft",enabled:false,generating:true);composer.layout()
        try check(composer.send.isEnabled && composer.editor.string == "Next draft","Import disabled stop or draft was lost")
        composer.update(text:"Next draft",enabled:true,generating:false);composer.layout();composer.submit()
        try check(!composer.send.isHidden && sent,"Send did not return after generation")
        composer.update(text:"",enabled:true,generating:false);composer.layout()
        try check(composer.send.isHidden,"Idle empty composer shows action")
        print("PASS: composer stop/send transitions, right inset, stop action, draft preservation")
        let action = ComposerActionButton()
        action.place(in:NSRect(x:100,y:12,width:32,height:32))
        action.show(true,enabled:true,animated:true)
        try check(action.layer?.animation(forKey:"action.scale") is CASpringAnimation,"Action entrance lacks spring")
        action.show(false,enabled:true,animated:true)
        try check(!action.isHidden && !action.isEnabled,"Action disappeared before exit animation or remained clickable")
        action.show(true,enabled:true,animated:false)
        try check(!action.isHidden && (action.layer?.animationKeys()?.isEmpty ?? true),"Reversed/reduced action animation failed")
        action.show(false,enabled:true,animated:false)
        try check(action.isHidden,"Reduced-motion exit failed")
        print("PASS: action spring entrance/exit, interruption, reduced motion, exit hit testing")
        guard let main = (NSApp.delegate as? AppDelegate)?.main, let window = main.window else {throw ModelFailure(message:"Missing test window")}
        try check(window.styleMask.contains(.resizable),"Native AppKit resizing is disabled")
        try check(main.root.acceptsFirstMouse(for:nil),"Inactive window discards first perimeter drag")
        main.windowWillStartLiveResize(Notification(name:NSWindow.willStartLiveResizeNotification,object:window))
        try check((window as? ChillorWindow)?.isUserManipulating == true,"Native resize interaction not tracked")
        main.windowDidEndLiveResize(Notification(name:NSWindow.didEndLiveResizeNotification,object:window))
        try check((window as? ChillorWindow)?.isUserManipulating == false,"Native resize interaction remains active")
        print("PASS: native resizable window, first-click dragging, live-resize interaction and recovery")
        let size = NSSize(width:496,height:922)
        for point in [NSPoint(x:200,y:20),NSPoint(x:200,y:60),NSPoint(x:200,y:5)] {
            try check(WindowGeometry.topContains(point,in:size),"Top hover region missed a point")
        }
        for point in [NSPoint(x:2,y:5),NSPoint(x:494,y:50),NSPoint(x:2,y:300),NSPoint(x:494,y:300),NSPoint(x:200,y:920),NSPoint(x:200,y:73)] {
            try check(!WindowGeometry.topContains(point,in:size),"Side/bottom activated chrome")
        }
        main.pointerInsideTop(false)
        // A propagated child tracking event must not briefly reveal the header.
        if let foreign = NSEvent.enterExitEvent(with:.mouseEntered,location:NSPoint(x:0,y:0),modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,trackingNumber:0,userData:nil) {
            main.root.mouseEntered(with:foreign)
            try check(!main.visibleChrome,"Unrelated tracking event flashed chrome")
        }
        let initial = NSRect(x:100,y:100,width:496,height:922)
        for (point,edge) in [(NSPoint(x:2,y:300),WindowGeometry.ResizeEdges.left),(NSPoint(x:494,y:300),.right),(NSPoint(x:200,y:920),.bottom),(NSPoint(x:200,y:2),.top)] {
            try check(WindowGeometry.resizeEdges(at:point,in:size).contains(edge),"Unmodified edge drag did not select resize")
        }
        let corners:[(NSPoint,WindowGeometry.ResizeEdges,NSPoint)] = [
            (NSPoint(x:24,y:68),[.left,.top],NSPoint(x:-60,y:40)),
            (NSPoint(x:size.width-24,y:68),[.right,.top],NSPoint(x:60,y:40)),
            (NSPoint(x:24,y:size.height-24),[.left,.bottom],NSPoint(x:-60,y:-40)),
            (NSPoint(x:size.width-24,y:size.height-24),[.right,.bottom],NSPoint(x:60,y:-40))]
        for (point,edges,delta) in corners {
            try check(WindowGeometry.resizeEdges(at:point,in:size) == edges,"Visible corner misses diagonal resize")
            try check(WindowGeometry.isDragEdge(point,in:size),"Corner click falls through to conversation")
            try check(!WindowGeometry.topContains(point,in:size),"Corner resize unexpectedly reveals chrome")
            let result = WindowGeometry.resizedFrame(initial,delta:delta,edges:edges,minimum:window.minSize)
            try check(result.width == initial.width+60 && result.height == initial.height+40,"Corner drag must change both dimensions")
            try check(edges.contains(.left) ? result.maxX == initial.maxX:result.minX == initial.minX,"Opposite horizontal edge moved")
            try check(edges.contains(.top) ? result.minY == initial.minY:result.maxY == initial.maxY,"Opposite vertical edge moved")
        }
        print("PASS: four visible rounded corners resize diagonally and preserve the opposite corner")
        let widened = WindowGeometry.resizedFrame(initial,delta:NSPoint(x:104,y:0),edges:.right,minimum:window.minSize)
        try check(widened.width == 600 && widened.origin == initial.origin,"Normal edge resize moved window")
        let minimum = WindowGeometry.resizedFrame(initial,delta:NSPoint(x:1000,y:1000),edges:[.left,.bottom],minimum:window.minSize)
        try check(minimum.size == window.minSize && minimum.maxX == initial.maxX && minimum.maxY == initial.maxY,"Minimum resize did not preserve opposite corner")
        let original = window.frame
        defer {window.setFrame(original,display:true)}
        for dimensions in [NSSize(width:400,height:560),size,NSSize(width:900,height:700)] {
            window.setFrame(NSRect(origin:original.origin,size:dimensions),display:true);main.layout()
            let surface = main.content.frame
            try check(surface == NSRect(x:8,y:48,width:dimensions.width-16,height:dimensions.height-56),"Content geometry changed")
            main.pointerInsideTop(true)
            try check(main.visibleChrome,"Top region failed to reveal chrome")
            main.pointerInsideTop(false)
            try check(!main.visibleChrome,"Chrome exit has a delay")
            try check(main.content.frame == surface,"Chrome animation moved content")
            try check(main.content.layer?.cornerRadius == 48,"Inner corner radius drifted")
            let path = WindowGeometry.outerPath(dimensions)
            try check(path.contains(CGPoint(x:10,y:10)),"Top radius is not 32pt")
            try check(!path.contains(CGPoint(x:10,y:dimensions.height-10)),"Bottom radius is not 52pt")
        }
        try check(main.shell.alphaValue == 1 && main.more.alphaValue == 0,"Hidden view/layer alpha diverged")
        main.pointerInsideTop(false);main.interaction = true;main.pointerInsideTop(false)
        try check(!main.visibleChrome,"Hidden perimeter drag revealed chrome")
        main.interaction = false;main.finishInteraction()
        let bottom = main.root.convert(NSPoint(x:main.root.bounds.midX,y:main.root.bounds.height-12),to:nil)
        if let down = NSEvent.mouseEvent(with:.leftMouseDown,location:bottom,modifierFlags:[],timestamp:0,windowNumber:window.windowNumber,context:nil,eventNumber:1,clickCount:1,pressure:1),
           let up = NSEvent.mouseEvent(with:.leftMouseUp,location:bottom,modifierFlags:[],timestamp:1,windowNumber:window.windowNumber,context:nil,eventNumber:2,clickCount:1,pressure:0) {
            // This must return before a mouse-up exists; a nested event wait hangs here.
            main.root.mouseDown(with:down)
            try check(main.interaction,"Bottom resize did not start")
            main.root.mouseUp(with:up)
            try check(!main.interaction,"Mouse-up left resize stuck")
            main.root.mouseDown(with:down)
            main.windowDidResignKey(Notification(name:NSWindow.didResignKeyNotification,object:window))
            try check(!main.interaction,"Interrupted resize remained active")
            print("PASS: bottom mouse-down returns immediately; mouse-up and focus loss release resize")
        } else {throw ModelFailure(message:"Could not construct resize regression events")}
        var spring = ChromeMotion.Spring()
        spring.retarget(1,at:1,animated:true)
        let before = spring.value(at:1.07)
        spring.retarget(0,at:1.07,animated:true)
        let after = spring.value(at:1.07)
        try check(abs(before.position-after.position)<0.000001 && abs(before.velocity-after.velocity)<0.000001,"Reversal lost position or velocity")
        try check(spring.value(at:1.6).position == 0,"Spring did not settle")
        let closed = WindowGeometry.shellPath(size,progress:0).boundingBoxOfPath
        try check(abs(closed.minX-8)<0.001 && abs(closed.minY-48)<0.001 && abs(closed.width-480)<0.001 && abs(closed.height-866)<0.001,"Closed shell escaped content")
        let layer = CAShapeLayer()
        ChromeMotion.animate(layer,keyPath:"path",values:spring.samples().map {WindowGeometry.shellPath(size,progress:$0)},target:WindowGeometry.shellPath(size,progress:0),at:1.07,animated:true)
        try check(layer.animation(forKey:"chrome.path") is CAKeyframeAnimation,"Shell spring animation missing")
        ChromeMotion.animate(layer,keyPath:"path",values:[],target:WindowGeometry.outerPath(size),at:2,animated:false)
        try check(layer.animationKeys()?.isEmpty ?? true,"Reduced motion left animations running")
        print("PASS: top-only activation, foreign tracking-event rejection, view/layer alpha, unmodified edge resizing, zero-delay exit, hidden-edge state, spring/reduced-motion, circular 48/32/52pt corners, stable content at three sizes")
    }
    static func runScrollTest() async throws {
        // Preloaded history exercises initial layout, unlike appending messages
        // after the transcript has already appeared.
        let fixture = Conversation(file:URL(fileURLWithPath:"/tmp/chillor-startup-scroll-\(UUID()).json"))
        fixture.messages = (0..<40).map {ChatMessage(role:"assistant",text:"## Saved message \($0)\n\n"+String(repeating:"A long saved paragraph with **Markdown** and 中文内容。\n\n",count:5))}
        let controller = MainWindowController(conversation:fixture)
        controller.reveal()
        defer {controller.window?.close()}
        try await Task.sleep(for:.milliseconds(600))
        func transcript(_ view:NSView)->NSScrollView? {
            if view is ConversationRowPosition.Marker {return view.enclosingScrollView}
            return view.subviews.compactMap {transcript($0)}.first
        }
        guard let history = transcript(controller.content),let document = history.documentView else {throw ModelFailure(message:"No startup transcript")}
        print("STARTUP_METRICS height=\(document.bounds.height) viewport=\(history.contentView.bounds) remaining=\(document.bounds.maxY-history.contentView.bounds.maxY)");fflush(stdout)
        try check(document.bounds.maxY-history.contentView.bounds.maxY<=8,"Initial saved history did not open at bottom")
        fixture.scrollTarget = fixture.messages[5].id
        try await Task.sleep(for:.milliseconds(300))
        let readingY = history.contentView.bounds.minY
        try check(document.bounds.maxY-history.contentView.bounds.maxY>200,"Cannot navigate to history")
        try await Task.sleep(for:.milliseconds(300))
        try check(abs(history.contentView.bounds.minY-readingY)<2,"Startup follow pulled reader away from history")
        controller.window?.orderOut(nil)
        controller.reveal()
        try await Task.sleep(for:.milliseconds(400))
        try check(document.bounds.maxY-history.contentView.bounds.maxY<=8,"Reopened window did not return to latest")
        print("PASS: preloaded history starts at bottom; history reading remains stable; reopen returns to bottom")
        func metrics(_ distance:CGFloat)->ConversationScrollMetrics {
            ConversationScrollMetrics(contentHeight:2000,viewportHeight:680,offset:1320-distance)
        }
        try check(metrics(0).isAtBottom && !metrics(0).showsReturnButton(previouslyVisible:true),"Return button visible at bottom")
        try check(metrics(96).isAtBottom && !metrics(96).showsReturnButton(previouslyVisible:true),"Near-bottom return button did not hide")
        try check(!metrics(160).showsReturnButton(previouslyVisible:false) && metrics(161).showsReturnButton(previouslyVisible:false),"Return button appeared too close to bottom")
        try check(metrics(120).showsReturnButton(previouslyVisible:true) && !metrics(120).showsReturnButton(previouslyVisible:false),"Return button threshold lacks hysteresis")
        try check(ConversationScrollMetrics(contentHeight:200,viewportHeight:680,offset:0).isAtBottom,"Short conversation is not at bottom")
        guard let app = NSApp.delegate as? AppDelegate else {throw ModelFailure(message:"Missing test app")}
        app.conversation.messages = [ChatMessage(role:"assistant",text:"Generating…",state:"working")]
        for index in 1...36 {
            app.conversation.messages[0].text += "\n\nParagraph \(index): streamed text grows and wraps across multiple lines. 最新回复应该始终出现在输入区域上方。"
            try await Task.sleep(for:.milliseconds(35))
        }
        try await Task.sleep(for:.milliseconds(250))
        func scrollViews(_ view:NSView)->[NSScrollView] {
            (view as? NSScrollView).map {[$0]} ?? view.subviews.flatMap {scrollViews($0)}
        }
        func checkBottom() throws {
            guard let scroll = scrollViews(app.main.content).max(by:{$0.bounds.height<$1.bounds.height}),let document = scroll.documentView else {throw ModelFailure(message:"Missing conversation scroll view")}
            let remaining = document.bounds.maxY-scroll.contentView.bounds.maxY
            try check(remaining<=8,"Stream stopped following bottom: \(remaining) pt hidden")
        }
        try checkBottom()
        app.conversation.attachmentError = String(repeating:"A notice increases the input area's height. ",count:6)
        app.conversation.draft = String(repeating:"Multiline draft\n",count:4)
        try await Task.sleep(for:.milliseconds(300))
        try checkBottom()
        print("PASS: 36 streamed layout updates follow bottom, including a taller composer and notice")
    }
    static func runPreviewScrollTest() async throws {
        guard let app = NSApp.delegate as? AppDelegate,let window = app.main.window else {throw ModelFailure(message:"Missing test app")}
        window.setFrame(NSRect(origin:window.frame.origin,size:NSSize(width:1000,height:760)),display:true)
        window.center()
        app.main.layout()
        let messages = (0..<40).map { index in
            ChatMessage(role:index.isMultiple(of:2) ? "user":"assistant",text:"Message \(index)\n\n"+String(repeating:"Preview resizing must keep this message in place. 消息重新换行时保持阅读位置。 ",count:3+index%4))
        }
        app.conversation.messages = messages
        app.conversation.attachmentError = nil
        app.conversation.draft = ""
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-preview-scroll.pdf")
        let page = NSView(frame:NSRect(x:0,y:0,width:400,height:500))
        try page.dataWithPDF(inside:page.bounds).write(to:file)
        defer {try? FileManager.default.removeItem(at:file)}
        let preview = PreviewItem(artifact:WorkArtifact(path:file.path,name:file.lastPathComponent,validation:""))
        func find(_ view:NSView,id:UUID)->NSView? {
            if let probe = view as? ConversationRowPosition.Marker,probe.messageID == id {return probe}
            for child in view.subviews {if let found = find(child,id:id) {return found}}
            return nil
        }
        func frame(_ message:ChatMessage)throws->NSRect {
            guard let item = find(app.main.content,id:message.id) else {throw ModelFailure(message:"Missing visible message \(message.id)")}
            return window.convertToScreen(item.convert(item.bounds,to:nil))
        }
        func chatScroll(_ view:NSView)->NSScrollView? {
            if view is ConversationRowPosition.Marker {return view.enclosingScrollView}
            return view.subviews.compactMap {chatScroll($0)}.first
        }
        func manualScroll(_ pixels:Int32) async throws {
            guard let scroll = chatScroll(app.main.content) else {throw ModelFailure(message:"Missing chat scroll view")}
            // Core Graphics phase bits differ from NSEvent.Phase bits.
            for phase:Int64 in [1,2,4] {
                guard let cg = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:phase == 2 ? pixels:0,wheel2:0,wheel3:0) else {throw ModelFailure(message:"Missing scroll event")}
                cg.setIntegerValueField(.scrollWheelEventScrollPhase,value:phase)
                guard let event = NSEvent(cgEvent:cg) else {throw ModelFailure(message:"Missing native scroll event")}
                scroll.scrollWheel(with:event)
                try await Task.sleep(for:.milliseconds(50))
            }
            try await Task.sleep(for:.milliseconds(350))
        }
        func visibleAnchor()throws->(ChatMessage,NSRect) {
            let top = window.convertToScreen(app.main.content.convert(app.main.content.bounds,to:nil)).maxY
            guard let candidate = messages.compactMap({message -> (ChatMessage,NSRect)? in
                guard let rect = try? frame(message),rect.minY<top,rect.maxY>top-500 else {return nil}
                return (message,rect)
            }).max(by:{$0.1.maxY<$1.1.maxY}) else {throw ModelFailure(message:"No visible anchor")}
            return candidate
        }
        try await Task.sleep(for:.milliseconds(500))
        app.conversation.scrollTarget = messages[20].id
        try await Task.sleep(for:.milliseconds(500))
        let (initialMessage,initial) = try visibleAnchor()
        print("PREVIEW_ANCHOR_INITIAL: \(initial)")
        for cycle in 0..<3 {
            app.conversation.previewArtifact = preview
            try await Task.sleep(for:.milliseconds(650))
            let opened = try frame(initialMessage)
            print("OPENED \(cycle): \(opened)")
            try check(opened.width<initial.width-100,"Preview did not actually resize the conversation")
            try check(abs(opened.maxY-initial.maxY)<2,"Opening preview moved reading anchor by \(opened.maxY-initial.maxY) pt (cycle \(cycle))")
            app.conversation.previewArtifact = nil
            try await Task.sleep(for:.milliseconds(650))
            let closed = try frame(initialMessage)
            print("CLOSED \(cycle): \(closed)")
            try check(abs(closed.maxY-initial.maxY)<2,"Closing preview moved reading anchor by \(closed.maxY-initial.maxY) pt (cycle \(cycle))")
        }
        print("PASS: message stays at the same viewport position across three preview open/close cycles")
        app.conversation.previewArtifact = preview
        try await Task.sleep(for:.milliseconds(650))
        let (manualMessage,beforeUserScroll) = try visibleAnchor()
        try await manualScroll(-180)
        let afterUserScroll = try frame(manualMessage)
        try check(abs(beforeUserScroll.maxY-afterUserScroll.maxY)>30,"Preview preservation blocked manual scrolling")
        let (scrolledMessage,scrolledFrame) = try visibleAnchor()
        app.conversation.previewArtifact = nil
        try await Task.sleep(for:.milliseconds(650))
        let afterClose = try frame(scrolledMessage)
        try check(abs(afterClose.maxY-scrolledFrame.maxY)<2,"Closing after manual scroll moved anchor by \(afterClose.maxY-scrolledFrame.maxY) pt")
        print("PASS: manual scrolling releases the old anchor; closing preserves the new reading position")

        // Enter at the bottom with automatic following still enabled.
        try await manualScroll(-80)
        app.conversation.messages.append(ChatMessage(role:"assistant",text:"Latest message"))
        try await Task.sleep(for:.milliseconds(800))
        let (bottomMessage,bottomFrame) = try visibleAnchor()
        app.conversation.previewArtifact = preview
        try await Task.sleep(for:.milliseconds(650))
        let bottomOpened = try frame(bottomMessage)
        try check(abs(bottomOpened.maxY-bottomFrame.maxY)<2,"Opening at bottom moved anchor by \(bottomOpened.maxY-bottomFrame.maxY) pt")
        print("PASS: opening preview at the bottom preserves visible content instead of following resized content")
        app.conversation.previewArtifact = nil
        try await Task.sleep(for:.milliseconds(650))
        let bottomClosed = try frame(bottomMessage)
        try check(abs(bottomClosed.maxY-bottomFrame.maxY)<2,"Closing at bottom moved anchor by \(bottomClosed.maxY-bottomFrame.maxY) pt")
        app.conversation.scrollTarget = messages[12].id
        try await Task.sleep(for:.milliseconds(500))
        let jumped = try frame(messages[12])
        let viewport = window.convertToScreen(app.main.content.convert(app.main.content.bounds,to:nil))
        try check(jumped.intersects(viewport) && abs(jumped.maxY-viewport.maxY)<96,"Explicit history navigation did not show its target: \(jumped), viewport: \(viewport)")
        print("PASS: closing preview at the bottom and explicit history navigation")
        // Quick Look also used to crash when a preview's window closed before
        // SwiftUI dismantled it. Exercise that lifecycle separately.
        let previewWindow = NSWindow(contentRect:NSRect(x:0,y:0,width:500,height:600),styleMask:[.titled,.closable],backing:.buffered,defer:false)
        previewWindow.isReleasedWhenClosed = false
        previewWindow.contentView = NSHostingView(rootView:ArtifactPreview(artifact:preview,onClose:{},onError:{_ in}))
        previewWindow.orderFront(nil)
        try await Task.sleep(for:.milliseconds(800))
        previewWindow.close()
        previewWindow.contentView = nil
        try await Task.sleep(for:.milliseconds(500))
        print("PASS: native PDF preview teardown and window-close lifecycle without duplicate Quick Look deactivation")
    }
    static func preparePreviewUIFixture() throws {
        guard let app = NSApp.delegate as? AppDelegate,let window = app.main.window else {throw ModelFailure(message:"Missing test app")}
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-preview-ui-fixture")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let pdf = root.appendingPathComponent("Preview-test.pdf")
        let page = NSView(frame:NSRect(x:0,y:0,width:400,height:500))
        let label = NSTextField(labelWithString:"Native PDF preview regression test")
        label.frame = NSRect(x:20,y:220,width:360,height:40);page.addSubview(label)
        try page.dataWithPDF(inside:page.bounds).write(to:pdf)
        let md = root.appendingPathComponent("Preview-test.md")
        try "# Markdown preview\n\nClose and reopen this preview.".write(to:md,atomically:true,encoding:.utf8)
        window.setFrame(NSRect(origin:window.frame.origin,size:NSSize(width:1000,height:760)),display:true)
        window.center();app.main.layout()
        app.conversation.messages = (0..<8).map {index in
            ChatMessage(role:"assistant",text:"## Section \(index+1)\n\n"+String(repeating:"This paragraph changes height when preview opens. The file card below should stay where it was clicked.\n\n",count:4),artifacts:[WorkArtifact(path:pdf.path,name:pdf.lastPathComponent,validation:""),WorkArtifact(path:md.path,name:md.lastPathComponent,validation:"")])
        }
        app.conversation.draft = "";app.conversation.previewArtifact = nil
    }
    static func run()async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:temp,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:temp)}
        let file = temp.appendingPathComponent("conversation.json")
        let conversation = Conversation(file:file)
        let old = ChatMessage(role:"user",text:"We are writing a launch plan.")
        let reply = ChatMessage(role:"assistant",text:"Here is the launch plan.")
        conversation.messages = [old,reply]
        conversation.persist()
        try check(Conversation(file:file).messages.count == 2,"History did not persist")
        conversation.search = "launch"
        try check(conversation.results.count == 2,"Search missed messages")
        try check(conversation.anchor == nil,"Search changed context")
        conversation.continueFrom(old)
        try check(conversation.anchor?.id == old.id,"Continue did not anchor exact source")
        let attached = ChatMessage(role:"user",text:"Summarize",attachments:[Attachment(name:"note.txt",text:"Release is Friday.")])
        let payload = conversation.payload(request:attached,history:conversation.messages)
        try check((payload.last?["content"] as? String)?.contains("Release is Friday.") == true,"Attachment omitted from model input")
        let isolated = conversation.payload(request:attached,history:conversation.messages,isolated:true)
        try check(isolated.count == 2,"Quick command included unrelated conversation")
        let textURL = temp.appendingPathComponent("sample.txt")
        try "The project codename is SILVER-PINE.".write(to:textURL,atomically:true,encoding:.utf8)
        let context = try FileContext.read(textURL)
        try check(context.text.contains("SILVER-PINE"),"Local file extraction failed")
        let suite = "ChillorTest-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName:suite)!
        defer {defaults.removePersistentDomain(forName:suite)}
        let preferences = Preferences(defaults:defaults)
        preferences.commands = []
        try check(Preferences(defaults:defaults).commands.isEmpty,"Deleted defaults were restored")
        preferences.textSize = 18
        try check(Preferences(defaults:defaults).textSize == 18,"Settings did not persist")
        if let main = (NSApp.delegate as? AppDelegate)?.main, let window = main.window {
            try check(window.minSize == NSSize(width:400,height:560), "Minimum window size not applied")
            let original = window.frame
            for size in [NSSize(width:400,height:560),NSSize(width:496,height:922),NSSize(width:900,height:700)] {
                window.setFrame(NSRect(origin:original.origin,size:size),display:true)
                main.layout()
                let surface = main.content.frame
                try check(surface.origin == NSPoint(x:8,y:48), "Window insets drifted")
                try check(surface.size == NSSize(width:size.width-16,height:size.height-56), "Conversation did not resize with the window")
                main.setChrome(true)
                try check(main.content.frame == surface, "Showing chrome moved content")
                main.setChrome(false)
                try check(main.content.frame == surface, "Hiding chrome moved content")
            }
            window.setFrame(original,display:true)
        }
        var answer = ""
        let modelInput = conversation.payload(request:ChatMessage(role:"user",text:"What is the project codename in the attached file? Answer only with the codename.",attachments:[context]),history:[],isolated:true)
        try await LocalModel.shared.respond(messages:modelInput) {answer += $0}
        try check(answer.contains("SILVER-PINE"),"Real local inference did not read attached context: \(answer)")
        print("PASS: persistence, search without context switch, explicit anchor, command isolation, file context, command deletion, live settings, real Qwen inference: \(answer)")
    }
}
