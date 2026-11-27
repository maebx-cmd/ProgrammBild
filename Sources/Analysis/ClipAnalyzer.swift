import CoreGraphics
import CoreML
import Foundation
import Vision

/// Mann/Frau-Einschätzung mit Apples MobileCLIP (S0), komplett auf dem Gerät.
/// Der Bild-Encoder liegt als `CLIPImage.mlmodelc` im Bundle, die Klassen
/// (Frau / Mann / keine Person) als vorberechnete Text-Embeddings in `CLIPClasses.json`.
/// Es ist eine Einschätzung nach Aussehen – Fehler sind möglich, die Schwelle ist einstellbar.
final class ClipAnalyzer: @unchecked Sendable {

    private struct ClassFile: Decodable {
        struct Entry: Decodable { let name: String; let embedding: [Float] }
        let logitScale: Float
        let classes: [Entry]
    }

    private let model: VNCoreMLModel?
    private let classes: [(name: String, vec: [Float])]
    private let scale: Float

    init() {
        var m: VNCoreMLModel?
        if let url = Bundle.main.url(forResource: "CLIPImage", withExtension: "mlmodelc") {
            let cfg = MLModelConfiguration()
            cfg.computeUnits = .all
            if let ml = try? MLModel(contentsOf: url, configuration: cfg) { m = try? VNCoreMLModel(for: ml) }
        }
        model = m
        if let url = Bundle.main.url(forResource: "CLIPClasses", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(ClassFile.self, from: data) {
            classes = file.classes.map { ($0.name, $0.embedding) }
            scale = file.logitScale
        } else {
            classes = []
            scale = 100
        }
    }

    var isAvailable: Bool { model != nil && !classes.isEmpty }

    /// Wahrscheinlichkeiten je Klasse („woman“, „man“, „none“), Summe 1.
    func probabilities(_ image: CGImage) -> [String: Float]? {
        guard let model, !classes.isEmpty else { return nil }
        let req = VNCoreMLRequest(model: model)
        req.imageCropAndScaleOption = .centerCrop
        do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([req]) } catch { return nil }
        guard let obs = req.results?.first as? VNCoreMLFeatureValueObservation,
              let arr = obs.featureValue.multiArrayValue else { return nil }

        var v = [Float](repeating: 0, count: arr.count)
        for i in 0..<arr.count { v[i] = arr[i].floatValue }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        guard norm > 0 else { return nil }
        v = v.map { $0 / norm }

        let logits = classes.map { c -> Float in
            guard c.vec.count == v.count else { return 0 }
            var dot: Float = 0
            for i in 0..<v.count { dot += v[i] * c.vec[i] }
            return dot * scale
        }
        let mx = logits.max() ?? 0
        let ex = logits.map { exp($0 - mx) }
        let sum = ex.reduce(0, +)
        var out: [String: Float] = [:]
        for (i, c) in classes.enumerated() { out[c.name] = ex[i] / sum }
        return out
    }
}
