import AppKit
import SwiftUI

struct ModelChoice:Identifiable,Equatable {
    let id:String
    let title:String
    let downloadGB:Double
    let minimumRAM:Int
    let detail:String
    static let catalog = [
        ModelChoice(id:"qwen3.5:4b",title:"Qwen 3.5 · 4B",downloadGB:3.4,minimumRAM:8,detail:"Lightweight · everyday chat and translation"),
        ModelChoice(id:"qwen3.5:9b",title:"Qwen 3.5 · 9B",downloadGB:6.6,minimumRAM:16,detail:"Balanced · writing and everyday tasks"),
        ModelChoice(id:"qwen3.8:27b",title:"Qwen 3.8 · 27B",downloadGB:18,minimumRAM:48,detail:"More capable · needs more memory")]
    static func recommended(ramGB:Int)->ModelChoice? {catalog.last(where:{$0.minimumRAM<=ramGB})}
}
struct ModelDownloadProgress {
    private var layers:[String:(completed:Int64,total:Int64)] = [:]
    var completed:Int64 {layers.values.reduce(0){$0+$1.completed}}
    var total:Int64 {layers.values.reduce(0){$0+$1.total}}
    mutating func update(_ event:[String:Any]) {
        guard let digest = event["digest"] as? String,let total = event["total"] as? Int64,total>0 else {return}
        let previous = layers[digest]?.completed ?? 0
        layers[digest] = (min(total,max(previous,event["completed"] as? Int64 ?? 0)),total)
    }
}

