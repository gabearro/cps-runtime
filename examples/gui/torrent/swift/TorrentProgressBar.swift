import SwiftUI

/// Segmented progress bar showing piece-level download breakdown.
///
/// Renders stacked colored segments (left to right): verified, optimistic, partial.
/// The remaining space represents pieces not yet started (empty + failed).
struct TorrentProgressBar: View {
    let pctVerified: Double
    let pctOptimistic: Double
    let pctPartial: Double
    let isDark: Bool

    private let barHeight: CGFloat = 4

    private var verifiedColor: Color { Color(red: 0.188, green: 0.820, blue: 0.345) }
    private var optimisticColor: Color { Color(red: 0.188, green: 0.835, blue: 0.784) }
    private var partialColor: Color { Color(red: 0.369, green: 0.361, blue: 0.902) }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(isDark ? Color.white.opacity(0.08) : Color.black.opacity(0.06))

                Canvas { context, size in
                    let segments: [(Color, Double)] = [
                        (verifiedColor, pctVerified),
                        (optimisticColor, pctOptimistic),
                        (partialColor, pctPartial),
                    ]

                    var x: CGFloat = 0
                    for (color, pct) in segments {
                        guard pct > 0 else { continue }
                        let segW = max(1, CGFloat(pct) * w)
                        let rect = CGRect(x: x, y: 0, width: segW, height: size.height)
                        context.fill(Path(rect), with: .color(color))
                        x += segW
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 2))
            }
        }
        .frame(height: barHeight)
    }
}
