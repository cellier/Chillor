import Foundation

@MainActor enum ModelSetupChecks {
    static func run() async throws {
        guard ProcessInfo.processInfo.environment["CHILLOR_TEST_MODEL_URL"] == "http://127.0.0.1:11449" else {throw ModelFailure(message:"Requires isolated model fixture")}
        let defaults = UserDefaults.standard
        let keys = ["modelSetupComplete","localModelName","localModelDirectory"]
        let original = keys.map {defaults.object(forKey:$0)}
        defer {for (key,value) in zip(keys,original) {if let value {defaults.set(value,forKey:key)} else {defaults.removeObject(forKey:key)}}}
        keys.forEach(defaults.removeObject(forKey:))
        for (ram,name) in [(7,""),(8,"qwen3.5:4b"),(16,"qwen3.5:9b"),(32,"qwen3.5:9b"),(48,"qwen3.8:27b")] {
            try SelfTests.check((ModelChoice.recommended(ramGB:ram)?.id ?? "") == name,"Memory recommendation failed")
        }
        var progress = ModelDownloadProgress()
        progress.update(["digest":"a","total":Int64(100),"completed":Int64(50)])
        progress.update(["digest":"b","total":Int64(50),"completed":Int64(50)])
        progress.update(["digest":"a","total":Int64(100),"completed":Int64(10)])
        try SelfTests.check(progress.completed == 100 && progress.total == 150,"Layer progress regressed")
        func mode(_ value:String) async throws {
            var request = URLRequest(url:LocalModel.endpoint.appendingPathComponent("test/mode"));request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject:["mode":value,"installed":false])
            _ = try await URLSession.shared.data(for:request)
        }
        func wait(_ setup:ModelSetup) async throws {
            for _ in 0..<200 {try await Task.sleep(for:.milliseconds(30));if setup.phase == "paused" || setup.phase == "ready" || setup.error != nil {return}}
            throw ModelFailure(message:"Setup did not settle")
        }
        try await mode("failure")
        let setup = ModelSetup();await setup.inspect();setup.selected = "qwen3.5:4b"
        try SelfTests.check(setup.visible && setup.phase == "choose","First launch must require model confirmation")
        setup.start()
        try SelfTests.check(setup.busy && setup.phase == "starting","Download click was not acknowledged synchronously")
        setup.start();setup.start()
        try await wait(setup)
        let (clickData,_) = try await URLSession.shared.data(from:LocalModel.endpoint.appendingPathComponent("test/stats"))
        let clicks = try JSONSerialization.jsonObject(with:clickData) as? [String:Any]
        try SelfTests.check(clicks?["pulls"] as? Int == 1,"Repeated download clicks started duplicate pulls")
        try SelfTests.check(setup.error != nil && !defaults.bool(forKey:"modelSetupComplete"),"Failed download marked ready")
        try await mode("slow")
        setup.start();try await Task.sleep(for:.milliseconds(150));setup.pause();try await wait(setup)
        try SelfTests.check(setup.phase == "paused" && !defaults.bool(forKey:"modelSetupComplete"),"Pause marked model ready")
        try await mode("ok")
        setup.start();try await wait(setup)
        try SelfTests.check(setup.phase == "ready" && !setup.visible && defaults.bool(forKey:"modelSetupComplete"),"Successful verified download did not enter chat")
        try SelfTests.check(LocalModel.modelName == "qwen3.5:4b" && InferencePolicy.contextSize == 8192,"Selected model did not reach inference config")
        let first = Task {try await ModelWarmth.shared.prewarm()}
        let second = Task {try await ModelWarmth.shared.prewarm()}
        _ = try await (first.value,second.value)
        let (data,_) = try await URLSession.shared.data(from:LocalModel.endpoint.appendingPathComponent("test/stats"))
        let stats = try JSONSerialization.jsonObject(with:data) as? [String:Any]
        try SelfTests.check(stats?["warmups"] as? Int == 1,"Concurrent warm-ups loaded twice")
        try SelfTests.check(InferencePolicy.keepAlive == "10m","Unexpected model retention policy")
        print("PASS: device policy; confirmation; progress; failed download; pause/retry; validation and saved model; shared warm-up; 10-minute retention")
    }
}
