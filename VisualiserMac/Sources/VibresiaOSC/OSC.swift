import Foundation

/// One argument of an OSC message.
public enum OSCArgument: Equatable {
    case float(Float)
    case int(Int32)
    case string(String)

    fileprivate var typeTag: Character {
        switch self {
        case .float: "f"
        case .int: "i"
        case .string: "s"
        }
    }
}

/// An OSC message: an address such as `/vibresia/bass` and its arguments.
public struct OSCMessage: Equatable {
    public let address: String
    public let arguments: [OSCArgument]

    public init(_ address: String, _ arguments: [OSCArgument]) {
        self.address = address
        self.arguments = arguments
    }
}

/// Writes OSC 1.0 packets (https://opensoundcontrol.stanford.edu/spec-1_0.html): strings are NUL-terminated and padded to a whole number of
/// 4-byte words, numbers are big-endian.
public enum OSCEncoder {
    public static func message(_ message: OSCMessage) -> Data {
        var data = string(message.address)
        data.append(string("," + String(message.arguments.map(\.typeTag))))
        for argument in message.arguments {
            switch argument {
            case let .float(value): data.append(word(value.bitPattern))
            case let .int(value): data.append(word(UInt32(bitPattern: value)))
            case let .string(value): data.append(string(value))
            }
        }
        return data
    }

    /// The messages as one bundle with the time tag meaning "immediately", so a receiver applies them together.
    public static func bundle(_ messages: [OSCMessage]) -> Data {
        var data = string("#bundle")
        data.append(Data([0, 0, 0, 0, 0, 0, 0, 1]))
        for message in messages {
            let element = Self.message(message)
            data.append(word(UInt32(element.count)))
            data.append(element)
        }
        return data
    }

    private static func word(_ value: UInt32) -> Data {
        Data([UInt8(truncatingIfNeeded: value >> 24), UInt8(truncatingIfNeeded: value >> 16), UInt8(truncatingIfNeeded: value >> 8), UInt8(truncatingIfNeeded: value)])
    }

    /// The text, a terminator, and zeros to a whole number of words (a text whose length fills a word gets a whole word of zeros).
    private static func string(_ text: String) -> Data {
        var data = Data(text.utf8)
        data.append(0)
        while data.count % 4 != 0 { data.append(0) }
        return data
    }
}
