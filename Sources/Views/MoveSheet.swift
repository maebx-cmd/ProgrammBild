import Photos
import SwiftUI

struct MoveSheet: View {
    let ids: [String]
    let suggestedName: String
    let onDone: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var albums: [PHAssetCollection] = []
    @State private var chosen: String?            // localIdentifier oder nil = neues Album
    @State private var newName = ""
    @State private var removeFromOthers = true
    @State private var hide = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ziel") {
                    HStack {
                        Image(systemName: chosen == nil ? "largecircle.fill.circle" : "circle")
                            .foregroundStyle(Color.accentColor)
                        TextField("Neues Album", text: $newName)
                            .onTapGesture { chosen = nil }
                    }
                    ForEach(albums, id: \.localIdentifier) { a in
                        Button {
                            chosen = a.localIdentifier
                        } label: {
                            HStack {
                                Image(systemName: chosen == a.localIdentifier ? "largecircle.fill.circle" : "circle")
                                Text(a.localizedTitle ?? "Album")
                                Spacer()
                                Text("\(a.estimatedAssetCount == NSNotFound ? 0 : a.estimatedAssetCount)")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)
                    }
                }
                Section {
                    Toggle("Aus anderen eigenen Alben entfernen", isOn: $removeFromOthers)
                    Toggle("Ausblenden (Album „Ausgeblendet“)", isOn: $hide)
                } footer: {
                    Text("iOS behält Fotos immer in der Mediathek. „Ausblenden“ entfernt sie aus „Zuletzt“ – das Album „Ausgeblendet“ ist per Face ID geschützt.")
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .navigationTitle("\(ids.count) Fotos einordnen")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Abbrechen") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Verschieben") { Task { await run() } }
                        .disabled(busy || (chosen == nil && newName.trimmingCharacters(in: .whitespaces).isEmpty))
                }
            }
            .onAppear {
                albums = PhotoLibrary.userAlbums()
                newName = suggestedName
                if let existing = albums.first(where: { $0.localizedTitle == suggestedName }) {
                    chosen = existing.localIdentifier
                }
            }
        }
    }

    private func run() async {
        busy = true; defer { busy = false }
        let target: PhotoLibrary.Target
        if let chosen, let a = albums.first(where: { $0.localIdentifier == chosen }) {
            target = .existing(a)
        } else {
            target = .new(newName.trimmingCharacters(in: .whitespaces))
        }
        do {
            let files = ids.compactMap(ImportStore.url(for:))
            let assets = ids.filter { !$0.hasPrefix("file:") }
            if !files.isEmpty {
                // Importierte Dateien: in die Mediathek übernehmen + ins Album
                try await PhotoLibrary.importFilesToAlbum(files, target: target)
            }
            if !assets.isEmpty {
                try await PhotoLibrary.move(assets, to: target,
                                            options: .init(removeFromOtherAlbums: removeFromOthers, hide: hide))
            }
            onDone()
            dismiss()
        } catch {
            self.error = "Fehler: \(error.localizedDescription)"
        }
    }
}
