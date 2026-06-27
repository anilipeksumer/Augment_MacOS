import SwiftUI

/// SwiftUI entry point for the Augment main application.
///
/// The actual lifecycle work (status item, permissions, window management,
/// Settings) lives inside `AppDelegate`. SwiftUI is used here only to host
/// the `App` type because Swift requires at least one declared `Scene`.
///
/// The body deliberately uses an empty `Settings { ... }` placeholder
/// instead of wiring the real settings UI through SwiftUI: in `LSUIElement`
/// apps the auto-generated `showSettingsWindow:` action is unreliable, so
/// Augment opens its settings window directly from `AppDelegate` via a
/// dedicated `SettingsWindowController`.
@main
struct AugmentApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}
