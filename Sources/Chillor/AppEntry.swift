import AppKit
import SwiftUI

@MainActor final class AppDelegate:NSObject,NSApplicationDelegate {
    var main:MainWindowController!
    var preferencesWindow:NSWindow?
    var runner:CommandRunner!
    var conversation:Conversation!
    private var statusItem:NSStatusItem?
    func applicationDidFinishLaunching(_ notification:Notification) {
        if let url = Bundle.main.url(forResource:"AppIconMac",withExtension:"icns") {
            NSApp.applicationIconImage = NSImage(contentsOf:url)
        }
        Preferences.shared.applyAppearance()
        let arguments = ProcessInfo.processInfo.arguments
        let testMode = arguments.contains("--ui-test")
        conversation = Conversation(file:testMode ? URL(fileURLWithPath:"/tmp/chillor-ui-test-conversation.json"):nil)
        main = MainWindowController(conversation:conversation)
        main.openSettings = { [weak self] in self?.settings() }
        makeMenus()
        if !testMode {makeStatusItem()}
        runner = CommandRunner(conversation:conversation)
        runner.reveal = { [weak self] in self?.main.reveal() }
        let headlessCheck = testMode && ["--memory-test","--speed-test","--writing-test","--recall-test","--ppt-test","--web-test","--harness-test","--task-test"].contains(where:arguments.contains)
        if !headlessCheck {main.reveal()}
        if arguments.contains("--composer-image-fixture") && testMode {
            conversation.messages = []
            conversation.draft = "Describe these images"
            if let image = Bundle.main.url(forResource:"Welcome",withExtension:"png") {
                conversation.importContextFiles([image,image])
            }
        } else if arguments.contains("--scroll-hang-test") && testMode {
            Task { @MainActor in
                do {try await ScrollHangChecks.run();NSApp.terminate(nil)}
                catch {fputs("SCROLL_HANG_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--model-setup-test") && testMode {
            Task { @MainActor in
                do {try await ModelSetupChecks.run();NSApp.terminate(nil)}
                catch {fputs("MODEL_SETUP_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--model-setup-fixture") && testMode {
            Task {await ModelSetup.shared.inspect()}
        } else if arguments.contains("--ui-performance-test") && testMode {
            Task { @MainActor in
                do {try await UIRenderingChecks.run();NSApp.terminate(nil)}
                catch {fputs("UI_PERFORMANCE_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--memory-test") && testMode {
            Task { @MainActor in
                do {try await ContextMemoryChecks.run();NSApp.terminate(nil)}
                catch {fputs("MEMORY_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--speed-test") && testMode {
            Task { @MainActor in
                do {try await ResponsePerformanceChecks.run();NSApp.terminate(nil)}
                catch {fputs("SPEED_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--preview-ui-fixture") && testMode {
            do {try SelfTests.preparePreviewUIFixture()}
            catch {fputs("PREVIEW_FIXTURE_FAILED: \(error)\n",stderr);exit(1)}
        } else if arguments.contains("--writing-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.writing();NSApp.terminate(nil)}
                catch {fputs("WRITING_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--recall-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.recallModel();NSApp.terminate(nil)}
                catch {fputs("RECALL_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--ppt-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.presentation();NSApp.terminate(nil)}
                catch {fputs("PPT_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--web-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.web();NSApp.terminate(nil)}
                catch {fputs("WEB_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--harness-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.harness();NSApp.terminate(nil)}
                catch {fputs("HARNESS_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--task-test") && testMode {
            Task { @MainActor in
                do {try await TaskRuntimeChecks.run(realModel:arguments.contains("--routing-model-test"));NSApp.terminate(nil)}
                catch {fputs("TASK_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--preview-scroll-test") && testMode {
            Task { @MainActor in
                do {try await SelfTests.runPreviewScrollTest();NSApp.terminate(nil)}
                catch {fputs("PREVIEW_SCROLL_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--scroll-test") && testMode {
            Task { @MainActor in
                do {try await SelfTests.runScrollTest();NSApp.terminate(nil)}
                catch {fputs("SCROLL_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if arguments.contains("--window-test") {
            do {try SelfTests.runWindowTests();NSApp.terminate(nil)}
            catch {fputs("WINDOW_TEST_FAILED: \(error)\n",stderr);exit(1)}
        } else if arguments.contains("--self-test") {
            Task { @MainActor in
                do {try await SelfTests.run();print("CHILLOR_SELF_TEST_PASS");NSApp.terminate(nil)}
                catch {fputs("SELF_TEST_FAILED: \(error)\n",stderr);exit(1)}
            }
        } else if !testMode {Task {await ModelSetup.shared.inspect()}}
    }
    @objc func settings() {
        if preferencesWindow == nil {
            let window = NSWindow(contentRect:NSRect(x:0,y:0,width:544,height:554),styleMask:[.titled,.closable,.miniaturizable],backing:.buffered,defer:false)
            window.title = "Chillor Settings";window.isReleasedWhenClosed = false
            window.contentView = NSHostingView(rootView:SettingsView())
            window.center();preferencesWindow = window
        }
        preferencesWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
    @objc func showMain(){main.reveal()}
    private func makeStatusItem() {
        guard let url = Bundle.main.url(forResource:"MenuBarIcon",withExtension:"png"),
              let source = NSImage(contentsOf:url) else {return}
        // Keep the supplied artwork intact; omit its transparent export margins
        // when drawing at menu-bar size. AppKit templates adapt to light/dark bars.
        source.size = NSSize(width:1339,height:1174)
        let size = NSSize(width:18*806/827,height:18)
        let icon = NSImage(size:size,flipped:false) { rect in
            source.draw(in:rect,from:NSRect(x:265,y:134,width:806,height:827),operation:.sourceOver,fraction:1)
            return true
        }
        icon.isTemplate = true
        let item = NSStatusBar.system.statusItem(withLength:NSStatusItem.squareLength)
        item.button?.image = icon
        item.button?.toolTip = "Open Chillor"
        item.button?.setAccessibilityLabel("Open Chillor")
        item.button?.target = self;item.button?.action = #selector(showMain)
        statusItem = item
    }
    @objc func find(){main.reveal();NotificationCenter.default.post(name:.findConversation,object:nil)}
    func makeMenus() {
        let bar = NSMenu()
        let app = NSMenuItem();bar.addItem(app)
        let menu = NSMenu(title:"Chillor");app.submenu = menu
        menu.addItem(withTitle:"About Chillor",action:#selector(NSApplication.orderFrontStandardAboutPanel(_:)),keyEquivalent:"")
        menu.addItem(.separator())
        let settings = menu.addItem(withTitle:"Settings…",action:#selector(self.settings),keyEquivalent:",");settings.target = self
        menu.addItem(.separator())
        menu.addItem(withTitle:"Hide Chillor",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h")
        menu.addItem(withTitle:"Quit Chillor",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q")
        let editItem = NSMenuItem();bar.addItem(editItem);let edit = NSMenu(title:"Edit");editItem.submenu = edit
        for (title,action,key) in [("Undo","undo:","z"),("Cut","cut:","x"),("Copy","copy:","c"),("Paste","paste:","v"),("Select All","selectAll:","a")] {edit.addItem(withTitle:title,action:Selector(action),keyEquivalent:key)}
        let find = edit.addItem(withTitle:"Find…",action:#selector(self.find),keyEquivalent:"f");find.target = self
        let windowItem = NSMenuItem();bar.addItem(windowItem);let windows = NSMenu(title:"Window");windowItem.submenu = windows
        let show = windows.addItem(withTitle:"Chillor",action:#selector(showMain),keyEquivalent:"0");show.target = self
        windows.addItem(withTitle:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m")
        windows.addItem(withTitle:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w")
        NSApp.mainMenu = bar;NSApp.windowsMenu = windows
    }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows flag:Bool)->Bool {main.reveal();return true}
    func applicationWillTerminate(_ notification:Notification){conversation?.persist();LocalPreview.shared.shutdown();LocalModel.shared.shutdown()}
}
@main struct ChillorMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
