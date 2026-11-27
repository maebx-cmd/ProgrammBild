import Foundation

// MARK: - Kategorien

enum ScanCategory: String, CaseIterable, Identifiable, Codable {
    case nude          // Apple SensitiveContentAnalysis (+ optionales eigenes Modell)
    case revealing     // freizügig, aber nicht nackt (Bademode, Unterwäsche)
    case otherPeople   // Menschen, die nicht zu den Referenzpersonen gehören
    case chats         // Screenshots von Chats, Dating-Apps, Profilen
    case social        // gespeichert aus TikTok/Instagram/Reels (Wasserzeichen, Hochformat-Video)
    case received      // ohne Kamera-Metadaten → empfangen (WhatsApp, Snapchat …)

    var id: String { rawValue }

    var title: String {
        switch self {
        case .nude:        return "Mögliche Nacktbilder"
        case .revealing:   return "Freizügig"
        case .otherPeople: return "Andere Personen"
        case .chats:       return "Chats & App-Screenshots"
        case .social:      return "Social-Media-Speicherungen"
        case .received:    return "Empfangen"
        }
    }

    var subtitle: String {
        switch self {
        case .nude:        return "Apple-Erkennung sensibler Inhalte"
        case .revealing:   return "Bademode, Unterwäsche, viel Haut"
        case .otherPeople: return "Nicht du oder deine Referenzpersonen"
        case .chats:       return "Text im Bild + deine Stichwörter"
        case .social:      return "TikTok, Reels, Instagram – auch Videos"
        case .received:    return "Keine Kamera-Daten, kein Social-Media-Logo"
        }
    }

    var symbol: String {
        switch self {
        case .nude:        return "eye.slash.fill"
        case .revealing:   return "figure.pool.swim"
        case .otherPeople: return "person.2.fill"
        case .chats:       return "bubble.left.and.text.bubble.right.fill"
        case .social:      return "play.rectangle.on.rectangle.fill"
        case .received:    return "tray.and.arrow.down.fill"
        }
    }
}

/// Eigene Kategorie, die das Sprachmodell auf dem Gerät prüft.
struct CustomCategory: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var question: String   // z. B. „Wurde das Foto in einer Bar oder auf einer Party aufgenommen?“
}

/// Ein Eintrag in der Startseite / Navigation.
enum Bucket: Hashable, Identifiable {
    case builtin(ScanCategory)
    case custom(UUID)
    var id: String {
        switch self {
        case .builtin(let c): return c.rawValue
        case .custom(let u):  return u.uuidString
        }
    }
}

// MARK: - Analyse-Ergebnisse

struct PersonSignals: Codable, Hashable {
    var faces: Int = 0
    var bodies: Int = 0
    var bestBodyConfidence: Float = 0
    var poseJoints: Int = 0
    var hands: Int = 0
    var maskCoverage: Float = 0
    var labels: [String: Float] = [:]
}

struct AssetResult: Codable, Hashable, Identifiable {
    static let pipelineVersion = 3

    let id: String                 // PHAsset.localIdentifier
    var modified: Date?
    var version = AssetResult.pipelineVersion
    var handled = false            // verschoben/ignoriert/gelöscht

    var sensitive: Bool?           // Apple
    var nsfwScore: Float?          // eigenes Modell (optional gebündelt)
    var person: PersonSignals?
    var facePrints: [Data] = []    // archivierte VNFeaturePrintObservation je Gesicht
    var isScreenshot = false
    var isVideo = false
    var isPortraitVideoish = false  // Hochformat ~9:16 (typisch TikTok/Reels)
    var hasCamera = true
    var ocrText: String?           // kleingeschrieben, nur lokal gespeichert
    var llm: [String: Bool] = [:]  // Antworten der Feinprüfung (Schlüssel = Frage-ID)
}

// MARK: - Einstellungen

struct Thresholds: Codable, Equatable {
    var minScore: Float = 0.55
    var minJoints: Int = 3
    var jointConfidence: Float = 0.3
    var minMaskCoverage: Float = 0.04
    var minLabelConfidence: Float = 0.25
    var revealingLabel: Float = 0.3
    var nsfwModel: Float = 0.7
    var faceMatchDistance: Float = 0.6   // kleiner = strenger „ist dieselbe Person“
}

struct ReferenceFace: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var print: Data
}

struct AppSettings: Codable, Equatable {
    var t = Thresholds()
    var keywords: [String] = [
        "tinder", "bumble", "hinge", "lovoo", "badoo", "parship", "onlyfans",
        "instagram", "snapchat", "telegram", "schatz", "vermiss", "süße", "kuss", "date"
    ]
    var socialMarkers: [String] = [
        "tiktok", "instagram", "reels", "capcut", "youtube", "shorts", "snapchat", "pinterest", "@"
    ]
    var womenOnly = false               // Personen-Kategorien auf Frauen eingrenzen (Apple Intelligence)
    var includeVideos = true
    var references: [ReferenceFace] = []
    var facelessCountsAsOther = true     // Körper ohne Gesicht → „Andere Personen“
    var custom: [CustomCategory] = []
    var llmVerify = true                 // Feinprüfung der Treffer
    var llmAllPhotos = false             // eigene Kategorien auf alle Fotos statt nur Kandidaten
    var appLock = true
    var allowICloud = false
    var blurPreviews = true
    var concurrency = 3
}

enum ScanScope: String, CaseIterable, Identifiable, Codable {
    case all, last30, last365
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: return "Alle"
        case .last30: return "30 Tage"
        case .last365: return "1 Jahr"
        }
    }
    var since: Date? {
        switch self {
        case .all: return nil
        case .last30: return Calendar.current.date(byAdding: .day, value: -30, to: .now)
        case .last365: return Calendar.current.date(byAdding: .year, value: -1, to: .now)
        }
    }
}

// MARK: - Tolerantes Laden

/// Neue Felder dürfen in alten gespeicherten Daten fehlen: gespeicherte Werte werden
/// über die Standardwerte gelegt, statt beim ersten Update alles zu verlieren.
enum Lenient {
    static func decode<T: Codable>(_ data: Data, defaults: T) -> T? {
        guard let stored = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return merge(stored, defaults: defaults)
    }

    static func decodeList<T: Codable>(_ data: Data, defaults: T) -> [T]? {
        guard let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        return list.compactMap { merge($0, defaults: defaults) }
    }

    private static func merge<T: Codable>(_ stored: [String: Any], defaults: T) -> T? {
        guard let dd = try? JSONEncoder().encode(defaults),
              var base = try? JSONSerialization.jsonObject(with: dd) as? [String: Any] else { return nil }
        for (k, v) in stored {
            if let sub = v as? [String: Any], let b = base[k] as? [String: Any] {
                base[k] = b.merging(sub) { _, new in new }   // eine Ebene tief (z. B. Thresholds)
            } else {
                base[k] = v
            }
        }
        guard let merged = try? JSONSerialization.data(withJSONObject: base) else { return nil }
        return try? JSONDecoder().decode(T.self, from: merged)
    }
}
