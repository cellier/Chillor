import Foundation

struct WorkArtifact:Codable,Identifiable,Equatable {
    var id = UUID()
    var path:String
    var name:String
    var validation:String
}

@MainActor protocol AgentHarness {
    func run(task:WorkTask,messages:[[String:Any]],attachments:[Attachment],root:URL,onText:@escaping(String)->Void,onStatus:@escaping(String)->Void)async throws->[WorkArtifact]
}

@MainActor final class LocalToolHarness:AgentHarness {
    func run(task:WorkTask,messages:[[String:Any]],attachments:[Attachment],root:URL,onText:@escaping(String)->Void,onStatus:@escaping(String)->Void)async throws->[WorkArtifact] {
        guard let resources = Bundle.main.resourceURL else {throw ModelFailure(message:"Application resources missing.")}
        let executable = resources.appendingPathComponent("AgentPython/bin/python3")
        let script = resources.appendingPathComponent("AgentTools/server.py")
        guard FileManager.default.isExecutableFile(atPath:executable.path) else {throw ModelFailure(message:"The local work runtime is not installed.")}
        if !ModelRouting.usesCloud {await ModelWarmth.shared.begin()}
        defer {if !ModelRouting.usesCloud {ModelWarmth.shared.end()}}
        try await LocalModel.shared.prepare()
        let workspace = root.appendingPathComponent("workspaces/\(task.id.uuidString)")
        try FileManager.default.createDirectory(at:workspace,withIntermediateDirectories:true)
        var imported:[String] = []
        for attachment in attachments {
            guard let source = attachment.sourcePath else {continue}
            let original = URL(fileURLWithPath:source)
            guard (try original.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? Int.max <= 20_000_000 else {throw ModelFailure(message:"Selected file exceeds 20 MB.")}
            let relative = "inputs/\(attachment.id.uuidString)-\(original.lastPathComponent)"
            let destination = workspace.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at:destination.deletingLastPathComponent(),withIntermediateDirectories:true)
            if !FileManager.default.fileExists(atPath:destination.path) {try FileManager.default.copyItem(at:original,to:destination)}
            imported.append(relative)
        }
        let runRoot = root.appendingPathComponent("runs/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at:runRoot,withIntermediateDirectories:true)
        let prompt = runRoot.appendingPathComponent("request.json")
        let introduction = attachments.isEmpty && messages.count == 2 && messages.first?["content"] as? String == ResponseProfile.introduction
        try JSONSerialization.data(withJSONObject:["conversation":messages,"importedFiles":imported,"runID":runRoot.lastPathComponent,
            "responseProfile":introduction ? "introduction":"agent","taskCategory":task.category,"taskID":task.id.uuidString,"taskTitle":task.title]).write(to:prompt,options:.atomic)
        defer {try? FileManager.default.removeItem(at:prompt)}
        let process = Process(), output = Pipe(), errors = Pipe(), nativeInput = Pipe()
        let desktop = DesktopTools()
        process.executableURL = executable
        process.currentDirectoryURL = workspace
        process.arguments = [script.path,"--agent",prompt.path,"--system", """
        Work on workspace copies; read inputs before editing. Use Office tools for Office formats, write_text for .md and HTML/CSS/JS. Preserve requested formats; default unspecified text files to .md. Return actual files, not code blocks.
        A long file must never be produced in one call: write the opening section with write_text mode "replace", then add each further section with mode "append", and change an existing file with edit_file rather than rewriting it. Aim for well under \(InferencePolicy.maxOutputTokens / 2) tokens per call. To illustrate a page, use read_webpage to find image URLs and fetch_image to save one into the workspace, then reference it by its relative path; never invent an image path or hotlink a remote URL. Do not claim visual verification or recalculated formulas; the app attaches artifacts, so omit absolute paths in prose.
        Use search_web and read_webpage for current facts, public URLs or requested lookups. Search minimal public terms, never private input. Read sources and cite returned URLs; prefer official profiles for biographies and credentials. Omit unverifiable claims. If irrelevant, simplify the search and retry. Check location and forecast dates; never invent weather or silently substitute a nearby city. Today's local date is \(DateFormatter.localizedString(from:Date(),dateStyle:.medium,timeStyle:.none)).
        desktop_control is available only in desktop tasks. Inspect fresh native IDs before acting; respect permission and native confirmations. Never bypass cancellation, run code, reveal secrets, or take unrequested actions through desktop controls. Never ask to install extensions.
        """]
        process.environment = ["PATH":"/usr/bin:/bin","HOME":NSHomeDirectory(),
            "CHILLOR_WORKSPACE":workspace.path,"CHILLOR_TOOL_SCOPE":"all",
            "HTTP_PROXY":"","HTTPS_PROXY":"","ALL_PROXY":"", "NO_PROXY":"localhost,127.0.0.1,::1",
            "no_proxy":"localhost,127.0.0.1,::1","PYTHONDONTWRITEBYTECODE":"1"]
        process.environment?["CHILLOR_STATE_DIR"] = root.appendingPathComponent("sessions/\(task.id.uuidString)").path
        process.environment?["CHILLOR_MEMORY_PATH"] = root.appendingPathComponent("personal-memory.sqlite").path
        let conversationFile = root.deletingLastPathComponent().appendingPathComponent("conversation.json")
        if FileManager.default.fileExists(atPath:conversationFile.path) {
            process.environment?["CHILLOR_CONVERSATION_FILE"] = conversationFile.path
        }
        process.environment?["CHILLOR_PROVIDER"] = ModelRouting.provider.rawValue
        process.environment?["CHILLOR_MODEL"] = ModelRouting.activeModelName
        process.environment?["CHILLOR_NUM_CTX"] = String(InferencePolicy.contextSize)
        process.environment?["CHILLOR_MAX_TOKENS"] = String(InferencePolicy.maxOutputTokens)
        process.environment?["CHILLOR_KEEP_ALIVE"] = InferencePolicy.keepAlive
        process.environment?["CHILLOR_THINK"] = "false"
        if ModelRouting.usesCloud {
            guard let key = ModelCredentials.read() else {
                throw ModelFailure(message:"Add a DeepSeek API key in Settings, or switch back to the local model.")
            }
            process.environment?["CHILLOR_API_BASE"] = ModelRouting.endpoint.absoluteString
            process.environment?["CHILLOR_API_KEY"] = key
            // The worker must reach the public API, so the loopback-only proxy
            // blanking below is lifted and the user's system proxy is honoured.
            for name in ["HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","NO_PROXY","no_proxy"] {
                process.environment?[name] = ProcessInfo.processInfo.environment[name]
            }
            process.environment?["NO_PROXY"] = "localhost,127.0.0.1,::1"
            process.environment?["no_proxy"] = "localhost,127.0.0.1,::1"
        }
        process.environment?["CHILLOR_DESKTOP_BRIDGE"] = task.category == "desktop" ? "1":"0"
        process.standardInput = nativeInput;process.standardOutput = output;process.standardError = errors
        onStatus(task.category == "document" ? "Drafting document":task.category == "presentation" ? "Drafting presentation":task.category == "spreadsheet" ? "Preparing spreadsheet":task.category == "website" ? "Preparing website":"Thinking")
        var artifacts:[WorkArtifact] = []
        var completed = false
        var runtimeFailure:String?
        var lastTextMessageID:String?
        var stderr = ""
        // Drain both pipes concurrently so verbose diagnostics can never deadlock.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty {Task { @MainActor in stderr += String(decoding:data,as:UTF8.self);if stderr.count>16000 {stderr = String(stderr.suffix(16000))}}}
        }
        try process.run()
        let reader = Task.detached {
            var buffer = Data()
            while true {
                let data = output.fileHandleForReading.availableData
                if data.isEmpty {break}
                buffer.append(data)
                guard buffer.count<4_000_000 else {process.terminate();throw ModelFailure(message:"Work runtime returned an oversized event.")}
                while let newline = buffer.firstIndex(of:10) {
                    let line = buffer.prefix(upTo:newline);buffer.removeSubrange(...newline)
                    guard let event = try? JSONSerialization.jsonObject(with:line) as? [String:Any] else {continue}
                    if event["type"] as? String == "native_request" {
                        let response:[String:Any]
                        do {
                            try Task.checkCancellation()
                            guard task.category == "desktop",process.isRunning else {throw ModelFailure(message:"Desktop tool is unavailable for this task.")}
                            response = ["result":try await desktop.execute(event["arguments"] as? [String:Any] ?? [:])]
                        } catch {response = ["error":error.localizedDescription]}
                        if let data = try? JSONSerialization.data(withJSONObject:response),process.isRunning {try? nativeInput.fileHandleForWriting.write(contentsOf:data+Data([10]))}
                        continue
                    }
                    await MainActor.run {
                        if event["type"] as? String == "tool_performance" {
                            let name = event["name"] as? String ?? "unknown"
                            let total = event["total_s"] as? Double ?? 0
                            InferencePolicy.logger.notice("tool execution=\(name,privacy:.public) total_s=\(total)")
                        }
                        if event["type"] as? String == "performance" {
                            let round = event["round"] as? Int ?? 0
                            let first = event["first_action_s"] as? Double ?? 0
                            let total = event["total_s"] as? Double ?? 0
                            let load = event["load_s"] as? Double ?? 0
                            let prompt = event["prompt_s"] as? Double ?? 0
                            let tokens = event["output_tokens"] as? Int ?? 0
                            InferencePolicy.logger.notice("tool round=\(round) first_action_s=\(first) total_s=\(total) load_s=\(load) prompt_s=\(prompt) output_tokens=\(tokens)")
                        }
                        if event["type"] as? String == "context_compaction" {onStatus("Organizing task context")}
                        if event["type"] as? String == "tools_loaded" {onStatus("Finding the right tool")}
                        if event["type"] as? String == "model_retry" {onStatus("Reconnecting local model")}
                        if event["type"] as? String == "complete" {completed = true}
                        if event["type"] as? String == "error" {runtimeFailure = event["message"] as? String ?? "Local work failed"}
                        guard let message = event["message"] as? [String:Any],let content = message["content"] as? [[String:Any]] else {return}
                        for item in content {
                            switch item["type"] as? String {
                            case "text":
                                if let text = item["text"] as? String,message["role"] as? String == "assistant" {
                                    if text.hasPrefix("Network error:") || text.hasPrefix("Ran into this error:") {runtimeFailure = text}
                                    if !text.isEmpty,let id = message["id"] as? String {
                                        if let previous = lastTextMessageID,previous != id {onText("\n\n")}
                                        lastTextMessageID = id
                                    }
                                    onText(text)
                                }
                            case "toolRequest":
                                let value = (item["toolCall"] as? [String:Any])?["value"] as? [String:Any]
                                let name = value?["name"] as? String ?? ""
                                onStatus(name.contains("search_web") ? "Searching the web":name.contains("read_webpage") ? "Reading webpage":name.contains("read") ? "Reading file":name.contains("spreadsheet") ? "Editing spreadsheet":name.contains("presentation") ? "Creating presentation":name.contains("document") ? "Editing document":name.contains("write") ? "Writing files":"Working")
                            case "toolResponse":
                                let result = (item["toolResult"] as? [String:Any])?["value"] as? [String:Any]
                                guard result?["isError"] as? Bool != true else {continue}
                                for part in result?["content"] as? [[String:Any]] ?? [] {
                                    guard let text = part["text"] as? String,let info = try? JSONSerialization.jsonObject(with:Data(text.utf8)) as? [String:Any],let relative = info["path"] as? String,info["sha256"] != nil else {continue}
                                    let file = workspace.appendingPathComponent(relative).resolvingSymlinksInPath()
                                    guard file.path.hasPrefix(workspace.resolvingSymlinksInPath().path+"/"),FileManager.default.fileExists(atPath:file.path) else {continue}
                                    artifacts.removeAll {$0.path == file.path}
                                    artifacts.append(WorkArtifact(path:file.path,name:file.lastPathComponent,validation:info["validation"] as? String ?? "Not visually verified"))
                                }
                            default:break // Thinking content never enters the chat or logs.
                            }
                        }
                    }
                }
            }
        }
        let deadline = Task {try await Task.sleep(for:.seconds(1800));try? nativeInput.fileHandleForWriting.close();if process.isRunning {process.terminate()};reader.cancel()}
        defer {deadline.cancel();errors.fileHandleForReading.readabilityHandler = nil;if process.isRunning {process.terminate()}}
        try await withTaskCancellationHandler(operation:{try await reader.value;try Task.checkCancellation()},onCancel:{reader.cancel();try? nativeInput.fileHandleForWriting.close();if process.isRunning {process.terminate()}})
        guard completed, runtimeFailure == nil else {
            print("Local work diagnostic: \(runtimeFailure ?? stderr)")
            let where_ = ModelRouting.usesCloud ? "任务未完成":"本地任务未完成"
            throw ModelFailure(message:"\(where_)，工作副本与执行记录已保留。\(runtimeFailure.map {"\n"+$0} ?? "")")
        }
        return artifacts
    }
}
