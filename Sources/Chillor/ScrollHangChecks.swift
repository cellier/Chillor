import AppKit

@MainActor enum ScrollHangChecks {
    static func run() async throws {
        guard let app = NSApp.delegate as? AppDelegate else {throw ModelFailure(message:"No app")}
        let path = ProcessInfo.processInfo.environment["CHILLOR_SCROLL_FIXTURE"] ?? ""
        let messages = try JSONDecoder().decode([ChatMessage].self,from:Data(contentsOf:URL(fileURLWithPath:path)))
        app.conversation.messages = messages
        app.main.window?.setContentSize(NSSize(width:800,height:760))
        print("SCROLL_FIXTURE messages=\(messages.count)");fflush(stdout)
        try await Task.sleep(for:.milliseconds(800))
        func find(_ view:NSView)->NSScrollView? {
            if view is ConversationRowPosition.Marker {return view.enclosingScrollView}
            return view.subviews.compactMap {find($0)}.first
        }
        guard let scroll = find(app.main.content) else {throw ModelFailure(message:"No scroll")}
        var maxTurn = 0.0
        var reachedTop = false, reachedBottom = false
        for pass in 0..<4 {
            for tick in 0..<210 {
                let start = ProcessInfo.processInfo.systemUptime
                let delta:Int32 = pass.isMultiple(of:2) ? 110:-110
                let event = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:delta,wheel2:0,wheel3:0)!
                event.setIntegerValueField(.scrollWheelEventScrollPhase,value:tick == 0 ? 1:2)
                scroll.scrollWheel(with:NSEvent(cgEvent:event)!)
                try await Task.sleep(for:.milliseconds(25))
                maxTurn = max(maxTurn,ProcessInfo.processInfo.systemUptime-start)
                reachedTop = reachedTop || scroll.contentView.bounds.minY<=1
                reachedBottom = reachedBottom || scroll.documentView!.bounds.maxY-scroll.contentView.bounds.maxY<=1
                if tick%20 == 0 {print("SCROLL_PROGRESS pass=\(pass) tick=\(tick) y=\(scroll.contentView.bounds.minY) height=\(scroll.documentView!.bounds.height)");fflush(stdout)}
            }
            let end = CGEvent(scrollWheelEvent2Source:nil,units:.pixel,wheelCount:1,wheel1:0,wheel2:0,wheel3:0)!
            end.setIntegerValueField(.scrollWheelEventScrollPhase,value:4)
            scroll.scrollWheel(with:NSEvent(cgEvent:end)!)
            try await Task.sleep(for:.milliseconds(300))
        }
        try SelfTests.check(reachedTop && reachedBottom,"Test did not traverse the whole transcript")
        try SelfTests.check(maxTurn<1,"Scroll blocked the main thread for over a second")
        print("PASS: four full scroll traversals; max main-thread turn \(maxTurn) seconds");fflush(stdout)
    }
}
