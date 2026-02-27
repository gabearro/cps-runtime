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
    static func forNick(_ nick: String) -> Color {
        var hash: UInt = 5381
        for scalar in nick.unicodeScalars {
            hash = ((hash &<< 5) &+ hash) &+ UInt(scalar.value)
        }
        let hue = Double(hash % 360) / 360.0
        return Color(hue: hue, saturation: 0.55, brightness: 0.80)
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
        // Check if any span has a link
        let hasLinks = spans.contains { $0.link != nil }

        if hasLinks {
            // Use a flow layout of Text + Link views
            buildLinkedText(spans: spans)
        } else {
            // All plain text: use Text concatenation for efficiency
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
        // Group consecutive non-link spans for efficiency
        let groups = groupSpans(spans)

        HStack(spacing: 0) {
            ForEach(0..<groups.count, id: \.self) { idx in
                let group = groups[idx]
                if let linkUrl = group.linkUrl {
                    Link(group.displayText, destination: URL(string: linkUrl) ?? URL(string: "about:blank")!)
                        .font(.callout)
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
