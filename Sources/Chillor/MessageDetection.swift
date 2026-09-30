// Adapted from the user-owned Chillor Reply detector.
import Cocoa

struct MessageCandidate: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var rect: CGRect
    var method: String
    var included = false
    var lineHeight: CGFloat = 0
}

// Capture and OCR cost scales with pixels, not with how much text is on screen.
// A 2x capture of a large window drove Vision's pyramid into hundreds of megabytes.
func captureScale(for frame: CGRect, maxDimension: CGFloat = 2200) -> CGFloat {
    let longest = max(frame.width, frame.height)
    guard longest > 0 else { return 1 }
    return min(2, max(1, maxDimension / longest))
}

// Roughly 11 pixels of text. Below this Vision adds pyramid levels that cost far
// more than they recover on chat interfaces.
func minimumTextHeight(for pixelHeight: Int) -> Float {
    Float(max(0.004, min(0.02, 11 / Double(max(1, pixelHeight)))))
}

// Candidate rows are a picker, not a reader. Unbounded self-sizing text inside a
// resizable pane is what forced SwiftUI to re-measure every row on every pass.
func previewText(_ text: String, limit: Int = 500) -> String {
    text.count > limit ? String(text.prefix(limit)) + "\u{2026}" : text
}


// The reading translation costs time in proportion to the tokens it emits, and a
// captured message carries chrome the model faithfully translates: file names,
// reply counters, composer placeholders, stray glyphs, whole URLs. Stripping those
// is both faster and a cleaner translation to read. Applied only to what the model
// sees; the captured text on screen is left exactly as captured.
func cleanForModel(_ text: String) -> String {
    // A quote or bullet marker carrying at most one character is a fragment the OCR
    // clipped, not something anyone wrote: "+", "> Y", "· 3".
    let noise = ["^[+>·•|~^]{1,3}\\s*[\\p{L}\\p{N}]?$",
                 "^\\d+\\s*(条回复|则回复|replies|reply)\\b",
                 "^Message\\s*#",
                 "^(ScreenRecording|Screenshot|IMG|截屏|录屏)[ _\\-]",
                 "^(Chat message|已编辑|edited)$",
                 "^[A-Za-z]$",
                 // A bare file name is an attachment label, not something anyone said.
                 "^[\\w\\-. ]{1,60}\\.(png|jpe?g|gif|mov|mp4|heic|webp|pdf|zip|docx?|xlsx?|pptx?)$",
                 // Placeholder text inside an input box always trails off.
                 "^(Find|Search|Jump to|Message|搜索|查找|发消息)\\b.*(\\.\\.\\.|…)$",
                 "^\\d+\\s*(unread|new messages?|未读|条新消息)\\b",
                 // Reaction counters and lone glyph+number pills.
                 "^[^\\p{L}\\p{N}]{0,4}\\s*\\d{1,3}$",
                 "^(Threads|Huddles|Directories|Drafts|Activity|Later|Canvases|Add a bookmark)$"]
    var kept: [String] = []
    for raw in text.components(separatedBy: .newlines) {
        // A URL never needs translating and is expensive to copy token by token.
        let line = raw.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "(?i)\\bhttps?://\\S+", with: "[链接]", options: .regularExpression)
        if line.isEmpty {
            if kept.last?.isEmpty == false { kept.append("") }
            continue
        }
        if noise.contains(where: { line.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil }) { continue }
        kept.append(line)
    }
    return kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
}

