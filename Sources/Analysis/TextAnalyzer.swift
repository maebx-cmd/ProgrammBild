import CoreGraphics
import Vision

/// Liest Text aus Screenshots/empfangenen Bildern – Vision-OCR, komplett lokal.
enum TextAnalyzer {
    static func recognize(_ image: CGImage) -> String? {
        let req = VNRecognizeTextRequest()
        req.recognitionLevel = .accurate
        req.recognitionLanguages = ["de-DE", "en-US"]
        req.usesLanguageCorrection = false
        do {
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        } catch { return nil }
        let lines = (req.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.isEmpty ? "" : lines.joined(separator: "\n").lowercased()
    }

    static func hits(in text: String?, keywords: [String]) -> [String] {
        guard let text, !text.isEmpty else { return [] }
        return keywords.filter { k in
            let k = k.trimmingCharacters(in: .whitespaces).lowercased()
            return !k.isEmpty && text.contains(k)
        }
    }
}
