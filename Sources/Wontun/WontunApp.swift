import AppKit
import SwiftUI

@main struct WontunApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model = AppModel()
    var body: some Scene {
        WindowGroup("Wontun") {
            ContentView(model: model)
                .task { delegate.model = model; await model.start() }
        }
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1120, height: 740)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Import Profiles…") { model.showImport = true }.keyboardShortcut("i")
                Button(model.status.running ? "Disconnect" : "Connect") { model.toggleConnection() }
                    .keyboardShortcut("k").disabled(model.busy || !model.ready || model.selected == nil)
            }
        }
        Settings { SettingsView(model: model).frame(width: 620, height: 540) }
        MenuBarExtra {
            Text(model.status.running ? "Running · \(model.active?.name ?? "Profile")" : "Disconnected")
            Button(model.status.running ? "Disconnect" : "Connect") { model.toggleConnection() }
                .disabled(model.busy || !model.ready || model.selected == nil)
            Divider()
            Button("Show Wontun") { NSApp.activate(ignoringOtherApps: true); NSApp.windows.first { $0.canBecomeMain }?.makeKeyAndOrderFront(nil) }
            Button("Quit Wontun") { NSApp.terminate(nil) }.keyboardShortcut("q")
        } label: {
            Image(nsImage: TrayIcon.image)
                .opacity(model.status.running ? 1 : 0.55)
                .accessibilityLabel("Wontun · \(model.status.running ? "Running" : "Disconnected")")
        }
    }
}
@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    private var terminating = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: url) {
            NSApp.applicationIconImage = icon
        }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { await model?.shutdown(); sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
