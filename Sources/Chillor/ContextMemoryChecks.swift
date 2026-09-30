import Foundation
import CSQLite

@MainActor enum ContextMemoryChecks {
    static func run()async throws {
        let root = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/native-memory-\(UUID())")
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        let conversation = Conversation(file:root.appendingPathComponent("conversation.json"))
        func submit(_ request:ChatMessage)async throws->ChatMessage {
            conversation.submit(request)
            let id = conversation.messages.last!.id
            let started = ProcessInfo.processInfo.systemUptime
            while conversation.activeIDs.contains(id) {
                try await Task.sleep(for:.milliseconds(30))
                if ProcessInfo.processInfo.systemUptime-started>150 {
                    conversation.stop(id);throw ModelFailure(message:"Memory test exceeded 150 seconds")
                }
            }
            let answer = conversation.messages.first(where:{$0.id == id})!
            try SelfTests.check(answer.state == "done","Memory request failed: \(answer.text)")
            print("MEMORY_ANSWER: \(answer.text)");fflush(stdout)
            return answer
        }
        let source = ChatMessage(role:"user",text:"请记住：我的测试代号是苍柏，今后提到我的测试代号时就用这个名字。")
        _ = try await submit(source)
        for i in 0..<12 {
            var unrelated = ChatMessage(role:i%2 == 0 ? "user":"assistant",text:"独立讨论 \(i)：月亮的圆缺与观察角度有关。")
            unrelated.taskID = UUID();conversation.messages.append(unrelated)
        }
        conversation.persist()
        let answer = try await submit(ChatMessage(role:"user",text:"我的测试代号是什么？只回复代号。"))
        try SelfTests.check(answer.text.contains("苍柏"),"Cross-task personal memory was not retrieved")
        let database = root.appendingPathComponent("AgentWork/personal-memory.sqlite")
        var db:OpaquePointer?
        guard sqlite3_open(database.path,&db) == SQLITE_OK else {throw ModelFailure(message:"Memory database missing")}
        defer {sqlite3_close(db)}
        func count(_ sql:String)->Int {
            var statement:OpaquePointer?
            guard sqlite3_prepare_v2(db,sql,-1,&statement,nil) == SQLITE_OK else {return -1}
            defer {sqlite3_finalize(statement)}
            return sqlite3_step(statement) == SQLITE_ROW ? Int(sqlite3_column_int(statement,0)):-1
        }
        try SelfTests.check(count("SELECT count(*) FROM memories WHERE status='active' AND source_id='\(source.id.uuidString)'")>0,"No source-bound memory was saved")
        conversation.delete(source)
        try SelfTests.check(!conversation.messages.contains(where:{$0.id == source.id}),"Source message deletion failed")
        try SelfTests.check(count("SELECT count(*) FROM memories WHERE source_id='\(source.id.uuidString)' AND (status='active' OR value!='' OR quote!='')") == 0,"Deleted message left active memory values")
        try SelfTests.check(count("SELECT count(*) FROM memory_search") == 0,"Deleted source remained in memory search")
        try SelfTests.check(count("SELECT count(*) FROM memory_hidden_messages")>0,"Deleted source's detached answer could rehydrate its memory")
        print("PASS: native submission, packaged SDK/MCP, shared source-bound memory across tasks and native deletion/FTS invalidation. Evidence: \(root.path)")
    }
}
