import SwiftUI
import UniformTypeIdentifiers

/// Lazy vertical section that highlights itself while its delegate accepts the
/// drag. LazyVStack is load-bearing: a plain VStack instantiates every row
/// together with its native mouse monitors.
struct SidebarDropArea<Delegate: DropDelegate, Content: View>: View {
    let types: [UTType]
    let delegate: (Binding<Bool>) -> Delegate
    let content: (Bool) -> Content
    @State private var targeted = false

    init(of types: [UTType],
         delegate: @escaping (Binding<Bool>) -> Delegate,
         @ViewBuilder content: @escaping (Bool) -> Content) {
        self.types = types; self.delegate = delegate; self.content = content
    }

    var body: some View {
        LazyVStack(alignment: .leading, spacing: 0) { content(targeted) }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(targeted ? Color.accentColor.opacity(0.16) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .animation(.easeInOut(duration: 0.15), value: targeted)
            .onDrop(of: types, delegate: delegate($targeted))
    }
}
