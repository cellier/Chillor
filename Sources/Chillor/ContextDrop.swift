import AppKit
import UniformTypeIdentifiers

enum ContextImagePaste {
    static func providers(_ pasteboard:NSPasteboard)->[NSItemProvider] {
        (pasteboard.pasteboardItems ?? []).compactMap { item in
            // Finder may advertise both a URL and a thumbnail. Use the original once.
            if let value = item.string(forType:.fileURL),let url = URL(string:value),url.isFileURL,
               UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true {
                return NSItemProvider(item:url as NSURL,typeIdentifier:UTType.fileURL.identifier)
            }
            guard let type = item.types.first(where:{UTType($0.rawValue)?.conforms(to:.image) == true}),
                  let data = item.data(forType:type) else {return nil}
            let provider = NSItemProvider()
            provider.suggestedName = "Pasted image"
            provider.registerDataRepresentation(forTypeIdentifier:type.rawValue,visibility:.all) {completion in
                completion(data,nil);return nil
            }
            return provider
        }
    }
    static func hasImages(_ pasteboard:NSPasteboard)->Bool {
        (pasteboard.pasteboardItems ?? []).contains {item in
            if item.types.contains(where:{UTType($0.rawValue)?.conforms(to:.image) == true}) {return true}
            guard let value = item.string(forType:.fileURL),let url = URL(string:value) else {return false}
            return url.isFileURL && UTType(filenameExtension:url.pathExtension)?.conforms(to:.image) == true
        }
    }
}

@MainActor extension Conversation {
    func importPastedImages(_ pasteboard:NSPasteboard)->Bool {
        let providers = ContextImagePaste.providers(pasteboard)
        guard !providers.isEmpty else {return false}
        _ = importDroppedImages(providers)
        return true
    }
    func importContextFiles(_ urls:[URL]) {
        guard beginContextImport(count:urls.count) else {return}
        Task { @MainActor in
            defer {finishContextImport()}
            var failures:[String] = []
            for url in urls {
                do {attachments.append(try FileContext.read(url))}
                catch {failures.append(error.localizedDescription)}
                await Task.yield()
            }
            if !failures.isEmpty {attachmentError = failures.joined(separator:"\n")}
        }
    }
    func importDroppedImages(_ providers:[NSItemProvider])->Bool {
        guard beginContextImport(count:providers.count) else {return false}
        Task { @MainActor in
            defer {finishContextImport()}
            var failures:[String] = []
            for provider in providers {
                do {
                    if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                        let data = try await dropData(provider,type:UTType.fileURL.identifier)
                        guard let url = URL(dataRepresentation:data,relativeTo:nil),url.isFileURL,
                              let type = UTType(filenameExtension:url.pathExtension),type.conforms(to:.image) else {
                            throw ModelFailure(message:"Drop image files here. Use + to add other documents.")
                        }
                        let access = url.startAccessingSecurityScopedResource()
                        defer {if access {url.stopAccessingSecurityScopedResource()}}
                        attachments.append(try FileContext.read(url))
                    } else {
                        guard let type = provider.registeredTypeIdentifiers.first(where:{UTType($0)?.conforms(to:.image) == true}) else {
                            throw ModelFailure(message:"This item is not an image.")
                        }
                        let data = try await dropData(provider,type:type)
                        guard data.count <= 20_000_000,let bitmap = NSBitmapImageRep(data:data),
                              let png = bitmap.representation(using:.png,properties:[:]),png.count <= 20_000_000 else {
                            throw ModelFailure(message:"The image is invalid or exceeds 20 MB.")
                        }
                        attachments.append(Attachment(name:provider.suggestedName ?? "Dropped image",text:"User-provided image context.",imageData:png))
                    }
                } catch {failures.append(error.localizedDescription)}
            }
            if !failures.isEmpty {attachmentError = failures.joined(separator:"\n")}
        }
        return true
    }
    private func beginContextImport(count:Int)->Bool {
        guard !importing else {return false}
        guard count > 0,attachments.count+count <= 4 else {
            attachmentError = "Attach up to 4 files per message.";return false
        }
        importing = true;attachmentError = nil;return true
    }
    private func finishContextImport() {
        importing = false
        NotificationCenter.default.post(name:.focusComposer,object:nil)
    }
    private func dropData(_ provider:NSItemProvider,type:String) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let request = DropDataRequest(continuation)
            provider.loadDataRepresentation(forTypeIdentifier:type) { data,error in
                if let data {request.finish(.success(data))}
                else {request.finish(.failure(error ?? ModelFailure(message:"Could not read the dropped image.")))}
            }
            DispatchQueue.global().asyncAfter(deadline:.now()+30) {
                request.finish(.failure(ModelFailure(message:"Image import timed out. Please drag it again.")))
            }
        }
    }
}

private final class DropDataRequest: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation:CheckedContinuation<Data,Error>?
    init(_ continuation:CheckedContinuation<Data,Error>) {self.continuation = continuation}
    func finish(_ result:Result<Data,Error>) {
        lock.lock();let pending = continuation;continuation = nil;lock.unlock()
        pending?.resume(with:result)
    }
}
