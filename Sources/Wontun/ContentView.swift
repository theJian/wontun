import SwiftUI
import AppKit

struct ContentView: View {
    @Bindable var model: AppModel
    @State private var editor: Profile?
    @State private var preview: String?
    @State private var pendingDelete: Profile?
    var body: some View {
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(selection: $model.section) {
                ForEach(AppModel.Section.allCases) { section in
                    Label(section.rawValue, systemImage: section.icon).tag(section)
                }
            }
            .listStyle(.sidebar)
            .safeAreaInset(edge: .bottom, spacing: 0) { connectionControls }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
            .navigationSplitViewColumnWidth(min: 210, ideal: 220, max: 250)
            .toolbar(removing: .sidebarToggle)
            .toolbar {
                // Keep the native sidebar toolbar region after removing its only control.
                ToolbarItem(placement: .navigation) {
                    Color.clear.frame(width: 1, height: 1).accessibilityHidden(true)
                }
            }
        } detail: {
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    Text(model.section.rawValue).font(.largeTitle.bold())
                    Spacer()
                    if model.busy { ProgressView().controlSize(.small).padding(.top, 10) }
                    if model.section == .profiles {
                        Button { model.showImport = true } label: { Label("Import", systemImage: "plus") }
                            .buttonStyle(.borderedProminent).disabled(model.busy || model.status.running)
                    }
                }.fixedSize(horizontal: false, vertical: true).padding(28)
                Divider()
                Group {
                    switch model.section {
                    case .profiles: profiles
                    case .subscriptions: SubscriptionsView(model: model)
                    case .routing: RoutingView(model: model)
                    case .logs: LogsView(model: model)
                    case .settings: SettingsView(model: model)
                    }
                }
                .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            }
            .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(nsColor: .controlBackgroundColor))
        }
        .frame(minWidth: 900, maxWidth: .infinity, minHeight: 600, maxHeight: .infinity)
        .sheet(isPresented: $model.showImport, onDismiss: { model.error = nil }) { ImportView(model: model) }
        .sheet(item: $editor, onDismiss: { model.error = nil }) { ProfileEditor(model: model, profile: $0) }
        .sheet(isPresented: Binding(get: { preview != nil }, set: { if !$0 { preview = nil } })) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Generated configuration").font(.title2.bold())
                Text("Contains profile credentials. Review before sharing.").foregroundStyle(.secondary)
                ScrollView { Text(preview ?? "").font(.system(.caption, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack { Spacer(); Button("Done") { preview = nil }.keyboardShortcut(.defaultAction) }
            }.padding(24).frame(width: 720, height: 560)
        }
        .alert("Wontun", isPresented: Binding(get: { model.error != nil && !model.showImport && editor == nil && !model.subscriptionSheetOpen }, set: { if !$0 { model.error = nil } })) {
            Button("OK") { model.error = nil }
        } message: { Text(model.error ?? "") }
        .confirmationDialog("Delete \(pendingDelete?.name ?? "profile")?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })) {
            Button("Delete Profile", role: .destructive) {
                if let profile = pendingDelete { Task { await model.perform("delete_profile", fields: ["id": .string(profile.id)]) } }
                pendingDelete = nil
            }
        } message: { Text("This removes the saved profile and its credentials.") }
    }
    private var connectionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Circle().fill(model.status.running ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(model.status.running ? "Core running" : "Disconnected").font(.callout.weight(.medium))
            }
            if model.status.running {
                Text(model.active?.name ?? "Custom profile").font(.caption).lineLimit(1)
                Text(Duration.seconds(model.status.uptime).formatted(.time(pattern: .hourMinuteSecond))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
            }
            Button(action: model.toggleConnection) {
                HStack { Spacer(); if model.busy { ProgressView().controlSize(.mini) }; Text(model.status.running ? "Disconnect" : "Connect"); Spacer() }
            }.buttonStyle(.borderedProminent)
                .disabled(model.busy || !model.ready || model.selected == nil)
            if !model.ready && !model.busy {
                Button("Retry backend") { Task { await model.perform("snapshot") } }
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .padding(14)
        .fixedSize(horizontal: false, vertical: true)
    }

    var profiles: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search profiles", text: $model.search).textFieldStyle(.plain)
                Spacer()
                Text("\(model.state.profiles.count) profiles").font(.caption).foregroundStyle(.secondary)
            }.padding(14).background(.background).clipShape(RoundedRectangle(cornerRadius: 8)).padding(.horizontal, 28).padding(.vertical, 20)
            if model.state.profiles.isEmpty {
                ContentUnavailableView {
                    Text("No profiles")
                } description: {
                    Text("Import a share link or sing-box JSON, or add a subscription to get started.")
                } actions: {
                    Button("Import Profiles…") { model.showImport = true }.buttonStyle(.borderedProminent)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Table(model.filteredProfiles, selection: Binding(get: { model.state.selectedId }, set: { if let id = $0 { model.select(id) } })) {
                    TableColumn("Profile") { profile in
                        HStack(spacing: 10) {
                            Image(systemName: profile.id == model.status.activeId ? "network.badge.shield.half.filled" : "globe").foregroundStyle(profile.id == model.status.activeId ? .green : .blue)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(profile.name).fontWeight(.medium)
                                Text(profile.server).font(.caption).foregroundStyle(.secondary)
                            }
                        }.padding(.vertical, 6)
                    }.width(min: 180, ideal: 280)
                    TableColumn("Protocol") { Text($0.protocol.uppercased()).font(.system(.caption, design: .monospaced)) }.width(min: 75, ideal: 90)
                    TableColumn("Collection") { profile in Text(model.state.subscriptions.first { $0.id == profile.subscriptionId }?.name ?? "Local").foregroundStyle(.secondary) }
                }.contextMenu(forSelectionType: String.self) { ids in
                    if let id = ids.first, let profile = model.state.profiles.first(where: { $0.id == id }) {
                        Button("Edit Profile…") { editor = profile }.disabled(model.status.running)
                        Button("Delete Profile…", role: .destructive) { pendingDelete = profile }.disabled(model.status.running)
                    }
                } primaryAction: { ids in
                    if let id = ids.first, let profile = model.state.profiles.first(where: { $0.id == id }) { editor = profile }
                }.padding(.horizontal, 20)
            }
            Divider()
            HStack(spacing: 12) {
                if let selected = model.selected {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(selected.name).fontWeight(.medium)
                        Text(selected.fullConfig ? "Full configuration · routing and proxy settings are defined by this profile" : "HTTP / SOCKS5 · 127.0.0.1:\(model.state.settings.mixedPort)").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("Edit…") { editor = selected }.disabled(model.status.running || model.busy)
                    Button("Configuration…") { Task { preview = await model.preview() } }.disabled(model.busy)
                } else { Text("Select a profile to connect").foregroundStyle(.secondary); Spacer() }
            }.padding(24).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct ImportView: View {
    @Bindable var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import profiles").font(.title2.bold())
            Text("Paste share links, a base64 subscription, or sing-box JSON. Multiple links can be separated by newlines.").foregroundStyle(.secondary)
            TextEditor(text: $content).font(.system(.body, design: .monospaced)).border(.separator).frame(minHeight: 250)
            HStack {
                Button("Open File…") {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = false
                    if panel.runModal() == .OK, let url = panel.url {
                        do {
                            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                            guard size < 8 * 1024 * 1024 else { throw CoreFailure(message: "File exceeds the 8 MiB import limit.") }
                            content = try String(contentsOf: url, encoding: .utf8)
                        } catch { model.error = error.localizedDescription }
                    }
                }
                Button("Paste") { content = NSPasteboard.general.string(forType: .string) ?? "" }
                Spacer()
                Button("Cancel") { model.error = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import") {
                    Task { model.error = nil; await model.perform("import", fields: ["content": .string(content)]); if model.error == nil { dismiss() } }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || model.busy)
            }
            if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
        }.padding(24).frame(width: 680)
    }
}

struct ProfileEditor: View {
    @Bindable var model: AppModel
    let profile: Profile
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var content = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit profile").font(.title2.bold())
            TextField("Name", text: $name)
            Text(profile.fullConfig ? "Complete sing-box configuration" : "Sing-box outbound JSON").font(.callout).foregroundStyle(.secondary)
            if profile.subscriptionId != nil { Text("Subscription refreshes may replace your edits.").font(.caption).foregroundStyle(.secondary) }
            TextEditor(text: $content).font(.system(.body, design: .monospaced)).border(.separator)
            if let error = model.error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                Spacer()
                Button("Cancel") { model.error = nil; dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") {
                    Task {
                        model.error = nil
                        await model.perform("save_profile", fields: ["id": .string(profile.id), "name": .string(name), "content": .string(content)])
                        if model.error == nil { dismiss() }
                    }
                }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || model.status.running)
            }
        }.padding(24).frame(width: 680, height: 540)
            .onAppear { name = profile.name; content = profile.outbound.pretty }
    }
}
