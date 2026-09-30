import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct ChillorGlass:ViewModifier {
    var radius:CGFloat = 28
    func body(content:Content)->some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in:RoundedRectangle(cornerRadius:radius))
        } else {
            content.background(.regularMaterial,in:RoundedRectangle(cornerRadius:radius))
                .overlay(RoundedRectangle(cornerRadius:radius).stroke(.primary.opacity(0.12),lineWidth:0.5))
        }
    }
}
struct ConversationView:View {
    @ObservedObject var conversation:Conversation
    @ObservedObject var preferences = Preferences.shared
    @State var composerHeight:CGFloat = 56
    @State var atBottom = true
    @State private var showsBackToNow = false
    @State private var returnScrollID:UUID?
    @State private var followsLatest = true
    @State private var positioningLatest = true
    @State private var userIsScrolling = false
    @State private var composerOverlayHeight:CGFloat = 104
    @State private var scrollPosition = ScrollPosition(edge:.bottom)
    @StateObject private var readingPosition = ConversationReadingPosition()
    @State var copiedID:UUID?
    @State private var imageDropTargeted = false
    @ObservedObject private var modelSetup = ModelSetup.shared
    var body:some View {
        GeometryReader { geometry in
            HSplitView {
                chatContent
                    .frame(minWidth:min(280,geometry.size.width * 0.45),idealWidth:geometry.size.width * 0.405,maxWidth:.infinity,maxHeight:.infinity)
                if let artifact = conversation.previewArtifact {
                    ArtifactPreview(artifact:artifact,onClose:{conversation.previewArtifact = nil},onError:{conversation.attachmentError = $0})
                        .frame(minWidth:min(280,geometry.size.width * 0.45),idealWidth:geometry.size.width * 0.595,maxWidth:.infinity,maxHeight:.infinity)
                        .transition(.move(edge:.trailing).combined(with:.opacity))
                }
            }
            .allowsHitTesting(!modelSetup.visible)
            .accessibilityHidden(modelSetup.visible)
            .overlay {if modelSetup.visible {ModelSetupView()}}
            // Do one deterministic reflow when the preview changes width.
            .animation(nil,value:conversation.previewArtifact != nil)
            .onDrop(of:[UTType.fileURL.identifier,UTType.image.identifier],isTargeted:$imageDropTargeted) { providers in
                conversation.importDroppedImages(providers)
            }
            .overlay {
                if imageDropTargeted {
                    RoundedRectangle(cornerRadius:32).fill(.regularMaterial)
                        .overlay(RoundedRectangle(cornerRadius:32).stroke(Color.primary.opacity(0.2),style:StrokeStyle(lineWidth:2,dash:[8])))
                        .overlay(Label("Drop images to add context",systemImage:"photo.on.rectangle.angled").font(.system(size:16,weight:.medium)))
                        .padding(12).allowsHitTesting(false)
                }
            }
        }
    }
    private var chatContent:some View {
        GeometryReader { geometry in
            ZStack(alignment:.bottom) {
                Color(nsColor:.textBackgroundColor)
                if conversation.messages.isEmpty {
                    VStack(spacing:16) {
                        if let url = Bundle.main.url(forResource:"Welcome",withExtension:"png"), let image = NSImage(contentsOf:url) {
                            Image(nsImage:image).resizable().interpolation(.high).scaledToFit().frame(width:120,height:120).accessibilityHidden(true)
                        }
                        Text("What can I help you?").font(.system(size:20)).foregroundStyle(.primary)
                    }
                    .position(x:geometry.size.width/2,y:geometry.size.height*0.453)
                } else {
                    ScrollViewReader { proxy in
                    GradientBlurContent(bottomHeight:composerOverlayHeight) {
                        ScrollView {
                            // Stable row ownership avoids a macOS lazy-row recycling
                            // layout loop with native rich text and message controls.
                            // Keep parsing/measurement caches and equatable rows.
                            VStack(alignment:.leading,spacing:24) {
                                ForEach(conversation.messages) { message in
                                    MessageRow(message:message,conversation:conversation,fontSize:preferences.textSize,readingPosition:readingPosition,onOpenPreview:openPreview,reduceMotion:preferences.motionDisabled,retryAvailable:conversation.canRetry(message),activity:conversation.activity[message.id])
                                        .equatable()
                                        .background(ConversationRowPosition(messageID:message.id,readingPosition:readingPosition))
                                        .id(message.id)
                                }
                                // Reserve the complete composer and a small readable gap.
                                Color.clear
                                    .frame(height:composerOverlayHeight+16)
                                    .id("latest")

                            }
                            .padding(.horizontal,24).padding(.top,32)
                        }
                        .scrollIndicators(.hidden)
                        .scrollPosition($scrollPosition)
                        .coordinateSpace(name:"conversationViewport")
                        .defaultScrollAnchor(.bottom,for:.initialOffset)
                        .defaultScrollAnchor(followsLatest ? .bottom:.top,for:.sizeChanges)
                        // Capture native, already-laid-out row coordinates before
                        // changing the split width. File clicks prefer their card;
                        // other changes preserve the first visible message.
                        .onReceive(conversation.$previewArtifact.map { $0 != nil }.removeDuplicates().dropFirst()) { _ in
                            readingPosition.capture()
                            positioningLatest = false
                            returnScrollID = nil
                            followsLatest = false
                            scrollPosition = ScrollPosition()
                        }
                        .onScrollPhaseChange { _,phase in
                            userIsScrolling = phase == .tracking || phase == .interacting || phase == .decelerating
                            if userIsScrolling { positioningLatest = false;readingPosition.release();returnScrollID = nil;followsLatest = atBottom }
                        }
                        .onScrollGeometryChange(for:ConversationScrollSignals.self) { geometry in
                            ConversationScrollSignals(metrics:ConversationScrollMetrics(contentHeight:geometry.contentSize.height,viewportHeight:geometry.containerSize.height,offset:geometry.contentOffset.y))
                        } action: { old,new in
                            // Initial layout may report a top offset before the bottom
                            // request is applied. It is not an intentional user scroll.
                            if positioningLatest {
                                if new.needsBottomCorrection {scrollPosition.scrollTo(edge:.bottom)}
                                else if new.viewportHeight > 0 {positioningLatest = false}
                                updateScrollFlags(band:new.band)
                                return
                            }
                            // Stable rows provide actual content geometry. The old lazy
                            // tail visibility fallback is stale for retained offscreen rows.
                            // Wheel/keyboard/accessibility scrolling can change offset
                            // without a live-scroll phase. Unchanged layout distinguishes
                            // that movement from a growing streamed response.
                            if old.contentHeight == new.contentHeight && old.viewportHeight == new.viewportHeight && returnScrollID == nil && !readingPosition.isPreserving {
                                followsLatest = new.isAtBottom
                            }
                            updateScrollFlags(band:new.band)
                            if new.needsBottomCorrection && followsLatest && !userIsScrolling && returnScrollID == nil && (old.contentHeight != new.contentHeight || old.viewportHeight != new.viewportHeight) {
                                scrollPosition.scrollTo(edge:.bottom)
                            }
                        }
                        .onChange(of:conversation.messages.count) { _,_ in
                            guard !readingPosition.isPreserving else {return}
                            returnScrollID = nil;followsLatest = true;showsBackToNow = false;scrollPosition.scrollTo(edge:.bottom)
                        }
                        .onChange(of:composerOverlayHeight) { _,_ in
                            if followsLatest && !userIsScrolling && returnScrollID == nil {scrollPosition.scrollTo(edge:.bottom)}
                        }
                        .onChange(of:conversation.scrollTarget) { _,value in
                            if let value { positioningLatest = false;readingPosition.release();returnScrollID = nil;followsLatest = false;proxy.scrollTo(value,anchor:.top);conversation.scrollTarget = nil }
                        }
                        .onAppear {showLatestOnOpen()}
                        .onChange(of:conversation.latestPositionRequest) { _,_ in showLatestOnOpen() }
                    }
                    }
                }

                VStack(spacing:8) {
                    if let status = conversation.contextCaptureStatus {
                        GenerationStatus(text:status,reduceMotion:preferences.motionDisabled)
                            .frame(maxWidth:.infinity,alignment:.leading)
                    }
                    if let error = conversation.attachmentError {
                        HStack(alignment:.top) {
                            Text(error).font(.system(size:12)).fixedSize(horizontal:false,vertical:true)
                            Spacer(minLength:4)
                            Button { conversation.attachmentError = nil } label:{Image(systemName:"xmark")}.buttonStyle(ChillorButtonStyle()).accessibilityLabel("Dismiss notice")
                        }.padding(12).background(.regularMaterial,in:RoundedRectangle(cornerRadius:16))
                    }
                    if let anchor = conversation.anchor {
                        HStack(spacing:8) {
                            Image(systemName:"arrowshape.turn.up.left")
                            Text(anchor.text).font(.system(size:13)).lineLimit(2)
                            Spacer(minLength:0)
                            Button {conversation.anchor = nil} label:{Image(systemName:"xmark.circle.fill").foregroundStyle(.secondary)}.buttonStyle(ChillorButtonStyle()).accessibilityLabel("Remove reference")
                        }.padding(12).modifier(ChillorGlass(radius:16))
                    }
                    HStack(alignment:.bottom,spacing:12) {
                        Button { conversation.searching.toggle() } label: {
                            Image(systemName:"magnifyingglass").font(.system(size:16,weight:.medium)).foregroundStyle(.black).frame(width:56,height:56,alignment:.center)
                        }.buttonStyle(ChillorButtonStyle()).modifier(ChillorGlass()).help("Search · ⌘F").accessibilityLabel("Search conversation")
                        VStack(spacing:0) {
                            pendingAttachments
                            Composer(conversation:conversation,height:$composerHeight)
                                .frame(height:composerHeight)
                        }
                        .modifier(ChillorGlass(radius:!conversation.attachments.isEmpty || composerHeight > 56 ? 24:28))
                        .animation(preferences.motionDisabled ? nil : .easeOut(duration:0.18),value:composerHeight)
                        if showsBackToNow && !conversation.messages.isEmpty {
                            Button(action:returnToNow) {
                                Image(systemName:"arrow.down")
                                    .font(.system(size:16,weight:.medium)).foregroundStyle(.black)
                                    .frame(width:56,height:56).contentShape(Circle())
                            }
                            .buttonStyle(ChillorButtonStyle()).modifier(ChillorGlass())
                            .help("Back to now").accessibilityLabel("Back to now")
                            .accessibilityIdentifier("back-to-now")
                            .transition(preferences.motionDisabled ? .opacity:.scale(scale:0.05,anchor:.center).combined(with:.opacity))
                        }
                    }
                    .animation(preferences.motionDisabled ? nil:.spring(response:0.38,dampingFraction:0.86),value:showsBackToNow)
                }
                .padding(24)
                .onGeometryChange(for:CGFloat.self) { $0.size.height } action: { height in
                    if abs(composerOverlayHeight-height)>0.5 {composerOverlayHeight = height}
                }

                if conversation.searching {
                    SearchView(conversation:conversation).padding(24).frame(maxHeight:.infinity,alignment:.top)
                }
            }
        }
        .foregroundStyle(.primary)
        .onReceive(NotificationCenter.default.publisher(for:.findConversation)) {_ in conversation.searching = true}
        .onExitCommand { conversation.searching = false; conversation.anchor = nil }
    }
    @ViewBuilder private var pendingAttachments:some View {
        if !conversation.attachments.isEmpty {
            ScrollView(.horizontal) {
                HStack {
                    ForEach(conversation.attachments) { attachment in
                        if let data = attachment.imageData,let image = MessageImageCache.image(id:attachment.id,data:data) {
                            ZStack(alignment:.topTrailing) {
                                Button {openPreview(PreviewItem(image:attachment))} label: {
                                    Image(nsImage:image).resizable().scaledToFill().frame(width:72,height:72).clipped().clipShape(RoundedRectangle(cornerRadius:12))
                                }.background(ConversationRowPosition(messageID:attachment.id,readingPosition:readingPosition)).buttonStyle(.plain).help(attachment.name).accessibilityLabel("Preview " + attachment.name)
                                Button {conversation.attachments.removeAll {$0.id == attachment.id}} label: {
                                    Image(systemName:"xmark").font(.system(size:10,weight:.semibold)).frame(width:24,height:24).background(.regularMaterial,in:Circle())
                                }.buttonStyle(ChillorButtonStyle()).accessibilityLabel("Remove " + attachment.name)
                            }.padding(4)
                        } else {
                        HStack(spacing:5) {
                            Image(systemName:attachment.imageData == nil ? "doc" : "photo")
                            Text(attachment.name).lineLimit(1)
                            Button {conversation.attachments.removeAll {$0.id == attachment.id}} label:{Image(systemName:"xmark.circle.fill")}.buttonStyle(ChillorButtonStyle()).accessibilityLabel("Remove \(attachment.name)")
                        }.font(.system(size:12)).padding(8).background(.quaternary,in:Capsule())
                        }
                    }
                }
            }.scrollIndicators(.hidden).frame(height:84).padding(.horizontal,12).padding(.top,12)
        }
    }
    private func openPreview(_ item:PreviewItem) {
        readingPosition.capture(preferredID:item.id)
        conversation.previewArtifact = item
    }
    private func showLatestOnOpen() {
        readingPosition.release()
        returnScrollID = nil;positioningLatest = true;followsLatest = true
        showsBackToNow = false
        scrollPosition.scrollTo(edge:.bottom)
    }
    private func updateScrollFlags(band:Int) {
        let bottom = band == 0
        if atBottom != bottom {atBottom = bottom}
        if userIsScrolling && followsLatest != bottom {followsLatest = bottom}
        let show = !followsLatest && (band == 2 || (showsBackToNow && band == 1))
        if showsBackToNow != show {showsBackToNow = show}
    }
    private func returnToNow() {
        readingPosition.release()
        followsLatest = true;showsBackToNow = false
        guard !preferences.motionDisabled else {
            returnScrollID = nil;scrollPosition.scrollTo(edge:.bottom);return
        }
        let id = UUID();returnScrollID = id
        // Let the native scroll animation finish before composer reflow or
        // streaming height changes can issue an unanimated follow-to-bottom.
        withAnimation(.easeOut(duration:0.28),completionCriteria:.removed) {
            scrollPosition.scrollTo(edge:.bottom)
        } completion: {
            guard returnScrollID == id else {return}
            returnScrollID = nil
            if followsLatest && !userIsScrolling {scrollPosition.scrollTo(edge:.bottom)}
        }
    }
}

