import SwiftUI

// A narrow soft highlight travels through the glyphs, like the reference's
// activity label. The label itself never moves or changes its layout width.
struct GenerationStatus:View {
    let text:String
    let reduceMotion:Bool
    @State private var sweeping = false
    private var label:some View {
        Text(text).font(.system(size:12,weight:.regular))
    }
    var body:some View {
        label.foregroundStyle(.secondary)
            .overlay {
                if !reduceMotion {
                    GeometryReader { geometry in
                        LinearGradient(colors:[.clear,Color(nsColor:.textBackgroundColor).opacity(0.75),.clear],startPoint:.leading,endPoint:.trailing)
                            .frame(width:geometry.size.width*0.7)
                            .offset(x:sweeping ? geometry.size.width*1.3 : -geometry.size.width*0.7)
                            .animation(.linear(duration:2.2).repeatForever(autoreverses:false),value:sweeping)
                    }
                    .mask(label)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
            }
            .onAppear {sweeping = !reduceMotion}
            .onChange(of:reduceMotion) {_,value in sweeping = !value}
            .onDisappear {sweeping = false}
    }
}
