import SwiftUI

/// A small shared vocabulary so the four screens look like one app.
enum Theme {
    static let accent = Color(red: 0.36, green: 0.78, blue: 0.62)
    static let warn = Color(red: 0.95, green: 0.68, blue: 0.29)
    static let bad = Color(red: 0.92, green: 0.42, blue: 0.42)

    static let cardBackground = Color(UIColor.secondarySystemBackground)
}

/// Status dot + label, used for the server and the game in several places.
struct StatusPill: View {
    let text: String
    let color: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(text).font(.footnote.weight(.medium))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.15)))
        .foregroundStyle(color)
    }
}

struct Card<Content: View>: View {
    var title: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let title {
                Text(title.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.cardBackground))
    }
}
