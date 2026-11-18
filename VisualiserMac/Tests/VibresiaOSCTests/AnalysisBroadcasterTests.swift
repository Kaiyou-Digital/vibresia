import Foundation
import Testing
@testable import VibresiaOSC

/// What the broadcaster sends for a frame of analysis, read back with a decoder written here (not the encoder's own code).
struct AnalysisBroadcasterTests {
    // MARK: a small independent OSC reader

    struct Decoded: Equatable {
        let address: String
        let arguments: [Argument]
    }

    enum Argument: Equatable {
        case float(Float)
        case int(Int32)
        case string(String)
    }

    /// The messages in a packet: one message, or the elements of a bundle (the bundle word and time tag are 16 bytes, then sized elements).
    private func decode(_ packet: Data) -> [Decoded] {
        let bytes = [UInt8](packet)
        guard bytes.starts(with: Array("#bundle".utf8)) else { return [decodeMessage(bytes)] }
        var offset = 16
        var found: [Decoded] = []
        while offset < bytes.count {
            let size = bytes[offset ..< offset + 4].reduce(0) { $0 << 8 | Int($1) }
            offset += 4
            found.append(decodeMessage(Array(bytes[offset ..< offset + size])))
            offset += size
        }
        return found
    }

    private func decodeMessage(_ bytes: [UInt8]) -> Decoded {
        var offset = 0
        func word() -> UInt32 {
            defer { offset += 4 }
            return bytes[offset ..< offset + 4].reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
        }
        func string() -> String {
            let end = bytes[offset...].firstIndex(of: 0)!
            defer { offset = (end + 4) & ~3 }
            return String(decoding: bytes[offset ..< end], as: UTF8.self)
        }
        let address = string()
        let tags = string().dropFirst()
        var arguments: [Argument] = []
        for tag in tags {
            switch tag {
            case "f": arguments.append(.float(Float(bitPattern: word())))
            case "i": arguments.append(.int(Int32(bitPattern: word())))
            default: arguments.append(.string(string()))
            }
        }
        return Decoded(address: address, arguments: arguments)
    }

    private func frame(beats: Double = 0) -> AnalysisFrame {
        var frame = AnalysisFrame()
        frame.bass = 0.5
        frame.mid = 0.25
        frame.treble = 0.125
        frame.level = 0.75
        frame.bands = (0 ..< 96).map { Float($0) / 96 }
        frame.genre = 2
        frame.genreName = "rock"
        frame.instruments = [0.9, 0.1, 0.8, 0.0, 0.4]
        frame.bpm = 128
        frame.beats = beats
        frame.beatStrength = 0.6
        frame.palette = "NEON"
        frame.vibescape = "ribbons"
        return frame
    }

    /// The state bundle among a frame's packets (the one that is a bundle).
    private func stateMessages(_ packets: [Data]) -> [Decoded] {
        packets.filter { $0.starts(with: Array("#bundle".utf8)) }.flatMap(decode)
    }

    // MARK: tests

    @Test func theStateIsOneBundleSoAReceiverAppliesItTogether() {
        let packets = AnalysisBroadcaster().packets(for: frame())
        #expect(packets.filter { $0.starts(with: Array("#bundle".utf8)) }.count == 1)
    }

    @Test func everyStateValueIsSentUnderItsOwnAddress() {
        let sent = Dictionary(uniqueKeysWithValues: stateMessages(AnalysisBroadcaster().packets(for: frame())).map { ($0.address, $0.arguments) })
        #expect(sent["/vibresia/bass"] == [.float(0.5)])
        #expect(sent["/vibresia/mid"] == [.float(0.25)])
        #expect(sent["/vibresia/treble"] == [.float(0.125)])
        #expect(sent["/vibresia/level"] == [.float(0.75)])
        #expect(sent["/vibresia/bpm"] == [.float(128)])
        #expect(sent["/vibresia/genre"] == [.int(2)])
        #expect(sent["/vibresia/genreName"] == [.string("rock")])
        #expect(sent["/vibresia/palette"] == [.string("NEON")])
        #expect(sent["/vibresia/vibescape"] == [.string("ribbons")])
        #expect(sent["/vibresia/instruments"] == [0.9, 0.1, 0.8, 0.0, 0.4].map { Argument.float($0) })
        for name in ["levelSmooth", "bassSmooth", "active", "presence", "beats", "scroll", "trackPos", "trackDuration", "trackProgress", "trackKnown"] {
            #expect(sent["/vibresia/\(name)"]?.count == 1, "\(name) is sent")
        }
    }

