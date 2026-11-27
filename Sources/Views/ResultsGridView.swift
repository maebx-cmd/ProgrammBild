import Photos
import SwiftUI

struct ResultsGridView: View {
    @EnvironmentObject var engine: ScanEngine
    let bucket: Bucket

    @State private var selection: Set<String> = []
    @State private var reveal = false
    @State private var showMove = false
    @State private var confirmDelete = false
    @State private var detail: String?
    @State private var error: String?

    private var selectedFiles: [URL] { selection.compactMap(ImportStore.url(for:)) }

    private var ids: [String] { engine.ids(for: bucket) }
    private let columns = [GridItem(.adaptive(minimum: 96), spacing: 2)]
    private var blurred: Bool { engine.settings.blurPreviews && !reveal }

    private var suggestedAlbum: String {
        switch bucket {
        case .builtin(.nude), .builtin(.revealing): return "Privat"
        case .builtin(.chats): return "Screenshots privat"
        case .builtin(.social): return "Gespeichert"
        default: return engine.title(bucket)
        }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 2) {
                ForEach(ids, id: \.self) { id in
                    ThumbCell(id: id, selected: selection.contains(id), blurred: blurred, isVideo: engine.isVideo(id))
                        .onTapGesture { toggle(id) }
                        .onLongPressGesture { detail = id }
                }
            }
            if let error { Text(error).font(.footnote).foregroundStyle(.red).padding() }
        }
        .navigationTitle(engine.title(bucket))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if engine.settings.blurPreviews {
                    Button { reveal.toggle() } label: { Image(systemName: reveal ? "eye.slash" : "eye") }
                        .accessibilityLabel(reveal ? "Unscharf" : "Anzeigen")
                }
                Button(selection.count == ids.count && !ids.isEmpty ? "Keine" : "Alle") {
                    selection = selection.count == ids.count ? [] : Set(ids)
                }
            }
            ToolbarItemGroup(placement: .bottomBar) {
                Menu {
                    Button("Ignorieren", systemImage: "hand.thumbsup") {
                        engine.markHandled(Array(selection)); selection = []
                    }
                    if !selectedFiles.isEmpty {
                        ShareLink(items: selectedFiles) { Label("Exportieren …", systemImage: "square.and.arrow.up") }
                    }
                    Button(selectedFiles.isEmpty ? "Aus Mediathek löschen" : "Löschen", systemImage: "trash", role: .destructive) { confirmDelete = true }
                } label: { Image(systemName: "ellipsis.circle") }
                .disabled(selection.isEmpty)
                Spacer()
                Text("\(selection.count) ausgewählt").font(.footnote)
                Spacer()
                Button { showMove = true } label: { Label("In Album", systemImage: "rectangle.stack.badge.plus") }
                    .buttonStyle(.borderedProminent)
                    .disabled(selection.isEmpty)
            }
        }
        .confirmationDialog("\(selection.count) Fotos aus der Mediathek löschen?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Löschen", role: .destructive) {
                let list = Array(selection)
                Task {
                    do { try await engine.delete(list); selection = [] }
                    catch { self.error = "Löschen abgebrochen." }
                }
            }
        } message: {
            Text(selectedFiles.count == selection.count
                 ? "Die importierten Kopien werden aus der App gelöscht. Die Originaldateien in „Dateien“ bleiben unverändert."
                 : "Sie landen in „Zuletzt gelöscht“. Dort in der Fotos-App endgültig löschen. Mit iCloud-Fotos verschwinden sie auf allen Geräten.")
        }
        .sheet(isPresented: $showMove) {
            MoveSheet(ids: Array(selection), suggestedName: suggestedAlbum) {
                engine.markHandled(Array(selection)); selection = []
            }
            .presentationDetents([.medium, .large])
        }
        .sheet(item: Binding(get: { detail.map(DetailID.init) }, set: { detail = $0?.id })) { d in
            DetailSheet(id: d.id).presentationDetents([.medium])
        }
    }

    private func toggle(_ id: String) {
        if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
    }
}

private struct DetailID: Identifiable { let id: String }

struct ThumbCell: View {
    let id: String
    let selected: Bool
    let blurred: Bool
    var isVideo = false
    @State private var image: UIImage?

    var body: some View {
        Color(.secondarySystemBackground)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().blur(radius: blurred ? 18 : 0)
                }
            }
            .clipped()
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(selected ? Color.accentColor : .white)
                    .background(Circle().fill(selected ? .white : .black.opacity(0.25)))
                    .padding(6)
            }
            .overlay(alignment: .topLeading) {
                if isVideo {
                    Image(systemName: "video.fill")
                        .font(.caption2).foregroundStyle(.white)
                        .padding(4).background(.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 5))
                        .padding(5)
                }
            }
            .overlay { if selected { Rectangle().stroke(Color.accentColor, lineWidth: 3) } }
            .task(id: id) {
                if let url = ImportStore.url(for: id) {
                    image = await ImageLoader.fileThumbnail(url, side: 120)
                    return
                }
                guard let asset = PhotoLibrary.assets([id]).first else { return }
                image = await ImageLoader.thumbnail(for: asset, side: 120)
            }
    }
}

struct DetailSheet: View {
    @EnvironmentObject var engine: ScanEngine
    let id: String

    var body: some View {
        NavigationStack {
            List(engine.reasons(for: id), id: \.self) { Text($0) }
                .navigationTitle("Warum vorgeschlagen?")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}
