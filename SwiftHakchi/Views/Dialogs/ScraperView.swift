import SwiftUI

/// Game metadata scraper (post-MVP placeholder)
struct ScraperView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Game Scraper")
                .font(.title2)

            Text("Automatically download game metadata and cover art\nfrom TheGamesDB.\nComing soon.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Button("Close") {
                dismiss()
            }
        }
        .padding(40)
        .frame(minWidth: 400, minHeight: 300)
    }
}
