import AppKit
import ApplicationServices

// One instance per task: element handles never cross task boundaries.
@MainActor final class DesktopTools {
    private var elements: [String:AXUIElement] = [:]
    private var snapshotTime = Date.distantPast
    func execute(_ args:[String:Any]) async throws -> [String:Any] {
        let action = args["action"] as? String ?? ""
        if action == "apps" {
            return ["apps":NSWorkspace.shared.runningApplications.filter {$0.activationPolicy == .regular}.map {
                ["name":$0.localizedName ?? "", "bundle_id":$0.bundleIdentifier ?? ""]
            },"accessibility":AXIsProcessTrusted()]
        }
        if action == "open_file" {
            let url = URL(fileURLWithPath:NSString(string:args["path"] as? String ?? "").expandingTildeInPath).resolvingSymlinksInPath()
            let allowed = ["md","txt","pdf","docx","xlsx","pptx","png","jpg","jpeg","csv","html"]
            guard allowed.contains(url.pathExtension.lowercased()),FileManager.default.fileExists(atPath:url.path) else {
                throw ModelFailure(message:"Provide an existing document path. Executables and scripts are not opened by this tool.")
            }
            try await confirm("Open file",detail:url.path)
            guard NSWorkspace.shared.open(url) else {throw ModelFailure(message:"The local application could not open this file.")}
            return ["opened":url.path]
        }
        let bundle = args["bundle_id"] as? String ?? ""
        guard !bundle.isEmpty,bundle != Bundle.main.bundleIdentifier else {throw ModelFailure(message:"Choose a target application's bundle_id from apps.")}
        // Do not expose a shell or script editor indirectly through desktop input.
        guard !["com.apple.Terminal","com.googlecode.iterm2","com.apple.ScriptEditor2"].contains(bundle) else {
            throw ModelFailure(message:"Terminal and script execution are not available through desktop controls.")
        }
        if action == "open_app" {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundle) else {throw ModelFailure(message:"Application is not installed.")}
            try await confirm("Open application",detail:bundle)
            guard NSWorkspace.shared.open(url) else {throw ModelFailure(message:"Application could not be opened.")}
            return ["launch_requested":bundle]
        }
        guard AXIsProcessTrusted() else {
            AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String:true] as CFDictionary)
            throw ModelFailure(message:"Enable Chillor in System Settings > Privacy & Security > Accessibility, then retry. Permission is checked on every operation.")
        }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier:bundle).first else {throw ModelFailure(message:"Open the target application first.")}
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root,0.2)
        if action == "inspect" {
            elements.removeAll();snapshotTime = Date()
            var rows:[[String:Any]] = []
            let start = Date()
            func visit(_ node:AXUIElement,_ depth:Int) {
                guard depth < 9,rows.count < 100,Date().timeIntervalSince(start) < 2 else {return}
                let role = value(node,kAXRoleAttribute) as? String ?? ""
                if value(node,kAXSubroleAttribute) as? String == "AXSecureTextField" {return}
                let id = UUID().uuidString
                elements[id] = node
                var row:[String:Any] = ["id":id,"role":role]
                for (key,attribute) in [("title",kAXTitleAttribute),("description",kAXDescriptionAttribute),("value",kAXValueAttribute)] {
                    if let text = value(node,attribute) as? String {row[key] = String(text.prefix(1500))}
                }
                rows.append(row)
                if let children = value(node,kAXChildrenAttribute) as? [AXUIElement] {for child in children {visit(child,depth+1)}}
            }
            if let windows = value(root,kAXWindowsAttribute) as? [AXUIElement] {for window in windows.prefix(3) {visit(window,0)}}
            return ["bundle_id":bundle,"elements":rows,"bounded_snapshot":true]
        }
        guard ["press","set_text"].contains(action),let id = args["element_id"] as? String,let element = elements[id],Date().timeIntervalSince(snapshotTime) < 60 else {
            throw ModelFailure(message:"Inspect the app again and use a fresh element_id for press or set_text.")
        }
        var pid:pid_t = 0;AXUIElementGetPid(element,&pid)
        guard pid == app.processIdentifier else {throw ModelFailure(message:"Element belongs to another application. Inspect again.")}
        let text = args["text"] as? String ?? ""
        guard text.count <= 10000 else {throw ModelFailure(message:"Text exceeds the input limit.")}
        try await confirm(action == "press" ? "Click control":"Fill text",detail:bundle+"\n"+(value(element,kAXTitleAttribute) as? String ?? value(element,kAXDescriptionAttribute) as? String ?? "Control")+(action == "set_text" ? "\n"+text:""))
        app.activate()
        let result = action == "press" ? AXUIElementPerformAction(element,kAXPressAction as CFString):AXUIElementSetAttributeValue(element,kAXValueAttribute as CFString,text as CFString)
        elements.removeAll()
        guard result == .success else {throw ModelFailure(message:"The application rejected this operation. Inspect again; do not assume success.")}
        return ["performed":action,"verify":"Inspect the application to verify the result."]
    }
    private func value(_ element:AXUIElement,_ name:String)->CFTypeRef? {
        var result:CFTypeRef?
        return AXUIElementCopyAttributeValue(element,name as CFString,&result) == .success ? result:nil
    }
    private func confirm(_ title:String,detail:String) async throws {
        try Task.checkCancellation()
        let alert = NSAlert();alert.messageText = title;alert.informativeText = detail
        alert.addButton(withTitle:"Allow");alert.addButton(withTitle:"Cancel")
        guard let window = NSApp.mainWindow else {throw ModelFailure(message:"Open Chillor to review this desktop action.")}
        NSApp.activate(ignoringOtherApps:true)
        let result = await withTaskCancellationHandler(operation:{
            await withCheckedContinuation { continuation in
                alert.beginSheetModal(for:window) { response in continuation.resume(returning:response) }
            }
        },onCancel:{
            Task { @MainActor in
                if alert.window.sheetParent != nil {window.endSheet(alert.window,returnCode:.cancel)}
            }
        })
        try Task.checkCancellation()
        guard result == .alertFirstButtonReturn else {throw ModelFailure(message:"User cancelled this desktop action. Do not retry it.")}
    }
}
