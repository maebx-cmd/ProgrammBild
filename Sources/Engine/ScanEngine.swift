import Foundation
import Photos
import SwiftUI
import Vision

/// Steuert Scan (Stufe 1, schnell, alle Fotos) und Feinprüfung (Stufe 2, Apple Intelligence,
/// nur Kandidaten). Ergebnisse liegen verschlüsselt (Data Protection) in Application Support.
@MainActor
final class ScanEngine: ObservableObject {

    enum Phase: Equatable { case idle, scanning, refining, done, needsAccess }

    @Published var phase: Phase = .idle
    @Published var processed = 0
    @Published var total = 0
    @Published private(set) var results: [String: AssetResult] = [:]
    @Published private(set) var buckets: [Bucket: [String]] = [:]
    @Published var settings: AppSettings {
        didSet { persistSettings(); scheduleRecompute() }
    }

    let nudity = NudityAnalyzer()
    let person = PersonAnalyzer()
    let clip = ClipAnalyzer()

    /// Asset-IDs des gewählten Albums (nur bei Quelle = Album).
    @Published private(set) var albumIDs: Set<String> = []

    private var task: Task<Void, Never>?
    private var recomputeTask: Task<Void, Never>?
    private var printCache: [String: [VNFeaturePrintObservation]] = [:]
    private var referenceCache: [VNFeaturePrintObservation] = []

