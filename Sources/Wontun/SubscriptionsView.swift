import SwiftUI

struct SubscriptionsView: View {
    @Bindable var model: AppModel
    @State private var name = ""
    @State private var url = ""
    @State private var deleting: Subscription?
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("\(model.state.subscriptions.count) collections").foregroundStyle(.secondary)
                Spacer()
                Button { model.subscriptionSheetOpen = true } label: { Label("Add Subscription", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).disabled(model.busy || model.status.running)
            }
            if model.state.subscriptions.isEmpty {
                ContentUnavailableView("Always up to date", systemImage: "arrow.triangle.2.circlepath", description: Text("Add an HTTPS subscription URL to import and refresh a collection of profiles."))
            } else {
                List {
                    ForEach(model.state.subscriptions) { sub in
                        HStack(spacing: 14) {
                            Image(systemName: "square.stack.3d.up.fill").foregroundStyle(.blue).font(.title2)
                            VStack(alignment: .leading, spacing: 5) {
                                Text(sub.name).font(.headline)
                                Text("\(model.state.profiles.filter { $0.subscriptionId == sub.id }.count) profiles · \(host(sub.url))").font(.callout).foregroundStyle(.secondary)
                                Text("Updated \(Date(timeIntervalSince1970: Double(sub.updatedAt)).formatted(date: .abbreviated, time: .shortened))").font(.caption).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button("Refresh", systemImage: "arrow.clockwise") { Task { await model.perform("refresh_subscription", fields: ["id": .string(sub.id)]) } }
                            Button("Delete", systemImage: "trash", role: .destructive) { deleting = sub }.labelStyle(.iconOnly)
                        }.padding(.vertical, 12).disabled(model.busy || model.status.running)
                    }
                }.listStyle(.inset)
            }
            Text("Refreshes are manual. A failed download or invalid response preserves your existing profiles.").font(.caption).foregroundStyle(.secondary)
        }.padding(28)
            .sheet(isPresented: $model.subscriptionSheetOpen, onDismiss: { model.error = nil }) {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Add subscription").font(.title2.bold())
                    TextField("Collection name", text: $name)
                    TextField("https://example.com/subscription", text: $url)
                    Text("The subscription URL may contain a private token. It is stored on this Mac and sent only to the subscription provider.").font(.caption).foregroundStyle(.secondary)
                    if let error = model.error { Text(error).foregroundStyle(.red).font(.callout) }
                    HStack {
                        Spacer()
                        Button("Cancel") { model.error = nil; model.subscriptionSheetOpen = false }.disabled(model.busy).keyboardShortcut(.cancelAction)
                        Button("Add & Fetch") {
                            Task {
                                model.error = nil
                                await model.perform("add_subscription", fields: ["name": .string(name), "url": .string(url.trimmingCharacters(in: .whitespacesAndNewlines))])
                                if model.error == nil { model.subscriptionSheetOpen = false; name = ""; url = "" }
                            }
                        }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(model.busy || name.isEmpty || url.isEmpty)
                    }
                }.padding(24).frame(width: 520)
            }
            .confirmationDialog("Delete \(deleting?.name ?? "subscription") and its profiles?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
                Button("Delete Subscription", role: .destructive) {
                    if let sub = deleting { Task { await model.perform("delete_subscription", fields: ["id": .string(sub.id)]) } }
                    deleting = nil
                }
            }
    }
    func host(_ value: String) -> String { URL(string: value)?.host ?? "Subscription" }
}

struct LogsView: View {
    @Bindable var model: AppModel
    @State private var filter = ""
    @State private var follow = true
    @State private var clearedThrough: UInt64 = 0
    var logs: [CoreLog] { model.status.logs.filter { $0.id > clearedThrough && (filter.isEmpty || $0.message.localizedCaseInsensitiveContains(filter)) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                TextField("Filter logs", text: $filter).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                Spacer()
                Toggle("Follow", isOn: $follow).toggleStyle(.checkbox)
                Button("Clear View") { clearedThrough = model.status.logs.last?.id ?? 0 }
            }.padding(20)
            Divider()
            if logs.isEmpty {
                ContentUnavailableView("Nothing to report", systemImage: "text.alignleft", description: Text("Start the core to see its output here."))
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            ForEach(logs) { log in
                                HStack(alignment: .top, spacing: 14) {
                                    Text(String(log.id)).foregroundStyle(.tertiary).frame(width: 38, alignment: .trailing)
                                    Text(log.message).textSelection(.enabled).foregroundStyle(log.message.localizedCaseInsensitiveContains("error") || log.message.localizedCaseInsensitiveContains("fatal") ? Color.red : Color.primary).frame(maxWidth: .infinity, alignment: .leading)
                                }.font(.system(.caption, design: .monospaced)).id(log.id)
                            }
                        }.padding(20)
                    }.onChange(of: model.status.logs.last?.id) { _, id in if follow, let id { proxy.scrollTo(id, anchor: .bottom) } }
                }
            }
            Divider()
            HStack { Text("Last 500 lines · updates every second"); Spacer(); Text(model.status.running ? "LIVE" : "IDLE") }.font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).padding(14)
        }
    }
}