// A captured bubble almost always opens with "<name> <separator> <time>". Naming the
// sender explicitly is what stops the model inventing one: an earlier run opened a
// reply with "Hi Jack", a person who appears nowhere in the conversation.
func senderName(in text: String) -> String? {
    guard let header = text.components(separatedBy: .newlines)
        .first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) else { return nil }
    let line = header.trimmingCharacters(in: .whitespaces)
    guard line.count <= 80 else { return nil }
    let clock = "(\\d{1,2}:\\d{2}|上午|下午|凌晨|晚上|中午|昨天|今天|Today|Yesterday|\\bAM\\b|\\bPM\\b)"
    guard let time = line.range(of: clock, options: [.regularExpression, .caseInsensitive]) else { return nil }
    var cut = time.lowerBound
    for mark in ["|", "·", "•", " — ", " - ", ","] {
        if let found = line.range(of: mark), found.lowerBound < cut { cut = found.lowerBound }
    }
    let name = String(line[line.startIndex..<cut])
        .trimmingCharacters(in: CharacterSet(charactersIn: " \t@:：-—·|•"))
    let words = name.split(separator: " ")
    // Every word must read like a name. Without this, "Can we meet at 3:00?" would
    // report a sender called "Can we meet at".
    func nameLike(_ word: Substring) -> Bool {
        guard let first = word.first else { return false }
        return first.isUppercase || String(first).range(of: "\\p{Han}", options: .regularExpression) != nil
    }
    guard (2...40).contains(name.count), (1...4).contains(words.count),
          name.rangeOfCharacter(from: .decimalDigits) == nil,
          words.allSatisfy(nameLike) else { return nil }
    return name
}

// Detect connected, approximately flat message backgrounds, independent of app names.
// A page-sized component is rejected rather than assumed to be a message.
final class BubbleMap {
    let width: Int
    let height: Int
    let frame: CGRect
    let bytes: [UInt8]
    var labels: [Int]
    var components: [CGRect?] = [nil]

    init?(_ image: CGImage, frame: CGRect) {
        self.frame = frame
        let scale = min(1, 1200 / CGFloat(image.width))
        width = max(1, Int(CGFloat(image.width) * scale))
        height = max(1, Int(CGFloat(image.height) * scale))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = data.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            ctx.interpolationQuality = .low
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        bytes = data
        labels = [Int](repeating: 0, count: width * height)
    }

    func component(at p: CGPoint) -> CGRect? {
        let x = Int((p.x - frame.minX) / frame.width * CGFloat(width))
        let y = Int((p.y - frame.minY) / frame.height * CGFloat(height))
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        let start = y * width + x
        if labels[start] > 0 { return components[labels[start]] }
        let offset = start * 4
        let r = Int(bytes[offset]), g = Int(bytes[offset + 1]), b = Int(bytes[offset + 2])
        let label = components.count
        components.append(nil)
        var queue = [start]
        labels[start] = label
        var cursor = 0, minX = x, maxX = x, minY = y, maxY = y
        while cursor < queue.count {
            let index = queue[cursor]
            cursor += 1
            let px = index % width, py = index / width
            minX = min(minX, px); maxX = max(maxX, px)
            minY = min(minY, py); maxY = max(maxY, py)
            for next in [px > 0 ? index - 1 : -1, px + 1 < width ? index + 1 : -1, py > 0 ? index - width : -1, py + 1 < height ? index + width : -1] where next >= 0 {
                if labels[next] != 0 { continue }
                let i = next * 4
                if abs(Int(bytes[i]) - r) <= 6 && abs(Int(bytes[i + 1]) - g) <= 6 && abs(Int(bytes[i + 2]) - b) <= 6 {
                    labels[next] = label
                    queue.append(next)
                }
            }
        }
        let boxArea = (maxX - minX + 1) * (maxY - minY + 1)
        let edges = [minX <= 1, minY <= 1, maxX >= width - 2, maxY >= height - 2].filter { $0 }.count
        guard queue.count > 160, boxArea < width * height * 3 / 4,
              maxY - minY < height * 3 / 4, edges < 2,
              Double(queue.count) / Double(boxArea) > 0.43 else { return nil }
        let rect = CGRect(x: frame.minX + CGFloat(minX) / CGFloat(width) * frame.width,
                          y: frame.minY + CGFloat(minY) / CGFloat(height) * frame.height,
                          width: CGFloat(maxX - minX + 1) / CGFloat(width) * frame.width,
                          height: CGFloat(maxY - minY + 1) / CGFloat(height) * frame.height)
        components[label] = rect
        return rect
    }

