import Foundation
import Testing
@testable import VibresiaOSC

/// OSC 1.0 encoding, checked against the byte layouts in the specification (https://opensoundcontrol.stanford.edu/spec-1_0.html).
struct OSCEncoderTests {
    private func bytes(_ values: UInt8...) -> Data { Data(values) }
    private func text(_ string: String) -> Data { Data(string.utf8) }

    @Test func aFloatMessageIsEncodedAsTheSpecificationShowsIt() {
        // "/oscillator/4/frequency" with the float 440.0: the address and type tags are NUL-terminated and padded to a whole number of
        // 4-byte words, and the float is its IEEE 754 bits, big-endian (440.0 is 0x43DC0000).
        var expected = Data()
        expected.append(text("/oscillator/4/frequency")) // 23 characters
        expected.append(bytes(0)) // and the terminator: 24 bytes, a whole number of words
        expected.append(text(",f"))
        expected.append(bytes(0, 0))
        expected.append(bytes(0x43, 0xDC, 0x00, 0x00))
        #expect(OSCEncoder.message(OSCMessage("/oscillator/4/frequency", [.float(440)])) == expected)
    }

    @Test func aStringWhoseLengthFillsAWordGetsAWholeWordOfZeros() {
        // "abcd" is 4 characters: its terminator needs a whole extra word
        var expected = Data()
        expected.append(text("/s"))
        expected.append(bytes(0, 0))
        expected.append(text(",s"))
        expected.append(bytes(0, 0))
        expected.append(text("abcd"))
        expected.append(bytes(0, 0, 0, 0))
        #expect(OSCEncoder.message(OSCMessage("/s", [.string("abcd")])) == expected)
    }

    @Test func anIntIsFourBytesBigEndian() {
        var expected = Data()
        expected.append(text("/i"))
        expected.append(bytes(0, 0))
        expected.append(text(",i"))
        expected.append(bytes(0, 0))
        expected.append(bytes(0, 0, 0x01, 0x02))
        #expect(OSCEncoder.message(OSCMessage("/i", [.int(258)])) == expected)
        #expect(OSCEncoder.message(OSCMessage("/i", [.int(-1)])).suffix(4) == bytes(0xFF, 0xFF, 0xFF, 0xFF))
    }

    @Test func aMessageWithNoArgumentsStillHasItsTypeTagString() {
        var expected = Data()
        expected.append(text("/ping"))
        expected.append(bytes(0, 0, 0))
        expected.append(text(","))
        expected.append(bytes(0, 0, 0)) // "," alone, padded
        #expect(OSCEncoder.message(OSCMessage("/ping", [])) == expected)
    }

    @Test func manyArgumentsGetOneTypeTagEachInOrder() {
        var expected = Data()
        expected.append(text("/m"))
        expected.append(bytes(0, 0))
        expected.append(text(",fisf"))
        expected.append(bytes(0, 0, 0))
        expected.append(bytes(0x3F, 0x80, 0, 0)) // 1.0
        expected.append(bytes(0, 0, 0, 2))
        expected.append(text("x"))
        expected.append(bytes(0, 0, 0))
        expected.append(bytes(0x40, 0x40, 0, 0)) // 3.0
        #expect(OSCEncoder.message(OSCMessage("/m", [.float(1), .int(2), .string("x"), .float(3)])) == expected)
    }

    @Test func aBundleIsTheBundleWordATimeTagAndSizedElements() {
        let first = OSCMessage("/a", [.float(1)])
        let second = OSCMessage("/b", [.int(5)])
        let one = OSCEncoder.message(first)
        let two = OSCEncoder.message(second)
        func size(_ data: Data) -> Data {
            var big = Int32(data.count).bigEndian
            return Data(bytes: &big, count: 4)
        }
        var expected = Data()
        expected.append(text("#bundle"))
        expected.append(bytes(0)) // "#bundle" and its terminator: 8 bytes
        expected.append(bytes(0, 0, 0, 0, 0, 0, 0, 1)) // the time tag meaning "immediately"
        expected.append(size(one))
        expected.append(one)
        expected.append(size(two))
        expected.append(two)
        #expect(OSCEncoder.bundle([first, second]) == expected)
    }

    @Test func ninetySixFloatsEncodeToTheExpectedLength() {
        // address "/vibresia/bands" is 15 characters + NUL = 16; the tags "," + 96 f + NUL are 98 bytes, padded to 100; then 96 x 4 bytes
        let encoded = OSCEncoder.message(OSCMessage("/vibresia/bands", Array(repeating: .float(0.5), count: 96)))
        #expect(encoded.count == 16 + 100 + 96 * 4)
    }
}
