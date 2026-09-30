import Cocoa

func fixtureImage(dark: Bool = false) -> CGImage {
    let size = NSSize(width: 1000, height: 720)
    let image = NSImage(size: size)
    image.lockFocus()
    NSColor(white: dark ? 0.09 : 1, alpha: 1).setFill()
    NSBezierPath(rect: CGRect(origin: .zero, size: size)).fill()
    func bubble(_ top: CGFloat, _ height: CGFloat) {
        NSColor(white: dark ? 0.20 : 0.945, alpha: 1).setFill()
        NSBezierPath(roundedRect: CGRect(x: 75, y: size.height - top - height, width: 850, height: height), xRadius: 15, yRadius: 15).fill()
    }
    let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 23), .foregroundColor: dark ? NSColor.white : NSColor.black]
    func text(_ value: String, _ top: CGFloat) {
        (value as NSString).draw(at: CGPoint(x: 98, y: size.height - top - 30), withAttributes: attributes)
    }
    text("Alex · Today 10:30", 33)
    bubble(78, 235)
    text("Could we jump to the live meeting view by default?", 105)
    text("I shared the document, but stayed in the original view.", 142)
    text("When I scroll, participants cannot see the same position.", 225)
    text("这是同一条消息的第二段补充。", 263)
    text("Sam · Today 10:35", 354)
    bubble(400, 130)
    text("Another topic: Add shortcut to a document.", 423)
    text("This unrelated message should remain unchecked.", 465)
    text("2 replies     Summarize", 560)
    image.unlockFocus()
    var rect = CGRect(origin: .zero, size: size)
    return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
}

func requireTest(_ result: Bool, _ message: String) {
    if !result { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

func runDetectionTests() throws {
    if let path = ProcessInfo.processInfo.environment["CHILLOR_CAPTURE_FIXTURE"],
       let image = NSImage(contentsOfFile:path)?.cgImage(forProposedRect:nil,context:nil,hints:nil) {
        let frame = CGRect(x:0,y:0,width:CGFloat(image.width)/2,height:CGFloat(image.height)/2)
        let candidates = candidateMessages(try recognize(image,frame:frame),image:image,frame:frame)
        let target = chooseTarget(candidates,point:CGPoint(x:813,y:472.5))
        for fragment in ["When editing a slide", "When editing the speaker notes", "both the Zoom Client", "In the Edit menu", "break the standard behavior"] {
            requireTest(target?.text.contains(fragment) == true,"Real Zoom capture dropped: \(fragment)")
        }
        requireTest(target?.text.contains("Write a message") == false,"Composer leaked into source")
        print("PASS: actual Zoom capture includes both bullets and all concluding paragraphs")
    }

    for dark in [false, true] {
        let image = fixtureImage(dark: dark)
        // Three prose paragraphs inside one bubble must not be pre-consumed
        // by the article-column pass, regardless of which paragraph is pointed at.
        let prose = (0..<3).map { index in
            TextItem(text:"Paragraph \(index) is a complete long sentence belonging to the same chat message.",
                     rect:CGRect(x:98,y:110+CGFloat(index)*60,width:750,height:20))
        }
        let grouped = candidateMessages(prose,image:image,frame:CGRect(x:0,y:0,width:1000,height:720))
        for y:CGFloat in [120,180,240] {
            let picked = chooseTarget(grouped,point:CGPoint(x:400,y:y))
            requireTest(picked?.method == "气泡边界" && (0..<3).allSatisfy {picked?.text.contains("Paragraph \($0)") == true},"Article pass stole text from a chat bubble")
        }
        let frame = CGRect(x: -250, y: 125, width: 1000, height: 720)
        let lines = try recognize(image, frame: frame)
        let messages = candidateMessages(lines, image: image, frame: frame)
        guard let target = chooseTarget(messages, point: CGPoint(x: -80, y: 245)) else { requireTest(false, "No target"); return }
        requireTest(target.method == "气泡边界", "No bubble found in \(dark ? "dark" : "light") fixture: \(messages.map { "\($0.method): \($0.text)" })")
        requireTest(target.text.contains("participants"), "Second paragraph was dropped: \(target.rect) \(target.text)")
        requireTest(target.text.contains("第二段"), "Chinese paragraph was dropped")
        requireTest(!target.text.contains("Another topic"), "Adjacent topic merged into target")
        requireTest(checkedContext(messages, excluding: [target.id]).isEmpty, "Context must be opt-in")
        var toggled = messages
        guard let otherIndex = toggled.firstIndex(where: { $0.text.contains("Another topic") }) else { requireTest(false, "Other candidate missing"); return }
        toggled[otherIndex].included = true
        let context = checkedContext(toggled, excluding: [target.id])
        requireTest(context.contains("Another topic") && !context.contains("participants"), "Selected context export is wrong")
        toggled[otherIndex].included = false
        requireTest(checkedContext(toggled, excluding: [target.id]).isEmpty, "Deselected text leaked into context")
        requireTest(chooseTarget(messages, point: CGPoint(x: 3000, y: 3000)) == nil, "Far pointer selected a message")
        print("PASS: \(dark ? "dark" : "light") multi-paragraph bubble, separate adjacent topic, opt-in context, checkbox export, negative screen coordinates")
    }
    let lines = [TextItem(text: "First line of a plain email.", rect: CGRect(x: 40, y: 50, width: 330, height: 20)),
                 TextItem(text: "Second line of this paragraph.", rect: CGRect(x: 40, y: 77, width: 360, height: 20)),
                 TextItem(text: "A separate paragraph.", rect: CGRect(x: 40, y: 150, width: 250, height: 20))]
    let groups = candidateMessages(lines, image: nil, frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    requireTest(groups.count == 2 && groups[0].text.contains("Second line"), "Plain text grouping failed")
    let articleLines = (0..<3).map { index in
        TextItem(text:"Article paragraph \(index) contains a complete sentence with enough detail to identify continuous prose.",rect:CGRect(x:200,y:100+CGFloat(index)*55,width:500,height:20))
    } + [TextItem(text:"Sidebar navigation",rect:CGRect(x:20,y:100,width:120,height:20)),TextItem(text:"Alex · Today 10:30",rect:CGRect(x:200,y:270,width:300,height:20))]
    let article = candidateMessages(articleLines,image:nil,frame:CGRect(x:0,y:0,width:900,height:600))
    let seed = article.first {$0.text.contains("paragraph 1")}!
    let ids = documentTargetIDs(article,target:seed)
    requireTest(ids.count == 3,"Visible article column was truncated or included sender/sidebar")
    let ambiguous = [MessageCandidate(text:"A",rect:CGRect(x:0,y:0,width:100,height:20),method:"文字段落"),MessageCandidate(text:"B",rect:CGRect(x:0,y:40,width:100,height:20),method:"文字段落")]
    requireTest(chooseTarget(ambiguous,point:CGPoint(x:50,y:30)) == nil,"Ambiguous inter-message gap selected a source")
    print("PASS: complete visible article column excludes sidebar/sender; ambiguous gaps require retry")
    print("PASS: plain-text fallback preserves paragraph boundaries")
}