    func bubble(around text: CGRect) -> CGRect? {
        let padding = max(3, min(7, text.height * 0.25))
        let probes = [CGPoint(x: text.minX - padding, y: text.midY),
                      CGPoint(x: text.minX + 4, y: text.minY - padding),
                      CGPoint(x: text.midX, y: text.minY - padding),
                      CGPoint(x: text.minX + 4, y: text.maxY + padding),
                      CGPoint(x: text.maxX + padding, y: text.midY)]
        var options: [CGRect] = []
        for p in probes {
            guard let box = component(at: p), box.width >= text.width * 0.80,
                  box.height > text.height * 1.22,
                  box.intersection(text).width * box.intersection(text).height > text.width * text.height * 0.70,
                  box.width > 45 else { continue }
            options.append(box)
        }
        return options.min { $0.width * $0.height < $1.width * $1.height }
    }
}

func candidateMessages(_ items: [TextItem], image: CGImage?, frame: CGRect) -> [MessageCandidate] {
    let lines = items.filter { item in
        guard let rect = item.rect else { return false }
        return rect.height > 4 && !item.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }.sorted { $0.rect!.minY < $1.rect!.minY }
    let map = image.flatMap { BubbleMap($0, frame: frame) }
    var used = Set<Int>()
    var result: [MessageCandidate] = []
    // Resolve continuous prose before background detection: a slide's gradient
    // can otherwise masquerade as one huge chat bubble containing editor chrome.
    if image != nil {
        let paragraphs = candidateMessages(items, image: nil, frame: frame)
        var documentIDs = Set<UUID>()
        for paragraph in paragraphs {
            let ids = documentTargetIDs(paragraphs, target: paragraph)
            if ids.count > 1 { documentIDs.formUnion(ids) }
        }
        for paragraph in paragraphs where documentIDs.contains(paragraph.id) {
            // A real message bubble has an explicit boundary; retain that grouping.
            if map?.bubble(around: paragraph.rect) != nil { continue }
            result.append(paragraph)
            for i in lines.indices where paragraph.rect.contains(CGPoint(x: lines[i].rect!.midX, y: lines[i].rect!.midY)) { used.insert(i) }
        }
    }
    for i in lines.indices where !used.contains(i) {
        let seed = lines[i].rect!
        guard let bubble = map?.bubble(around: seed) else { continue }
        let members = lines.indices.filter { j in
            guard !used.contains(j) else { return false }
            let r = lines[j].rect!
            return bubble.contains(CGPoint(x: r.midX, y: r.midY)) &&
                bubble.intersection(r).width * bubble.intersection(r).height > r.width * r.height * 0.60
        }
        guard !members.isEmpty else { continue }
        used.formUnion(members)
        result.append(MessageCandidate(text: joinLines(members.map { lines[$0] }), rect: bubble, method: "气泡边界"))
    }
    // White backgrounds without distinguishable bubbles use conservative paragraph blocks.
    for i in lines.indices where !used.contains(i) {
        var members = [i]
        used.insert(i)
        var box = lines[i].rect!
        var last = box
        for j in lines.indices where !used.contains(j) {
            let r = lines[j].rect!
            let gap = r.minY - last.maxY
            let aligned = abs(r.minX - lines[i].rect!.minX) < max(20, last.height * 1.5)
            if gap >= -2 && gap <= max(7, min(18, last.height * 0.7)) && aligned &&
                max(r.height, last.height) / max(1, min(r.height, last.height)) < 1.65 {
                members.append(j); used.insert(j); box = box.union(r); last = r
            }
        }
        result.append(MessageCandidate(text: joinLines(members.map { lines[$0] }), rect: box.insetBy(dx: -3, dy: -3), method: "文字段落", lineHeight: members.map { lines[$0].rect!.height }.sorted()[members.count / 2]))
    }
    return result.sorted { $0.rect.minY < $1.rect.minY }
}

