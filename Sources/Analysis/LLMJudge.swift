import CoreGraphics
import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

/// Feinprüfung mit Apples Sprachmodell AUF DEM GERÄT (Apple Intelligence, iOS 27, iPhone 15 Pro+).
/// Bewusst nur `SystemLanguageModel.default` – niemals Private Cloud Compute oder
/// ein anderer Anbieter. Das Bild verlässt das iPhone nicht.
///
/// Rückgabe `nil` = keine Aussage (Modell nicht verfügbar, Schutzfilter, Fehler).
/// Für Nacktheit wird das Modell absichtlich NICHT gefragt – das macht die Apple-Erkennung.
enum LLMJudge {

    static var isAvailable: Bool {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return SystemLanguageModel.default.isAvailable
        }
        #endif
        return false
    }

    static var statusText: String {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available: return "Apple Intelligence bereit (auf dem Gerät)"
            case .unavailable(.deviceNotEligible): return "Gerät unterstützt Apple Intelligence nicht"
            case .unavailable(.appleIntelligenceNotEnabled): return "Apple Intelligence in den Einstellungen einschalten"
            case .unavailable(.modelNotReady): return "Modell wird noch geladen …"
            case .unavailable: return "Apple Intelligence nicht verfügbar"
            }
        }
        #endif
        return "Benötigt iOS 27 und Apple Intelligence"
    }

    // Feste Prüffragen der eingebauten Kategorien
    static let qPerson = "person"
    static let qRevealing = "revealing"
    static let qChat = "chat"
    static let qWoman = "woman"

    static func question(for key: String, custom: [CustomCategory]) -> String? {
        switch key {
        case qPerson: return "Ist auf dem Bild ein Mensch oder ein menschlicher Körperteil (z. B. Beine, Hände, Rücken) zu sehen?"
        case qRevealing: return "Trägt eine Person auf dem Bild Bademode oder Unterwäsche oder ist sie auffallend leicht bekleidet?"
        case qWoman: return "Ist auf dem Bild mindestens eine Frau zu sehen?"
        case qChat: return "Zeigt das Bild einen privaten Chatverlauf, eine Dating-App oder das Social-Media-Profil einer Person?"
        default: return custom.first { $0.id.uuidString == key }?.question
        }
    }

    static func ask(_ question: String, image: CGImage) async -> Bool? {
        #if canImport(FoundationModels)
        if #available(iOS 27.0, *) {
            return await Impl.ask(question, image: image)
        }
        #endif
        return nil
    }
}

#if canImport(FoundationModels)
@available(iOS 27.0, *)
private enum Impl {
    @Generable
    struct Verdict {
        @Guide(description: "true, wenn die Frage für dieses Bild mit Ja zu beantworten ist, sonst false")
        var answer: Bool
    }

    static func ask(_ question: String, image: CGImage) async -> Bool? {
        guard SystemLanguageModel.default.isAvailable else { return nil }
        let session = LanguageModelSession(
            model: SystemLanguageModel.default,
            instructions: "Du sortierst private Fotos. Beantworte jede Frage zum Bild nur mit true oder false."
        )
        do {
            // ⚠️ API-PRÜFEN beim ersten Build (iOS-27-SDK): Bildanhänge im Prompt-Builder.
            // Laut WWDC26 lassen sich Anhänge aus CGImage/UIImage/CVPixelBuffer/URL erstellen;
            // der genaue Typname kann abweichen (Xcode-Autovervollständigung).
            let response = try await session.respond(generating: Verdict.self) {
                question
                Attachment(image)
            }
            return response.content.answer
        } catch {
            // u. a. LanguageModelSession.GenerationError.guardrailViolation → keine Aussage
            return nil
        }
    }
}
#endif
