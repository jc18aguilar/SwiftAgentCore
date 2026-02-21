import Foundation

public typealias JSONObject = [String: JSONValue]

public enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object(JSONObject)
    case array([JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSONValue].self) {
            self = .array(value)
        } else if let value = try? container.decode(JSONObject.self) {
            self = .object(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unsupported JSON value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value):
            try container.encode(value)
        case .number(let value):
            try container.encode(value)
        case .bool(let value):
            try container.encode(value)
        case .object(let value):
            try container.encode(value)
        case .array(let value):
            try container.encode(value)
        case .null:
            try container.encodeNil()
        }
    }

    public var anyValue: Any {
        switch self {
        case .string(let value):
            return value
        case .number(let value):
            return value
        case .bool(let value):
            return value
        case .object(let value):
            return value.mapValues(\.anyValue)
        case .array(let value):
            return value.map(\.anyValue)
        case .null:
            return NSNull()
        }
    }

    public static func from(any value: Any) -> JSONValue {
        switch value {
        case let string as String:
            return .string(string)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            return .number(number.doubleValue)
        case let object as [String: Any]:
            return .object(object.mapValues(Self.from(any:)))
        case let array as [Any]:
            return .array(array.map(Self.from(any:)))
        default:
            return .null
        }
    }

    public var stringValue: String? {
        guard case .string(let value) = self else { return nil }
        return value
    }

    public var objectValue: JSONObject? {
        guard case .object(let value) = self else { return nil }
        return value
    }

    public var boolValue: Bool? {
        guard case .bool(let value) = self else { return nil }
        return value
    }

    public var doubleValue: Double? {
        guard case .number(let value) = self else { return nil }
        return value
    }
}

public enum LLMProviderType: String, Codable, Sendable {
    case openAICompatible
    case claude
    case gemini
}

public enum LLMMessageRole: String, Codable, Sendable {
    case system
    case user
    case assistant
    case tool
}

public struct LLMModelInfo: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var contextWindow: Int?

    public init(id: String, name: String, contextWindow: Int? = nil) {
        self.id = id
        self.name = name
        self.contextWindow = contextWindow
    }
}

public struct ToolDefinition: Codable, Sendable, Equatable {
    public var name: String
    public var description: String
    public var inputSchema: JSONObject

    public init(name: String, description: String, inputSchema: JSONObject) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
    }
}

public enum ContentBlock: Codable, Sendable, Equatable {
    case text(String)
    case toolUse(id: String, name: String, input: JSONObject)
    case toolResult(toolUseId: String, content: String, isError: Bool)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case id
        case name
        case input
        case toolUseId
        case content
        case isError
    }

    private enum Kind: String, Codable {
        case text
        case toolUse
        case toolResult
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .type)
        switch kind {
        case .text:
            self = .text(try container.decode(String.self, forKey: .text))
        case .toolUse:
            self = .toolUse(
                id: try container.decode(String.self, forKey: .id),
                name: try container.decode(String.self, forKey: .name),
                input: try container.decode(JSONObject.self, forKey: .input)
            )
        case .toolResult:
            self = .toolResult(
                toolUseId: try container.decode(String.self, forKey: .toolUseId),
                content: try container.decode(String.self, forKey: .content),
                isError: try container.decode(Bool.self, forKey: .isError)
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode(Kind.text, forKey: .type)
            try container.encode(text, forKey: .text)
        case .toolUse(let id, let name, let input):
            try container.encode(Kind.toolUse, forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            try container.encode(input, forKey: .input)
        case .toolResult(let toolUseId, let content, let isError):
            try container.encode(Kind.toolResult, forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
            try container.encode(isError, forKey: .isError)
        }
    }
}

public enum LLMStopReason: String, Codable, Sendable {
    case endTurn
    case toolUse
}

public struct LLMUsage: Codable, Sendable, Equatable {
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var totalTokens: Int?

    public init(inputTokens: Int? = nil, outputTokens: Int? = nil, totalTokens: Int? = nil) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.totalTokens = totalTokens
    }
}

public struct LLMResponse: Codable, Sendable, Equatable {
    public var contentBlocks: [ContentBlock]
    public var stopReason: LLMStopReason
    public var usage: LLMUsage?

    public init(contentBlocks: [ContentBlock], stopReason: LLMStopReason, usage: LLMUsage? = nil) {
        self.contentBlocks = contentBlocks
        self.stopReason = stopReason
        self.usage = usage
    }
}

public struct LLMProviderConfig: Codable, Sendable, Equatable {
    public var baseURL: URL
    public var authMethod: LLMAuthMethod
    public var model: String
    public var headers: [String: String]

    public init(
        baseURL: URL,
        authMethod: LLMAuthMethod,
        model: String,
        headers: [String: String] = [:]
    ) {
        self.baseURL = baseURL
        self.authMethod = authMethod
        self.model = model
        self.headers = headers
    }
}

public extension LLMMessage {
    static func text(role: LLMMessageRole, _ value: String) -> LLMMessage {
        LLMMessage(role: role, contentBlocks: [.text(value)])
    }
}

public struct LLMMessage: Codable, Sendable, Equatable {
    public var role: LLMMessageRole
    public var contentBlocks: [ContentBlock]

    public init(role: LLMMessageRole, contentBlocks: [ContentBlock]) {
        self.role = role
        self.contentBlocks = contentBlocks
    }

    public var textContent: String {
        contentBlocks.compactMap {
            if case .text(let text) = $0 {
                return text
            }
            return nil
        }
        .joined()
    }
}