    @Test func theSpectrumIsNinetySixFloatsInOrder() {
        let sent = stateMessages(AnalysisBroadcaster().packets(for: frame())).first { $0.address == "/vibresia/bands" }
        #expect(sent?.arguments.count == 96)
        #expect(sent?.arguments.first == .float(0))
        #expect(sent?.arguments.last == .float(95.0 / 96))
    }

    @Test func theBeatCounterIsSentWrappedLikeTheUniform() {
        let sent = stateMessages(AnalysisBroadcaster().packets(for: frame(beats: 1024 + 3.5))).first { $0.address == "/vibresia/beats" }
        #expect(sent?.arguments == [.float(3.5)], "uBeats wraps at 1024")
    }

    @Test func aBeatIsAnEventSentTheMomentTheCounterCrossesAWholeNumber() {
        let broadcaster = AnalysisBroadcaster()
        let first = broadcaster.packets(for: frame(beats: 4.2))
        #expect(first.allSatisfy { $0.starts(with: Array("#bundle".utf8)) }, "no event on the first frame: there is no earlier one to cross from")
        let same = broadcaster.packets(for: frame(beats: 4.9))
        #expect(same.allSatisfy { $0.starts(with: Array("#bundle".utf8)) }, "still inside beat 4: no event")
        let crossed = broadcaster.packets(for: frame(beats: 5.05))
        let events = crossed.filter { !$0.starts(with: Array("#bundle".utf8)) }.flatMap(decode)
        #expect(events == [Decoded(address: "/vibresia/beat", arguments: [.float(0.6)])], "one event carrying the strength")
    }

    @Test func theEventComesBeforeTheStateAndIsNotInsideIt() {
        let broadcaster = AnalysisBroadcaster()
        _ = broadcaster.packets(for: frame(beats: 1.9))
        let packets = broadcaster.packets(for: frame(beats: 2.1))
        #expect(packets.count == 2)
        #expect(!packets[0].starts(with: Array("#bundle".utf8)), "the event first, so it is not held up behind the bundle")
        #expect(!stateMessages(packets).contains { $0.address == "/vibresia/beat" }, "and the bundle does not repeat it")
    }

    @Test func aCounterThatGoesBackOrStandsStillMakesNoEvent() {
        let broadcaster = AnalysisBroadcaster()
        _ = broadcaster.packets(for: frame(beats: 10.5))
        #expect(broadcaster.packets(for: frame(beats: 10.5)).count == 1, "standing still")
        #expect(broadcaster.packets(for: frame(beats: 2.5)).count == 1, "a restart sets the counter back: no event")
        #expect(broadcaster.packets(for: frame(beats: 3.2)).count == 2, "and the next real crossing is a beat again")
    }

    @Test func severalBeatsInOneStepAreOneEvent() {
        let broadcaster = AnalysisBroadcaster()
        _ = broadcaster.packets(for: frame(beats: 1.5))
        #expect(broadcaster.packets(for: frame(beats: 4.5)).count == 2, "a stall that spans three beats still sends one beat")
    }

    @Test func theInstrumentNamesGoOutAtFirstAndThenNowAndAgain() {
        let broadcaster = AnalysisBroadcaster(namesEvery: 3)
        func hasNames(_ packets: [Data]) -> Bool {
            stateMessages(packets).contains { $0.address == "/vibresia/instrumentNames" }
        }
        #expect(hasNames(broadcaster.packets(for: frame())), "the first frame, so a receiver that starts first hears them")
        #expect(!hasNames(broadcaster.packets(for: frame())))
        #expect(!hasNames(broadcaster.packets(for: frame())))
        #expect(hasNames(broadcaster.packets(for: frame())), "every third frame, because UDP has no connection to send them on")
        let names = stateMessages(AnalysisBroadcaster().packets(for: frame())).first { $0.address == "/vibresia/instrumentNames" }
        #expect(names?.arguments == ["drums", "bass", "guitar", "keys", "vocals"].map { Argument.string($0) })
    }
}
