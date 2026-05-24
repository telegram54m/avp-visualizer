/// A continuous description of a clip's tonal color.
///
/// Unlike `Key`, this makes no attempt to name a musical key. It captures two
/// robust, consistent signals well suited to driving a visualization:
/// the prominent tonal center, and a sliding scale of major/minor character.
public struct Tonality: Sendable, Equatable {

    /// The most prominent pitch class — the perceived tonal center.
    public let center: PitchClass

    /// Major-ness on a continuous scale:
    /// `+1` clearly major, `0` ambiguous, `-1` clearly minor.
    ///
    /// Derived from the energy balance between the major third and the minor
    /// third above the tonal center — the single note that distinguishes the
    /// two modes.
    public let majorness: Float

    /// Computes the tonality of a chromagram.
    public init(of chromagram: Chromagram) {
        let center = chromagram.dominant
        self.center = center

        let centerEnergy = chromagram.values[center.rawValue]
        let majorThird = chromagram.values[(center.rawValue + 4) % 12]
        let minorThird = chromagram.values[(center.rawValue + 3) % 12]
        let thirdsTotal = majorThird + minorThird

        // The major/minor distinction only means something if a third is
        // actually present. If the thirds carry negligible energy relative to
        // the tonal center, treat the tonality as ambiguous rather than
        // computing a ratio of near-zero noise.
        if thirdsTotal < centerEnergy * 0.15 {
            self.majorness = 0
        } else {
            self.majorness = (majorThird - minorThird) / thirdsTotal
        }
    }
}
