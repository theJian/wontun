import Foundation

struct Profile: Codable, Identifiable, Hashable, Sendable {
    let id: String
    var name: String
    let `protocol`: String
    let server: String
    let subscriptionId: String?
    let outbound: JSONValue
    let fullConfig: Bool
}
struct Subscription: Codable, Identifiable, Sendable {
    let id: String
    let name: String
    let url: String
    let updatedAt: UInt64
}
struct CoreSettings: Codable, Equatable, Sendable {
    var corePath = ""
    var mixedPort: UInt16 = 2080
    var systemProxy = false
    var routeMode = "rules"
    var bypassPrivate = true
    var directDomains: [String] = []
    var blockedDomains: [String] = []
}
struct AppState: Codable, Sendable {
    var profiles: [Profile] = []
    var subscriptions: [Subscription] = []
    var settings = CoreSettings()
    var selectedId: String?
}
struct CoreLog: Codable, Identifiable, Sendable {
    let id: UInt64
    let message: String
}
struct CoreStatus: Codable, Sendable {
    var running = false
    var activeId: String?
    var uptime: UInt64 = 0
    var logs: [CoreLog] = []
}
struct Snapshot: Decodable, Sendable {
    let state: AppState
    let status: CoreStatus
}
indirect enum JSONValue: Codable, Hashable, Sendable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .object(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v)
        case .null: try c.encodeNil()
        }
    }
    subscript(key: String) -> JSONValue? { if case .object(let v) = self { return v[key] }; return nil }
    var string: String? { if case .string(let v) = self { return v }; return nil }
    var pretty: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? String(data: encoder.encode(self), encoding: .utf8)) ?? "{}"
    }
}
extension JSONEncoder {
    static var core: JSONEncoder { let e = JSONEncoder(); e.keyEncodingStrategy = .convertToSnakeCase; return e }
}
extension JSONDecoder {
    static var core: JSONDecoder { let d = JSONDecoder(); d.keyDecodingStrategy = .convertFromSnakeCase; return d }
}