    private let storeURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scan-cache.json")
    }()

    init() {
        settings = UserDefaults.standard.data(forKey: "settings")
            .flatMap { Lenient.decode($0, defaults: AppSettings()) } ?? AppSettings()
        load()
        refreshAlbumIDs()
        recompute()
    }

    // MARK: - Quelle (Mediathek / Album / Dateien)

    var sourceTitle: String {
        switch settings.source {
        case .library: return "Mediathek"
        case .album(let id): return PhotoLibrary.title(ofAlbum: id) ?? "Album"
        case .imported: return "Importierte Dateien"
        }
    }

    func setSource(_ s: SourceScope) {
        settings.source = s
        refreshAlbumIDs()
        recompute()
    }

    private func refreshAlbumIDs() {
        if case .album(let id) = settings.source,
           PHPhotoLibrary.authorizationStatus(for: .readWrite) == .authorized || PHPhotoLibrary.authorizationStatus(for: .readWrite) == .limited {
            albumIDs = PhotoLibrary.assetIDs(inAlbum: id)
        } else {
            albumIDs = []
        }
    }

    private func inSource(_ r: AssetResult) -> Bool {
        switch settings.source {
        case .library: return !r.isImported
        case .album: return albumIDs.contains(r.id)
        case .imported: return r.isImported
        }
    }

    // MARK: - Abfragen

    func ids(for b: Bucket) -> [String] { buckets[b] ?? [] }
    func count(_ b: Bucket) -> Int { buckets[b]?.count ?? 0 }

    var allBuckets: [Bucket] {
        ScanCategory.allCases.map { Bucket.builtin($0) } + settings.custom.map { Bucket.custom($0.id) }
    }

    func title(_ b: Bucket) -> String {
        switch b {
        case .builtin(let c): return c.title
        case .custom(let id): return settings.custom.first { $0.id == id }?.name ?? "Eigene Kategorie"
        }
    }

    /// Kandidaten für die Feinprüfung: alles, was in Stufe 1 auffiel.
    var refineCandidates: [String] {
        let cats: [ScanCategory] = [.revealing, .otherPeople, .chats, .social, .received]
        var set = Set<String>()
        for c in cats { set.formUnion(rawHeuristic(c)) }
        if settings.llmAllPhotos && !settings.custom.isEmpty {
            set.formUnion(results.values.filter { !$0.handled && inSource($0) }.map(\.id))
        }
        return Array(set)
    }

    // MARK: - Kategorien berechnen

    private func scheduleRecompute() {
        recomputeTask?.cancel()
        recomputeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled else { return }
            self?.recompute()
        }
    }

    func recompute() {
        referenceCache = settings.references.compactMap { PersonAnalyzer.decode($0.print) }
        var out: [Bucket: [String]] = [:]
        for b in allBuckets { out[b] = [] }
        for r in results.values where !r.handled && inSource(r) {
            for b in allBuckets where belongs(r, to: b) { out[b, default: []].append(r.id) }
        }
        buckets = out
    }

    private func rawHeuristic(_ c: ScanCategory) -> [String] {
        results.values.filter { !$0.handled && inSource($0) && heuristic($0, c) }.map(\.id)
    }

    /// Stufe-1-Entscheidung ohne Sprachmodell.
    private func heuristic(_ r: AssetResult, _ c: ScanCategory) -> Bool {
        let t = settings.t
        switch c {
        case .nude:
            // Apple entscheidet, wenn verfügbar; sonst das Ersatzmodell
            if let s = r.sensitive { return s }
            return (r.nsfwScore ?? 0) >= t.nsfwModel
        case .revealing:
            if heuristic(r, .nude) { return false }   // Nacktbilder nicht doppelt
            if (r.sexyScore ?? 0) >= t.sexyModel { return true }
            guard let s = r.person else { return false }
            return PersonAnalyzer.revealingScore(s) >= t.revealingLabel
        case .otherPeople:
            guard let s = r.person, PersonAnalyzer.isPerson(s, t) else { return false }
            let prints = decodedPrints(r)
            if prints.isEmpty { return settings.facelessCountsAsOther }
            if referenceCache.isEmpty { return true }
            // mindestens ein Gesicht, das keiner Referenzperson ähnelt
            return prints.contains { p in
                !referenceCache.contains { PersonAnalyzer.distance(p, $0) <= t.faceMatchDistance }
            }
        case .chats:
            return !TextAnalyzer.hits(in: r.ocrText, keywords: settings.keywords).isEmpty
                || (r.isScreenshot && (r.ocrText?.count ?? 0) > 40)   // textreicher Screenshot → Kandidat
        case .social:
            return isSocial(r)
        case .women:
            return genderShare(r).map { $0 >= t.genderShare || ($0 > 1 - t.genderShare && bothGenders(r)) } ?? false
        case .men:
            return genderShare(r).map { $0 <= 1 - t.genderShare || ($0 < t.genderShare && bothGenders(r)) } ?? false
        case .received:
            return !r.hasCamera && !r.isScreenshot && !isSocial(r)
        }
    }

    /// Gespeichert aus TikTok & Co.: keine Kamera-Daten und Wasserzeichen/Logo-Text im Bild,
    /// oder ein Hochformat-Video ohne Kamera-Daten (so sehen TikTok-Downloads aus).
    private func isSocial(_ r: AssetResult) -> Bool {
        guard !r.hasCamera, !r.isScreenshot else { return false }
        if !TextAnalyzer.hits(in: r.ocrText, keywords: settings.socialMarkers).isEmpty { return true }
        return r.isVideo && r.isPortraitVideoish
    }

    /// Anteil „Frau“ an (Frau + Mann) laut MobileCLIP – nur wenn überhaupt ein Mensch zu sehen ist.
    private func genderShare(_ r: AssetResult) -> Float? {
        guard let w = r.clipWoman, let m = r.clipMan, w + m >= settings.t.genderMinPerson else { return nil }
        if let s = r.person, !PersonAnalyzer.isPerson(s, settings.t) { return nil }
        return w / (w + m)
    }

    /// Beide deutlich vertreten (z. B. Paarfoto) → in beiden Kategorien.
    private func bothGenders(_ r: AssetResult) -> Bool {
        (r.clipWoman ?? 0) >= 0.25 && (r.clipMan ?? 0) >= 0.25
    }

    /// „Frau zu sehen?“ – Apple Intelligence, sonst MobileCLIP, sonst unbekannt (nil).
    private func womanVisible(_ r: AssetResult) -> Bool? {
        if let v = r.llm[LLMJudge.qWoman] { return v }
        if let w = r.clipWoman, let m = r.clipMan, w + m >= settings.t.genderMinPerson {
            return w / (w + m) >= 0.5 || (r.clipWoman ?? 0) >= 0.25
        }
        return nil
    }

    /// Kategorien, in denen Menschen gezeigt werden – dort greift der Filter „nur Frauen“.
    private static let personBuckets: Set<ScanCategory> = [.revealing, .otherPeople, .social]

    /// Endgültige Entscheidung: Antwort der Feinprüfung überstimmt die Heuristik.
    private func belongs(_ r: AssetResult, to b: Bucket) -> Bool {
        switch b {
        case .builtin(let c):
            // „Nur Frauen“: erst ausblenden, wenn Apple Intelligence „nein“ gesagt hat –
            // ungeprüfte Treffer bleiben sichtbar, bis die Feinprüfung gelaufen ist.
            if settings.womenOnly && Self.personBuckets.contains(c) && womanVisible(r) == false {
                return false
            }
            let h = heuristic(r, c)
            switch c {
            case .nude, .received, .social, .women, .men:
                return h
            case .revealing:
                return h && r.llm[LLMJudge.qRevealing] != false || r.llm[LLMJudge.qRevealing] == true
            case .otherPeople:
                return h && r.llm[LLMJudge.qPerson] != false
            case .chats:
                let kw = !TextAnalyzer.hits(in: r.ocrText, keywords: settings.keywords).isEmpty
                if kw { return true }                         // Stichwort-Treffer zählt immer
                if let v = r.llm[LLMJudge.qChat] { return v }  // sonst entscheidet die Feinprüfung
                return false                                   // ungeprüfte Text-Screenshots nur als Kandidat
            }
        case .custom(let id):
            return r.llm[id.uuidString] == true
        }
    }

    private func decodedPrints(_ r: AssetResult) -> [VNFeaturePrintObservation] {
        if let c = printCache[r.id] { return c }
        let d = r.facePrints.compactMap(PersonAnalyzer.decode)
        printCache[r.id] = d
        return d
    }

    /// Erklärung für die Detailansicht.
    func reasons(for id: String) -> [String] {
        guard let r = results[id] else { return [] }
        var out: [String] = []
        if r.sensitive == true { out.append("Apple: sensibler Inhalt") }
        if let n = r.nsfwScore, n >= 0.2 { out.append("Ersatzmodell nackt: \(Int(n * 100)) %") }
        if let x = r.sexyScore, x >= 0.2 { out.append("Ersatzmodell freizügig: \(Int(x * 100)) %") }
        if let s = r.person {
            out.append("Menschen-Score \(Int(PersonAnalyzer.score(s, settings.t) * 100)) %")
            out += PersonAnalyzer.reasons(s, settings.t)
        }
        if !r.hasCamera { out.append("Keine Kamera-Metadaten") }
        if let w = r.clipWoman, let m = r.clipMan {
            out.append("MobileCLIP: Frau \(Int(w * 100)) % · Mann \(Int(m * 100)) %")
        }
        if r.isImported { out.append("Importiert aus Dateien") }
        if r.isScreenshot { out.append("Screenshot") }
        if r.isVideo { out.append(r.isPortraitVideoish ? "Video im Hochformat" : "Video") }
        let sm = TextAnalyzer.hits(in: r.ocrText, keywords: settings.socialMarkers)
        if !sm.isEmpty && !r.hasCamera { out.append("Social-Media-Hinweis: " + sm.joined(separator: ", ")) }
        let kw = TextAnalyzer.hits(in: r.ocrText, keywords: settings.keywords)
        if !kw.isEmpty { out.append("Stichwörter: " + kw.joined(separator: ", ")) }
        for (k, v) in r.llm {
            let name = settings.custom.first { $0.id.uuidString == k }?.name ?? k
            out.append("Apple Intelligence „\(name)“: \(v ? "ja" : "nein")")
        }
        return out
    }

    // MARK: - Stufe 1: Scan

    private enum WorkItem: @unchecked Sendable {
        case asset(PHAsset)
        case file(String)
    }

    func start(scope: ScanScope) {
        guard phase != .scanning, phase != .refining else { return }
        task = Task {
            var items: [WorkItem] = []
            if case .imported = settings.source {
                items = ImportStore.allIDs()
                    .filter { (results[$0]?.version ?? 0) < AssetResult.pipelineVersion }
                    .map { .file($0) }
            } else {
                let status = await PhotoLibrary.requestAccess()
                guard status == .authorized || status == .limited else { phase = .needsAccess; return }
                refreshAlbumIDs(); recompute()
                let assets: [PHAsset]
                if case .album(let id) = settings.source {
                    assets = PhotoLibrary.assets(inAlbum: id, includeVideos: settings.includeVideos)
                } else {
                    assets = PhotoLibrary.fetchMedia(since: scope.since, includeVideos: settings.includeVideos)
                }
                items = assets.filter { a in
                    guard let r = results[a.localIdentifier] else { return true }
                    return r.modified != a.modificationDate || r.version < AssetResult.pipelineVersion
                }.map { .asset($0) }
            }
            await run(items)
        }
    }

    /// Dateien importieren und sofort analysieren.
    func importFiles(_ urls: [URL]) {
        let ids = ImportStore.importFiles(urls)
        guard !ids.isEmpty else { return }
        if settings.source != .imported { setSource(.imported) }
        guard phase != .scanning, phase != .refining else { return }
        task = Task { await run(ids.map { .file($0) }) }
    }

    private func run(_ todo: [WorkItem]) async {
            phase = .scanning
            total = todo.count
            processed = 0

            let t = settings.t, net = settings.allowICloud
            let nudity = self.nudity, person = self.person, clip = self.clip
            let width = max(1, min(6, settings.concurrency))
            let handledIDs = Set(results.values.filter(\.handled).map(\.id))

            await withTaskGroup(of: AssetResult?.self) { group in
                var it = todo.makeIterator()
                func enqueue() {
                    guard let item = it.next() else { return }
                    group.addTask {
                        var r: AssetResult?
                        switch item {
                        case .asset(let a):
                            r = await Self.analyze(a, t: t, net: net, nudity: nudity, person: person, clip: clip)
                        case .file(let id):
                            r = await Self.analyzeFile(id, t: t, nudity: nudity, person: person, clip: clip)
                        }
                        if let id = r?.id { r?.handled = handledIDs.contains(id) }
                        return r
                    }
                }
                for _ in 0..<width { enqueue() }
                while let r = await group.next() {
                    if let r { results[r.id] = r; printCache[r.id] = nil }
                    processed += 1
                    if processed % 100 == 0 { save(); recompute() }
                    if Task.isCancelled { group.cancelAll(); break }
                    enqueue()
                }
            }
            save(); recompute()
            phase = .done
    }

    nonisolated private static func analyzeFile(_ id: String, t: Thresholds, nudity: NudityAnalyzer,
                                                person: PersonAnalyzer, clip: ClipAnalyzer) async -> AssetResult? {
        guard let url = ImportStore.url(for: id), let img = ImageLoader.analysisImage(fileURL: url) else { return nil }
        var r = AssetResult(id: id, modified: nil)
        r.hasCamera = img.hasCamera
        await analyzeFrames([img.cg], into: &r, t: t, nudity: nudity, person: person, clip: clip)
        return r
    }

    nonisolated private static func analyze(_ asset: PHAsset, t: Thresholds, net: Bool,
                                            nudity: NudityAnalyzer, person: PersonAnalyzer, clip: ClipAnalyzer) async -> AssetResult? {
        var r = AssetResult(id: asset.localIdentifier, modified: asset.modificationDate)
        r.isScreenshot = asset.mediaSubtypes.contains(.photoScreenshot)
        r.isVideo = asset.mediaType == .video

        let frames: [CGImage]
        if r.isVideo {
            guard let v = await ImageLoader.videoFrames(for: asset, allowNetwork: net) else { return nil }
            frames = v.frames
            r.hasCamera = v.hasCamera
            let ratio = Double(asset.pixelHeight) / Double(max(asset.pixelWidth, 1))
            r.isPortraitVideoish = ratio > 1.6   // 9:16 ≈ 1,78
        } else {
            guard let img = await ImageLoader.analysisImage(for: asset, allowNetwork: net) else { return nil }
            frames = [img.cg]
            r.hasCamera = img.hasCamera
        }

        await analyzeFrames(frames, into: &r, t: t, nudity: nudity, person: person, clip: clip)
        return r
    }

    /// Jedes Einzelbild prüfen, Ergebnisse zusammenführen (Maximum je Signal).
    nonisolated private static func analyzeFrames(_ frames: [CGImage], into r: inout AssetResult, t: Thresholds,
                                                  nudity: NudityAnalyzer, person: PersonAnalyzer, clip: ClipAnalyzer) async {
        var texts: [String] = []
        for f in frames {
            if let s = await nudity.appleSensitive(f) { r.sensitive = (r.sensitive ?? false) || s }
            if let m = nudity.modelScores(f) {
                r.nsfwScore = max(r.nsfwScore ?? 0, m.nude)
                r.sexyScore = max(r.sexyScore ?? 0, m.sexy)
            }
            if let out = person.analyze(f, thresholds: t) {
                r.person = Self.merge(r.person, out.signals)
                r.facePrints = Array((r.facePrints + out.facePrints).prefix(6))
            }
            if let p = clip.probabilities(f) {
                r.clipWoman = max(r.clipWoman ?? 0, p["woman"] ?? 0)
                r.clipMan = max(r.clipMan ?? 0, p["man"] ?? 0)
            }
            // Text nur dort lesen, wo Chats/Wasserzeichen wahrscheinlich sind (spart viel Zeit)
            if r.isScreenshot || !r.hasCamera, let txt = TextAnalyzer.recognize(f) { texts.append(txt) }
        }
        if !texts.isEmpty { r.ocrText = texts.joined(separator: "\n") }
    }

    nonisolated private static func merge(_ a: PersonSignals?, _ b: PersonSignals) -> PersonSignals {
        guard var m = a else { return b }
        m.faces = max(m.faces, b.faces)
        m.bodies = max(m.bodies, b.bodies)
        m.bestBodyConfidence = max(m.bestBodyConfidence, b.bestBodyConfidence)
        m.poseJoints = max(m.poseJoints, b.poseJoints)
        m.hands = max(m.hands, b.hands)
        m.maskCoverage = max(m.maskCoverage, b.maskCoverage)
        m.labels.merge(b.labels) { max($0, $1) }
        return m
    }

    // MARK: - Stufe 2: Feinprüfung (Apple Intelligence, auf dem Gerät)

    func refine() {
        guard LLMJudge.isAvailable, phase != .scanning, phase != .refining else { return }
        let ids = refineCandidates
        task = Task {
            phase = .refining
            total = ids.count
            processed = 0
            let custom = settings.custom
            let verify = settings.llmVerify
            for id in ids {
                if Task.isCancelled { break }
                guard var r = results[id], let cg = await Self.refineImage(id, allowNetwork: settings.allowICloud)
                else { processed += 1; continue }

                var keys: [String] = []
                if verify {
                    if heuristic(r, .otherPeople) { keys.append(LLMJudge.qPerson) }
                    if heuristic(r, .revealing) || (r.person.map { PersonAnalyzer.isPerson($0, settings.t) } ?? false) {
                        keys.append(LLMJudge.qRevealing)
                    }
                    if r.isScreenshot && heuristic(r, .chats) { keys.append(LLMJudge.qChat) }
                }
                let customScope = settings.llmAllPhotos || heuristic(r, .otherPeople) || r.isScreenshot || !r.hasCamera
                if customScope { keys += custom.map { $0.id.uuidString } }
                if settings.womenOnly && Self.personBuckets.contains(where: { heuristic(r, $0) }) {
                    keys.append(LLMJudge.qWoman)
                }

                for k in keys where r.llm[k] == nil {
                    guard let q = LLMJudge.question(for: k, custom: custom) else { continue }
                    if let v = await LLMJudge.ask(q, image: cg) { r.llm[k] = v }
                }
                results[id] = r
                processed += 1
                if processed % 20 == 0 { save(); recompute() }
            }
            save(); recompute()
            phase = .done
        }
    }

    /// Für Fotos das Bild, für Videos das mittlere Einzelbild.
    private static func refineImage(_ id: String, allowNetwork: Bool) async -> CGImage? {
        if let url = ImportStore.url(for: id) { return ImageLoader.analysisImage(fileURL: url, maxPixel: 768)?.cg }
        guard let asset = PhotoLibrary.assets([id]).first else { return nil }
        if asset.mediaType == .video {
            return await ImageLoader.videoFrames(for: asset, positions: [0.5], maxPixel: 768, allowNetwork: allowNetwork)?.frames.first
        }
        return await ImageLoader.analysisImage(for: asset, maxPixel: 768, allowNetwork: allowNetwork)?.cg
    }

    func isVideo(_ id: String) -> Bool { results[id]?.isVideo ?? false }

    func cancel() { task?.cancel() }

    // MARK: - Aktionen

    func markHandled(_ ids: [String]) {
        for id in ids { results[id]?.handled = true }
        save(); recompute()
    }

    func delete(_ ids: [String]) async throws {
        let files = ids.filter { $0.hasPrefix("file:") }
        ImportStore.remove(files)
        try await PhotoLibrary.delete(ids.filter { !$0.hasPrefix("file:") })
        for id in ids { results[id] = nil; printCache[id] = nil }
        save(); recompute()
    }

    func resetCache() {
        results = [:]; printCache = [:]
        try? FileManager.default.removeItem(at: storeURL)
        recompute()
        phase = .idle
    }

    /// Antworten einer gelöschten/geänderten eigenen Kategorie verwerfen.
    func clearLLMAnswers(for key: String) {
        for id in results.keys { results[id]?.llm[key] = nil }
        save(); recompute()
    }

    // MARK: - Speicher

    private func persistSettings() {
        if let d = try? JSONEncoder().encode(settings) { UserDefaults.standard.set(d, forKey: "settings") }
    }

    private func load() {
        guard let d = try? Data(contentsOf: storeURL),
              let list = Lenient.decodeList(d, defaults: AssetResult(id: "")) else { return }
        results = Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
        if !results.isEmpty { phase = .done }
    }

    private func save() {
        let list = Array(results.values)
        let url = storeURL
        Task.detached(priority: .utility) {
            if let d = try? JSONEncoder().encode(list) {
                try? d.write(to: url, options: [.atomic, .completeFileProtection])
            }
        }
    }
}
