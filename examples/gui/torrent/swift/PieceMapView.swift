import SwiftUI

/// Comprehensive piece map visualization with analytics header and state grid.
///
/// Parses the compact `data` string (one ASCII char per piece) to compute per-state
/// breakdowns, render a proportional distribution bar, and draw the piece grid.
///
/// Encoding: '0'=empty, '1'=partial, '2'=complete, '3'=verified, '4'=failed, '5'=optimistic
struct PieceMapView: View {
    let data: String
    let pieceCount: Int
    let isDark: Bool

    private let cellSize: CGFloat = 7
    private let cellSpacing: CGFloat = 1

    // MARK: - State Analysis

    private struct Breakdown {
        var empty: Int = 0
        var partial: Int = 0
        var complete: Int = 0
        var verified: Int = 0
        var failed: Int = 0
        var optimistic: Int = 0

        var downloading: Int { partial + complete }
    }

    private var breakdown: Breakdown {
        var b = Breakdown()
        for byte in data.utf8 {
            switch byte {
            case 0x30: b.empty += 1
            case 0x31: b.partial += 1
            case 0x32: b.complete += 1
            case 0x33: b.verified += 1
            case 0x34: b.failed += 1
            case 0x35: b.optimistic += 1
            default: break
            }
        }
        return b
    }

    // MARK: - Colors

    private var verifiedColor: Color { Color(red: 0.188, green: 0.820, blue: 0.345) }
    private var optimisticColor: Color { Color(red: 0.188, green: 0.835, blue: 0.784) }
    private var downloadingColor: Color { Color(red: 0.369, green: 0.361, blue: 0.902) }
    private var failedColor: Color { Color(red: 1.0, green: 0.263, blue: 0.227) }
    private var emptyColor: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.06) }

    private var textPrimary: Color { isDark ? Color(red: 0.96, green: 0.96, blue: 0.97) : Color.black.opacity(0.85) }
    private var textSecondary: Color { isDark ? Color(red: 0.66, green: 0.66, blue: 0.69) : Color.black.opacity(0.55) }
    private var textMuted: Color { isDark ? Color(red: 0.54, green: 0.54, blue: 0.57) : Color.gray }
    private var textSubtle: Color { isDark ? Color(red: 0.44, green: 0.44, blue: 0.47) : Color.black.opacity(0.25) }
    private var divider: Color { isDark ? Color.white.opacity(0.06) : Color.black.opacity(0.04) }
    private var headerBg: Color { isDark ? Color.white.opacity(0.02) : Color.black.opacity(0.015) }

    // MARK: - Number Formatting

    private static let numFmt: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private func fmt(_ n: Int) -> String {
        Self.numFmt.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    private func pct(_ value: Double) -> String {
        if value >= 1.0 { return "100%" }
        if value <= 0.0 { return "0.0%" }
        return String(format: "%.1f%%", value * 100)
    }

    // MARK: - Body

    var body: some View {
        let b = breakdown

        VStack(spacing: 0) {
            // Analytics header
            VStack(spacing: 10) {
                // State indicators
                HStack(spacing: 0) {
                    stateCell(color: verifiedColor, label: "Verified", count: b.verified)
                    stateCell(color: optimisticColor, label: "Optimistic", count: b.optimistic)
                    stateCell(color: downloadingColor, label: "Partial", count: b.downloading)
                    stateCell(color: failedColor, label: "Failed", count: b.failed)
                    stateCell(color: emptyColor, label: "Empty", count: b.empty, bordered: true)
                }

                // Distribution bar
                segmentBar(b)

                // Summary
                HStack(spacing: 0) {
                    Text(fmt(pieceCount))
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                        .foregroundColor(textSecondary)
                    Text(" pieces")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)

                    Spacer()

                    let ratio = pieceCount > 0 ? Double(b.verified) / Double(pieceCount) : 0.0
                    Text(pct(ratio))
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .foregroundColor(ratio >= 1.0 ? verifiedColor : textPrimary)
                    Text(" verified")
                        .font(.system(size: 11))
                        .foregroundColor(textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .background(headerBg)

            Rectangle().fill(divider).frame(height: 1)

            // Piece grid
            pieceGrid
        }
    }

    // MARK: - State Indicator

    private func stateCell(color: Color, label: String, count: Int, bordered: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2)
                .fill(color)
                .frame(width: 8, height: 8)
                .overlay(
                    Group {
                        if bordered {
                            RoundedRectangle(cornerRadius: 2)
                                .stroke((isDark ? Color.white : Color.black).opacity(0.18), lineWidth: 0.5)
                        }
                    }
                )

            Text(fmt(count))
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(count > 0 ? textPrimary : textSubtle)

            Text(label)
                .font(.system(size: 10))
                .foregroundColor(textMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Distribution Bar

    private func segmentBar(_ b: Breakdown) -> some View {
        GeometryReader { geo in
            let w = geo.size.width
            let total = max(pieceCount, 1)

            ZStack(alignment: .leading) {
                // Background (represents empty)
                RoundedRectangle(cornerRadius: 4)
                    .fill(isDark ? Color.white.opacity(0.04) : Color.black.opacity(0.04))

                // Stacked colored segments
                Canvas { context, size in
                    let segments: [(Color, Int)] = [
                        (verifiedColor, b.verified),
                        (optimisticColor, b.optimistic),
                        (downloadingColor, b.downloading),
                        (failedColor, b.failed),
                    ]

                    var x: CGFloat = 0
                    for (color, count) in segments {
                        guard count > 0 else { continue }
                        let segW = max(2, CGFloat(count) / CGFloat(total) * w)
                        let rect = CGRect(x: x, y: 0, width: segW, height: size.height)
                        context.fill(Path(rect), with: .color(color))
                        x += segW
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
        .frame(height: 6)
    }

    // MARK: - Piece Grid

    private var pieceGrid: some View {
        GeometryReader { geometry in
            let availWidth = geometry.size.width
            let totalCellWidth = cellSize + cellSpacing
            let columns = max(1, Int(availWidth / totalCellWidth))
            let rows = (pieceCount + columns - 1) / max(1, columns)
            let gridHeight = CGFloat(rows) * totalCellWidth
            let pieceBytes = Array(data.utf8)

            ScrollView {
                Canvas { context, size in
                    for i in 0..<pieceCount {
                        let col = i % columns
                        let row = i / columns
                        let x = CGFloat(col) * totalCellWidth
                        let y = CGFloat(row) * totalCellWidth

                        let byte: UInt8 = i < pieceBytes.count ? pieceBytes[i] : 0x30
                        let color = cellColor(byte)

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
        .padding(16)
    }

    // MARK: - Cell Color

    private func cellColor(_ byte: UInt8) -> Color {
        switch byte {
        case 0x33: return verifiedColor      // '3' verified
        case 0x35: return optimisticColor     // '5' optimistic
        case 0x31, 0x32: return downloadingColor // '1' partial, '2' complete
        case 0x34: return failedColor         // '4' failed
        default: return emptyColor            // '0' empty
        }
    }
}
