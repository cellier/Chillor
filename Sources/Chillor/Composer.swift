import AppKit
import SwiftUI

struct Composer: NSViewRepresentable {
    @ObservedObject var conversation: Conversation
    @Binding var height: CGFloat
    func makeNSView(context:Context)->ComposerView {
        let view = ComposerView()
        view.editor.unregisterDraggedTypes()
        view.editor.onPasteImages = {conversation.importPastedImages($0)}
        view.onChange = { conversation.draft = $0 }
        view.onHeight = { newHeight in if abs(height-newHeight)>1 { DispatchQueue.main.async { height = newHeight } } }
        view.onSend = { if conversation.activeIDs.isEmpty {conversation.send()} }
        view.onStop = { for id in conversation.activeIDs {conversation.stop(id)} }
        view.onAttach = { context.coordinator.pick(view.window) }
        return view
    }
    func updateNSView(_ view:ComposerView,context:Context) { view.update(text:conversation.draft,enabled:!conversation.importing,generating:!conversation.activeIDs.isEmpty) }
    func makeCoordinator()->Coordinator { Coordinator(conversation) }
    @MainActor class Coordinator {
        let conversation:Conversation
        init(_ conversation:Conversation) { self.conversation = conversation }
        func pick(_ window:NSWindow?) {
            guard let window else { return }
            let panel = NSOpenPanel()
            panel.canChooseDirectories = false; panel.allowsMultipleSelection = true
            panel.prompt = "Add context"
            panel.beginSheetModal(for:window) { [weak self] response in
                guard response == .OK, let self else { return }
                self.conversation.importContextFiles(panel.urls)

            }
        }
    }
}
final class PlaceholderLabel:NSTextField {
    override func hitTest(_ point:NSPoint)->NSView? { nil }
}
final class AddContextButton:HoverFeedbackButton {}
final class PromptTextView:NSTextView {
    var onPasteImages:(NSPasteboard)->Bool = {_ in false}
    override func paste(_ sender:Any?) {
        if onPasteImages(.general) {return}
        super.paste(sender)
    }
    override func validateUserInterfaceItem(_ item:NSValidatedUserInterfaceItem)->Bool {
        if item.action == #selector(paste(_:)),ContextImagePaste.hasImages(.general) {return isEditable}
        return super.validateUserInterfaceItem(item)
    }
    var onSend:()->Void = {}
    var onEditingStateChange:()->Void = {}
    override func setMarkedText(_ string:Any,selectedRange:NSRange,replacementRange:NSRange) {
        super.setMarkedText(string,selectedRange:selectedRange,replacementRange:replacementRange)
        onEditingStateChange()
    }
    override func unmarkText() {
        super.unmarkText()
        onEditingStateChange()
    }
    override func insertText(_ string:Any,replacementRange:NSRange) {
        super.insertText(string,replacementRange:replacementRange)
        onEditingStateChange()
    }
    override func didChangeText() {
        super.didChangeText()
        onEditingStateChange()
    }
    override func keyDown(with event:NSEvent) {
        if event.keyCode == 36, !event.modifierFlags.contains(.shift), !hasMarkedText() { onSend(); return }
        super.keyDown(with:event)
    }
}
@MainActor final class ComposerView:NSView,NSTextViewDelegate {
    let editor = PromptTextView()
    let scroll = NSScrollView()
    let plus = AddContextButton()
    private let sendButton = ComposerActionButton()
    private let stopButton = ComposerActionButton()
    var send:ComposerActionButton {generating ? stopButton:sendButton}
    private var actionEnabled = true
    let placeholder = PlaceholderLabel(labelWithString:"Message Chillor")
    var onChange:(String)->Void = {_ in}
    var onHeight:(CGFloat)->Void = {_ in}
    var onSend:()->Void = {}
    var onStop:()->Void = {}
    var onAttach:()->Void = {}
    var focusObserver:NSObjectProtocol?
    private var applying = false
    private var generating = false
    override init(frame:NSRect) {
        super.init(frame:frame)
        editor.isRichText = false; editor.drawsBackground = false
        editor.font = .systemFont(ofSize:14); editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.textContainerInset = NSSize(width:0,height:0)
        editor.textContainer?.lineFragmentPadding = 0
        editor.isHorizontallyResizable = false; editor.isVerticallyResizable = true
        editor.autoresizingMask = [.width]; editor.textContainer?.widthTracksTextView = true
        editor.delegate = self; editor.onSend = { [weak self] in self?.onSend() }
        editor.onEditingStateChange = { [weak self] in self?.refreshPlaceholder() }
        editor.setAccessibilityLabel("Message Chillor")
        scroll.drawsBackground = false; scroll.hasVerticalScroller = false
        scroll.documentView = editor
        addSubview(scroll)
        placeholder.font = .systemFont(ofSize:16); placeholder.textColor = .placeholderTextColor
        placeholder.isSelectable = false
        addSubview(placeholder)
        plus.image = NSImage(systemSymbolName:"plus",accessibilityDescription:"Add local files")
        plus.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:16,weight:.medium)
        plus.contentTintColor = .black
        plus.imagePosition = .imageOnly
        plus.isBordered = false; plus.target = self; plus.action = #selector(attach)
        plus.toolTip = "Add local files"; plus.setAccessibilityIdentifier("attach-file")
        addSubview(plus)
        for (button,symbol,label,identifier) in [
            (sendButton,"arrow.up","Send message","send-message"),
            (stopButton,"stop.fill","Stop generating","stop-generation")] {
            button.image = NSImage(systemSymbolName:symbol,accessibilityDescription:label)
            button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize:14,weight:.medium)
            button.target = self;button.action = #selector(submit)
            button.toolTip = label;button.setAccessibilityLabel(label)
            button.setAccessibilityIdentifier(identifier)
            addSubview(button)
        }
        focusObserver = NotificationCenter.default.addObserver(forName:.focusComposer,object:nil,queue:.main) { [weak self] _ in guard let self else {return}; self.window?.makeFirstResponder(self.editor) }
    }
    required init?(coder:NSCoder) { fatalError() }
    @objc func attach() { onAttach() }
    @objc func submit() { if generating {onStop()} else {onSend()} }
    func update(text:String,enabled:Bool,generating:Bool = false) {
        let stateChanged = self.generating != generating || actionEnabled != enabled
        let textChanged = !editor.hasMarkedText() && editor.string != text
        self.generating = generating
        if textChanged { applying = true; editor.string = text; applying = false }
        refreshPlaceholder()
        actionEnabled = enabled
        for button in [sendButton,stopButton] {
            button.contentTintColor = .textBackgroundColor
            button.layer?.backgroundColor = NSColor.labelColor.cgColor
        }
        plus.isEnabled = enabled
        if textChanged || stateChanged {needsLayout = true}
    }
    private func refreshPlaceholder() {
        placeholder.isHidden = editor.hasMarkedText() || !editor.string.isEmpty
    }
    func textDidChange(_ notification:Notification) {
        refreshPlaceholder()
        if !applying { onChange(editor.string) }
        needsLayout = true
    }
    override func layout() {
        super.layout()
        let w = bounds.width
        let font = editor.font ?? .systemFont(ofSize:14)
        let compactWidth = max(100,w-92)
        let measured = (editor.string as NSString).boundingRect(with:NSSize(width:compactWidth,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font]).height
        let expanded = measured > 24 || editor.string.contains("\n")
        let textWidth = max(100,w-(expanded ? 40:92))
        let measuredExpanded = (editor.string as NSString).boundingRect(with:NSSize(width:textWidth,height:10000),options:[.usesLineFragmentOrigin,.usesFontLeading],attributes:[.font:font]).height
        let textHeight = expanded ? min(200,max(40,ceil(measuredExpanded)+4)) : 22
        let total:CGFloat = expanded ? textHeight+76 : 56
        onHeight(total)
        let lineHeight = editor.layoutManager?.defaultLineHeight(for:font) ?? 17
        editor.textContainerInset = NSSize(width:0,height:expanded ? 0:max(0,(textHeight-lineHeight)/2))
        scroll.frame = NSRect(x:expanded ? 20:48,y:expanded ? 56:(56-textHeight)/2,width:textWidth,height:textHeight)
        editor.setFrameSize(NSSize(width:textWidth,height:expanded ? max(textHeight,measuredExpanded+8):textHeight))
        editor.textContainer?.containerSize = NSSize(width:textWidth,height:.greatestFiniteMagnitude)
        plus.frame = NSRect(x:12,y:12,width:32,height:32)
        let actionFrame = NSRect(x:w-44,y:12,width:32,height:32)
        sendButton.place(in:actionFrame);stopButton.place(in:actionFrame)
        let animated = window != nil && !Preferences.shared.motionDisabled
        let hasText = !editor.string.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty
        sendButton.show(!generating && hasText,enabled:actionEnabled,animated:animated)
        stopButton.show(generating,enabled:true,animated:animated)
        let placeholderHeight = placeholder.cell?.cellSize.height ?? lineHeight
        placeholder.frame = NSRect(x:48,y:(56-placeholderHeight)/2,width:w-96,height:placeholderHeight)
        refreshPlaceholder()
    }
}
