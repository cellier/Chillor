import SwiftUI
import MarkdownUI
import AppKit

struct MarkdownContentView:View,Equatable {
    let text:String
    var fontSize:Double
    var body:some View {
        let _ = UIRenderingChecks.markdownRendered()
        Markdown(MarkdownContentCache.content(text))
            .markdownTheme(Theme.chillor.text {
                FontSize(fontSize)
                ForegroundColor(.primary)
                BackgroundColor(nil)
            })
            .markdownImageProvider(MessageImageProvider())
            .markdownInlineImageProvider(MessageInlineImageProvider())
            .textSelection(.enabled)
            .frame(maxWidth:.infinity,alignment:.leading)
    }
}

private extension Theme {
    static let chillor = Theme.gitHub
        .heading1 { c in
            c.label.markdownTextStyle { FontSize(.em(1.6));FontWeight(.semibold) }
                .markdownMargin(top:18,bottom:10)
        }
        .heading2 { c in
            c.label.markdownTextStyle { FontSize(.em(1.35));FontWeight(.semibold) }
                .markdownMargin(top:18,bottom:10)
        }
        .heading3 { c in
            c.label.markdownTextStyle { FontSize(.em(1.15));FontWeight(.semibold) }
                .markdownMargin(top:16,bottom:8)
        }
        .paragraph { c in
            c.label.fixedSize(horizontal:false,vertical:true)
                .relativeLineSpacing(.em(0.3)).markdownMargin(top:0,bottom:10)
        }
        .codeBlock { c in
            ScrollView(.horizontal) {
                c.label.markdownTextStyle { FontFamilyVariant(.monospaced);FontSize(.em(0.93)) }
                    .fixedSize(horizontal:true,vertical:true).padding(12)
            }
            .background(Color.primary.opacity(0.045),in:RoundedRectangle(cornerRadius:10))
            .markdownMargin(top:4,bottom:12)
        }
}

// Local chat should not fetch model-supplied image URLs automatically.
private struct MessageImageProvider:ImageProvider {
    func makeImage(url:URL?)->some View {
        if let url,url.isFileURL,let image = NSImage(contentsOf:url) {
            Image(nsImage:image).resizable().scaledToFit()
        } else if let url,["https","http"].contains(url.scheme?.lowercased() ?? "") {
            Link(destination:url) {Label("Image",systemImage:"photo")}
        } else {
            Label("Image",systemImage:"photo").foregroundStyle(.secondary)
        }
    }
}
private struct MessageInlineImageProvider:InlineImageProvider {
    func image(with url:URL,label:String) async throws -> Image {
        if url.isFileURL,let image = NSImage(contentsOf:url) {return Image(nsImage:image)}
        return Image(systemName:"photo")
    }
}

// A bounded cache also reuses parsed content when a lazy row re-enters the viewport.
private enum MarkdownContentCache {
    final class Entry:NSObject {let content:MarkdownContent;init(_ text:String) {content = MarkdownContent(text)}}
    static let cache:NSCache<NSString,Entry> = {
        let cache = NSCache<NSString,Entry>();cache.countLimit = 256;cache.totalCostLimit = 16*1024*1024;return cache
    }()
    static func content(_ text:String)->MarkdownContent {
        if let entry = cache.object(forKey:text as NSString) {return entry.content}
        let entry = Entry(text);cache.setObject(entry,forKey:text as NSString,cost:text.utf8.count*8)
        return entry.content
    }
}

@MainActor enum MessageImageCache {
    final class Entry:NSObject {
        let data:Data
        let image:NSImage
        init(data:Data,image:NSImage) {self.data = data;self.image = image}
    }
    static let cache:NSCache<NSUUID,Entry> = {
        let cache = NSCache<NSUUID,Entry>();cache.countLimit = 48;cache.totalCostLimit = 64*1024*1024;return cache
    }()
    static func image(id:UUID,data:Data)->NSImage? {
        if let entry = cache.object(forKey:id as NSUUID),entry.data == data {return entry.image}
        guard let image = NSImage(data:data) else {return nil}
        let cost = max(data.count,image.representations.reduce(0) {sum,rep in sum+max(0,rep.pixelsWide)*max(0,rep.pixelsHigh)*4})
        cache.setObject(Entry(data:data,image:image),forKey:id as NSUUID,cost:cost)
        return image
    }
}

/// A separate native hosting graph keeps rich text updates local to this message.
/// Rendering, selection and link handling still use the existing Markdown view.
struct MarkdownMessage:NSViewControllerRepresentable,Equatable {
    let text:String
    var fontSize:Double
    @Environment(\.colorScheme) private var colorScheme
    static func ==(lhs:Self,rhs:Self)->Bool {lhs.text == rhs.text && lhs.fontSize == rhs.fontSize && lhs.colorScheme == rhs.colorScheme}
    final class Host:NSHostingController<AnyView> {
        var renderedText = ""
        var renderedSize:Double = 0
        var renderedScheme:ColorScheme?
        var measurements:[CGFloat:CGSize] = [:]
        func configure(text:String,fontSize:Double,colorScheme:ColorScheme) {
            guard renderedText != text || renderedSize != fontSize || renderedScheme != colorScheme else {return}
            renderedText = text;renderedSize = fontSize;renderedScheme = colorScheme
            measurements.removeAll()
            rootView = AnyView(MarkdownContentView(text:text,fontSize:fontSize).environment(\.colorScheme,colorScheme))
        }
        func measure(width:CGFloat)->CGSize {
            if let size = measurements[width] {return size}
            let measured = sizeThatFits(in:CGSize(width:width,height:CGFloat.greatestFiniteMagnitude))
            let size = CGSize(width:width,height:ceil(measured.height))
            if measurements.count>=8 {measurements.removeAll()}
            measurements[width] = size
            return size
        }
    }
    func makeNSViewController(context:Context)->Host {
        let host = Host(rootView:AnyView(EmptyView()))
        host.sizingOptions = []
        updateNSViewController(host,context:context)
        return host
    }
    func updateNSViewController(_ host:Host,context:Context) {
        host.configure(text:text,fontSize:fontSize,colorScheme:colorScheme)
    }
    func sizeThatFits(_ proposal:ProposedViewSize,nsViewController host:Host,context:Context)->CGSize? {
        guard let width = proposal.width,width.isFinite,width>0 else {return nil}
        return host.measure(width:width)
    }
}
