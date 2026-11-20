import Foundation

// Master audio chain (applies to the whole timeline's sound). Every effect starts neutral; you set the values.
// Order: Gate -> EQ -> Compressor -> Output gain -> Limiter.
public struct EQBand: Codable, Equatable {
    public var type: String = "bell"      // bell | lowshelf | highshelf | highpass | lowpass | notch
    public var freq: Double = 1000        // Hz, 20...20000
    public var gainDb: Double = 0         // -24...+24 (bell/shelves)
    public var q: Double = 0.707          // 0.1...18
    public var enabled: Bool = true
    public init() {}
}
public struct GateParams: Codable, Equatable {
    public var enabled = false
    public var thresholdDb: Double = -80   // below this the gate closes
    public var rangeDb: Double = 0         // how far it turns down when closed (0 = no effect)
    public var attackMs: Double = 1
    public var releaseMs: Double = 100
    public init() {}
}
public struct CompressorParams: Codable, Equatable {
    public var enabled = false
    public var thresholdDb: Double = 0
    public var ratio: Double = 1           // 1 = no compression
    public var attackMs: Double = 10
    public var releaseMs: Double = 100
    public var kneeDb: Double = 0
    public var makeupDb: Double = 0
    public init() {}
}
public struct LimiterParams: Codable, Equatable {
    public var enabled = false
    public var ceilingDb: Double = 0       // sample-peak ceiling (dBFS)
    public var releaseMs: Double = 50
    public var lookaheadMs: Double = 5
    public init() {}
}
public struct AudioChain: Codable, Equatable {
    public var eqEnabled = true
    // five bands at 0 dB (no effect) so there is always something to grab on the graph, like Premiere
    public var eq: [EQBand] = AudioChain.neutralBands
    public static var neutralBands: [EQBand] {
        [("lowshelf", 100.0), ("bell", 400), ("bell", 1000), ("bell", 3000), ("highshelf", 8000)].map { t, f in
            var b = EQBand(); b.type = t; b.freq = f; b.gainDb = 0; b.q = 0.707; return b }
    }
    public var gate = GateParams()
    public var compressor = CompressorParams()
    public var outputGainDb: Double = 0
    public var limiter = LimiterParams()
    public var targetLUFS: Double? = nil    // used by "match loudness"
    public init() {}
}
