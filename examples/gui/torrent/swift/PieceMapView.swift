import SwiftUI

/// Piece map visualization showing a grid of colored cells representing piece states.
/// Each cell represents one piece, colored by state:
///   - Green (#30D158): verified (SHA1 confirmed)
///   - Teal  (#30D5C8): optimistic (peer consensus verified, SHA1 pending)
///   - Purple (#5E5CE6): partial (downloading)
///   - Gray  (#38383A): empty
///   - Red   (#FF453A): failed
///
/// The `data` string is a compact encoding where each character represents a piece state:
///   '0' = empty, '1' = partial, '2' = complete, '3' = verified, '4' = failed, '5' = optimistic
struct PieceMapView: View {
    let data: String
    let pieceCount: Int

    private let cellSize: CGFloat = 7
    private let cellSpacing: CGFloat = 1

    private var states: [UInt8] {
        Array(data.utf8).map { byte in
            if byte >= 0x30 && byte <= 0x35 {
                return byte - 0x30
            }
            return 0
        }
    }

    private func colorFor(state: UInt8) -> Color {
        switch state {
        case 3: return Color(red: 0.188, green: 0.820, blue: 0.345)  // verified green
        case 5: return Color(red: 0.188, green: 0.835, blue: 0.784)  // optimistic teal
        case 1, 2: return Color(red: 0.369, green: 0.361, blue: 0.902)  // partial/complete purple
        case 4: return Color(red: 1.0, green: 0.271, blue: 0.227)  // failed red
        default: return Color.white.opacity(0.06)  // empty - subtle dark
        }
    }

    var body: some View {
        GeometryReader { geometry in
            let availWidth = geometry.size.width
            let totalCellWidth = cellSize + cellSpacing
            let columns = max(1, Int(availWidth / totalCellWidth))
            let rows = (pieceCount + columns - 1) / max(1, columns)
            let gridHeight = CGFloat(rows) * totalCellWidth
            let pieceStates = states

            ScrollView {
                Canvas { context, size in
                    for i in 0..<pieceCount {
                        let col = i % columns
                        let row = i / columns
                        let x = CGFloat(col) * totalCellWidth
                        let y = CGFloat(row) * totalCellWidth

                        let state: UInt8 = i < pieceStates.count ? pieceStates[i] : 0
                        let color = colorFor(state: state)

                        let rect = CGRect(x: x, y: y, width: cellSize, height: cellSize)
                        context.fill(
                            Path(roundedRect: rect, cornerRadius: 1),
                            with: .color(color)
                        )
                    }
                }
                .frame(width: availWidth, height: gridHeight)
            }
        }
    }
}
