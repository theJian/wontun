import Foundation
import Testing
@testable import Wontun

struct CoreIntegrationTests {
    @Test func rustBridgeImportsPersistsAndDecodesSnapshot() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let executable = root.appendingPathComponent("core/target/debug/wontun-core")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path), "Run cargo build --manifest-path core/Cargo.toml first")
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("wontun-swift-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let bridge = CoreBridge(executable: executable, directory: directory)
        let result = try await bridge.request(.object(["command": .string("import"), "content": .string("trojan://secret@example.com:443#Swift%20Bridge")]))
        let snapshot = try JSONDecoder.core.decode(Snapshot.self, from: JSONEncoder().encode(result))
        #expect(snapshot.state.profiles.count == 1)
        #expect(snapshot.state.profiles.first?.name == "Swift Bridge")
        #expect(snapshot.state.profiles.first?.fullConfig == false)
        #expect(snapshot.state.profiles.first?.outbound["password"] == .string("secret"))
        #expect(snapshot.state.selectedId == snapshot.state.profiles.first?.id)
        #expect(!snapshot.status.running)
        do {
            _ = try await bridge.request(.object(["command": .string("import"), "content": .string("invalid://profile")]))
            Issue.record("Invalid imports must fail")
        } catch { #expect(error.localizedDescription.contains("Unsupported share scheme")) }
        let preview = try await bridge.request(.object(["command": .string("preview")]))
        let config = try JSONDecoder().decode(JSONValue.self, from: Data(try #require(preview["config"]?.string).utf8))
        #expect(config["route"]?["final"] == .string("proxy"))
        await bridge.shutdown()
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("state.json").path))
        let reopened = CoreBridge(executable: executable, directory: directory)
        let second = try await reopened.request(.object(["command": .string("snapshot")]))
        let saved = try JSONDecoder.core.decode(Snapshot.self, from: JSONEncoder().encode(second))
        #expect(saved.state.profiles == snapshot.state.profiles)
        await reopened.shutdown()
    }
    @Test func settingsEncodeWithRustFieldNames() throws {
        let settings = CoreSettings()
        let value = try JSONDecoder().decode(JSONValue.self, from: JSONEncoder.core.encode(settings))
        #expect(value["mixed_port"] == .number(2080))
        #expect(value["route_mode"] == .string("rules"))
        #expect(value["system_proxy"] == .bool(false))
        let decoded = try JSONDecoder.core.decode(CoreSettings.self, from: JSONEncoder().encode(value))
        #expect(decoded == settings)
    }
}