struct MessageRow:View,Equatable {
    let message:ChatMessage
    let conversation:Conversation
    var fontSize:Double
    let readingPosition:ConversationReadingPosition
    let onOpenPreview:(PreviewItem)->Void
    let reduceMotion:Bool
    let retryAvailable:Bool
    let activity:String?
    static func ==(lhs:Self,rhs:Self)->Bool {
        lhs.message == rhs.message && lhs.fontSize == rhs.fontSize && lhs.reduceMotion == rhs.reduceMotion
            && lhs.retryAvailable == rhs.retryAvailable && lhs.activity == rhs.activity
            && lhs.conversation === rhs.conversation && lhs.readingPosition === rhs.readingPosition
    }
    @State var hover = false
    @State var expandedSource = false
    var body:some View {
        let _ = UIRenderingChecks.rowRendered()
        VStack(alignment:message.role == "user" ? .trailing:.leading,spacing:8) {
            if !message.attachments.isEmpty {
                DisclosureGroup(isExpanded:$expandedSource) {
                    ForEach(message.attachments) { attachment in
                        VStack(alignment:.leading,spacing:8) {
                            Text(attachment.name).font(.system(size:12,weight:.medium))
                            if let data = attachment.imageData, let image = MessageImageCache.image(id:attachment.id,data:data) {
                                Button {onOpenPreview(PreviewItem(image:attachment))} label: {
                                    Image(nsImage:image).resizable().scaledToFit().frame(maxHeight:180).clipShape(RoundedRectangle(cornerRadius:12))
                                }
                                .background(ConversationRowPosition(messageID:attachment.id,readingPosition:readingPosition))
                                .buttonStyle(.plain).contentShape(Rectangle())
                                .help("Preview image").accessibilityLabel("Preview " + attachment.name)
                                .contextMenu {
                                    Button {ImageClipboard.copy(image)} label: {Label("Copy image",systemImage:"square.on.square")}
                                }
                            }
                            Text(attachment.text).font(.system(size:12)).lineLimit(12).textSelection(.enabled)
                        }.frame(maxWidth:.infinity,alignment:.leading)
                    }
                } label: { Label(message.attachments.map(\.name).joined(separator:", "),systemImage:"paperclip").font(.system(size:12)).lineLimit(1) }
                .frame(maxWidth:320).padding(12).background(.quaternary,in:RoundedRectangle(cornerRadius:16))
            }
            if !message.text.isEmpty {
                Group {
                    if message.role == "assistant" {
                        MarkdownMessage(text:message.text,fontSize:fontSize).equatable()
                    } else {
                        Text(message.text).font(.system(size:fontSize)).lineSpacing(5).textSelection(.enabled)
                    }
                }
                    .padding(.horizontal,message.role == "user" ? 20:0).padding(.vertical,message.role == "user" ? 10:0)
                    .background(message.role == "user" ? Color.primary.opacity(0.045):.clear,in:RoundedRectangle(cornerRadius:24))
                    .frame(maxWidth:message.role == "user" ? 380:.infinity,alignment:message.role == "user" ? .trailing:.leading)
            }
            if let artifacts = message.artifacts,!artifacts.isEmpty {
                VStack(alignment:.leading,spacing:6) {
                    ForEach(artifacts) { artifact in
                        Button {onOpenPreview(PreviewItem(artifact:artifact))} label: {
                            Label(artifact.name,systemImage:"doc").font(.system(size:13)).padding(8)
                        }.background(ConversationRowPosition(messageID:artifact.id,readingPosition:readingPosition)).buttonStyle(ChillorButtonStyle()).help(artifact.validation)
                    }
                }
            }
            if let status = generationStatus {
                GenerationStatus(text:status,reduceMotion:reduceMotion)
                    .frame(maxWidth:.infinity,alignment:.leading)
                    .padding(.vertical,4)
            }
            if hasMessageActions {
              HStack(spacing:8) {
                if message.role == "user" {
                    timestamp
                    Button(action:copyMessage) {
                        Image(systemName:"square.on.square").frame(width:28,height:28).contentShape(Rectangle())
                    }.help("Copy message").accessibilityLabel("Copy message")
                    messageMenu
                } else {
                    if retryAvailable {
                        Button {conversation.retry(message)} label:{Label("Retry",systemImage:"arrow.clockwise")}
                    }
                    if message.state != "working" {
                      Button {conversation.continueFrom(message)} label:{
                        Image(systemName:"plus.message").frame(width:28,height:28).contentShape(Rectangle())
                      }.help("Continue from here").accessibilityLabel("Continue from here")
                    }
                    messageMenu
                    timestamp
                }
            }.font(.system(size:13)).foregroundStyle(.secondary).buttonStyle(ChillorButtonStyle())
                .opacity(hover ? 1:0)
                .scaleEffect(hover ? 1:0.92,anchor:message.role == "user" ? .trailing:.leading)
                .offset(y:hover ? 0:-4)
                .animation(reduceMotion ? nil:.spring(response:0.3,dampingFraction:0.8),value:hover)
                .allowsHitTesting(hover)
                .accessibilityHidden(!hover)
            }
        }.frame(maxWidth:.infinity,alignment:message.role == "user" ? .trailing:.leading)
            .accessibilityElement(children:.contain)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active: hover = true
                case .ended: hover = false
                }
            }
            .onReceive(NotificationCenter.default.publisher(for:NSWindow.didResignKeyNotification)) { _ in hover = false }
            .onDisappear {hover = false}
            .contextMenu {
              if hasMessageActions {
                if message.role != "user" {Button("Continue from here") {conversation.continueFrom(message)}}
                Button("Copy",action:copyMessage)
                Divider()
                deleteButton
              }
            }
    }
    private var hasMessageActions:Bool {
        !(message.role == "assistant" && message.state == "working")
    }
    private var generationStatus:String? {
        guard message.role == "assistant",message.state == "working" else {return nil}
        return activity ?? (message.text.isEmpty ? "Thinking":nil)
    }
    private var messageMenu:some View {
        Menu {
            if message.role != "user" {
                if message.state != "working" {
                    Button("Continue from here") {conversation.continueFrom(message)}
                }
                Button("Copy",action:copyMessage)
                Divider()
            }
            deleteButton
        } label:{
            Image(systemName:"ellipsis").foregroundStyle(.secondary)
                .frame(width:28,height:28).contentShape(Rectangle())
        }.menuStyle(.borderlessButton).menuIndicator(.hidden).tint(Color(nsColor:.secondaryLabelColor))
            .fixedSize().modifier(ButtonHoverFeedback()).help("Message actions").accessibilityLabel("Message actions")
    }
    private var deleteButton:some View {
        Button(role:.destructive) {conversation.delete(message)} label:{
            Label("Delete",systemImage:"trash")
        }
    }
    private var timestamp:some View {
        TimelineView(.periodic(from:.now,by:60)) { context in
            Text(MessageTimestamp.string(message.date,now:context.date))
                .font(.system(size:12)).foregroundStyle(.secondary)
                .lineLimit(1).help(message.date.formatted(date:.complete,time:.shortened))
        }
    }
    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text,forType:.string)
    }
}
struct SearchView:View {
    @ObservedObject var conversation:Conversation
    @FocusState var focused:Bool
    var body:some View {
        VStack(spacing:0) {
            HStack {
                Image(systemName:"magnifyingglass").foregroundStyle(.secondary)
                TextField("Find something",text:$conversation.search).textFieldStyle(.plain).focused($focused)
                Button {conversation.searching = false} label:{Image(systemName:"xmark")}.buttonStyle(ChillorButtonStyle()).accessibilityLabel("Close search")
            }.padding(16)
            Divider()
            if conversation.results.isEmpty {
                Text(conversation.search.isEmpty ? "Your conversation will appear here." : "No results").foregroundStyle(.secondary).padding(24)
            } else {
                ScrollView {
                    LazyVStack(alignment:.leading,spacing:4) {
                        ForEach(conversation.results) { message in
                            Button {
                                conversation.searching = false
                                conversation.scrollTarget = message.id
                            } label: {
                                VStack(alignment:.leading,spacing:4) {
                                    Text(message.date,style:.date).font(.system(size:11)).foregroundStyle(.secondary)
                                    Text(message.text).font(.system(size:13)).lineLimit(3).frame(maxWidth:.infinity,alignment:.leading)
                                }.padding(12).contentShape(Rectangle())
                            }.buttonStyle(ChillorButtonStyle())
                        }
                    }.padding(4)
                }.frame(maxHeight:420)
            }
        }.background(.regularMaterial,in:RoundedRectangle(cornerRadius:24)).overlay(RoundedRectangle(cornerRadius:24).stroke(.primary.opacity(0.08),lineWidth:0.5)).shadow(color:.black.opacity(0.1),radius:20,y:8).onAppear {focused = true}
    }
}

