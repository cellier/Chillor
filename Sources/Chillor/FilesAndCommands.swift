import AppKit
import PDFKit
import Vision
import ScreenCaptureKit
import Carbon

struct FileContext {
    static func read(_ url: URL) throws -> Attachment {
        let size = (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0
        guard size <= 20_000_000 else { throw ModelFailure(message: "\(url.lastPathComponent) exceeds the 20 MB attachment limit.") }
        let ext = url.pathExtension.lowercased()
        if ["png", "jpg", "jpeg", "heic", "tiff", "webp"].contains(ext) {
            guard let image = NSImage(contentsOf:url), let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data:tiff) else { throw ModelFailure(message:"This image could not be opened.") }
            // Bound image resolution without changing the source file.
            let ratio = min(1.0, 1400.0 / CGFloat(max(rep.pixelsWide, rep.pixelsHigh)))
            let resized = NSImage(size:NSSize(width:CGFloat(rep.pixelsWide)*ratio, height:CGFloat(rep.pixelsHigh)*ratio))
            resized.lockFocus(); image.draw(in:NSRect(origin:.zero,size:resized.size)); resized.unlockFocus()
            guard let resizedTiff = resized.tiffRepresentation, let bitmap = NSBitmapImageRep(data:resizedTiff), let data = bitmap.representation(using:.jpeg, properties:[.compressionFactor:0.85]) else { throw ModelFailure(message:"Could not prepare this image.") }
            return Attachment(name:url.lastPathComponent,text:"User-selected image. Analyze the attached image.",imageData:data)
        }
        if ["docx","xlsx","pptx"].contains(ext) {
            return Attachment(name:url.lastPathComponent,text:"User-selected Office file. Read the imported task copy using the work tools before answering or modifying it.",sourcePath:url.path)
        }
        if ext == "pdf" {
            guard let pdf = PDFDocument(url:url), let text = pdf.string, !text.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty else { throw ModelFailure(message:"This PDF has no readable text. Please attach an image of the relevant page.") }
            return Attachment(name:url.lastPathComponent,text:limited(text),sourcePath:url.path)
        }
        let supported = ["txt","md","csv","json","html","xml","yaml","yml","swift","py","js","ts","tsx","css","log","rtf"]
        guard supported.contains(ext) else { throw ModelFailure(message:"\(url.lastPathComponent): use a text file, PDF, or image in this first version.") }
        if ext == "rtf" {
            let doc = try NSAttributedString(url:url,options:[:],documentAttributes:nil)
            return Attachment(name:url.lastPathComponent,text:limited(doc.string))
        }
        let data = try Data(contentsOf:url)
        guard let text = String(data:data,encoding:.utf8) ?? String(data:data,encoding:.utf16) else { throw ModelFailure(message:"This file's text encoding could not be read.") }
        return Attachment(name:url.lastPathComponent,text:limited(text),sourcePath:url.path)
    }
    static func limited(_ text: String) -> String { String(text.prefix(12000)) + (text.count > 12000 ? "\n[Excerpt: first 12,000 characters only.]" : "") }
}

