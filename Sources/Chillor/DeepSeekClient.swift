import Foundation

/// Swift-side DeepSeek calls: the introduction reply, isolated quick commands and
/// the older-work routing decision. Agent tasks use the Python SDK adapter instead.
/// Mirrors LocalModel.respond so no caller changes when the provider switches.
enum DeepSeekClient {
    /// Vision is model-dependent. Only send image parts to a model that reads them;
    /// quick-command OCR text is already in the prompt, so text-only stays correct.
    static func readsImages(_ model:String)->Bool {model == "deepseek-flash"}

    static func verify(model:String)async throws {
        guard let key = ModelCredentials.read() else {
            throw ModelFailure(message:"Add a DeepSeek API key in Settings, or switch back to the local model.")
        }
        var request = URLRequest(url:ModelRouting.endpoint.appendingPathComponent("models"))
        request.timeoutInterval = 15
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        let (data,response) = try await URLSession.shared.data(for:request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw ModelFailure(message:status == 401 ? "DeepSeek rejected this API key. Check it in Settings."
                : "DeepSeek is unreachable right now (HTTP \(status)). Check the network, or switch back to the local model.")
        }
        let json = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        let available = (json?["data"] as? [[String:Any]] ?? []).compactMap {$0["id"] as? String}
        guard available.isEmpty || available.contains(model) else {
            throw ModelFailure(message:"This DeepSeek account does not offer \(model). Available: \(available.joined(separator:", ")).")
        }
    }

    /// Ollama-shaped messages in, OpenAI chat-completions shape out.
    static func body(messages:[[String:Any]],model:String,json:Bool,format:[String:Any]?,maxTokens:Int)throws->Data {
        var converted:[[String:Any]] = []
        var droppedImages = false
        for message in messages {
            let role = message["role"] as? String ?? "user"
            let text = message["content"] as? String ?? ""
            guard let images = message["images"] as? [String],!images.isEmpty else {
                converted.append(["role":role,"content":text]);continue
            }
            guard readsImages(model) else {
                droppedImages = true
                converted.append(["role":role,"content":text]);continue
            }
            var parts:[[String:Any]] = text.isEmpty ? []:[["type":"text","text":text]]
            for image in images.prefix(4) {
                parts.append(["type":"image_url","image_url":["url":"data:image/png;base64,"+image]])
            }
            converted.append(["role":role,"content":parts])
        }
        if droppedImages {
            converted.insert(["role":"system","content":"An image was attached but \(model) cannot read images. Use only the supplied text. Do not describe or guess the image contents; say the image could not be read if it matters."],at:0)
        }
        if json {
            // DeepSeek supports json_object, not json_schema: state the shape in the
            // prompt and keep the caller's decoder as the real contract check.
            var instruction = "Reply with a single JSON object and nothing else."
            if let format,let data = try? JSONSerialization.data(withJSONObject:format,options:[.sortedKeys]) {
                instruction += " It must satisfy this JSON Schema: "+String(decoding:data,as:UTF8.self)
            }
            converted.insert(["role":"system","content":instruction],at:0)
        }
        var payload:[String:Any] = ["model":model,"messages":converted,"stream":true,
                                    "reasoning_effort":"none",
                                    "max_tokens":max(maxTokens,512),
                                    "temperature":json ? 0:0.5]
        if json {payload["response_format"] = ["type":"json_object"]}
        return try JSONSerialization.data(withJSONObject:payload)
    }

    static func respond(messages:[[String:Any]],model:String,json:Bool,format:[String:Any]?,maxTokens:Int,
                        onToken:@escaping(String)->Void)async throws {
        guard let key = ModelCredentials.read() else {
            throw ModelFailure(message:"Add a DeepSeek API key in Settings, or switch back to the local model.")
        }
        var request = URLRequest(url:ModelRouting.endpoint.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST";request.timeoutInterval = 240
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.setValue("text/event-stream",forHTTPHeaderField:"Accept")
        request.setValue("Bearer "+key,forHTTPHeaderField:"Authorization")
        request.httpBody = try body(messages:messages,model:model,json:json,format:format,maxTokens:maxTokens)
        let started = ProcessInfo.processInfo.systemUptime
        let (bytes,response) = try await URLSession.shared.bytes(for:request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            var detail = ""
            for try await line in bytes.lines {detail += line;if detail.count > 800 {break}}
            throw ModelFailure(message:failure(status:status,detail:detail))
        }
        var done = false
        var produced = false
        var first = true
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.hasPrefix("data:") else {continue}
            let payload = line.dropFirst(5).trimmingCharacters(in:.whitespaces)
            if payload == "[DONE]" {done = true;break}
            guard let data = payload.data(using:.utf8),
                  let event = try? JSONSerialization.jsonObject(with:data) as? [String:Any] else {continue}
            if let error = event["error"] as? [String:Any] {
                throw ModelFailure(message:(error["message"] as? String) ?? "DeepSeek returned an error.")
            }
            guard let choice = (event["choices"] as? [[String:Any]])?.first else {continue}
            // reasoning_content stays internal, exactly like local thinking output.
            if let token = (choice["delta"] as? [String:Any])?["content"] as? String,!token.isEmpty {
                if first {first = false;InferencePolicy.logger.notice("deepseek first_token_s=\(ProcessInfo.processInfo.systemUptime-started)")}
                produced = true;onToken(token)
            }
            if let reason = choice["finish_reason"] as? String {
                done = true
                if reason == "length" && !produced {
                    throw ModelFailure(message:"DeepSeek reached its output limit before writing a reply. Please retry.")
                }
            }
        }
        guard done else {throw ModelFailure(message:"The DeepSeek connection ended early. Please retry.")}
        guard produced else {throw ModelFailure(message:"DeepSeek returned an empty answer. Please retry.")}
    }

    static func failure(status:Int,detail:String)->String {
        let message = (try? JSONSerialization.jsonObject(with:Data(detail.utf8)) as? [String:Any])
            .flatMap {($0?["error"] as? [String:Any])?["message"] as? String}
        switch status {
        case 401: return "DeepSeek rejected this API key. Check it in Settings."
        case 402: return "This DeepSeek account has no balance left. Top it up, or switch back to the local model."
        case 429: return "DeepSeek is rate limiting this key. Wait a moment and retry."
        default: return message ?? "DeepSeek could not complete this request (HTTP \(status)). Please retry."
        }
    }
}
