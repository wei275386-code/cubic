import SwiftUI

/// Present failures from the modal that owns the draft. A root-level alert can
/// dismiss the active sheet in iOS, losing unsaved input even when storage rejects it.
struct ModalMessages: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()

    func body(content: Content) -> some View {
        content
            .cubicSheetSize()
            .onAppear {
                model.enterModalMessageHost(id)
            }
            .onDisappear {
                model.leaveModalMessageHost(id)
            }
            .alert(model.errorMessage == nil ? "Cubic" : model.errorTitle, isPresented: Binding(
                get: { model.isCurrentModalMessageHost(id) && (model.errorMessage != nil || model.statusMessage != nil) },
                set: { if !$0 && model.isCurrentModalMessageHost(id) { model.errorMessage = nil; model.statusMessage = nil } }
            )) {
                Button("知道了") { model.errorMessage = nil; model.statusMessage = nil }
            } message: {
                Text(model.errorMessage ?? model.statusMessage ?? "")
            }
    }
}

/// Navigation destinations have separate lifetimes from the root and its sheets.
/// A message from an earlier visit must never be presented on a new page.
private struct MessagePageContext: ViewModifier {
    @Environment(AppModel.self) private var model
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content
            .onAppear { model.enterMessagePage(id) }
            .onDisappear { model.leaveMessagePage(id) }
    }
}

extension View {
    func cubicNavigationTitle(_ title: String) -> some View {
        navigationTitle(title).modifier(MessagePageContext())
    }
}
