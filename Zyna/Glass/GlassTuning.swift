import UIKit

/// Live-tunable glass refraction parameters.
/// Shared singleton read by GlassRenderer every frame.
final class GlassTuning {

    static let shared = GlassTuning()

    /// Bevel zone width in points (how far from edge refraction extends).
    var bezelPt: CGFloat = 36

    /// Glass thickness in points (displacement strength).
    var glassThickPt: CGFloat = 55

    /// Index of refraction (1.5 = glass, 3–4 = crystal).
    var ior: Float = 1.5

    /// Squircle profile exponent (2 = hemisphere, 3 = steep).
    var squircleN: Float = 6

    /// Final displacement multiplier.
    var refractScale: Float = 1.1
}
