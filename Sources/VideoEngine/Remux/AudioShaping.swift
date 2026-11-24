import Foundation

/// Changes to the sound of re-encoded audio (v2.2.0+), set on `AudioPolicy.shaping`.
///
/// Shaping runs between the decoder and the encoder, so it applies only when the audio is re-encoded.
/// Setting any of it forces a re-encode of a stream that would otherwise be copied.
public struct AudioShaping: Sendable, Equatable {
    /// The largest delay either way, in seconds.
    public static let maxDelay: TimeInterval = 2
    /// The largest dialogue lift, in decibels.
    public static let maxDialogueLift: Double = 12

    /// Seconds the sound moves later (positive) or earlier (negative), to line it up with the picture;
    /// limited to `maxDelay` either way and kept to whole milliseconds.
    public var delay: TimeInterval
    /// Decibels added to the speech: the centre channel of 5.1, or the part of a stereo mix that both
    /// sides share. From 0 (off) to `maxDialogueLift`.
    public var dialogueLift: Double
    /// Compresses the loudest passages toward the quiet ones, so a late-night viewer hears speech and not
    /// the explosion that follows it.
    public var nightMode: Bool

    public init(delay: TimeInterval = 0, dialogueLift: Double = 0, nightMode: Bool = false) {
        self.delay = delay
        self.dialogueLift = dialogueLift
        self.nightMode = nightMode
    }

    /// Whole milliseconds of delay after clamping; negative moves the sound earlier.
    var delayMilliseconds: Int {
        guard delay.isFinite else { return 0 }
        return Int((min(max(delay, -Self.maxDelay), Self.maxDelay) * 1000).rounded())
    }

    var liftDecibels: Double {
        dialogueLift.isFinite ? min(max(dialogueLift, 0), Self.maxDialogueLift) : 0
    }

    /// Whether anything is shaped, after clamping.
    var isActive: Bool { delayMilliseconds != 0 || liftDecibels > 0 || nightMode }

    /// The libavfilter chain for audio with `channels` output channels (6 for surround, else 2) decoded at
    /// `sampleRate`, or nil when nothing is shaped. Dialogue lift comes first, then night mode, then the
    /// delay, which works in whole samples: padding with silence to move later, trimming the start to
    /// move earlier.
    func filterChain(channels: Int, sampleRate: Int) -> String? {
        var filters: [String] = []
        let lift = liftDecibels
        if lift > 0 {
            let gain = pow(10, lift / 20)
            if channels > 2 {
                // Named channels need a known layout, so the input is brought to 5.1(side) first.
                filters.append("aformat=channel_layouts=5.1(side)")
                filters.append("pan=5.1(side)|FL=FL|FR=FR|FC=\(Self.number(gain))*FC|LFE=LFE|SL=SL|SR=SR")
            } else {
                // The mid (what both sides share) gains `gain` and the side signal stays: each side becomes
                // (gain + 1) / 2 of itself plus (gain - 1) / 2 of the other.
                let same = Self.number((gain + 1) / 2)
                let cross = Self.number((gain - 1) / 2)
                filters.append("aformat=channel_layouts=stereo")
                filters.append("pan=stereo|FL=\(same)*FL+\(cross)*FR|FR=\(cross)*FL+\(same)*FR")
            }
        }
        if nightMode {
            // Over -24 dBFS every 4 dB in comes out 1 dB; 6 dB of make-up gain brings the whole back up, and
            // the limiter catches what is left.
            filters.append("acompressor=threshold=0.0631:ratio=4:attack=10:release=200:makeup=2")
            filters.append("alimiter=limit=0.9:level=0")
        }
        let milliseconds = delayMilliseconds
        if milliseconds > 0 {
            filters.append("adelay=delays=\(milliseconds):all=1")
        } else if milliseconds < 0 {
            let samples = (Double(-milliseconds) * Double(sampleRate) / 1000).rounded()
            filters.append("atrim=start_sample=\(Int(samples))")
        }
        return filters.isEmpty ? nil : filters.joined(separator: ",")
    }

    /// A coefficient in the plain decimal form filter expressions read.
    private static func number(_ value: Double) -> String { String(format: "%.6f", value) }
}
