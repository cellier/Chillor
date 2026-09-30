import Foundation
import AppKit
import UniformTypeIdentifiers

@MainActor enum TaskRuntimeChecks {
    static func writing()async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-writing-\(UUID())")
        defer {try? FileManager.default.removeItem(at:dir)}
        let conversation = Conversation(file:dir.appendingPathComponent("conversation.json"))
        let request = ChatMessage(role:"user",text:"写一个 PRD，Zoom slides 要支持 master layout")
        let started = ProcessInfo.processInfo.systemUptime
        conversation.submit(request)
        let id = conversation.messages.last!.id
        var first:Double?
        while conversation.activeIDs.contains(id) {
            try await Task.sleep(for:.milliseconds(25))
            let elapsed = ProcessInfo.processInfo.systemUptime-started
            if first == nil,let reply = conversation.messages.first(where:{$0.id == id}),!reply.text.isEmpty {
                first = elapsed
                print("WRITING_FIRST_VISIBLE_SECONDS: \(elapsed)");fflush(stdout)
            }
            if elapsed > 240 || (first == nil && elapsed > 40) {
                conversation.stop(id)
                while conversation.activeIDs.contains(id) {try await Task.sleep(for:.milliseconds(25))}
                throw ModelFailure(message:"Writing test exceeded its response deadline")
            }
        }
        guard let reply = conversation.messages.first(where:{$0.id == id}) else {throw ModelFailure(message:"Missing writing result")}
        try SelfTests.check(reply.state == "done","Writing failed: \(reply.text.suffix(300))")
        try SelfTests.check(first != nil && (reply.artifacts?.isEmpty ?? true),"Writing still used an implicit artifact step")
        try SelfTests.check(reply.text.lowercased().contains("master") && reply.text.contains("验收"),"Draft omitted requested topic or acceptance criteria")
        print("WRITING_TOTAL_SECONDS: \(ProcessInfo.processInfo.systemUptime-started)")
        print("WRITING_CHARACTERS: \(reply.text.count)")
        let evidence = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/prd-streaming-result.md")
        try reply.text.write(to:evidence,atomically:true,encoding:.utf8)
        let exported = try await TaskCoordinator().route(request:ChatMessage(role:"user",text:"写一个 PRD，Zoom slides 要支持 master layout，保存为 Word 文件"),history:[],tasks:[],isolated:false)
        try SelfTests.check(exported.category == "document","Explicit Word request lost file output")
        print("PASS: exact PRD request streams in chat; explicit Word request retains document route")
    }
    static func presentation()async throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/native-ppt-regression")
        try await LocalModel.shared.prepare()
        let task = WorkTask(id:UUID(),title:"Zoom CEO introduction",category:"presentation",updated:Date())
        let artifacts = try await LocalToolHarness().run(task:task,messages:[["role":"user","content":"我想做一个简单的 PPT，来介绍 zoom CEO。请做成 4 页中文 PPT，并在末页列出查证来源。"]],attachments:[],root:root,onText:{print($0,terminator:"");fflush(stdout)},onStatus:{print("\nSTATUS: \($0)");fflush(stdout)})
        guard let file = artifacts.first(where:{$0.path.hasSuffix(".pptx")}) else {throw ModelFailure(message:"No actual PPT artifact was produced")}
        print("\nPPT_ARTIFACT: \(file.path)")
        print("PASS: actual local model researched and created a PowerPoint artifact")
    }
    static func web()async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-web-check-\(UUID())")
        defer {try? FileManager.default.removeItem(at:root)}
        try await LocalModel.shared.prepare()
        let request = ChatMessage(role:"user",text:"能查涠洲岛今天天气吗？请自主查证，附来源。")
        let task = try await TaskCoordinator().route(request:request,history:[],tasks:[],isolated:false)
        try SelfTests.check(task.category == "research","Weather did not route to web tools")
        var output = "",statuses:[String] = []
        _ = try await LocalToolHarness().run(task:task,messages:[["role":"user","content":request.text]],attachments:[],root:root,onText:{output += $0},onStatus:{statuses.append($0);print("STATUS: \($0)")})
        print("WEB ANSWER: \(output)")
        try SelfTests.check(statuses.contains("Searching the web") && statuses.contains("Reading webpage"),"Model did not search and open a source")
        try SelfTests.check(output.contains("https://") || output.contains("http://"),"Web answer omitted source links")
        print("PASS: local model autonomously routes, searches, reads public sources and cites its answer")
    }
    static func harness()async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-harness-check-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:root)}
        try await LocalModel.shared.prepare()
        let task = WorkTask(id:UUID(),title:"Bakery site",category:"website",updated:Date())
        var output = ""
        let artifacts = try await LocalToolHarness().run(task:task,messages:[["role":"user","content":"Create index.html in the workspace: a minimal valid HTML page with title Bakery and heading Fresh bread. Use write_text. Then read it back with read_file and confirm the heading. Do not merely print code."]],attachments:[],root:root,onText:{output += $0},onStatus:{print("STATUS: \($0)")})
        guard let file = artifacts.first(where:{$0.name == "index.html"}) else {throw ModelFailure(message:"Harness did not create website artifact: \(output)")}
        let text = try String(contentsOfFile:file.path,encoding:.utf8)
        try SelfTests.check(text.contains("Fresh bread"),"Website content was not generated")
        let changed = try await LocalToolHarness().run(task:task,messages:[["role":"user","content":"Read existing index.html and change its heading from Fresh bread to Daily bread, preserving the page. Use tools to save the file."]],attachments:[],root:root,onText:{_ in},onStatus:{print("STATUS: \($0)")})
        try SelfTests.check(!changed.isEmpty && (try String(contentsOfFile:file.path,encoding:.utf8)).contains("Daily bread"),"Follow-up did not update task artifact")
        print("PASS: native Ollama + local Qwen + workspace tools create, read and modify website, returning real artifacts")
        let cancelled = Task {
            try await LocalToolHarness().run(task:task,messages:[["role":"user","content":"List workspace files and then read index.html."]],attachments:[],root:root,onText:{_ in},onStatus:{_ in})
        }
        try await Task.sleep(for:.milliseconds(300));cancelled.cancel()
        do {_ = try await cancelled.value;throw ModelFailure(message:"Cancelled harness returned success")}
        catch is CancellationError {print("PASS: cancelling work terminates the local harness")}

    }
    static func run(realModel:Bool)async throws {
        let check = SelfTests.check
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-tasks-\(UUID())")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:true)
        defer {try? FileManager.default.removeItem(at:dir)}
        try await imageDrop(in:dir)
        try await deletion(in:dir)
        try recall(in:dir)
        try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:"写一个 PRD，Zoom slides 要支持 master layout"))?.category == "writing","PRD still requires a hidden file-generation step")
        for text in ["写一个 PRD，保存为 Word 文件","写一个 PRD，根据刚才的内容修改","写一个 PRD，查找最新资料并列出来源","写一个 PRD，基于附件","写一个 PRD，顺便生成网页"] {
            try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:text)) == nil,"Writing shortcut swallowed file/research/continuation request")
        }
        try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:"Write a PRD as a .md file")) == nil,"Markdown file request bypassed tools")
        let task = WorkTask(id:UUID(),title:"Build a bakery website",category:"website",updated:Date())
        let other = WorkTask(id:UUID(),title:"Quarterly budget spreadsheet",category:"spreadsheet",updated:Date())
        var prior = ChatMessage(role:"assistant",text:"Discussing a bakery website");prior.taskID = task.id
        let follow = try await TaskCoordinator().route(request:ChatMessage(role:"user",text:"继续修改标题"),history:[prior],tasks:[task,other],isolated:false)
        try check(follow.id == task.id,"Local route lost immediate continuation")
        let weather = try await TaskCoordinator().route(request:ChatMessage(role:"user",text:"杭州天气如何"),history:[prior],tasks:[task],isolated:false)
        try check(weather.category == "research" && weather.id != task.id,"New topic reused previous workspace")
        let request = UUID()
        var store:TaskStore? = try TaskStore(url:dir.appendingPathComponent("tasks.sqlite"))
        try store!.save(task,request:request,event:"task.started")
        try store!.save(other,request:UUID(),event:"task.started")
        store = nil
        let reopened = try TaskStore(url:dir.appendingPathComponent("tasks.sqlite"))
        try check(try reopened.all().count == 2,"Tasks were lost after reopening")
        let invalid = TaskCoordinator.resolve(TaskRoute(taskID:UUID().uuidString,title:"New task",category:"made-up"),candidates:[task])
        try check(invalid.id != task.id && invalid.category == "conversation","Unrecognized route reused another task")
        let lookup = TaskCoordinator.resolve(TaskRoute(taskID:task.id.uuidString,title:task.title,category:"research"),candidates:[task])
        try check(lookup.id == task.id && lookup.category == "research","Existing task could not acquire web lookup capability")
        let compact = try TaskCoordinator.resolveCompact(CompactTaskRoute(task:0,category:"research"),request:ChatMessage(role:"user",text:"Check sources"),candidates:[task])
        try check(compact.id == task.id && compact.category == "research","Compact routing lost existing task identity")
        do {
            _ = try TaskCoordinator.resolveCompact(CompactTaskRoute(task:1,category:"research"),request:ChatMessage(role:"user",text:"Check"),candidates:[task])
            throw ModelFailure(message:"Invalid task index accepted")
        } catch let error as ModelFailure {try check(error.message != "Invalid task index accepted","Invalid task index accepted")}
        let advice = ChatMessage(role:"user",text:"你觉得杭州这边，婚礼随礼多少钱比较合适")
        try check(TaskCoordinator.fastRoute(request:advice)?.category == "conversation","Everyday advice took semantic routing")
        for text in ["根据刚才的预算，你觉得哪个合适", "你觉得今天股票投资多少合适", "你觉得这份文件怎么修改比较好", "你觉得杭州随礼多少合适，查一下最新来源"] {
            try check(!TaskCoordinator.isEverydayAdvice(ChatMessage(role:"user",text:text)),"Advice shortcut swallowed references or actions")
        }
        let oldScreen = ChatMessage(role:"user",text:"Translate",attachments:[Attachment(name:"Screen context",text:String(repeating:"old screen",count:1000),imageData:Data([1,2,3]))])
        var newAdvice = advice;newAdvice.taskID = UUID()
        let advicePayload = Conversation(file:dir.appendingPathComponent("advice.json")).payload(request:newAdvice,history:[oldScreen,ChatMessage(role:"assistant",text:"Translation")],includeRecentDialogue:true)
        try check(!advicePayload.contains(where:{$0["images"] != nil}) && !String(describing:advicePayload).contains("old screen"),"Unrelated screen image leaked into advice prompt")
        try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:"你好！"))?.category == "conversation","Greeting missed the fast path")
        for text in ["你好，查一下天气","继续","谢谢，改一下 PPT","hello, read this URL"] {
            try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:text)) == nil,"Fast path swallowed a task request")
        }
        try check(TaskCoordinator.fastRoute(request:ChatMessage(role:"user",text:"hi",attachments:[Attachment(name:"file",text:"source")])) == nil,"Fast path ignored an attachment")
        var a = ChatMessage(role:"user",text:"Bakery uses the SECRET_CINNAMON theme");a.taskID = task.id
        var b = ChatMessage(role:"assistant",text:"Budget SECRET_BUDGET");b.taskID = other.id
        var c = ChatMessage(role:"user",text:"Change the heading");c.taskID = task.id
        let conversation = Conversation(file:dir.appendingPathComponent("conversation.json"))
        let payload = conversation.payload(request:c,history:[a,b])
        let serialized = String(decoding:try JSONSerialization.data(withJSONObject:payload),as:UTF8.self)
        try check(serialized.contains("SECRET_CINNAMON") && !serialized.contains("SECRET_BUDGET"),"Cross-task context leaked")
        var extended = [a]
        for index in 0..<20 {
            var filler = ChatMessage(role:index % 2 == 0 ? "user":"assistant",text:"Later task detail \(index)")
            filler.taskID = task.id;extended.append(filler)
        }
        let full = conversation.payload(request:c,history:extended)
        try check(full.contains(where:{($0["content"] as? String) == a.text}),"Old intent was discarded before SDK compaction")
        try check(full.count == extended.count+2,"Task history was limited to a fixed number of messages")
        try check(full.last?["id"] as? String == c.id.uuidString,"Request identity missing from SDK session input")
        let isolated = conversation.payload(request:c,history:[a,b],isolated:true)
        try check(isolated.count == 2,"Quick command imported task history")
        let legacy = ChatMessage(role:"assistant",text:"Legacy chosen result")
        c.replyTo = legacy.id
        let legacyPayload = conversation.payload(request:c,history:[a,b,legacy])
        try check(legacyPayload.count == 3,"Legacy explicit reference was lost")
        let coordinator = TaskCoordinator()
        let first = UUID(), second = UUID()
        try await coordinator.acquire(first)
        let queued = Task {try await coordinator.acquire(second)}
        await Task.yield();queued.cancel()
        do {try await queued.value;throw ModelFailure(message:"Cancelled queue item executed")} catch is CancellationError {}
        coordinator.release()
        try await coordinator.acquire(UUID());coordinator.release()
        let anchored = ChatMessage(role:"user",text:"Make it shorter",replyTo:a.id)
        let route = try await coordinator.route(request:anchored,history:[a,b],tasks:[task,other],isolated:false)
        try check(route.id == task.id,"Explicit reference did not outrank recent task")
        let export = ChatMessage(role:"user",text:"Save this as a .md file",replyTo:a.id)
        let exportRoute = try await coordinator.route(request:export,history:[a,b],tasks:[task,other],isolated:false)
        try check(exportRoute.id == task.id && exportRoute.category == "document","Anchored Markdown export lost the task or file route")
        print("PASS: SQLite persistence, task isolation, legacy reference, routing validation, queued cancellation, explicit continuation")
        var followup = ChatMessage(role:"user",text:"Will that change?");followup.taskID = UUID()
        let fallback = conversation.payload(request:followup,history:[a,b],includeRecentDialogue:true)
        try check(fallback.contains(where:{($0["content"] as? String) == b.text}),"New chat task lost immediate dialogue")
        let isolatedFallback = conversation.payload(request:followup,history:[a,b],isolated:true,includeRecentDialogue:true)
        try check(isolatedFallback.count == 2,"Dialogue fallback contaminated quick commands")
        if realModel {
            let topic = WorkTask(id:UUID(),title:"Early cancer symptoms",category:"conversation",updated:Date())
            var question = ChatMessage(role:"user",text:"生癌早期会有什么症状？");question.taskID = topic.id
            var answer = ChatMessage(role:"assistant",text:"你在问癌症早期症状，其中讨论了体重变化。");answer.taskID = topic.id
            let next = ChatMessage(role:"user",text:"会变胖吗")
            let continued = try await coordinator.route(request:next,history:[question,answer],tasks:[topic,task,other],isolated:false)
            try check(continued.id == topic.id,"Implicit follow-up lost its immediate subject")
            let changed = try await coordinator.route(request:ChatMessage(role:"user",text:"帮我做一个面包店网站"),history:[question,answer],tasks:[topic],isolated:false)
            try check(changed.id != topic.id && changed.category == "website","New topic was forced into the previous conversation")
            print("PASS: real local implicit follow-up and explicit subject change")
            let history = [a,b]
            let cases:[(String,UUID?)] = [("回到刚才那个面包店网站，把标题改短一点",task.id),("今天吃什么比较好？",nil),("继续修改那个季度预算表，增加一列实际支出",other.id)]
            for (text,expected) in cases {
                let result = try await coordinator.route(request:ChatMessage(role:"user",text:text),history:history,tasks:[other,task],isolated:false)
                if let expected {try check(result.id == expected,"Local model routed a continuation to the wrong task")}
                else {try check(![task.id,other.id].contains(result.id),"Local model attached unrelated question to existing work")}
                print("PASS: real local routing — \(text) → \(result.category)")
            }
        }
    }
    private static func imageDrop(in dir:URL) async throws {
        let conversation = Conversation(file:dir.appendingPathComponent("image-drop.json"))
        conversation.draft = "Keep my prompt"
        let image = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:16,pixelsHigh:16,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        let png = image.representation(using:.png,properties:[:])!
        func provider(_ name:String)->NSItemProvider {
            let item = NSItemProvider();item.suggestedName = name
            item.registerDataRepresentation(forTypeIdentifier:UTType.png.identifier,visibility:.all) { handler in handler(png,nil);return nil }
            return item
        }
        try SelfTests.check(conversation.importDroppedImages([provider("First"),provider("Second")]),"Multi-image drop rejected")
        while conversation.importing {try await Task.sleep(for:.milliseconds(10))}
        try SelfTests.check(conversation.attachments.map(\.name) == ["First","Second"] && conversation.draft == "Keep my prompt","Drop order or prompt changed")
        let removed = conversation.attachments[0].id
        conversation.attachments.removeAll {$0.id == removed}
        try SelfTests.check(conversation.attachments.count == 1,"Independent removal failed")
        let url = dir.appendingPathComponent("drop.png");try png.write(to:url)
        let file = NSItemProvider(item:url as NSURL,typeIdentifier:UTType.fileURL.identifier)
        try SelfTests.check(conversation.importDroppedImages([file]),"Finder file drop rejected")
        while conversation.importing {try await Task.sleep(for:.milliseconds(10))}
        try SelfTests.check(conversation.attachments.count == 2 && conversation.attachmentError == nil,"Finder image URL did not import")
        try SelfTests.check(!conversation.importDroppedImages([provider("A"),provider("B"),provider("C")]),"Attachment limit bypassed")
        print("PASS: multi-image drop, Finder URL import, order, prompt preservation, removal and attachment limit")
        let board = NSPasteboard.withUniqueName()
        defer {board.releaseGlobally()}
        conversation.attachments = []
        let first = NSPasteboardItem();first.setData(png,forType:.png)
        let second = NSPasteboardItem();second.setData(image.tiffRepresentation!,forType:.tiff)
        board.writeObjects([first,second])
        try SelfTests.check(ContextImagePaste.hasImages(board),"Image clipboard not recognized")
        let editor = PromptTextView()
        editor.string = "Keep my prompt"
        editor.onPasteImages = {_ in conversation.importPastedImages(board)}
        editor.paste(nil)
        while conversation.importing {try await Task.sleep(for:.milliseconds(10))}
        try SelfTests.check(conversation.attachments.count == 2 && conversation.draft == "Keep my prompt" && editor.string == "Keep my prompt","Pasted images lost or replaced draft")
        try SelfTests.check(conversation.attachments.allSatisfy {$0.imageData?.starts(with:[137,80,78,71]) == true},"Clipboard image was not normalized to PNG")
        board.clearContents();board.setString("Plain text",forType:.string)
        try SelfTests.check(!conversation.importPastedImages(board),"Plain text paste intercepted")
        board.clearContents();board.writeObjects([url as NSURL])
        try SelfTests.check(conversation.importPastedImages(board),"Finder clipboard image not recognized")
        while conversation.importing {try await Task.sleep(for:.milliseconds(10))}
        try SelfTests.check(conversation.attachments.count == 3,"Finder paste duplicated image representations")
        print("PASS: PNG and TIFF clipboard images, multiple images, Finder copy, plain-text fallback and draft preservation")
    }
    private static func recall(in dir:URL)throws {
        let check = SelfTests.check
        let conversation = Conversation(file:dir.appendingPathComponent("recall.json"))
        let old = ChatMessage(role:"user",text:String(repeating:"背景资料。",count:300)+"项目代号是 SILVER_MAPLE。",taskID:UUID())
        let history = [old] + (0..<30).map {ChatMessage(role:"user",text:"Topic \($0)",taskID:UUID())}
        conversation.messages = history;conversation.persist()
        let reopened = Conversation(file:dir.appendingPathComponent("recall.json"))
        let request = ChatMessage(role:"user",text:"我之前说的项目代号是什么？",taskID:UUID())
        func serialized(_ isolated:Bool = false)throws->String {
            String(decoding:try JSONSerialization.data(withJSONObject:reopened.payload(request:request,history:reopened.messages,isolated:isolated,recallingHistory:true)),as:UTF8.self)
        }
        try check(try serialized().contains("SILVER_MAPLE"),"Recall lost old history or keyword deep in message after reopening")
        try check(try !serialized(true).contains("SILVER_MAPLE"),"Recall leaked into isolated quick command")
        let unrelated = reopened.payload(request:ChatMessage(role:"user",text:"New unrelated topic",taskID:UUID()),history:reopened.messages)
        try check(!String(decoding:JSONSerialization.data(withJSONObject:unrelated),as:UTF8.self).contains("SILVER_MAPLE"),"Recall leaked into unrelated task")
        reopened.delete(old)
        try check(try !serialized().contains("SILVER_MAPLE"),"Deleted memory was recalled")
        let broad = ConversationRecall.evidence(query:"我说的是以往的聊天",history:reopened.messages)
        try check(broad.contains("Topic 29") && broad.contains("Topic 18"),"Broad recall did not cover distinct topics")
        try check(broad.count < 13000,"Recall context exceeded bounded budget")
        print("PASS: local history recall, old keyword retrieval, restart, deletion, bounded topic coverage and quick-command isolation")
    }
    static func recallModel()async throws {
        let check = SelfTests.check
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chillor-recall-\(UUID())")
        defer {try? FileManager.default.removeItem(at:dir)}
        let file = dir.appendingPathComponent("conversation.json")
        let saved = Conversation(file:file)
        saved.messages = [ChatMessage(role:"user",text:"我的项目代号是 SILVER_MAPLE。",taskID:UUID()),
                          ChatMessage(role:"user",text:"我们给面包店做了一个网站，首页标题定为 Daily Bread。",taskID:UUID()),
                          ChatMessage(role:"user",text:"另一件事是整理季度预算表。",taskID:UUID()),
                          ChatMessage(role:"assistant",text:"我无法访问以往的聊天记录，每次对话都是全新的开始。",taskID:UUID())]
        saved.persist()
        let reopened = Conversation(file:file)
        for (question,expected) in [("我说的是以往的聊天","面包"),("我之前告诉你的项目代号是什么？","SILVER_MAPLE")] {
            var request = ChatMessage(role:"user",text:question)
            let task = try await TaskCoordinator().route(request:request,history:reopened.messages,tasks:[],isolated:false)
            try check(task.category == "recall","History question did not route to local recall")
            request.taskID = task.id
            var answer = ""
            try await LocalModel.shared.respond(messages:reopened.payload(request:request,history:reopened.messages,recallingHistory:true),maxTokens:400) {answer += $0}
            print("RECALL ANSWER: \(answer)")
            try check(answer.contains(expected),"Model did not use retrieved history")
        }
        print("PASS: real local model recalls previous topics and an old fact after reopening")
    }
    private static func deletion(in dir:URL)async throws {
        let check = SelfTests.check
        let file = dir.appendingPathComponent("deletion.json")
        let conversation = Conversation(file:file)
        let taskID = UUID()
        let user = ChatMessage(role:"user",text:"DELETE_ONLY_SOURCE",taskID:taskID)
        let reply = ChatMessage(role:"assistant",text:"Keep this response",replyTo:user.id,state:"failed",taskID:taskID)
        let other = ChatMessage(role:"user",text:"Keep this question",taskID:taskID)
        conversation.messages = [user,reply,other]
        conversation.anchor = user;conversation.scrollTarget = user.id
        try check(conversation.canRetry(reply),"Existing failed reply cannot retry")
        conversation.delete(user)
        try check(conversation.messages.map(\.id) == [reply.id,other.id],"Deleting a question removed other messages")
        try check(conversation.anchor == nil && conversation.scrollTarget == nil && conversation.messages[0].replyTo == nil,"Deletion left dangling references")
        try check(!conversation.canRetry(conversation.messages[0]),"Orphaned reply still offers Retry")
        conversation.search = "DELETE_ONLY_SOURCE"
        try check(conversation.results.isEmpty,"Deleted message remains searchable")
        let input = conversation.payload(request:other,history:conversation.messages)
        let json = String(decoding:try JSONSerialization.data(withJSONObject:input),as:UTF8.self)
        try check(!json.contains("DELETE_ONLY_SOURCE"),"Deleted message remains in model context")
        try check(Conversation(file:file).messages == conversation.messages,"Deleted question reappeared after reopening")
        conversation.delete(reply)
        conversation.delete(reply)
        try check(Conversation(file:file).messages == [other],"Assistant deletion was not persisted or repeat deletion changed remaining messages")
        conversation.delete(other)
        try check(Conversation(file:file).messages.isEmpty,"Deleting the last message did not persist an empty conversation")

        // Delete synchronously before yielding so these checks never contact a model.
        let pending = ChatMessage(role:"user",text:"Pending request")
        conversation.submit(pending)
        let pendingReply = conversation.messages.last!
        conversation.delete(pendingReply)
        for _ in 0..<100 where !conversation.activeIDs.isEmpty {
            try await Task.sleep(for:.milliseconds(10))
        }
        try check(conversation.activeIDs.isEmpty && conversation.activity.isEmpty,"Deleted response left an active job")
        try check(Conversation(file:file).messages == [pending],"Cancelled job resurrected a deleted response")
        let next = ChatMessage(role:"user",text:"Delete pending question")
        conversation.submit(next)
        let nextReplyID = conversation.messages.last!.id
        conversation.delete(next)
        for _ in 0..<100 where !conversation.activeIDs.isEmpty {
            try await Task.sleep(for:.milliseconds(10))
        }
        try check(conversation.activeIDs.isEmpty && conversation.activity.isEmpty,"Deleting a question failed to cancel its reply")
        let remaining = conversation.messages.first(where:{$0.id == nextReplyID})
        try check(remaining?.state == "cancelled" && remaining?.replyTo == nil,"Pending reply was not safely detached")
        try check(Conversation(file:file).messages == conversation.messages,"Cancellation cleanup lost deletion on disk")
        print("PASS: user/assistant deletion, references, search/context removal, reopening, empty conversation and generation cancellation")
    }
}
