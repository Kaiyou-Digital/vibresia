import Foundation

/// Everything Vibresia hears at one moment, as the OSC channel carries it.
///
/// A plain value, so the part of the app that sends it does not depend on the audio code and can be tested on its own.
public struct AnalysisFrame {
    public var bass: Float = 0
    public var mid: Float = 0
    public var treble: Float = 0
    public var level: Float = 0
    public var levelSmooth: Float = 0
    public var bassSmooth: Float = 0
    public var active: Float = 0
    public var presence: Float = 0
    public var scroll: Float = 0
    /// The beat counter locked to the detected tempo, not wrapped: it crosses a whole number on every beat.
    public var beats: Double = 0
    public var beatStrength: Float = 0
    public var bpm: Float = 0
    /// The spectrum, 96 values from 40 Hz to 16 kHz on a log scale.
    public var bands: [Float] = Array(repeating: 0, count: 96)
    /// The genre as Vibresia's `uGenre` numbers it (0 classical ... 9 ambient), and its name.
    public var genre: Int = 0
    public var genreName: String = ""
    /// Confidence 0 to 1 for each instrument, in the order of `instrumentNames`.
    public var instruments: [Float] = []
    public var trackPos: Float = 0
    public var trackDuration: Float = 0
    public var trackProgress: Float = 0
    public var trackKnown: Float = 0
    public var palette: String = ""
    public var vibescape: String = ""

    public init() {}
}

/// Turns frames of analysis into OSC packets, in the layout the receiving side documents (docs/spec/host-values.md in Quartzing, the
/// README here): the state as one bundle, and each beat as an event of its own.
public final class AnalysisBroadcaster {
    private static let prefix = "/vibresia/"

    private let instrumentNames: [String]
    private let namesEvery: Int
    private var frames = 0
    private var lastBeat: Int?

    /// `namesEvery`: UDP has no connection to send the instrument names on once, so they go out with the first frame and then every this many.
    public init(instrumentNames: [String] = ["drums", "bass", "guitar", "keys", "vocals"], namesEvery: Int = 60) {
        self.instrumentNames = instrumentNames
        self.namesEvery = max(namesEvery, 1)
    }

    /// The packets for `frame`, in the order to send them: a beat event first if the beat counter crossed a whole number since the last
    /// frame (so it is not held up behind the state), then the state bundle.
    public func packets(for frame: AnalysisFrame) -> [Data] {
        var packets: [Data] = []
        let beat = Int(frame.beats.rounded(.down))
        if let last = lastBeat, beat > last {
            packets.append(OSCEncoder.message(OSCMessage(Self.prefix + "beat", [.float(frame.beatStrength)])))
        }
        lastBeat = beat
        var state = Self.state(of: frame)
        if frames % namesEvery == 0 { state.append(OSCMessage(Self.prefix + "instrumentNames", instrumentNames.map { .string($0) })) }
        frames += 1
        packets.append(OSCEncoder.bundle(state))
        return packets
    }

    private static func state(of frame: AnalysisFrame) -> [OSCMessage] {
        func number(_ name: String, _ value: Float) -> OSCMessage { OSCMessage(prefix + name, [.float(value)]) }
        return [
            number("bass", frame.bass), number("mid", frame.mid), number("treble", frame.treble), number("level", frame.level),
            number("levelSmooth", frame.levelSmooth), number("bassSmooth", frame.bassSmooth),
            number("active", frame.active), number("presence", frame.presence),
            number("beats", Float(frame.beats.truncatingRemainder(dividingBy: 1024))), // as the uBeats uniform wraps
            number("bpm", frame.bpm), number("scroll", frame.scroll),
            OSCMessage(prefix + "bands", frame.bands.map { .float($0) }),
            OSCMessage(prefix + "genre", [.int(Int32(clamping: frame.genre))]),
            OSCMessage(prefix + "genreName", [.string(frame.genreName)]),
            OSCMessage(prefix + "instruments", frame.instruments.map { .float($0) }),
            number("trackPos", frame.trackPos), number("trackDuration", frame.trackDuration),
            number("trackProgress", frame.trackProgress), number("trackKnown", frame.trackKnown),
            OSCMessage(prefix + "palette", [.string(frame.palette)]),
            OSCMessage(prefix + "vibescape", [.string(frame.vibescape)]),
        ]
    }
}
