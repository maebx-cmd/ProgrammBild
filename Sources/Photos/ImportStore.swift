import Foundation
import UniformTypeIdentifiers

/// Aus „Dateien“ importierte Bilder. Sie werden in den App-Container kopiert
/// (Data Protection), damit die Analyse sie auch später noch findet.
enum ImportStore {
    static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Importiert", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.protectionKey: FileProtectionType.complete])
        return dir
    }()

    static func url(for id: String) -> URL? {
        guard id.hasPrefix("file:") else { return nil }
        return folder.appendingPathComponent(String(id.dropFirst(5)))
    }

    /// Kopiert die gewählten Dateien; liefert die neuen IDs ("file:<Name>").
    static func importFiles(_ urls: [URL]) -> [String] {
        var ids: [String] = []
        for src in urls {
            let scoped = src.startAccessingSecurityScopedResource()
            defer { if scoped { src.stopAccessingSecurityScopedResource() } }
            let ext = src.pathExtension.isEmpty ? "jpg" : src.pathExtension.lowercased()
            let base = src.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "/", with: "_").prefix(60)
            let name = "\(base)-\(UUID().uuidString.prefix(8)).\(ext)"
            let dst = folder.appendingPathComponent(name)
            do {
                try FileManager.default.copyItem(at: src, to: dst)
                ids.append("file:" + name)
            } catch { continue }
        }
        return ids
    }

    static func remove(_ ids: [String]) {
        for id in ids { if let u = url(for: id) { try? FileManager.default.removeItem(at: u) } }
    }

    static func allIDs() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return names.filter { !$0.hasPrefix(".") }.map { "file:" + $0 }
    }
}
