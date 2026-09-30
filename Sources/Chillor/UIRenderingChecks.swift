import AppKit
import SwiftUI

@MainActor enum UIRenderingChecks {
    static let enabled = ProcessInfo.processInfo.arguments.contains("--ui-performance-test")
    static var rowBodies = 0
    static var markdownBodies = 0
    static func rowRendered() {if enabled {rowBodies += 1}}
    static func markdownRendered() {if enabled {markdownBodies += 1}}

    static func run() async throws {
        guard let app = NSApp.delegate as? AppDelegate else {throw ModelFailure(message:"Missing test app")}
        let started = ProcessInfo.processInfo.systemUptime
        app.conversation.messages = (0..<120).map { i in
            ChatMessage(role:"assistant",text:"## Message \(i)\n\n"+String(repeating:"Long conversation rendering should remain smooth while scrolling and typing. **Bold text**, a [link](https://example.com), and 中文段落。\n\n",count:3)+"- First item\n- Second item\n\n```swift\nlet value = \(i)\n```",state:i == 119 ? "working":"done")
        }
        try await Task.sleep(for:.milliseconds(700))
        print("UI_INITIAL_SECONDS: \(ProcessInfo.processInfo.systemUptime-started)")
        func findScroll(_ view:NSView)->NSScrollView? {
            if view is ConversationRowPosition.Marker {return view.enclosingScrollView}
            return view.subviews.compactMap {findScroll($0)}.first
        }
        guard let scroll = findScroll(app.main.content) else {throw ModelFailure(message:"No transcript scroll view")}
        guard let window = app.main.window else {throw ModelFailure(message:"No window")}
        let original = window.frame
        for scenario in ["move", "resize_width", "resize_height", "resize_corner", "scroll", "streaming_scroll"] {
            window.setFrame(original, display:false)
            try await Task.sleep(for:.milliseconds(400))
            rowBodies = 0; markdownBodies = 0
            var operations:[Double] = [], turns:[Double] = []
            for tick in 0..<180 {
                let begin = ProcessInfo.processInfo.systemUptime
                let phase = CGFloat(tick < 90 ? tick : 179-tick)/89
                var frame = original
                switch scenario {
                case "move": frame.origin.x += phase*180; frame.origin.y += phase*60
                case "resize_width": frame.size.width += phase*240
                case "resize_height": frame.size.height += phase*140; frame.origin.y -= phase*140
                case "resize_corner": frame.size.width += phase*240; frame.size.height += phase*140; frame.origin.y -= phase*140
                default: break
                }
                if scenario.hasPrefix("resize") || scenario == "move" {window.setFrame(frame,display:false)}
                else {
                    let maxY = max(0,(scroll.documentView?.bounds.height ?? 0)-scroll.contentView.bounds.height)
                    // Traverse beyond the initially visible rows, then return to the tail.
                    let y = max(0,maxY-phase*12000)
                    scroll.contentView.scroll(to:NSPoint(x:0,y:y))
                    scroll.reflectScrolledClipView(scroll.contentView)
                    if scenario == "streaming_scroll" {app.conversation.messages[119].text += " token"}
                }
                operations.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
                try await Task.sleep(for:.milliseconds(16))
                turns.append((ProcessInfo.processInfo.systemUptime-begin)*1000)
            }
            let ordered = turns.sorted(), ops = operations.sorted()
            print("BENCH \(scenario) n=180 operation_p95_ms=\(ops[170]) turn_p50_ms=\(ordered[89]) turn_p95_ms=\(ordered[170]) turn_max_ms=\(ordered.last!) turns_over50=\(turns.filter{$0>50}.count) turns_over100=\(turns.filter{$0>100}.count) rows=\(rowBodies) markdown=\(markdownBodies)")
            fflush(stdout)
        }
        window.setFrame(original,display:false)
        if ProcessInfo.processInfo.arguments.contains("--manual-performance-hold") {
            app.conversation.messages[119].state = "done"
            print("MANUAL_READY"); fflush(stdout)
            try await Task.sleep(for:.seconds(180))
        }
    }
}
