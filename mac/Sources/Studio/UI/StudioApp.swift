import SwiftUI
import AppKit

struct StudioApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @State private var model = AppModel(services: makeServices())

    var body: some SwiftUI.Scene {
        WindowGroup("7XEN Studio") {
            RootView()
                .environment(model)
                .preferredColorScheme(.dark)
                .onAppear { delegate.model = model }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        .commands { StudioCommands(model: model) }
        Settings { SettingsView().environment(model).preferredColorScheme(.dark) }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel?
    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.appearance = NSAppearance(named: .darkAqua)
        NSApp.activate(ignoringOtherApps: true)
        if Stress.uiRequested { Stress.startUIScenario(self) }
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { true }
    func applicationShouldTerminate(_ app: NSApplication) -> NSApplication.TerminateReply {
        guard let m = model else { return .terminateNow }
        Task { @MainActor in await m.shutdown(); app.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}

struct StudioCommands: Commands {
    let model: AppModel
    var body: some Commands {
        CommandMenu("Show") {
            Button("Take") { model.take() }.keyboardShortcut(.return, modifiers: .command)
            Button("Cut to Preview Scene") { model.transition = .cut; model.take() }.keyboardShortcut("t", modifiers: .command)
            Divider()
            ForEach(0..<9, id: \.self) { i in
                Button("Preview Scene \(i + 1)") { model.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
            }
            Divider()
            Button("Toggle Microphone (M)") { model.services.audio?.toggleMicMute() }
                .disabled(model.services.audio == nil)
            Divider()
            Button("New Scene…") { model.newScene() }.keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Add Phone…") { model.showAddPhone = true }.keyboardShortcut("p", modifiers: [.command, .shift])
            Button("Add Stream Key…") { model.showStreamKey = true }
            Divider()
            Button(model.recordOn ? "Disable Recording" : "Enable Recording") { model.recordOn.toggle() }.disabled(model.isLive)
            Button(model.isLive ? "End Show" : "Go Live…") { model.isLive ? model.stopLive() : (model.showGoLiveConfirm = true) }
                .keyboardShortcut("l", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .newItem) {
            Button("New Scene…") { model.newScene() }.keyboardShortcut("n", modifiers: .command)
            Button("Add Phone…") { model.showAddPhone = true }
        }
        CommandGroup(after: .sidebar) {
            Divider()
            ForEach(Array(StudioPage.allCases.enumerated()), id: \.element) { i, p in
                Button(p.rawValue) { NotificationCenter.default.post(name: .studioNavigate, object: p.rawValue) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: [.command, .option])
            }
        }
    }
}

/// Picks the real backend when Core/Engine/Output have landed (RealServices.swift), otherwise the mock.
@MainActor func makeServices() -> StudioServices {
    #if STUDIO_MOCK
    return MockServices()
    #else
    return realServicesIfAvailable() ?? MockServices()
    #endif
}
