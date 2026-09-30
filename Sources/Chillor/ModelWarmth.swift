import Foundation

/// One shared warm-up, initiated only at launch/setup. Never repeatedly reload an idle model.
@MainActor final class ModelWarmth {
    static let shared = ModelWarmth()
    private var warming:Task<Void,Error>?
    private var activity = 0
    private var pressure:DispatchSourceMemoryPressure?
    private var releasing:Task<Void,Never>?
    init() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask:[.warning,.critical],queue:.main)
        source.setEventHandler { [weak self] in Task { @MainActor in self?.releaseIfIdle() } }
        source.resume();pressure = source
    }
    func prewarm() async throws {
        // A remote provider has nothing to load or unload on this Mac.
        guard !ModelRouting.usesCloud else {return}
        if let warming {return try await warming.value}
        guard activity == 0 else {return}
        if let releasing {await releasing.value}
        let task = Task { @MainActor in
            try await LocalModel.shared.prepare()
            try Task.checkCancellation()
            var request = URLRequest(url:LocalModel.endpoint.appendingPathComponent("api/generate"))
            request.httpMethod = "POST";request.timeoutInterval = 180
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject:["model":LocalModel.modelName,"stream":false,"keep_alive":InferencePolicy.keepAlive,"options":["num_ctx":InferencePolicy.contextSize]])
            let started = ProcessInfo.processInfo.systemUptime
            let (data,response) = try await URLSession.shared.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let result = try JSONSerialization.jsonObject(with:data) as? [String:Any],result["done"] as? Bool == true else {throw ModelFailure(message:"Could not load the local model. Try again.")}
            InferencePolicy.logger.notice("prewarm total_s=\(ProcessInfo.processInfo.systemUptime-started)")
        }
        warming = task
        defer {warming = nil}
        try await task.value
    }
    func begin() async {
        activity += 1
        if let releasing {await releasing.value}
        if let warming {try? await warming.value}
    }
    func end() {activity = max(0,activity-1)}
    private func releaseIfIdle() {
        guard !ModelRouting.usesCloud else {return}
        guard activity == 0,warming == nil,releasing == nil else {return}
        releasing = Task { @MainActor in
            defer {releasing = nil}
            // Respect an external caller using the same Ollama service.
            var query = URLRequest(url:LocalModel.endpoint.appendingPathComponent("api/ps"));query.timeoutInterval = 2
            guard let (data,_) = try? await URLSession.shared.data(for:query),
                  let result = try? JSONSerialization.jsonObject(with:data) as? [String:Any],
                  (result["models"] as? [[String:Any]])?.contains(where:{$0["name"] as? String == LocalModel.modelName}) == true else {return}
            // Only unload the runtime owned by this app, not another app's service.
            guard LocalModel.shared.ownsService else {return}
            var request = URLRequest(url:LocalModel.endpoint.appendingPathComponent("api/generate"));request.httpMethod = "POST";request.timeoutInterval = 5
            request.setValue("application/json",forHTTPHeaderField:"Content-Type")
            request.httpBody = try? JSONSerialization.data(withJSONObject:["model":LocalModel.modelName,"keep_alive":0,"stream":false])
            _ = try? await URLSession.shared.data(for:request)
        }
    }
}
