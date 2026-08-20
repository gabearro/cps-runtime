#if os(macOS)
import SwiftUI
import AppKit

extension Color {
    init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (r, g, b) = ((value >> 8) * 17, ((value >> 4) & 0xF) * 17, (value & 0xF) * 17)
        case 6, 8:
            (r, g, b) = ((value >> 16) & 0xFF, (value >> 8) & 0xFF, value & 0xFF)
        default:
            (r, g, b) = (10, 132, 255)
        }
        self.init(red: Double(r) / 255.0, green: Double(g) / 255.0, blue: Double(b) / 255.0)
    }
}

struct ClipboardPreview: View {
    let kind: String
    let text: String
    let path: String
    let colorHex: String
    let isDark: Bool

    var body: some View {
        Group {
            if kind == "Image", let image = loadImage() {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(24)
            } else if kind == "Color" {
                VStack(spacing: 14) {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color(hex: colorHex.isEmpty ? text : colorHex))
                        .frame(width: 180, height: 120)
                    Text(colorHex.isEmpty ? text : colorHex)
                        .font(.system(size: 13, design: .monospaced))
                        .textSelection(.enabled)
                }
            } else if kind == "File" {
                VStack(spacing: 10) {
                    Image(systemName: "doc")
                        .font(.system(size: 48))
                    Text((path as NSString).lastPathComponent)
                        .font(.system(size: 15, weight: .semibold))
                    Text(path)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(24)
            } else {
                ScrollView {
                    Text(text.isEmpty ? "No preview available" : text)
                        .font(.system(size: 13, design: .monospaced))
                        .foregroundStyle(isDark ? Color.white.opacity(0.86) : Color.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(22)
                }
            }
        }
    }

    private func loadImage() -> NSImage? {
        guard !path.isEmpty else { return nil }
        return NSImage(contentsOfFile: path)
    }
}
#endif
