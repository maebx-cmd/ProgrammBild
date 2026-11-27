import CoreGraphics
import CoreML
import SensitiveContentAnalysis
import Vision

/// 1) Apples SensitiveContentAnalysis (wie NudeFndr), komplett lokal.
///    Braucht Entitlement + in iOS „Hinweis auf sensible Inhalte“.
/// 2) Ersatz: ein eigenes Core-ML-Modell `NSFW.mlmodelc` im App-Bundle (optional).
///    Greift, wenn (1) nicht verfügbar ist – z. B. falls die Berechtigung beim
///    Sideloaden nicht mitsigniert wird. Ohne gebündeltes Modell bleibt es aus.
final class NudityAnalyzer: @unchecked Sendable {
    private let analyzer = SCSensitivityAnalyzer()
    private let fallback: VNCoreMLModel?

    /// Klassen-Namen gängiger offener NSFW-Klassifizierer (z. B. „nsfw“, „porn“, „hentai“, „sexy“).
    private let nsfwLabels: Set<String> = ["nsfw", "porn", "hentai", "unsafe", "explicit", "nude", "sexy"]

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

    func fallbackScore(_ image: CGImage) -> Float? {
        guard let fallback else { return nil }
        let req = VNCoreMLRequest(model: fallback)
        req.imageCropAndScaleOption = .centerCrop
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return nil }
        let obs = (req.results as? [VNClassificationObservation]) ?? []
        return obs.filter { nsfwLabels.contains($0.identifier.lowercased()) }.map(\.confidence).max() ?? 0
    }
}
