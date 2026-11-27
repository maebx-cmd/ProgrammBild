import CoreGraphics
import CoreML
import SensitiveContentAnalysis
import Vision

/// 1) Apples SensitiveContentAnalysis (wie NudeFndr), komplett lokal.
///    Braucht Entitlement + in iOS „Hinweis auf sensible Inhalte“.
/// 2) Ersatz: Core-ML-Modell `NSFW` im App-Bundle (GantMan nsfw_model, MobileNet v2,
///    Klassen drawings/hentai/neutral/porn/sexy). Wird beim Build automatisch umgewandelt.
///    Für Nacktbilder greift es nur, wenn (1) nicht verfügbar ist (z. B. LiveContainer);
///    „sexy“ hilft immer bei der Kategorie „Freizügig“.
final class NudityAnalyzer: @unchecked Sendable {
    private let analyzer = SCSensitivityAnalyzer()
    private let fallback: VNCoreMLModel?

    private let nudeLabels: Set<String> = ["porn", "hentai", "nsfw", "explicit", "nude"]
    private let sexyLabels: Set<String> = ["sexy"]

    init() {
        if let url = Bundle.main.url(forResource: "NSFW", withExtension: "mlmodelc"),
           let ml = try? MLModel(contentsOf: url, configuration: MLModelConfiguration()) {
            fallback = try? VNCoreMLModel(for: ml)
        } else {
            fallback = nil
        }
    }

    var appleAvailable: Bool { analyzer.analysisPolicy != .disabled }
    var fallbackAvailable: Bool { fallback != nil }

    var statusText: String {
        var s: String
        switch analyzer.analysisPolicy {
        case .disabled: s = "Apple-Erkennung aus – in iOS „Hinweis auf sensible Inhalte“ einschalten."
        case .simpleInterventions: s = "Apple-Erkennung aktiv"
        case .descriptiveInterventions: s = "Apple-Erkennung aktiv (Kommunikationssicherheit)"
        @unknown default: s = "Apple-Erkennung: unbekannter Status"
        }
        s += fallbackAvailable ? " · Ersatzmodell vorhanden" : " · kein Ersatzmodell gebündelt"
        return s
    }

    func appleSensitive(_ image: CGImage) async -> Bool? {
        guard appleAvailable else { return nil }
        return try? await analyzer.analyzeImage(image).isSensitive
    }

    /// (nackt, freizügig) jeweils 0…1, oder nil ohne Modell.
    func modelScores(_ image: CGImage) -> (nude: Float, sexy: Float)? {
        guard let fallback else { return nil }
        let req = VNCoreMLRequest(model: fallback)
        req.imageCropAndScaleOption = .scaleFill   // so wurde das Modell trainiert (224×224, gestaucht)
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return nil }
        let obs = (req.results as? [VNClassificationObservation]) ?? []
        func score(_ set: Set<String>) -> Float {
            obs.filter { set.contains($0.identifier.lowercased()) }.map(\.confidence).reduce(0, +)
        }
        return (min(1, score(nudeLabels)), min(1, score(sexyLabels)))
    }
}
