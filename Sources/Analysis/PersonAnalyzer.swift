import CoreGraphics
import CoreVideo
import Vision

/// Menschen auch ohne Gesicht + Gesichts-Fingerabdrücke + freizügige Labels.
/// Alles Vision-Framework, läuft lokal auf der Neural Engine.
final class PersonAnalyzer: @unchecked Sendable {

    static let bodyCandidates = [
        "people", "adult", "child", "baby", "crowd", "portrait", "selfie",
        "hand", "foot", "leg", "arm", "finger", "toe", "skin", "tattoo", "beard", "hair"
    ]
    static let revealingCandidates = [
        "swimwear", "bikini", "swimsuit", "lingerie", "underwear", "brassiere", "bra", "shirtless", "swimming_pool", "beach"
    ]
    /// Labels, die allein reichen, um „freizügig“ vorzuschlagen (Strand/Pool nur als Zusatz).
    static let revealingStrong: Set<String> = ["swimwear", "bikini", "swimsuit", "lingerie", "underwear", "brassiere", "bra", "shirtless"]

    let bodyLabels: Set<String>
    let revealingLabels: Set<String>

    init() {
        let supported = Set((try? VNClassifyImageRequest().supportedIdentifiers()) ?? [])
        bodyLabels = Set(Self.bodyCandidates).intersection(supported)
        revealingLabels = Set(Self.revealingCandidates).intersection(supported)
    }

    struct Output {
        var signals: PersonSignals
        var facePrints: [Data]
    }

    func analyze(_ image: CGImage, thresholds: Thresholds) -> Output? {
        let handler = VNImageRequestHandler(cgImage: image, options: [:])

        let faces = VNDetectFaceRectanglesRequest()
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let pose = VNDetectHumanBodyPoseRequest()
        let hands = VNDetectHumanHandPoseRequest()
        hands.maximumHandCount = 4
        let classify = VNClassifyImageRequest()
        let segment = VNGeneratePersonSegmentationRequest()
        segment.qualityLevel = .fast
        segment.outputPixelFormat = kCVPixelFormatType_OneComponent8

        do { try handler.perform([faces, humans, pose, hands, classify, segment]) } catch { return nil }

        var s = PersonSignals()
        let faceObs = faces.results ?? []
        s.faces = faceObs.count
        let bodyObs = humans.results ?? []
        s.bodies = bodyObs.count
        s.bestBodyConfidence = bodyObs.map(\.confidence).max() ?? 0
        s.poseJoints = (pose.results ?? []).map { obs in
            ((try? obs.recognizedPoints(.all)) ?? [:]).values.filter { $0.confidence >= thresholds.jointConfidence }.count
        }.max() ?? 0
        s.hands = hands.results?.count ?? 0
        if let mask = segment.results?.first?.pixelBuffer { s.maskCoverage = Self.coverage(of: mask) }

        let wanted = bodyLabels.union(revealingLabels)
        for obs in classify.results ?? [] where wanted.contains(obs.identifier) && obs.confidence >= 0.05 {
            s.labels[obs.identifier] = obs.confidence
        }

        // Gesichts-Fingerabdrücke (max. 6 größte Gesichter)
        let biggest = faceObs.sorted { $0.boundingBox.width * $0.boundingBox.height > $1.boundingBox.width * $1.boundingBox.height }.prefix(6)
        let prints = biggest.compactMap { Self.facePrint(of: $0.boundingBox, in: image) }
        return Output(signals: s, facePrints: prints)
    }

    // MARK: Gesichter

    /// Schneidet das Gesicht (mit Rand) aus und erzeugt einen Feature-Print.
    /// Hinweis: generischer Bild-Fingerabdruck, keine biometrische Gesichtserkennung –
    /// reicht für „ähnlich wie Referenz“, erzeugt aber Fehltreffer. Schwelle in den Einstellungen.
    static func facePrint(of box: CGRect, in image: CGImage) -> Data? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        var r = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
        r = r.insetBy(dx: -r.width * 0.2, dy: -r.height * 0.2).intersection(CGRect(x: 0, y: 0, width: w, height: h))
        guard r.width >= 40, r.height >= 40, let crop = image.cropping(to: r.integral) else { return nil }
        let req = VNGenerateImageFeaturePrintRequest()
        do {
            try VNImageRequestHandler(cgImage: crop, options: [:]).perform([req])
            guard let obs = req.results?.first else { return nil }
            return try NSKeyedArchiver.archivedData(withRootObject: obs, requiringSecureCoding: true)
        } catch { return nil }
    }

    /// Größtes Gesicht eines Referenzfotos.
    static func referencePrint(from image: CGImage) -> Data? {
        let req = VNDetectFaceRectanglesRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        guard let face = req.results?.max(by: { $0.boundingBox.width < $1.boundingBox.width }) else { return nil }
        return facePrint(of: face.boundingBox, in: image)
    }

    static func decode(_ data: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: data)
    }

    static func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return d
    }

    // MARK: Bewertung

    static func score(_ s: PersonSignals, _ t: Thresholds) -> Float {
        var parts: [Float] = []
        if s.faces > 0 { parts.append(0.95) }
        if s.bodies > 0 { parts.append(min(0.9, max(0.5, s.bestBodyConfidence))) }
        if s.poseJoints >= t.minJoints { parts.append(min(0.9, 0.5 + Float(s.poseJoints) * 0.04)) }
        if s.hands > 0 { parts.append(0.7) }
        if s.maskCoverage >= t.minMaskCoverage { parts.append(min(0.85, 0.45 + s.maskCoverage * 2)) }
        let body = s.labels.filter { bodyCandidates.contains($0.key) }.values.max() ?? 0
        if body >= t.minLabelConfidence { parts.append(min(0.9, body + 0.2)) }
        return 1 - parts.reduce(1) { $0 * (1 - $1) }
    }

    static func isPerson(_ s: PersonSignals, _ t: Thresholds) -> Bool { score(s, t) >= t.minScore }

    static func revealingScore(_ s: PersonSignals) -> Float {
        s.labels.filter { revealingStrong.contains($0.key) }.values.max() ?? 0
    }

    static func reasons(_ s: PersonSignals, _ t: Thresholds) -> [String] {
        var r: [String] = []
        if s.faces > 0 { r.append("\(s.faces) Gesicht(er)") }
        if s.bodies > 0 { r.append("Körper erkannt") }
        if s.poseJoints >= t.minJoints { r.append("Pose: \(s.poseJoints) Gelenke") }
        if s.hands > 0 { r.append("\(s.hands) Hand/Hände") }
        if s.maskCoverage >= t.minMaskCoverage { r.append("Personenfläche \(Int(s.maskCoverage * 100)) %") }
        for (k, v) in s.labels.sorted(by: { $0.value > $1.value }) where v >= t.minLabelConfidence {
            r.append("„\(k)“ \(Int(v * 100)) %")
        }
        return r
    }

    private static func coverage(of buffer: CVPixelBuffer) -> Float {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return 0 }
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let stride = CVPixelBufferGetBytesPerRow(buffer)
        let p = base.assumingMemoryBound(to: UInt8.self)
        var hit = 0
        for y in 0..<h {
            let row = p + y * stride
            for x in 0..<w where row[x] > 127 { hit += 1 }
        }
        return w * h == 0 ? 0 : Float(hit) / Float(w * h)
    }
}
