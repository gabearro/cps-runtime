import SwiftUI

// MARK: - Span Model

struct MessageSpan: Decodable {
    let t: String
    var fg: String?
    var bg: String?
    var b: Bool?
    var i: Bool?
    var u: Bool?
    var s: Bool?
    var link: String?
}

// MARK: - Nick Color

enum NickColor {
    // Tuned for high contrast on dark backgrounds, readable in sunlight.
    // Each color is distinct, avoids confusion with UI semantic colors,
    // and maintains strong contrast against dark surfaces.
    private static let darkPalette: [Color] = [
        Color(hue: 0.02, saturation: 0.50, brightness: 0.92),  // warm coral
        Color(hue: 0.08, saturation: 0.55, brightness: 0.92),  // apricot
        Color(hue: 0.14, saturation: 0.48, brightness: 0.91),  // amber
        Color(hue: 0.28, saturation: 0.42, brightness: 0.87),  // sage
        Color(hue: 0.38, saturation: 0.44, brightness: 0.87),  // seafoam
        Color(hue: 0.48, saturation: 0.38, brightness: 0.89),  // teal
        Color(hue: 0.55, saturation: 0.36, brightness: 0.91),  // sky
        Color(hue: 0.62, saturation: 0.40, brightness: 0.92),  // periwinkle
        Color(hue: 0.72, saturation: 0.34, brightness: 0.91),  // lavender
        Color(hue: 0.82, saturation: 0.36, brightness: 0.91),  // mauve
        Color(hue: 0.92, saturation: 0.38, brightness: 0.91),  // rose
        Color(hue: 0.42, saturation: 0.46, brightness: 0.85),  // mint
        Color(hue: 0.58, saturation: 0.46, brightness: 0.90),  // cornflower
        Color(hue: 0.76, saturation: 0.38, brightness: 0.89),  // wisteria
        Color(hue: 0.18, saturation: 0.44, brightness: 0.89),  // chartreuse
        Color(hue: 0.95, saturation: 0.40, brightness: 0.92),  // blush
    ]

    private static let lightPalette: [Color] = [
        Color(hue: 0.02, saturation: 0.65, brightness: 0.62),
        Color(hue: 0.08, saturation: 0.70, brightness: 0.58),
        Color(hue: 0.14, saturation: 0.60, brightness: 0.56),
        Color(hue: 0.28, saturation: 0.55, brightness: 0.52),
        Color(hue: 0.38, saturation: 0.58, brightness: 0.50),
        Color(hue: 0.48, saturation: 0.52, brightness: 0.52),
        Color(hue: 0.55, saturation: 0.50, brightness: 0.55),
        Color(hue: 0.62, saturation: 0.55, brightness: 0.58),
        Color(hue: 0.72, saturation: 0.48, brightness: 0.56),
        Color(hue: 0.82, saturation: 0.50, brightness: 0.56),
        Color(hue: 0.92, saturation: 0.52, brightness: 0.56),
        Color(hue: 0.42, saturation: 0.60, brightness: 0.48),
        Color(hue: 0.58, saturation: 0.60, brightness: 0.55),
        Color(hue: 0.76, saturation: 0.52, brightness: 0.54),
        Color(hue: 0.18, saturation: 0.58, brightness: 0.52),
        Color(hue: 0.95, saturation: 0.55, brightness: 0.58),
    ]

    static func forNick(_ nick: String) -> Color {
        var hash: UInt = 5381
        for scalar in nick.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt(scalar.value)
        }
        let idx = Int(hash % UInt(darkPalette.count))
        return darkPalette[idx]
    }

    /// Returns override color if set in nickColors JSON, otherwise falls back to hash.
    static func forNick(_ nick: String, overrides: String) -> Color {
        if !overrides.isEmpty,
           let data = overrides.data(using: .utf8),
           let dict = try? JSONSerialization.jsonObject(with: data) as? [String: String],
           let hex = dict[nick.lowercased()],
           let color = colorFromHex(hex) {
            return color
        }
        return forNick(nick)
    }
}

// MARK: - Hex Color Parser

private func colorFromHex(_ hex: String) -> Color? {
    var str = hex
    if str.hasPrefix("#") {
        str = String(str.dropFirst())
    }
    guard str.count == 6, let rgb = UInt(str, radix: 16) else {
        return nil
    }
    let r = Double((rgb >> 16) & 0xFF) / 255.0
    let g = Double((rgb >> 8) & 0xFF) / 255.0
    let b = Double(rgb & 0xFF) / 255.0
    return Color(red: r, green: g, blue: b)
}

// MARK: - Rich Message Text View

struct RichMessageText: View {
    let spansJson: String

    var body: some View {
        let spans = parseSpans()
        if spans.isEmpty {
            Text("")
        } else {
            buildTextView(spans: spans)
        }
    }

    private func parseSpans() -> [MessageSpan] {
        guard !spansJson.isEmpty,
              let data = spansJson.data(using: .utf8),
              let spans = try? JSONDecoder().decode([MessageSpan].self, from: data)
        else {
            return []
        }
        return spans
    }

    @ViewBuilder
    private func buildTextView(spans: [MessageSpan]) -> some View {
        let hasLinks = spans.contains { $0.link != nil }
        if hasLinks {
            buildLinkedText(spans: spans)
        } else {
            buildPlainText(spans: spans)
        }
    }

    private func buildPlainText(spans: [MessageSpan]) -> Text {
        var result = Text("")
        for span in spans {
            var t = Text(span.t)

            if span.b == true {
                t = t.bold()
            }
            if span.i == true {
                t = t.italic()
            }
            if span.u == true {
                t = t.underline()
            }
            if span.s == true {
                t = t.strikethrough()
            }
            if let fg = span.fg, let color = colorFromHex(fg) {
                t = t.foregroundColor(color)
            }

            result = result + t
        }
        return result
    }

    @ViewBuilder
    private func buildLinkedText(spans: [MessageSpan]) -> some View {
        let groups = groupSpans(spans)

        HStack(spacing: 0) {
            ForEach(0..<groups.count, id: \.self) { idx in
                let group = groups[idx]
                if let linkUrl = group.linkUrl {
                    Link(group.displayText, destination: URL(string: linkUrl) ?? URL(string: "about:blank")!)
                        .font(.system(size: 13))
                } else {
                    buildPlainText(spans: group.spans)
                }
            }
        }
    }

    private struct SpanGroup {
        var spans: [MessageSpan]
        var linkUrl: String?
        var displayText: String {
            spans.map { $0.t }.joined()
        }
    }

    private func groupSpans(_ spans: [MessageSpan]) -> [SpanGroup] {
        var groups: [SpanGroup] = []
        var currentPlain: [MessageSpan] = []

        for span in spans {
            if let link = span.link, !link.isEmpty {
                if !currentPlain.isEmpty {
                    groups.append(SpanGroup(spans: currentPlain, linkUrl: nil))
                    currentPlain = []
                }
                groups.append(SpanGroup(spans: [span], linkUrl: link))
            } else {
                currentPlain.append(span)
            }
        }

        if !currentPlain.isEmpty {
            groups.append(SpanGroup(spans: currentPlain, linkUrl: nil))
        }

        return groups
    }
}
