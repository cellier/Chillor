import Foundation

@MainActor enum ResponsePerformanceChecks {
    static func run()async throws {
        for text in ["hi 你好","Hi，你好！","hello 您好","你是谁，你能做什么？","你好！","请介绍一下你自己。","Who are you and what can you do?"] {
            try SelfTests.check(ResponseProfile.isIntroduction(ChatMessage(role:"user",text:text)),"Missed introduction: \(text)")
        }
        for text in ["hi 你好 帮我查天气","hi 修改文件","你好 会变胖吗","你能帮我查找并读取文件吗？","你好，帮我创建一个文件","你是谁？把回答保存为文件", "介绍一下之前的项目", "What can you do with the file above?", "你还记得我是谁吗？"] {
            try SelfTests.check(!ResponseProfile.isIntroduction(ChatMessage(role:"user",text:text)),"Action/history bypassed routing: \(text)")
        }
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/response-speed-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let conversation = Conversation(file:root.appendingPathComponent("conversation.json"))
        let oldTask = UUID()
        for n in 0..<24 {
            var old = ChatMessage(role:n % 2 == 0 ? "user":"assistant",text:"旧任务 \(n)："+String(repeating:"这是以前的长篇网站方案，和当前的问题无关。",count:160))
            old.taskID = oldTask;conversation.messages.append(old)
        }
        let request = ChatMessage(role:"user",text:"hi 你好")
        let payload = conversation.payload(request:request,history:conversation.messages,includeRecentDialogue:true)
        try SelfTests.check(payload.count == 2,"Introduction imported unrelated task history")
        try SelfTests.check(TaskCoordinator.fastRoute(request:request)?.category == "conversation","Greeting invoked semantic routing")
        var anchored = request;anchored.replyTo = conversation.messages.last!.id
        try SelfTests.check(!ResponseProfile.isIntroduction(anchored),"Explicit reply lost context")
        let started = ProcessInfo.processInfo.systemUptime
        conversation.submit(request)
        let id = conversation.messages.last!.id
        var first:Double?
        while conversation.activeIDs.contains(id) {
            try await Task.sleep(for:.milliseconds(20))
            let elapsed = ProcessInfo.processInfo.systemUptime-started
            if first == nil,let answer = conversation.messages.first(where:{$0.id == id}),!answer.text.isEmpty {
                first = elapsed;print("SPEED_FIRST_VISIBLE_SECONDS: \(elapsed)");fflush(stdout)
            }
            if elapsed > 90 {
                conversation.stop(id)
                throw ModelFailure(message:"Simple introduction exceeded 90 seconds")
            }
        }
        let answer = conversation.messages.first(where:{$0.id == id})!
        try SelfTests.check(answer.state == "done" && !answer.text.isEmpty,"Introduction failed: \(answer.text)")
        let total = ProcessInfo.processInfo.systemUptime-started
        print("SPEED_TOTAL_SECONDS: \(total)\nSPEED_ANSWER: \(answer.text)\nSPEED_EVIDENCE: \(root.path)")
        let trace = root.appendingPathComponent("AgentWork/sessions/\(answer.taskID!.uuidString)/trace.jsonl")
        try SelfTests.check(!FileManager.default.fileExists(atPath:trace.path),"Greeting unnecessarily started an agent tool session")
        print("PASS: native submission with 24 long old messages completed directly without classification, compaction or tools")
    }
}
