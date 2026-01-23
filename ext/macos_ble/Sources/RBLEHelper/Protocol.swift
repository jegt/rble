import Foundation

// MARK: - Standard JSON-RPC Error Codes
enum ErrorCode {
    static let parseError = -32700      // Invalid JSON
    static let invalidRequest = -32600  // Invalid request object
    static let methodNotFound = -32601  // Method not found
    static let invalidParams = -32602   // Invalid method parameters
    static let internalError = -32603   // Internal error
}

// MARK: - Request (Ruby -> Swift)
struct Request: Codable {
    let id: Int
    let method: String
    let params: [String: AnyCodable]?
}

// MARK: - Response (Swift -> Ruby)
struct Response: Codable {
    let id: Int
    let result: [String: AnyCodable]?
    let error: ResponseError?

    init(id: Int, result: [String: AnyCodable]? = nil, error: ResponseError? = nil) {
        self.id = id
        self.result = result
        self.error = error
    }

    static func success(id: Int, result: [String: AnyCodable]) -> Response {
        Response(id: id, result: result, error: nil)
    }

    static func error(id: Int, code: Int, message: String, data: [String: String]? = nil) -> Response {
        Response(id: id, result: nil, error: ResponseError(code: code, message: message, data: data))
    }
}

// MARK: - Response Error
struct ResponseError: Codable {
    let code: Int
    let message: String
    let data: [String: String]?

    init(code: Int, message: String, data: [String: String]? = nil) {
        self.code = code
        self.message = message
        self.data = data
    }
}

// MARK: - Event (Swift -> Ruby, asynchronous notifications)
struct Event: Codable {
    let method: String
    let params: [String: AnyCodable]

    init(method: String, params: [String: AnyCodable]) {
        self.method = method
        self.params = params
    }
}

// MARK: - AnyCodable Type-Erased Wrapper
/// A type-erased Codable wrapper that handles common JSON types:
/// String, Int, Double, Bool, Array, Dictionary, and null
struct AnyCodable: Codable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "AnyCodable cannot decode value"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        if value is NSNull {
            try container.encodeNil()
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if let int = value as? Int {
            try container.encode(int)
        } else if let double = value as? Double {
            try container.encode(double)
        } else if let string = value as? String {
            try container.encode(string)
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else {
            throw EncodingError.invalidValue(
                value,
                EncodingError.Context(
                    codingPath: encoder.codingPath,
                    debugDescription: "AnyCodable cannot encode value of type \(type(of: value))"
                )
            )
        }
    }
}

// MARK: - AnyCodable Convenience Extensions
extension AnyCodable: ExpressibleByStringLiteral {
    init(stringLiteral value: String) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) {
        self.value = value
    }
}

extension AnyCodable: ExpressibleByArrayLiteral {
    init(arrayLiteral elements: Any...) {
        self.value = elements
    }
}

extension AnyCodable: ExpressibleByDictionaryLiteral {
    init(dictionaryLiteral elements: (String, Any)...) {
        var dict: [String: Any] = [:]
        for (key, value) in elements {
            dict[key] = value
        }
        self.value = dict
    }
}

extension AnyCodable: ExpressibleByNilLiteral {
    init(nilLiteral: ()) {
        self.value = NSNull()
    }
}