@MainActor final class CommandRunner {
    let conversation: Conversation
    var reveal: () -> Void = {}
    var registrations: [EventHotKeyRef] = []
    var handler: EventHandlerRef?
    var map: [UInt32: UUID] = [:]
    var observer: NSObjectProtocol?
    var capturing = false
    static let keys: [String: UInt32] = ["A":0,"S":1,"D":2,"F":3,"H":4,"G":5,"Z":6,"X":7,"C":8,"V":9,"B":11,"Q":12,"W":13,"E":14,"R":15,"Y":16,"T":17,"O":31,"U":32,"I":34,"P":35,"L":37,"J":38,"K":40,"N":45,"M":46]
    init(conversation:Conversation) {
        self.conversation = conversation
        var type = EventTypeSpec(eventClass:OSType(kEventClassKeyboard),eventKind:UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _,event,userData in
            guard let event, let userData else { return noErr }
            var id = EventHotKeyID()
            GetEventParameter(event,EventParamName(kEventParamDirectObject),EventParamType(typeEventHotKeyID),nil,MemoryLayout<EventHotKeyID>.size,nil,&id)
            let runner = Unmanaged<CommandRunner>.fromOpaque(userData).takeUnretainedValue()
            let commandID = id.id
            Task { @MainActor in runner.invoke(id:commandID) }
            return noErr
        },1,&type,Unmanaged.passUnretained(self).toOpaque(),&handler)
        register()
        observer = NotificationCenter.default.addObserver(forName:.commandsChanged,object:nil,queue:.main) { [weak self] _ in Task { @MainActor in self?.register() } }
    }
    func register() {
        registrations.forEach { UnregisterEventHotKey($0) }; registrations = []; map = [:]
        var used: Set<String> = []
        for (index, command) in Preferences.shared.commands.enumerated() where command.enabled {
            let key = command.key.uppercased()
            guard !used.contains(key), let code = Self.keys[key] else { continue }
            used.insert(key)
            var ref: EventHotKeyRef?
            let id = UInt32(index+1)
            let status = RegisterEventHotKey(code,UInt32(controlKey | optionKey),EventHotKeyID(signature:0x43484C52,id:id),GetApplicationEventTarget(),0,&ref)
            if status == noErr, let ref { registrations.append(ref); map[id] = command.id }
            else { conversation.attachmentError = "Shortcut ⌃⌥\(key) is unavailable. Choose another key in Settings." }
        }
    }
    func invoke(id:UInt32) {
        guard let uuid = map[id], let command = Preferences.shared.commands.first(where:{$0.id == uuid}) else { return }
        run(command)
    }
    func run(_ command:QuickCommand) {
        guard !capturing else { return }
        let point = NSEvent.mouseLocation
        // ScreenCaptureKit is authoritative. A CoreGraphics preflight can disagree
        // with it after a development rebuild; do not block the real request.
        capturing = true
        let started = ProcessInfo.processInfo.systemUptime
        Task { @MainActor in
            defer { capturing = false;conversation.contextCaptureStatus = nil }
            do {
                let attachment = try await Self.capture(at:point) {
                    // Reveal only after freezing the source image so Chillor cannot
                    // cover the target. OCR and model loading can now overlap.
                    conversation.contextCaptureStatus = "Reading screen"
                    reveal()
                    Task {try? await ModelWarmth.shared.prewarm()}
                }
                InferencePolicy.logger.notice("shortcut context_ready_s=\(ProcessInfo.processInfo.systemUptime-started)")
                let request = ChatMessage(role:"user", text:"\(command.name)\n\n\(command.instruction)",attachments:[attachment])
                conversation.submit(request,isolated:true)
            } catch {
                reveal()
                let nsError = error as NSError
                if nsError.domain == SCStreamErrorDomain && nsError.code == SCStreamError.Code.userDeclined.rawValue {
                    conversation.attachmentError = "Chillor needs Screen Recording permission for Translate and Reply. Open System Settings → Privacy & Security → Screen & System Audio Recording and enable Chillor, then quit and reopen it. If already enabled after an update, remove the old Chillor entry and add this version again."
                } else { conversation.attachmentError = error.localizedDescription }
            }
        }
    }
    static func capture(at point:NSPoint,onCaptured:()->Void = {}) async throws -> Attachment {
        let started = ProcessInfo.processInfo.systemUptime
        // Freeze the pointer and front-to-back window order before awaiting capture.
        let quartz = ScreenContextGeometry.quartzPoint(point,primaryHeight:NSScreen.screens.first?.frame.maxY ?? 0)
        let ordered = (CGWindowListCopyWindowInfo([.optionOnScreenOnly,.excludeDesktopElements],kCGNullWindowID) as? [[String:Any]]) ?? []
        let content = try await SCShareableContent.excludingDesktopWindows(true,onScreenWindowsOnly:true)
        let windows = Dictionary(uniqueKeysWithValues:content.windows.map {($0.windowID,$0)})
        let target = ordered.compactMap { info -> SCWindow? in
            guard let id = info[kCGWindowNumber as String] as? UInt32,
                  let window = windows[id],window.windowLayer == 0,
                  window.frame.contains(quartz),window.frame.width>1,window.frame.height>1 else {return nil}
            return window
        }.first
        guard let target,target.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier else {throw ModelFailure(message:"Move the pointer over the application window you want to translate, then try again.")}
        let filter = SCContentFilter(desktopIndependentWindow:target)
        let width = filter.contentRect.width,height = filter.contentRect.height
        guard width>0,height>0 else {throw ModelFailure(message:"The selected window is unavailable.")}
        let scale = CGFloat(filter.pointPixelScale)
        let configuration = SCStreamConfiguration()
        configuration.width = Int((width*scale).rounded());configuration.height = Int((height*scale).rounded())
        configuration.ignoreShadowsSingleWindow = true
        configuration.showsCursor = false;configuration.captureResolution = .best
        let image = try await SCScreenshotManager.captureImage(contentFilter:filter,configuration:configuration)
        InferencePolicy.logger.notice("shortcut screenshot_s=\(ProcessInfo.processInfo.systemUptime-started)")
        onCaptured()
        async let encoded = Task.detached(priority:.userInitiated) {
            NSBitmapImageRep(cgImage:image).representation(using:.png,properties:[:])
        }.value
        let pointer = CGPoint(x:quartz.x-target.frame.minX,y:quartz.y-target.frame.minY)
        let frame = CGRect(x:0,y:0,width:width,height:height)
        // Vision and connected-component analysis must not block window interaction.
        let candidates = try await Task.detached(priority:.userInitiated) {
            let items = try recognize(image,frame:frame)
            return candidateMessages(items,image:image,frame:frame)
        }.value
        guard let chosen = chooseTarget(candidates,point:pointer) else {
            throw ModelFailure(message:"The pointer does not clearly identify a message or paragraph. Place it inside the text area and try again.")
        }
        let selectedIDs = documentTargetIDs(candidates,target:chosen)
        let selected = candidates.filter {selectedIDs.contains($0.id)}
        let source = selected.map(\.text).joined(separator:"\n\n")
        let selectedRect = selected.reduce(CGRect.null) {$0.union($1.rect)}
        let contextIDs = automaticContextIDs(candidates,target:chosen,in:frame).subtracting(selectedIDs)
        let nearby = candidates.filter {contextIDs.contains($0.id)}.map(\.text).joined(separator:"\n\n——\n\n")
        let data = await encoded
        let app = target.owningApplication?.applicationName ?? "Application"
        let pixelX = Int(pointer.x/width*CGFloat(image.width)),pixelY = Int(pointer.y/height*CGFloat(image.height))
        return Attachment(name:"Screen context",text:"""
        Application: \(app)
        Window: \(target.title ?? "")
        Screenshot: complete application window, \(image.width) × \(image.height) pixels.
        Pointer in screenshot (top-left origin): (\(pixelX), \(pixelY)).

        Selected source — translate this COMPLETE block, preserving all paragraphs. Do not translate only the nearest line:
        \(source)

        Selection method: \(selectedIDs.count>1 ? "Visible article column":chosen.method).
        Selected bounds in window points: \(selectedRect).

        Nearby window text — context only; may include other messages or UI. Do not translate this as the selected source or assume the whole window is one message:
        \(String(nearby.prefix(10000)))
        """,imageData:data)
    }
}
