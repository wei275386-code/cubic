import Foundation

/// Any JSON value. Used for portable settings and for comparing encoded results.
public enum JSONValue: Codable, Sendable, Equatable {
    case object([String: JSONValue]), array([JSONValue]), string(String), number(Double), bool(Bool), null
    public init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode([String: JSONValue].self) { self = .object(v) }
        else { self = .array(try c.decode([JSONValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
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
    var object: [String: JSONValue]? { if case .object(let v) = self { v } else { nil } }
    var string: String? { if case .string(let v) = self { v } else { nil } }
}

/// Canonical JSON: sorted keys and Foundation's default date encoding.
public enum JSONCoding {
    public static func encode<T: Encodable>(_ value: T) throws -> Data {
        let e = JSONEncoder(); e.dateEncodingStrategy = .deferredToDate; e.outputFormatting = [.sortedKeys]
        return try e.encode(value)
    }
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        let d = JSONDecoder(); d.dateDecodingStrategy = .deferredToDate; return try d.decode(type, from: data)
    }
}
