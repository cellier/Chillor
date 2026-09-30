import AppKit
import SwiftUI

// Compile the supplied artwork into a legacy ICNS-compatible macOS silhouette.
// Keep the original square PNG untouched for a future Icon Composer asset.
@MainActor func buildIcon() throws {
    let source = URL(fileURLWithPath:CommandLine.arguments[1])
    let directory = URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    guard let image = NSImage(contentsOf:source) else {fatalError("Missing app icon artwork")}
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    let artwork = Image(nsImage:image)
        .resizable().interpolation(.high)
        .frame(width:824,height:824)
        .clipShape(RoundedRectangle(cornerRadius:185,style:.continuous))
        .shadow(color:.black.opacity(0.18),radius:10,x:0,y:6)
        .frame(width:1024,height:1024)
    let sizes:[(String,Int)] = [
        ("icon_16x16",16),("icon_16x16@2x",32),
        ("icon_32x32",32),("icon_32x32@2x",64),
        ("icon_128x128",128),("icon_128x128@2x",256),
        ("icon_256x256",256),("icon_256x256@2x",512),
        ("icon_512x512",512),("icon_512x512@2x",1024)]
    for (name,pixels) in sizes {
        let renderer = ImageRenderer(content:artwork)
        renderer.scale = Double(pixels)/1024
        renderer.isOpaque = false
        guard let cg = renderer.cgImage else {fatalError("Icon render failed")}
        let bitmap = NSBitmapImageRep(cgImage:cg)
        guard let png = bitmap.representation(using:.png,properties:[:]) else {fatalError("PNG encoding failed")}
        try png.write(to:directory.appendingPathComponent(name+".png"))
    }
}
try MainActor.assumeIsolated { try buildIcon() }
