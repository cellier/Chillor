import AppKit
import SwiftUI

/// Keeps the visible message at the same viewport coordinate while a preview
/// reflows the transcript. Native coordinates avoid LazyVStack height estimates.
@MainActor final class ConversationReadingPosition:ObservableObject {
    private let rows = NSHashTable<ConversationRowPosition.Marker>.weakObjects()
    private var anchor:(id:UUID,top:CGFloat)?
    private var observers:[NSObjectProtocol] = []
    private var restorationScheduled = false
    var isPreserving:Bool {anchor != nil}

    func register(_ row:ConversationRowPosition.Marker) {rows.add(row)}

    func capture(preferredID:UUID? = nil) {
        if preferredID != nil {release()}
        guard anchor == nil else {return}
        let candidates = rows.allObjects.compactMap { row -> (ConversationRowPosition.Marker,NSScrollView,CGRect)? in
            guard let scroll = row.enclosingScrollView,let document = scroll.documentView,row.window != nil else {return nil}
            let rect = row.convert(row.bounds,to:document)
            guard rect.maxY>scroll.contentView.bounds.minY,rect.minY<scroll.contentView.bounds.maxY else {return nil}
            return (row,scroll,rect)
        }
        guard let (row,scroll,rect) = candidates.first(where:{$0.0.messageID == preferredID}) ?? candidates.min(by:{$0.2.minY<$1.2.minY}) else {return}
        anchor = (row.messageID,rect.minY-scroll.contentView.bounds.minY)
        // Bounds changes cover both clamping during resize and lazy stack
        // corrections. User input releases these observers before scrolling.
        scroll.contentView.postsBoundsChangedNotifications = true
        scroll.documentView?.postsFrameChangedNotifications = true
        for (name,object) in [(NSView.boundsDidChangeNotification,scroll.contentView as NSView),
                              (NSView.frameDidChangeNotification,scroll.documentView!)] {
            observers.append(NotificationCenter.default.addObserver(forName:name,object:object,queue:.main) { [weak self] _ in
                MainActor.assumeIsolated {self?.restoreAfterLayout()}
            })
        }
        restoreAfterLayout()
    }

    func release() {
        anchor = nil
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    func restoreAfterLayout() {
        guard anchor != nil,!restorationScheduled else {return}
        restorationScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else {return}
            self.restorationScheduled = false
            self.restore()
        }
    }

    private func restore() {
        guard let anchor,let row = rows.allObjects.first(where:{$0.messageID == anchor.id && $0.window != nil}),
              let scroll = row.enclosingScrollView,let document = scroll.documentView else {return}
        let rect = row.convert(row.bounds,to:document)
        let clip = scroll.contentView
        let desired = min(max(0,rect.minY-anchor.top),max(0,document.bounds.height-clip.bounds.height))
        guard abs(desired-clip.bounds.minY)>0.5 else {return}
        clip.scroll(to:NSPoint(x:clip.bounds.minX,y:desired))
        scroll.reflectScrolledClipView(clip)
    }

    deinit {observers.forEach(NotificationCenter.default.removeObserver)}
}

struct ConversationRowPosition:NSViewRepresentable {
    let messageID:UUID
    let readingPosition:ConversationReadingPosition
    final class Marker:NSView {
        var messageID = UUID()
        weak var readingPosition:ConversationReadingPosition?
        override func hitTest(_ point:NSPoint)->NSView? {nil}
        override func setFrameOrigin(_ origin:NSPoint) {super.setFrameOrigin(origin);readingPosition?.restoreAfterLayout()}
        override func setFrameSize(_ size:NSSize) {super.setFrameSize(size);readingPosition?.restoreAfterLayout()}
        override func viewDidMoveToWindow() {super.viewDidMoveToWindow();readingPosition?.restoreAfterLayout()}
    }
    func makeNSView(context:Context)->Marker {
        let view = Marker()
        view.messageID = messageID;view.readingPosition = readingPosition
        readingPosition.register(view)
        return view
    }
    func updateNSView(_ view:Marker,context:Context) {view.messageID = messageID}
}