func joinLines(_ lines: [TextItem]) -> String {
    var output = ""
    var previous: CGRect?
    for line in lines.sorted(by: { $0.rect!.minY < $1.rect!.minY }) {
        if let previous, let r = line.rect {
            output += r.minY - previous.maxY > max(8, previous.height * 0.8) ? "\n\n" : "\n"
        }
        output += line.text
        previous = line.rect
    }
    return output
}

func chooseTarget(_ candidates: [MessageCandidate], point: CGPoint) -> MessageCandidate? {
    let containing = candidates.filter { $0.rect.contains(point) }
    if let best = containing.min(by: { area($0.rect) < area($1.rect) }) { return best }
    let ranked = candidates.sorted {distance(point,$0.rect)<distance(point,$1.rect)}
    guard let nearest = ranked.first,distance(point,nearest.rect)<=32 else {return nil}
    if ranked.count>1 && distance(point,ranked[1].rect)-distance(point,nearest.rect)<6 {return nil}

    return nearest
}

func checkedContext(_ candidates: [MessageCandidate], excluding targetIDs: Set<UUID>) -> String {
    candidates.filter { $0.included && !targetIDs.contains($0.id) }.map(\.text).joined(separator: "\n\n——\n\n")
}

// UI chrome sits in predictable places and does not read like something a person
// said. Rejecting it structurally keeps this independent of any particular chat
// app. Without it a reply once asked the sender whether a notification banner was
// "a system alert or you simulating a scenario".
func looksLikeChrome(_ item: MessageCandidate, target: MessageCandidate, in frame: CGRect) -> Bool {
    let lines = item.text.components(separatedBy: .newlines)
        .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    guard !lines.isEmpty else { return true }
    let prose = item.text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?。！？")) != nil
    // A banner or toolbar spans far more width than the conversation column.
    if item.rect.width > target.rect.width * 1.5 { return true }
    // A sidebar, member list or rail is a narrow column beside the conversation.
    if item.rect.width < max(120, frame.width * 0.22) { return true }
    // The composer and status strips sit below the last message, near the bottom edge.
    if item.rect.minY > target.rect.maxY,
       item.rect.minY > frame.maxY - frame.height * 0.15, !prose { return true }
    // A navigation list is a stack of short labels; a message is sentences.
    if lines.count >= 3, lines.reduce(0, { $0 + $1.count }) / lines.count <= 14 { return true }
    // Short and unpunctuated reads as a label, not as something anyone wrote.
    if item.text.count < 45, !prose { return true }
    return false
}

// Visible, same-column neighbors are tentative context, not a verified thread.
// A bounded selection avoids pulling sidebars or the entire captured window.
func automaticContextIDs(_ candidates: [MessageCandidate], target: MessageCandidate, in frame: CGRect) -> Set<UUID> {
    let nearby = candidates.filter { item in
        guard item.id != target.id, item.text.count >= 16,
              !looksLikeChrome(item, target: target, in: frame) else { return false }
        let overlap = max(0, min(item.rect.maxX, target.rect.maxX) - max(item.rect.minX, target.rect.minX))
        let gap = max(0, item.rect.minY - target.rect.maxY, target.rect.minY - item.rect.maxY)
        return overlap / max(1, min(item.rect.width, target.rect.width)) > 0.45 && gap < 450
    }.sorted { abs($0.rect.midY - target.rect.midY) < abs($1.rect.midY - target.rect.midY) }
    var ids = Set<UUID>(), bytes = 0
    for item in nearby {
        guard ids.count < 4 else { break }
        if bytes + item.text.utf8.count <= 5500 { ids.insert(item.id); bytes += item.text.utf8.count }
    }
    return ids
}

