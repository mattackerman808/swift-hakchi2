import SwiftUI

/// Folders Manager (post-MVP placeholder)
struct FoldersManagerView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)

            Text("Folders Manager")
                .font(.title2)

            Text("Organize games into folders on your console.\nComing soon.")
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
