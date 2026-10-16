import AppKit
import SwiftUI

struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var settings = CoreSettings()
    @State private var port = "2080"
    @State private var saved = false
    var body: some View {
        Form {
            SwiftUI.Section("Proxy core") {
                LabeledContent("Included core", value: "sing-box 1.14.3")
                Text("Ready to connect. Wontun includes its proxy core and validates every configuration before starting.").font(.caption).foregroundStyle(.secondary)
                DisclosureGroup("Advanced core override") {
                    HStack {
                        TextField("Custom executable (optional)", text: $settings.corePath)
                        Button("Choose…") {
                            let panel = NSOpenPanel(); panel.canChooseDirectories = false
                            if panel.runModal() == .OK, let url = panel.url { settings.corePath = url.path }
                        }
                    }
                    Button("Use Included Core") { settings.corePath = "" }.disabled(settings.corePath.isEmpty)
                    Text("Leave this empty to use the core included in Wontun.").font(.caption).foregroundStyle(.secondary)
                }
            }
            SwiftUI.Section("Local listener") {
                TextField("HTTP / SOCKS5 port", text: $port)
                LabeledContent("Listen address", value: "127.0.0.1")
                Toggle("Set macOS system proxy while connected", isOn: $settings.systemProxy)
                Text("System proxy changes are handled by sing-box and may need macOS authorization. A normal disconnect restores them. This is a local proxy, not a system TUN VPN.").font(.caption).foregroundStyle(.secondary)
            }
            SwiftUI.Section {
                HStack {
                    Text(model.status.running ? "Disconnect to change settings." : "Changes apply on the next connection.").foregroundStyle(.secondary)
                    Spacer()
                    if saved { Label("Saved", systemImage: "checkmark").foregroundStyle(.green) }
                    Button("Save Settings") {
                        guard let value = UInt16(port), value > 0 else { model.error = "Port must be between 1 and 65535."; return }
                        settings.mixedPort = value
                        Task {
                            model.error = nil
                            await model.saveSettings(settings)
                            saved = model.error == nil
                        }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || model.status.running || !model.ready)
                }
            }
            SwiftUI.Section("Wontun 0.1") {
                Text("Profiles and subscription credentials are stored locally in Application Support/Wontun with owner-only file permissions.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).onAppear { settings = model.state.settings; port = String(settings.mixedPort) }
            .onChange(of: settings) { _, _ in saved = false }
            .onChange(of: port) { _, _ in saved = false }
    }
}

struct RoutingView: View {
    @Bindable var model: AppModel
    @State private var settings = CoreSettings()
    @State private var direct = ""
    @State private var blocked = ""
    @State private var saved = false
    var body: some View {
        Form {
            SwiftUI.Section("Routing policy") {
                Picker("Mode", selection: $settings.routeMode) {
                    Text("Rules").tag("rules")
                    Text("Global proxy").tag("global")
                    Text("Direct").tag("direct")
                }.pickerStyle(.segmented)
                Text("Rules mode blocks matching domains, bypasses private addresses and direct domains, then sends remaining traffic through the selected proxy.").font(.caption).foregroundStyle(.secondary)
                Toggle("Bypass private IP addresses", isOn: $settings.bypassPrivate).disabled(settings.routeMode != "rules")
            }
            SwiftUI.Section("Direct domain suffixes") {
                TextEditor(text: $direct).font(.system(.body, design: .monospaced)).frame(height: 100)
                Text("One suffix per line, for example example.com. Matches the domain and its subdomains.").font(.caption).foregroundStyle(.secondary)
            }.disabled(settings.routeMode != "rules")
            SwiftUI.Section("Blocked domain suffixes") {
                TextEditor(text: $blocked).font(.system(.body, design: .monospaced)).frame(height: 100)
            }.disabled(settings.routeMode != "rules")
            SwiftUI.Section {
                HStack {
                    Text("Complete config profiles use their own routing.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if saved { Text("Saved").foregroundStyle(.green) }
                    Button("Save Routing") {
                        settings.directDomains = domains(direct); settings.blockedDomains = domains(blocked)
                        Task { model.error = nil; await model.saveSettings(settings); saved = model.error == nil }
                    }.buttonStyle(.borderedProminent).disabled(model.busy || model.status.running || !model.ready)
                }
            }
        }.formStyle(.grouped).disabled(model.status.running)
            .onAppear { settings = model.state.settings; direct = settings.directDomains.joined(separator: "\n"); blocked = settings.blockedDomains.joined(separator: "\n") }
            .onChange(of: settings) { _, _ in saved = false }
            .onChange(of: direct) { _, _ in saved = false }
            .onChange(of: blocked) { _, _ in saved = false }
    }
    func domains(_ text: String) -> [String] {
        Array(Set(text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty })).sorted()
    }
}
