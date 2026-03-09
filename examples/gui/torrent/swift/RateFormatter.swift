import Foundation
import SwiftUI

/// Format a byte rate (bytes/sec) to a human-readable string.
func formatRate(_ bytesPerSec: Double) -> String {
    if bytesPerSec < 1 {
        return "0 B/s"
    } else if bytesPerSec < 1024 {
        return String(format: "%.0f B/s", bytesPerSec)
    } else if bytesPerSec < 1024 * 1024 {
        return String(format: "%.1f KB/s", bytesPerSec / 1024)
    } else if bytesPerSec < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB/s", bytesPerSec / (1024 * 1024))
    } else {
        return String(format: "%.2f GB/s", bytesPerSec / (1024 * 1024 * 1024))
    }
}

/// Format a byte count to a human-readable string.
func formatBytes(_ bytes: Double) -> String {
    if bytes < 0 {
        return "0 B"
    } else if bytes < 1024 {
        return String(format: "%.0f B", bytes)
    } else if bytes < 1024 * 1024 {
        return String(format: "%.1f KB", bytes / 1024)
    } else if bytes < 1024 * 1024 * 1024 {
        return String(format: "%.1f MB", bytes / (1024 * 1024))
    } else if bytes < 1024 * 1024 * 1024 * 1024 {
        return String(format: "%.2f GB", bytes / (1024 * 1024 * 1024))
    } else {
        return String(format: "%.2f TB", bytes / (1024 * 1024 * 1024 * 1024))
    }
}

/// Format a progress percentage (0.0 - 1.0) to a string like "73.2%"
func formatPercent(_ progress: Double) -> String {
    if progress >= 1.0 {
        return "100%"
    } else if progress <= 0.0 {
        return "0%"
    } else {
        return String(format: "%.1f%%", progress * 100)
    }
}

/// Format an ETA string to a human-readable display.
func formatEta(_ eta: String) -> String {
    if eta.isEmpty { return "∞" }
    return eta
}

/// Return an SF Symbol name for a torrent state.
func stateIcon(_ state: String) -> String {
    switch state {
    case "downloading": return "arrow.down.circle.fill"
    case "seeding": return "arrow.up.circle.fill"
    case "paused": return "pause.circle.fill"
    case "checking": return "checkmark.circle"
    case "error": return "exclamationmark.triangle.fill"
    case "queued": return "clock.fill"
    default: return "circle"
    }
}

/// Return a color for a torrent state.
func stateColor(_ state: String) -> Color {
    switch state {
    case "downloading": return Color(red: 0.369, green: 0.361, blue: 0.902) // #5E5CE6
    case "seeding": return Color(red: 0.188, green: 0.820, blue: 0.345)     // #30D158
    case "paused": return Color(red: 0.631, green: 0.631, blue: 0.651)      // #A1A1A6
    case "checking": return Color(red: 1.0, green: 0.839, blue: 0.039)      // #FFD60A
    case "error": return Color(red: 1.0, green: 0.271, blue: 0.227)         // #FF453A
    case "queued": return Color(red: 0.631, green: 0.631, blue: 0.651)      // #A1A1A6
    default: return Color.gray
    }
}

/// Return an SF Symbol name for a file based on its extension.
func fileIcon(_ path: String) -> String {
    let ext = (path as NSString).pathExtension.lowercased()
    switch ext {
    case "mp4", "mkv", "avi", "mov", "wmv", "flv", "webm":
        return "film"
    case "mp3", "flac", "aac", "ogg", "wav", "m4a":
        return "music.note"
    case "jpg", "jpeg", "png", "gif", "bmp", "tiff", "webp", "svg":
        return "photo"
    case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
        return "archivebox"
    case "pdf":
        return "doc.richtext"
    case "txt", "md", "log", "nfo":
        return "doc.text"
    case "iso", "img", "dmg":
        return "opticaldisc"
    case "exe", "msi", "app", "deb", "rpm":
        return "app.badge"
    default:
        return "doc"
    }
}

/// Format a ratio value (e.g., 1.234 → "1.23")
func formatRatio(_ ratio: Double) -> String {
    return String(format: "%.2f", ratio)
}

/// Return a display color for a tracker status.
func trackerStatusColor(_ status: String) -> Color {
    switch status {
    case "working": return Color(red: 0.188, green: 0.820, blue: 0.345)   // #30D158
    case "updating": return Color(red: 1.0, green: 0.839, blue: 0.039)    // #FFD60A
    case "error": return Color(red: 1.0, green: 0.271, blue: 0.227)       // #FF453A
    case "disabled": return Color.gray
    default: return Color.gray
    }
}