// Expand a document column before applying the pointer's context radius. Require
// several prose paragraphs, consistent type size, and no chat sender boundaries.
func documentTargetIDs(_ candidates: [MessageCandidate], target: MessageCandidate) -> Set<UUID> {
    guard target.method == "文字段落", target.lineHeight > 0 else { return [target.id] }
    let height = target.lineHeight
    let column = candidates.filter {
        abs($0.rect.minX - target.rect.minX) <= max(12, height * 0.8)
    }.sorted { $0.rect.minY < $1.rect.minY }
    guard let index = column.firstIndex(where: { $0.id == target.id }) else { return [target.id] }
    func eligible(_ item: MessageCandidate) -> Bool {
        item.method == "文字段落" && item.lineHeight / height >= 0.75 &&
        item.lineHeight / height <= 1.4 && senderName(in: item.text) == nil &&
        cleanForModel(item.text) == item.text && item.text.count >= 4
    }
    guard eligible(target) else { return [target.id] }
    var start = index, end = index
    while start > 0, eligible(column[start - 1]),
          column[start].rect.minY - column[start - 1].rect.maxY <= height * 3.5,
          column[start - 1].rect.maxY <= column[start].rect.minY + 2 { start -= 1 }
    while end + 1 < column.count, eligible(column[end + 1]),
          column[end + 1].rect.minY - column[end].rect.maxY <= height * 3.5,
          column[end].rect.maxY <= column[end + 1].rect.minY + 2 { end += 1 }
    let block = Array(column[start...end])
    let prose = block.filter { $0.text.count >= 45 && $0.text.rangeOfCharacter(from: CharacterSet(charactersIn: ".!?。！？")) != nil }
    guard prose.count >= 3 else { return [target.id] }
    return Set(block.map(\.id))
}

import Vision
struct TextItem {let text:String;let rect:CGRect?}
func area(_ rect:CGRect)->CGFloat {rect.width*rect.height}
func distance(_ point:CGPoint,_ rect:CGRect)->CGFloat {ScreenContextGeometry.distance(point,to:rect)}
func recognize(_ image: CGImage, frame: CGRect) throws -> [TextItem] {
    let english = VNRecognizeTextRequest()
    let mixed = VNRecognizeTextRequest()
    english.recognitionLanguages = ["en-US"]
    mixed.recognitionLanguages = ["zh-Hans", "en-US"]
    // 0.003 asked Vision to find ~7px text on a 2x capture: many extra pyramid
    // levels, hundreds of megabytes, and nothing recovered on real chat UI.
    let minHeight = minimumTextHeight(for: image.height)
    for request in [english, mixed] {
        request.recognitionLevel = .accurate
        request.minimumTextHeight = minHeight
        request.usesLanguageCorrection = true
    }
    // One perform with both requests keeps two full pyramids alive at the same
    // time. Separate pools halve the peak footprint for the same output.
    try autoreleasepool { try VNImageRequestHandler(cgImage: image).perform([english]) }
    try autoreleasepool { try VNImageRequestHandler(cgImage: image).perform([mixed]) }
    func lines(_ request: VNRecognizeTextRequest) -> [TextItem] {
        (request.results ?? []).compactMap { observation in
            guard let text = observation.topCandidates(1).first?.string else { return nil }
            let b = observation.boundingBox
            let rect = CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + (1 - b.maxY) * frame.height, width: b.width * frame.width, height: b.height * frame.height)
            return TextItem(text: text, rect: rect)
        }
    }
    // Chinese-first recognition can corrupt Latin words. Retain the English pass for
    // Latin lines, replacing overlapping fragments only where Chinese was detected.
    var merged = lines(english)
    for line in lines(mixed) where line.text.range(of: "[\\p{Han}]{2}", options: .regularExpression) != nil {
        merged.removeAll { item in
            let overlap = line.rect!.intersection(item.rect!)
            return !overlap.isNull && area(overlap) / max(1, min(area(line.rect!), area(item.rect!))) > 0.45
        }
        merged.append(line)
    }
    return merged.sorted { $0.rect!.minY < $1.rect!.minY }
}