struct SettingsView:View {
    @ObservedObject var preferences = Preferences.shared
    @ObservedObject var model = LocalModel.shared
    @State var tab = "General"
    @State private var engineSelection = ModelRouting.selectedProvider == .local ? "local":ModelRouting.remoteModelName
    @State private var keyDraft = ""
    @State private var storedKey:String? = ModelCredentials.masked()
    private var usesRemote:Bool {engineSelection != "local"}
    /// Switching re-checks the newly selected engine so its real state, not the
    /// previous engine's, is what the status line reports.
    private func applyEngine(_ value:String) {
        engineSelection = value
        ModelRouting.select(provider:value == "local" ? .local:.deepseek,
                            remoteModel:value == "local" ? nil:value)
        model.resetReadiness()
        Task {try? await model.prepare()}
    }
    var body:some View {
        TabView(selection:$tab) {
            Form {
                Section("Appearance") {
                    Picker("Appearance",selection:$preferences.appearance) {ForEach(["Light","Dark","System"],id:\.self) {Text($0)}}
                    HStack {Text("Text size"); Slider(value:$preferences.textSize,in:13...20,step:1); Text("\(Int(preferences.textSize)) pt").monospacedDigit().frame(width:42)}
                    Toggle("Reduce motion",isOn:$preferences.reduceMotion)
                }
                Section("Model") {
                    Picker("Engine",selection:Binding(get:{engineSelection},set:applyEngine)) {
                        Text("Local · \(LocalModel.modelName)").tag("local")
                        ForEach(RemoteModelChoice.deepseek) {Text($0.title).tag($0.id)}
                    }
                    if let detail = RemoteModelChoice.deepseek.first(where:{$0.id == engineSelection})?.detail {
                        Text(detail).font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    Text(model.status).font(.system(size:12)).foregroundStyle(.secondary).textSelection(.enabled)
                    if usesRemote {
                        SecureField("DeepSeek API key",text:$keyDraft,prompt:Text(storedKey ?? "sk-…"))
                        HStack {
                            Button("Save key") {
                                if ModelCredentials.write(keyDraft) {
                                    ModelCredentials.invalidate()
                                    keyDraft = "";storedKey = ModelCredentials.masked();applyEngine(engineSelection)
                                }
                            }.disabled(keyDraft.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                            if storedKey != nil {
                                Button("Remove key") {
                                    ModelCredentials.remove();storedKey = nil;applyEngine(engineSelection)
                                }
                            }
                        }
                        if storedKey == nil {
                            Text("Add a key to use DeepSeek. Until then Chillor keeps using the local model.")
                                .font(.system(size:12)).foregroundStyle(.orange)
                        }
                        Text("Each request's text, attached file excerpts and retrieved memory are sent to DeepSeek. Your files, chat history and memory stay stored on this Mac.")
                            .font(.system(size:12)).foregroundStyle(.secondary)
                    } else {
                        Text("Messages and selected files are processed on this Mac. No cloud fallback.").font(.system(size:12)).foregroundStyle(.secondary)
                    }
                    if !model.ready {Button("Retry connection") {Task {try? await model.prepare()}}}
                }
                Section {Text("Changes take effect immediately.").font(.system(size:12)).foregroundStyle(.secondary)}
            }.formStyle(.grouped).tabItem {Label("General",systemImage:"gearshape")}.tag("General")
            VStack(alignment:.leading,spacing:12) {
                Text("Save an instruction. Run it from any app.").foregroundStyle(.secondary)
                ScrollView {
                    VStack(spacing:16) {
                        ForEach($preferences.commands) { $command in
                            VStack(alignment:.leading,spacing:10) {
                                HStack {
                                    TextField("Command name",text:$command.name).font(.headline)
                                    Toggle("Enabled",isOn:$command.enabled).labelsHidden()
                                    Button {preferences.commands.removeAll {$0.id == command.id}} label:{Image(systemName:"trash")}.help("Delete command").accessibilityLabel("Delete \(command.name)")
                                }
                                TextField("Instruction",text:$command.instruction,axis:.vertical).lineLimit(3...6)
                                HStack {
                                    Text("Keyboard shortcut").font(.system(size:12))
                                    Spacer()
                                    Text("⌃⌥")
                                    Picker("Key",selection:$command.key) {ForEach(CommandRunner.keys.keys.sorted(),id:\.self){Text($0)}}.labelsHidden().frame(width:65)
                                }
                                if preferences.commands.filter({$0.enabled && $0.key == command.key}).count > 1 && command.enabled {
                                    Text("This shortcut is already assigned. Choose another key.").font(.system(size:12)).foregroundStyle(.red)
                                }
                            }.padding(14).background(.quaternary,in:RoundedRectangle(cornerRadius:12))
                        }
                    }
                }
                Button {let used = Set(preferences.commands.map(\.key)); let key = CommandRunner.keys.keys.sorted().first(where:{!used.contains($0)}) ?? "A"; preferences.commands.append(QuickCommand(name:"New command",instruction:"Translate the content at my pointer into Chinese.",key:key))} label:{Label("Add command",systemImage:"plus")}
                Text("Results appear in your Chillor conversation. Screen recording access is requested on first use. Tap triggering will be added after its gesture is defined.").font(.system(size:12)).foregroundStyle(.secondary)
            }.padding(20).tabItem {Label("Quick commands",systemImage:"command")}.tag("Commands")
        }.padding(12).frame(width:520,height:530)
    }
}

struct ConversationScrollMetrics:Equatable {
    let contentHeight:CGFloat
    let viewportHeight:CGFloat
    let offset:CGFloat
    var distanceFromBottom:CGFloat {max(0,contentHeight-viewportHeight-offset)}
    var isAtBottom:Bool {distanceFromBottom <= 96}
    func showsReturnButton(previouslyVisible:Bool)->Bool {
        // Different entry/exit thresholds prevent tiny scroll/layout changes
        // from repeatedly resizing the input near the bottom.
        distanceFromBottom > (previouslyVisible ? 96:160)
    }
}

// Scrolling changes the UI only at these thresholds; pixel offsets stay native.
struct ConversationScrollSignals:Equatable {
    let contentHeight:CGFloat
    let viewportHeight:CGFloat
    let band:Int
    let needsBottomCorrection:Bool
    init(metrics:ConversationScrollMetrics) {
        contentHeight = metrics.contentHeight;viewportHeight = metrics.viewportHeight
        needsBottomCorrection = metrics.distanceFromBottom > 1
        band = metrics.distanceFromBottom<=96 ? 0:(metrics.distanceFromBottom<=160 ? 1:2)
    }
    var isAtBottom:Bool {band == 0}
    func showsReturnButton(previouslyVisible:Bool)->Bool {band == 2 || (previouslyVisible && band == 1)}
}
