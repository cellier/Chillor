import Foundation

// A conservative whole-message match: action requests and contextual follow-ups
// must retain semantic routing, task history and the full tool loop.
enum ResponseProfile {
    /// The engine sentence must match the engine actually serving the reply:
    /// the assistant may not describe a remote run as on-device inference.
    static var introduction:String {
        let engine = ModelRouting.usesCloud
            ? "an AI assistant on this Mac. You answer through the DeepSeek API the user selected in Settings, so request text leaves this Mac; their files, chat history and memory stay stored here"
            : "a private AI assistant on this Mac, using a local Qwen model through Ollama"
        return """
    You are Chillor, \(engine).
    Reply naturally in the user's language in 2–4 short sentences, under 120 Chinese characters
    or 80 English words. You can answer questions, draft/translate, search public web pages,
    read user-selected workspace files, create/edit documents, spreadsheets and presentations,
    and operate supported apps with permission. Chat and task memory are saved locally.
    Only describe relevant capabilities; do not claim an action was performed. Invite a concrete task.
    """
    }
    static func isIntroduction(_ request:ChatMessage)->Bool {
        guard request.replyTo == nil,request.attachments.isEmpty,request.text.count <= 160 else {return false}
        let clauses = request.text.lowercased().components(separatedBy:.punctuationCharacters.union(.newlines))
            .map {$0.split(whereSeparator:{$0.isWhitespace}).joined(separator:" ")}.filter {!$0.isEmpty}
        let allowed:Set<String> = ["你好","您好","嗨","hello","hi","hey","你是谁","你叫什么","你叫什么名字",
            "你能做什么","你可以做什么","你有什么功能","你有哪些功能","介绍一下你自己","介绍下你自己",
            "请介绍一下你自己","请介绍下你自己","你是谁以及你能做什么","你是谁你能做什么",
            "who are you","what can you do","who are you and what can you do","introduce yourself",
            "please introduce yourself"]
        return !clauses.isEmpty && clauses.allSatisfy {
            allowed.contains($0) || $0.range(of:"^(?:(?:你好|您好|嗨|hello|hi|hey)\\s*)+$",options:.regularExpression) != nil
        }
    }
}
