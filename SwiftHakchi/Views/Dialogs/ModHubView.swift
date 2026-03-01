import SwiftUI

/// Mod Hub browser (post-MVP placeholder)
struct ModHubView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "shippingbox")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Mod Hub")
                .font(.title2)

            Text("Browse and install community mods.\nComing soon.")
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
