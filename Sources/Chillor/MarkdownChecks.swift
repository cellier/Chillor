import AppKit
import SwiftUI
import MarkdownUI

@MainActor enum MarkdownChecks {
    static func run() throws {
        // Compare actual glyph dimensions against native SF text, catching a
        // theme overriding the requested font after environment styles apply.
        func inkSize<V:View>(_ view:V) throws -> CGSize {
            let renderer = ImageRenderer(content:view.frame(width:240,height:70).background(Color.white).environment(\.colorScheme,.light))
            renderer.scale = 2
            guard let image = renderer.cgImage else {throw ModelFailure(message:"Font comparison render failed")}
            let bitmap = NSBitmapImageRep(cgImage:image)
            var minX = bitmap.pixelsWide,minY = bitmap.pixelsHigh,maxX = -1,maxY = -1
            for y in 0..<bitmap.pixelsHigh {
                for x in 0..<bitmap.pixelsWide {
                    if let color = bitmap.colorAt(x:x,y:y)?.usingColorSpace(.deviceRGB),color.redComponent<0.4,color.alphaComponent>0.9 {
                        minX = min(minX,x);maxX = max(maxX,x);minY = min(minY,y);maxY = max(maxY,y)
                    }
                }
            }
            try SelfTests.check(maxX >= minX,"Font comparison contains no text")
            return CGSize(width:maxX-minX+1,height:maxY-minY+1)
        }
        for size:Double in [14,18] {
            let native = try inkSize(Text("MMMM Hello 123").font(.system(size:size)))
            let markdown = try inkSize(MarkdownContentView(text:"MMMM Hello 123",fontSize:size))
            try SelfTests.check(abs(native.width-markdown.width)<=2 && abs(native.height-markdown.height)<=2,"Markdown body overrides requested \(size) pt font: \(native) vs \(markdown)")
        }
        print("PASS: Markdown body glyph size matches native SF at 14 pt and 18 pt")
        let measurementHost = MarkdownMessage.Host(rootView:AnyView(EmptyView()))
        measurementHost.sizingOptions = []
        let paragraph = String(repeating:"中文与 English text must wrap correctly. ",count:25)
        measurementHost.configure(text:paragraph,fontSize:14,colorScheme:.light)
        let wide = measurementHost.measure(width:600)
        let narrow = measurementHost.measure(width:280)
        try SelfTests.check(narrow.height>wide.height,"Narrow Markdown failed to reflow")
        try SelfTests.check(measurementHost.measure(width:600) == wide,"Repeated width measurement changed")
        measurementHost.configure(text:paragraph+"\n\n"+paragraph,fontSize:14,colorScheme:.light)
        try SelfTests.check(measurementHost.measure(width:600).height>wide.height,"Streaming text did not invalidate height")
        measurementHost.configure(text:paragraph,fontSize:20,colorScheme:.dark)
        try SelfTests.check(measurementHost.measure(width:600).height>wide.height,"Font change did not invalidate height")
        print("PASS: Native Markdown height tracks width, streaming text and font changes")


        let fixture = """
        ### 1. 主要瓶颈：网络延迟
        正文默认 14 pt，支持 **粗体**、*斜体*、~~删除线~~ 和 `inline code`。

        * **现象**：发送请求后等待回复。
        * **原因**：本地资源占用。
          * 嵌套列表正常缩进。

        1. 第一步：检查状态
        2. 第二步：继续对话

        > 引用内容应当有独立的视觉样式。

        ```swift
        let greeting = "你好，Chillor"
        print(greeting)
        ```

        | 项目 | 状态 |
        | --- | --- |
        | Markdown | 已支持 |
        | 本地渲染 | 已启用 |

        - [x] 已完成
        - [ ] 待处理

        ---

        [链接示例](https://example.com) 与转义符：\\*原样保留\\*。
        """
        let html = MarkdownContent(fixture).renderHTML()
        for tag in ["<h3>","<ul>","<ol>","<blockquote>","<pre>","<table>","<strong>","<em>","<del>","<hr", "type=\"checkbox\""] {
            try SelfTests.check(html.contains(tag),"Markdown structure missing: \(tag)")
        }
        for partial in ["### 未完成标题","**正在生成","```swift\nlet value = 1", "| A | B |\n| --"] {
            try SelfTests.check(!MarkdownContent(partial).renderPlainText().isEmpty,"Partial streaming Markdown lost content")
        }
        let host = NSHostingView(rootView:MarkdownMessage(text:fixture,fontSize:14).padding(24).frame(width:560,alignment:.topLeading).background(Color.white).environment(\.colorScheme,.light))
        host.frame = NSRect(x:0,y:0,width:560,height:1100)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in:host.bounds) else {throw ModelFailure(message:"Cannot capture Markdown layout")}
        host.cacheDisplay(in:host.bounds,to:rep)
        let output = URL(fileURLWithPath:FileManager.default.currentDirectoryPath).appendingPathComponent("work/markdown-render-check.png")
        try rep.representation(using:.png,properties:[:])!.write(to:output)
        print("PASS: Markdown blocks, inline styles, GFM tables/tasks, partial streams; rendered fixture: \(output.path)")
    }
}
