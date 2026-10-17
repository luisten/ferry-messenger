import Foundation

/// Arbitrary JSON, for event content whose shape depends on the event type (and for passing bridge payloads such as
/// `com.beeper.unresolved_media` back verbatim in M5). Numbers are Doubles: Matrix timestamps stay below 2^53.
nonisolated enum JSON: Codable, Hashable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: JSON].self)) }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    subscript(key: String) -> JSON? {
        if case .object(let object) = self { object[key] } else { nil }
    }

    var string: String? { if case .string(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var int64: Int64? { number.map { Int64($0) } }
    var array: [JSON]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSON]? { if case .object(let value) = self { value } else { nil } }
}

/// Literals keep event content readable where the app builds it (sends, reactions, edits) and in tests.
extension JSON: ExpressibleByStringLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
    ExpressibleByArrayLiteral, ExpressibleByDictionaryLiteral {
    nonisolated init(stringLiteral value: String) { self = .string(value) }
    nonisolated init(integerLiteral value: Int) { self = .number(Double(value)) }
    nonisolated init(booleanLiteral value: Bool) { self = .bool(value) }
    nonisolated init(arrayLiteral elements: JSON...) { self = .array(elements) }
    nonisolated init(dictionaryLiteral elements: (String, JSON)...) { self = .object(Dictionary(uniqueKeysWithValues: elements)) }
}
