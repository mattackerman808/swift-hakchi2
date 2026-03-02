import SwiftUI

/// Individual game tile for the explorer grid
struct GameCardView: View {
    let game: Game
    let isActive: Bool
    let isOnBar: Bool
    var cardSize: CGFloat = 130

    var body: some View {
        ZStack {
            // Cover art or placeholder
            if let coverImage = game.coverImage {
                Image(nsImage: coverImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: cardSize)
                    .cornerRadius(8)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(.quaternary)
                    .frame(width: cardSize, height: cardSize)
                    .overlay {
                        Image(systemName: game.isStock ? "star.fill" : "gamecontroller.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
            }

            // Tinted overlay when on the install bar
            if isOnBar {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.15))
                    .allowsHitTesting(false)
            }
        }
        .shadow(color: .black.opacity(isActive ? 0.5 : 0.15), radius: isActive ? 8 : 2, y: isActive ? 4 : 1)
        .scaleEffect(isActive ? 1.06 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isActive)
        .animation(.easeInOut(duration: 0.15), value: isOnBar)
        .frame(width: cardSize)
        .padding(4)
        .contentShape(Rectangle())
    }
}