@MainActor final class ModelSetup:ObservableObject {
    static let shared = ModelSetup()
    @Published var visible = false
    @Published var choices = ModelChoice.catalog
    @Published var selected = ""
    @Published var installed:Set<String> = []
    @Published var phase = "choose"
    @Published var note = ""
    @Published var progress = ModelDownloadProgress()
    @Published var bytesPerSecond:Double = 0
    @Published var error:String?
    @Published var ramGB = 0
    private var job:Task<Void,Never>?
    private var session:URLSession?
    private var inspected = false
    var busy:Bool {phase == "starting" || phase == "download" || phase == "verify"}
    var choice:ModelChoice? {choices.first(where:{$0.id == selected})}
    var compatible:Bool {
        #if arch(arm64)
        return choice.map{$0.minimumRAM<=ramGB} ?? false
        #else
        return false
        #endif
    }
    private let defaults = UserDefaults.standard
    init() {
        ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        selected = ModelChoice.recommended(ramGB:ramGB)?.id ?? ""
        // A configured remote provider is a completed setup: never block launch on a
        // local download the user has chosen not to use.
        visible = !ProcessInfo.processInfo.arguments.contains("--ui-test") && !defaults.bool(forKey:"modelSetupComplete")
            && !ModelRouting.usesCloud
    }
    func inspect() async {
        guard !inspected else {return};inspected = true
        if ModelRouting.usesCloud {
            // Verify the remote provider instead of starting the local runtime.
            visible = false
            do {try await LocalModel.shared.prepare()} catch {self.error = error.localizedDescription}
            return
        }
        ramGB = Int(ProcessInfo.processInfo.physicalMemory / 1_073_741_824)
        selected = ModelChoice.recommended(ramGB:ramGB)?.id ?? ""
        // Local inspection only: no registry request, no model download, no permission prompt.
        do {
            try await LocalModel.shared.ensureService()
            installed = Set(try await LocalModel.shared.tags())
            if defaults.bool(forKey:"modelSetupComplete"),installed.contains(LocalModel.modelName) {
                Task {try? await ModelWarmth.shared.prewarm()};return
            }
            if job == nil,installed.contains(LocalModel.modelName) {selected = LocalModel.modelName}
        } catch {self.error = "The local runtime could not start. \(error.localizedDescription)"}
        visible = true
    }
    func start() {
        guard job == nil,!busy,let choice,compatible else {return}
        error = nil;progress = ModelDownloadProgress();bytesPerSecond = 0
        // Acknowledge the click before the first await and reject duplicate starts.
        phase = "starting";note = "Starting download"
        job = Task { @MainActor in
            do {
                try await LocalModel.shared.ensureService()
                try Task.checkCancellation()
                if !installed.contains(choice.id) {
                    let directory = LocalModel.shared.modelDirectory
                    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
                    let free = try directory.resourceValues(forKeys:[.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage ?? 0
                    guard Double(free)>=(choice.downloadGB*2+2)*1_000_000_000 else {throw ModelFailure(message:"Not enough free disk space. Free at least \(Int(ceil(choice.downloadGB*2+2))) GB, then try again.")}
                    phase = "download";note = "Downloading model"
                    try await pull(choice.id)
                    installed.insert(choice.id)
                }
                try Task.checkCancellation()
                phase = "verify";note = "Preparing your model"
                try await validate(choice.id)
                try Task.checkCancellation()
                defaults.set(choice.id,forKey:"localModelName")
                defaults.set(LocalModel.shared.modelDirectory.path,forKey:"localModelDirectory")
                LocalModel.shared.resetReadiness()
                try await LocalModel.shared.prepare()
                defaults.set(true,forKey:"modelSetupComplete")
                phase = "ready";visible = false
            } catch {
                if Task.isCancelled {phase = "paused";note = "Download paused"}
                else {phase = "choose";self.error = error.localizedDescription}
            }
            job = nil
        }
    }
    func pause() {job?.cancel();session?.invalidateAndCancel()}
    private func pull(_ name:String) async throws {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60;config.timeoutIntervalForResource = 24*60*60
        let client = URLSession(configuration:config);session = client
        defer {client.invalidateAndCancel();session = nil}
        var request = URLRequest(url:LocalModel.endpoint.appendingPathComponent("api/pull"));request.httpMethod = "POST"
        request.setValue("application/json",forHTTPHeaderField:"Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject:["model":name,"stream":true])
        let (bytes,response) = try await client.bytes(for:request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {throw ModelFailure(message:"Download could not start. Check your connection and retry.")}
        var succeeded = false
        var sampleTime = ProcessInfo.processInfo.systemUptime
        var sampleBytes:Int64?
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard let data = line.data(using:.utf8),let event = try JSONSerialization.jsonObject(with:data) as? [String:Any] else {continue}
            if let error = event["error"] as? String {throw ModelFailure(message:error)}
            progress.update(event)
            let now = ProcessInfo.processInfo.systemUptime
            if sampleBytes == nil {sampleBytes = progress.completed;sampleTime = now}
            else if now-sampleTime >= 0.5 {
                bytesPerSecond = Double(max(0,progress.completed-(sampleBytes ?? 0)))/(now-sampleTime)
                sampleBytes = progress.completed;sampleTime = now
            }
            let state = event["status"] as? String ?? ""
            note = state.contains("verifying") ? "Verifying download":(progress.total > 0 ? "Downloading model":"Connecting to download")
            if state == "success" {succeeded = true}
        }
        guard succeeded else {throw ModelFailure(message:"Download was interrupted. Retry to continue the download.")}
    }
    private func validate(_ name:String) async throws {
        let config = URLSessionConfiguration.ephemeral;config.timeoutIntervalForRequest = 180
        let client = URLSession(configuration:config);session = client
        defer {client.invalidateAndCancel();session = nil}
        func post(_ path:String,_ body:[String:Any]) async throws -> [String:Any] {
            var request = URLRequest(url:LocalModel.endpoint.appendingPathComponent(path));request.httpMethod = "POST"
            request.setValue("application/json",forHTTPHeaderField:"Content-Type");request.httpBody = try JSONSerialization.data(withJSONObject:body)
            let (data,response) = try await client.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,let result = try JSONSerialization.jsonObject(with:data) as? [String:Any],result["error"] == nil else {throw ModelFailure(message:"This model could not run. Try a smaller model or retry.")}
            return result
        }
        let metadata = try await post("api/show",["model":name])
        let capabilities = Set(metadata["capabilities"] as? [String] ?? [])
        guard capabilities.isSuperset(of:["completion","tools","vision"]) else {throw ModelFailure(message:"This model does not support all required chat, image and tool capabilities.")}
        let result = try await post("api/chat",["model":name,"messages":[["role":"user","content":"Reply with OK."]],"think":false,"stream":false,"keep_alive":InferencePolicy.keepAlive,"options":["num_ctx":InferencePolicy.contextSize(for:name),"num_predict":16]])
        guard result["done"] as? Bool == true,let message = result["message"] as? [String:Any],!(message["content"] as? String ?? "").isEmpty else {throw ModelFailure(message:"The model did not return a response. Please retry.")}
    }
}

struct ModelSetupView:View {
    @ObservedObject var setup = ModelSetup.shared
    var body:some View {
        VStack(alignment:.leading,spacing:20) {
            Image(systemName:"sparkles").font(.system(size:28)).accessibilityHidden(true)
            Text("Make Chillor yours").font(.system(size:24,weight:.semibold))
            Text("Choose a model to run on your Mac. No account or model subscription needed.").foregroundStyle(.secondary)
            if setup.busy || setup.phase == "paused" {
                Text(setup.choice?.title ?? "Local model").fontWeight(.medium)
                if setup.progress.total>0 {
                    ProgressView(value:Double(setup.progress.completed),total:Double(setup.progress.total))
                    Text("\(ByteCountFormatter.string(fromByteCount:setup.progress.completed,countStyle:.file)) / \(ByteCountFormatter.string(fromByteCount:setup.progress.total,countStyle:.file))").font(.system(size:12)).foregroundStyle(.secondary)
                    if setup.bytesPerSecond > 0 && setup.phase == "download" {
                        Text(ByteCountFormatter.string(fromByteCount:Int64(setup.bytesPerSecond),countStyle:.file)+"/s").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                } else {ProgressView().controlSize(.small)}
                Text(setup.note).foregroundStyle(.secondary)
                if setup.busy {Button(setup.phase == "verify" ? "Cancel":"Pause") {setup.pause()}}
                else {Button("Continue download") {setup.start()}}
            } else {
                Picker("Model",selection:$setup.selected) {
                    ForEach(setup.choices) {model in
                        Text(model.title+(model.id == ModelChoice.recommended(ramGB:setup.ramGB)?.id ? " · Recommended":"")).tag(model.id)
                    }
                }.labelsHidden()
                if let choice = setup.choice {
                    Text(choice.detail).foregroundStyle(.secondary)
                    Text(setup.installed.contains(choice.id) ? "Already on this Mac · no download needed":"About \(choice.downloadGB.formatted()) GB download · stored on this Mac")
                        .font(.system(size:12)).foregroundStyle(.secondary)
                    if !setup.compatible {Text("This model needs at least \(choice.minimumRAM) GB of memory. Choose a smaller model.").foregroundStyle(.secondary)}
                }
                if setup.ramGB<8 {Text("This version needs an Apple silicon Mac with at least 8 GB of memory.")}
                Button(setup.installed.contains(setup.selected) ? "Use this model":"Download and continue") {setup.start()}
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(!setup.compatible)
            }
            if let error = setup.error {Text(error).font(.system(size:12)).foregroundStyle(.red).textSelection(.enabled)}
        }.font(.system(size:14)).padding(32).frame(maxWidth:440,alignment:.leading)
            .frame(maxWidth:.infinity,maxHeight:.infinity).background(Color(nsColor:.textBackgroundColor))
    }
}
