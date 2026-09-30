import Foundation
import NaturalLanguage

// Retrieval uses the current persisted conversation, never backups or a second
// copy of message content. Deletion and restart therefore have the same semantics.
enum ConversationRecall {
    static func isDirectQuestion(_ text:String)->Bool {
        let normalized = text.lowercased().filter {!$0.isWhitespace && !$0.isPunctuation}
        return ["我说的是以往的聊天","我说的是之前的聊天","我们以前聊过什么","我们之前聊过什么","我们聊过什么","你记得以前的聊天吗","你能记住以前的聊天吗","你有记忆吗","怎么没有记忆啊","chathistory","whatdidwetalkabout","doyourememberourpreviouschats"].contains(normalized)
    }
    static func terms(_ text:String)->Set<String> {
        var query = text.lowercased()
        for filler in ["我说的是","以往","以前","之前","历史","聊天记录","聊天","记忆","记得","我们","什么","哪些","告诉我","还记","do you remember","previous","history","about","what","did","our","chat"] {
            query = query.replacingOccurrences(of:filler,with:" ")
        }
        let tokenizer = NLTokenizer(unit:.word);tokenizer.string = query
        var result = Set<String>()
        tokenizer.enumerateTokens(in:query.startIndex..<query.endIndex) {range,_ in
            let term = String(query[range]).trimmingCharacters(in:.punctuationCharacters)
            if term.count >= 2 {result.insert(term)}
            return true
        }
        return result
    }
    static func evidence(query:String,history:[ChatMessage])->String {
        let eligible = history.filter { $0.state == "done" && ["user","assistant"].contains($0.role) && !$0.text.isEmpty }
        let keywords = terms(query)
        var selected:[ChatMessage] = []
        if !keywords.isEmpty {
            let matches = eligible.enumerated().compactMap { index,message -> (Int,Int)? in
                let text = message.text.lowercased()
                let score = keywords.reduce(0) {$0 + (text.contains($1) ? 1:0)}
                return score > 0 ? (index,score):nil
            }.sorted { $0.1 == $1.1 ? $0.0 > $1.0:$0.1 > $1.1 }.prefix(12)
            for (index,_) in matches {
                let match = eligible[index]
                selected.append(match)
                if let parent = eligible.first(where:{$0.id == match.replyTo}) {selected.append(parent)}
                if let response = eligible.first(where:{$0.replyTo == match.id && $0.role == "assistant"}) {selected.append(response)}
            }
        }
        if selected.isEmpty {
            // A broad question gets topic coverage, not just the last few turns.
            var groups = Set<UUID>()
            for message in eligible.reversed() where message.role == "user" {
                let group = message.taskID ?? message.id
                if groups.insert(group).inserted {
                    selected.append(message)
                    if let reply = eligible.first(where:{$0.replyTo == message.id && $0.role == "assistant"}) {selected.append(reply)}
                }
                if groups.count >= 12 {break}
            }
        }
        var seen = Set<UUID>();var entries:[[String:String]] = [];var budget = 8000
        let date = ISO8601DateFormatter()
        for message in selected where seen.insert(message.id).inserted {
            guard entries.count < 24,budget >= 160 else {break}
            var excerpt = message.text
            let limit = min(640,budget)
            if excerpt.count > limit {
                let lower = excerpt.lowercased()
                // Match near the keyword even when it occurs deep in a long answer.
                if let range = keywords.sorted().compactMap({lower.range(of:$0)}).first {
                    let offset = lower.distance(from:lower.startIndex,to:range.lowerBound)
                    let start = excerpt.index(excerpt.startIndex,offsetBy:max(0,min(excerpt.count,offset)-120))
                    excerpt = "[Excerpt] " + String(excerpt[start...].prefix(limit))
                } else {excerpt = String(excerpt.prefix(limit)) + " [Truncated]"}
            }
            budget -= excerpt.count
            entries.append(["messageID":message.id.uuidString,"date":date.string(from:message.date),"role":message.role,"text":excerpt])
        }
        let data:[String:Any] = ["availableMessageCount":eligible.count,"retrievedCount":entries.count,
                                "coverage":"Bounded excerpts from saved Chillor chat, not a complete archive. User statements and assistant claims are different sources. No deleted messages or attachment bodies included.","messages":entries]
        return String(decoding:(try? JSONSerialization.data(withJSONObject:data,options:[.sortedKeys])) ?? Data(),as:UTF8.self)
    }
}
