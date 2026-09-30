import AppKit

struct PreviewItem: Identifiable {
    let id: UUID
    let name: String
    let path: String
    let imageData: Data?
    let artifact: WorkArtifact?
    init(artifact:WorkArtifact) {
        id = artifact.id;name = artifact.name;path = artifact.path
        imageData = nil;self.artifact = artifact
    }
    init(image:Attachment) {
        id = image.id;name = image.name;path = ""
        imageData = image.imageData;artifact = nil
    }
}

@MainActor enum ImageClipboard {
    static func copy(_ image:NSImage) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }
}

@MainActor final class LocalPreview {
    static let shared = LocalPreview()
    private var processes:[Process] = []
    private let imageDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ChillorPreview-"+UUID().uuidString)
    func open(_ item:PreviewItem,onError:@escaping(String)->Void) {
        if let artifact = item.artifact {open(artifact,onError:onError);return}
        do {
            guard let data = item.imageData,let bitmap = NSBitmapImageRep(data:data),let png = bitmap.representation(using:.png,properties:[:]) else {
                throw ModelFailure(message:"This image could not be opened.")
            }
            try FileManager.default.createDirectory(at:imageDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let file = imageDirectory.appendingPathComponent(item.id.uuidString+".png")
            try png.write(to:file,options:.atomic)
            if !NSWorkspace.shared.open(file) {throw ModelFailure(message:"This image could not be opened in a local app.")}
        } catch {onError(error.localizedDescription)}
    }
    func open(_ artifact:WorkArtifact,onError:@escaping(String)->Void) {
        let file = URL(fileURLWithPath:artifact.path)
        guard file.pathExtension.lowercased() == "html" else {
            if !NSWorkspace.shared.open(file) {onError("This file could not be opened in a local app.")}
            return
        }
        Task {
            do {
                let process = Process(), pipe = Pipe()
                process.executableURL = Bundle.main.resourceURL!.appendingPathComponent("AgentPython/bin/python3")
                process.arguments = [Bundle.main.resourceURL!.appendingPathComponent("AgentTools/server.py").path,"--preview"]
                process.environment = ["PATH":"/usr/bin:/bin","CHILLOR_WORKSPACE":file.deletingLastPathComponent().path,"PYTHONDONTWRITEBYTECODE":"1"]
                process.standardInput = FileHandle.nullDevice;process.standardOutput = pipe;process.standardError = FileHandle.nullDevice
                try process.run()
                var retained = false
                defer {if !retained && process.isRunning {process.terminate()}}
                let timeout = Task {try await Task.sleep(for:.seconds(5));if process.isRunning {process.terminate()}}
                let data = await Task.detached {pipe.fileHandleForReading.availableData}.value
                timeout.cancel()
                guard let result = try JSONSerialization.jsonObject(with:data) as? [String:String],let base = result["url"],let url = URL(string:base)?.appendingPathComponent(file.lastPathComponent) else {
                    if process.isRunning {process.terminate()}
                    throw ModelFailure(message:"Local website preview could not start.")
                }
                processes.removeAll {!$0.isRunning}
                while processes.count >= 3 {processes.removeFirst().terminate()}
                processes.append(process);retained = true
                NSWorkspace.shared.open(url)
            } catch {onError(error.localizedDescription)}
        }
    }
    func shutdown() {for process in processes where process.isRunning {process.terminate()};processes = [];try? FileManager.default.removeItem(at:imageDirectory)}
}
