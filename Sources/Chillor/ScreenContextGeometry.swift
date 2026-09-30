import Foundation

enum ScreenContextGeometry {
    struct Line {
        let text:String
        let rect:CGRect // Window-local points, origin at top left.
    }
    static func quartzPoint(_ point:CGPoint,primaryHeight:CGFloat)->CGPoint {
        CGPoint(x:point.x,y:primaryHeight-point.y)
    }
    static func rect(_ normalized:CGRect,in size:CGSize)->CGRect {
        CGRect(x:normalized.minX*size.width,y:(1-normalized.maxY)*size.height,width:normalized.width*size.width,height:normalized.height*size.height)
    }
    static func distance(_ point:CGPoint,to rect:CGRect)->CGFloat {
        let dx = max(rect.minX-point.x,0,point.x-rect.maxX)
        let dy = max(rect.minY-point.y,0,point.y-rect.maxY)
        return hypot(dx,dy)
    }
    static func target(in lines:[Line],at point:CGPoint)->Int? {
        let best = lines.indices.min {
            let a = distance(point,to:lines[$0].rect), b = distance(point,to:lines[$1].rect)
            if abs(a-b)>0.1 {return a<b}
            return abs(lines[$0].rect.midY-point.y)<abs(lines[$1].rect.midY-point.y)
        }
        guard let best,distance(point,to:lines[best].rect)<=32 else {return nil}
        return best
    }
    static func paragraph(in lines:[Line],target:Int)->String {
        let anchor = lines[target]
        // Grow only along adjacent, left-aligned lines in the same column.
        // Keep the exact pointer line separately; this is contextual grouping.
        var selected = [target]
        for direction in [-1,1] {
            var last = target
            for _ in 0..<8 {
                let candidates = lines.indices.filter { i in
                    guard !selected.contains(i) else {return false}
                    let a = lines[last].rect,b = lines[i].rect
                    let gap = direction<0 ? a.minY-b.maxY:b.minY-a.maxY
                    return gap >= -2 && gap <= min(12,max(a.height,b.height)*0.65)
                        && abs(b.minX-anchor.rect.minX)<=24
                        && min(b.maxX,anchor.rect.maxX)>max(b.minX,anchor.rect.minX)
                }
                guard let next = candidates.min(by:{abs(lines[$0].rect.midY-lines[last].rect.midY)<abs(lines[$1].rect.midY-lines[last].rect.midY)}) else {break}
                selected.append(next);last = next
            }
        }
        return selected.sorted {lines[$0].rect.minY<lines[$1].rect.minY}.map {lines[$0].text}.joined(separator:"\n")
    }
}
