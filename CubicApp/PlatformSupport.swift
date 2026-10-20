import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Keep platform-specific presentation out of the shared domain and editors.
extension View {
    @ViewBuilder func cubicSelectionPicker() -> some View {
        #if os(iOS)
        pickerStyle(.navigationLink)
        #else
        pickerStyle(.menu)
        #endif
    }

    @ViewBuilder func cubicInlineNavigationTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }

    @ViewBuilder func cubicNumberKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }

    @ViewBuilder func cubicVerbatimInput() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }

    @ViewBuilder func cubicSheetSize() -> some View {
        #if os(macOS)
        frame(minWidth: 560, idealWidth: 640, minHeight: 480, idealHeight: 650)
            .formStyle(.grouped)
        #else
        self
        #endif
    }
}

@MainActor enum CubicSystemSettings {
    static func open() {
        #if os(macOS)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") {
            NSWorkspace.shared.open(url)
        }
        #else
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
        #endif
    }
}
