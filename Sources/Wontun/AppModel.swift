import AppKit
import SwiftUI

@MainActor @Observable final class AppModel {
    var state = AppState()
    var status = CoreStatus()
    var error: String?
    var busy = false
    var ready = false
    var showImport = false
    var section: Section = .profiles
    var search = ""
    private let bridge = CoreBridge()
    private var polling: Task<Void, Never>?
    private var quitting = false
    private var refreshing = false
    var subscriptionSheetOpen = false
    enum Section: String, CaseIterable, Identifiable {
        case profiles = "Profiles", subscriptions = "Subscriptions", routing = "Routing", logs = "Logs", settings = "Settings"
        var id: Self { self }
        var icon: String {
            switch self {
            case .profiles: "square.stack.3d.up"
            case .subscriptions: "arrow.triangle.2.circlepath"
            case .routing: "point.3.connected.trianglepath.dotted"
            case .logs: "text.alignleft"
            case .settings: "gearshape"
            }
        }
    }
    var selected: Profile? { state.profiles.first { $0.id == state.selectedId } }
    var active: Profile? { state.profiles.first { $0.id == status.activeId } }
    var filteredProfiles: [Profile] {
        state.profiles.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.server.localizedCaseInsensitiveContains(search) || $0.protocol.localizedCaseInsensitiveContains(search) }
    }
    func start() async {
        guard polling == nil else { return }
        await perform("snapshot")
        polling = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !self.quitting else { return }
                if !self.busy && self.ready { await self.refresh() }
            }
        }
    }
    private func refresh() async {
        guard !busy, !refreshing, !quitting else { return }
        refreshing = true
        defer { refreshing = false }
        do {
            let result = try await bridge.request(.object(["command": .string("snapshot")]))
            // An action queued during polling owns the next visible state.
            guard !busy, !quitting else { return }
            let snapshot = try JSONDecoder.core.decode(Snapshot.self, from: JSONEncoder().encode(result))
            state = snapshot.state; status = snapshot.status
        } catch {
            guard !quitting else { return }
            self.error = "Lost contact with the backend: \(error.localizedDescription)"
            ready = false; status.running = false
        }
    }
    func perform(_ command: String, fields: [String: JSONValue] = [:]) async {
        guard !quitting else { return }
        guard !busy else { error = "Another operation is in progress. Please try again."; return }
        busy = true
        defer { busy = false }
        var payload = fields
        payload["command"] = .string(command)
        do {
            let result = try await bridge.request(.object(payload))
            let snapshot = try JSONDecoder.core.decode(Snapshot.self, from: JSONEncoder().encode(result))
            state = snapshot.state; status = snapshot.status; ready = true
        } catch {
            self.error = error.localizedDescription
        }
    }
    func select(_ id: String) { Task { await perform("select", fields: ["id": .string(id)]) } }
    func toggleConnection() { Task { await perform(status.running ? "stop" : "start") } }
    func saveSettings(_ settings: CoreSettings) async {
        do {
            let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder.core.encode(settings))
            await perform("settings", fields: ["settings": value])
        } catch { self.error = error.localizedDescription }
    }
    func preview() async -> String? {
        guard !busy else { return nil }
        busy = true
        defer { busy = false }
        do { return try await bridge.request(.object(["command": .string("preview")]))["config"]?.string }
        catch { self.error = error.localizedDescription; return nil }
    }
    func shutdown() async {
        quitting = true
        polling?.cancel()
        await bridge.shutdown()
    }
}
