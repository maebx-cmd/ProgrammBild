import Photos
import SwiftUI

/// Analyse und Vorschläge auf ein Album beschränken.
struct AlbumPickerSheet: View {
    @EnvironmentObject var engine: ScanEngine
    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []

    var body: some View {
        NavigationStack {
            List(albums, id: \.localIdentifier) { a in
                Button {
                    engine.setSource(.album(a.localIdentifier))
                    dismiss()
                } label: {
                    HStack {
                        Image(systemName: a.assetCollectionType == .smartAlbum ? "gearshape.2" : "rectangle.stack")
                            .foregroundStyle(.secondary)
                        Text(a.localizedTitle ?? "Album")
                        Spacer()
                        if engine.settings.source == .album(a.localIdentifier) {
                            Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                        }
                    }
                }
                .foregroundStyle(.primary)
            }
            .navigationTitle("Album wählen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Abbrechen") { dismiss() } }
            .task {
                _ = await PhotoLibrary.requestAccess()
                albums = PhotoLibrary.allAlbums()
            }
        }
    }
}
