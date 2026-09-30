import SwiftUI
import AppKit
import Quartz

struct ArtifactPreview: View {
    let artifact: PreviewItem
    let onClose: () -> Void
    let onError: (String) -> Void
    @State private var markdown: String?
    @State private var previewImage: NSImage?
    @State private var error: String?
    @State private var loaded = false
    private var file: URL { URL(fileURLWithPath:artifact.path) }
    private var isMarkdown: Bool { ["md","markdown"].contains(file.pathExtension.lowercased()) }

    var body: some View {
        VStack(spacing:0) {
            Group {
                if let error {
                    VStack(spacing:12) {
                        Image(systemName:"doc.questionmark").font(.system(size:28))
                        Text(error).font(.system(size:13)).multilineTextAlignment(.center)
                    }.padding(24).frame(maxWidth:.infinity,maxHeight:.infinity)
                } else if !loaded {
                    ProgressView().frame(maxWidth:.infinity,maxHeight:.infinity)
                } else if let previewImage {
                    Image(nsImage:previewImage).resizable().scaledToFit()
                        .padding(.horizontal,16).padding(.top,68).padding(.bottom,16)
                        .frame(maxWidth:.infinity,maxHeight:.infinity)
                        .contentShape(Rectangle())
                        .contextMenu {
                            Button {ImageClipboard.copy(previewImage)} label: {Label("Copy image",systemImage:"square.on.square")}
                        }
                        .accessibilityLabel(artifact.name)
                } else if let markdown {
                    ScrollView {
                        MarkdownMessage(text:markdown,fontSize:14).padding(.horizontal,24).padding(.top,68).padding(.bottom,24)
                    }.scrollIndicators(.hidden)
                } else {
                    NativeFilePreview(file:file).id(file)
                }
            }.frame(maxWidth:.infinity,maxHeight:.infinity)
        }
        .background(Color(nsColor:.textBackgroundColor))
        .overlay(alignment:.top) {
            LinearGradient(colors:[Color(nsColor:.textBackgroundColor),Color(nsColor:.textBackgroundColor).opacity(0)],startPoint:.top,endPoint:.bottom)
                .frame(height:68).allowsHitTesting(false).accessibilityHidden(true)
            previewHeader
        }
        .task(id:artifact.id) {
            loaded = false;markdown = nil;previewImage = nil;error = nil
            if let data = artifact.imageData {
                previewImage = NSImage(data:data)
                if previewImage == nil {error = "This image could not be decoded."}
                loaded = true
                return
            }
            let url = file, renderMarkdown = isMarkdown
            let result = await Task.detached(priority:.userInitiated) { () -> Result<String?,Error> in
                Result {
                    let values = try url.resourceValues(forKeys:[.isRegularFileKey,.fileSizeKey])
                    guard values.isRegularFile == true else { throw ModelFailure(message:"This file is no longer available.") }
                    guard renderMarkdown else { return nil }
                    guard (values.fileSize ?? 0) <= 1_000_000 else {
                        throw ModelFailure(message:"This Markdown file is too large for inline preview. Open it in a local app.")
                    }
                    return try String(contentsOf:url,encoding:.utf8)
                }
            }.value
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let text): markdown = text
            case .failure(let failure): error = failure.localizedDescription
            }
            loaded = true
        }
    }
    private var previewHeader: some View {
        GeometryReader { geometry in
            HStack(spacing:12) {
                HStack(spacing:0) {
                    Image(systemName:artifact.imageData == nil ? "document":"photo").frame(width:32,height:32)
                    Text(artifact.name).lineLimit(1).truncationMode(.middle)
                }
                .font(.system(size:14,weight:.medium))
                .padding(.leading,8).padding(.trailing,16).frame(height:36)
                .modifier(ChillorGlass(radius:18)).help(artifact.name)
                .accessibilityLabel(artifact.name)
                Spacer(minLength:0)
                HStack(spacing:12) {
                    Button {LocalPreview.shared.open(artifact,onError:onError)} label: {
                        HStack(spacing:0) {
                            Image(systemName:"arrow.up.forward.square").frame(width:32,height:32)
                            if geometry.size.width >= 360 {Text("Open")}
                        }
                        .padding(.leading,geometry.size.width >= 360 ? 8:2)
                        .padding(.trailing,geometry.size.width >= 360 ? 16:2)
                        .frame(height:36).contentShape(Capsule())
                    }
                    .buttonStyle(ChillorButtonStyle()).modifier(ChillorGlass(radius:18))
                    .help("Open in local app").accessibilityLabel("Open in local app")
                    .disabled(artifact.imageData == nil && !FileManager.default.fileExists(atPath:file.path))
                    Button(action:onClose) {
                        Image(systemName:"xmark").frame(width:36,height:36).contentShape(Circle())
                    }
                    .buttonStyle(ChillorButtonStyle()).modifier(ChillorGlass(radius:18))
                    .help("Close preview").accessibilityLabel("Close preview")
                }.fixedSize()
            }
            .font(.system(size:14,weight:.medium))
            .padding(.leading,16).padding(.trailing,24).padding(.vertical,16)
        }.frame(height:68)
    }
}

// System Quick Look renders supported Office, PDF, image and text formats
// inside the panel. It does not launch the file's default application.
private struct NativeFilePreview: NSViewRepresentable {
    let file: URL
    func makeNSView(context:Context) -> QLPreviewView {
        let view = ScrollerlessPreviewView(frame:.zero,style:.normal)!
        // SwiftUI owns this view's lifetime. Do not also close it from the
        // window notification: that can deactivate Quick Look twice.
        view.shouldCloseWithWindow = false
        view.autostarts = false
        view.previewItem = file as NSURL
        return view
    }
    func updateNSView(_ view:QLPreviewView,context:Context) {
        if (view.previewItem as? NSURL) != file as NSURL { view.previewItem = file as NSURL }
    }
    static func dismantleNSView(_ view:QLPreviewView,coordinator:()) {
        view.close()
    }
}

// Quick Look creates native scroll views lazily. Update only local scroll-view
// chrome during layout, preserving wheel/trackpad scrolling and document size.
private final class ScrollerlessPreviewView: QLPreviewView {
    override func layout() {
        super.layout()
        hideScrollers(in:self)
    }
    private func hideScrollers(in view:NSView) {
        if let scroll = view as? NSScrollView {
            if scroll.hasVerticalScroller {scroll.hasVerticalScroller = false}
            if scroll.hasHorizontalScroller {scroll.hasHorizontalScroller = false}
        }
        for child in view.subviews {hideScrollers(in:child)}
    }
}
