import AVFoundation
import ImageIO
import Photos
import UIKit

struct LoadedImage {
    let cg: CGImage
    let hasCamera: Bool   // TIFF-Make oder EXIF-Objektiv vorhanden → mit einer Kamera aufgenommen
}

enum ImageLoader {
    /// Richtig ausgerichtetes, verkleinertes Bild für die Analyse + Metadaten.
    static func analysisImage(for asset: PHAsset, maxPixel: Int = 1024, allowNetwork: Bool) async -> LoadedImage? {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let data: Data? = await withCheckedContinuation { cont in
            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, _, _, _ in
                cont.resume(returning: data)
            }
        }
        guard let data, let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }

        let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
        let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let hasCamera = tiff?[kCGImagePropertyTIFFMake] != nil || exif?[kCGImagePropertyExifLensModel] != nil

        let thumbOpts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, thumbOpts as CFDictionary) else { return nil }
        return LoadedImage(cg: cg, hasCamera: hasCamera)
    }

    /// Einzelbilder aus einem Video (Standard: bei 10 %, 50 %, 90 % der Länge) + Kamera-Metadaten.
    static func videoFrames(for asset: PHAsset, positions: [Double] = [0.1, 0.5, 0.9],
                            maxPixel: Int = 1024, allowNetwork: Bool) async -> (frames: [CGImage], hasCamera: Bool)? {
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = allowNetwork
        options.deliveryMode = .fastFormat
        options.version = .current
        let av: AVAsset? = await withCheckedContinuation { cont in
            PHImageManager.default().requestAVAsset(forVideo: asset, options: options) { av, _, _ in
                cont.resume(returning: av)
            }
        }
        guard let av else { return nil }

        let meta = (try? await av.load(.metadata)) ?? []
        let cameraIDs: Set<AVMetadataIdentifier> = [.quickTimeMetadataMake, .quickTimeMetadataModel, .commonIdentifierMake]
        let hasCamera = meta.contains { $0.identifier.map(cameraIDs.contains) ?? false }

        let gen = AVAssetImageGenerator(asset: av)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxPixel, height: maxPixel)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        let duration = asset.duration
        var frames: [CGImage] = []
        for p in positions {
            let t = CMTime(seconds: max(0, duration * p), preferredTimescale: 600)
            if let img = try? await gen.image(at: t).image { frames.append(img) }
        }
        return frames.isEmpty ? nil : (frames, hasCamera)
    }

    static func thumbnail(for asset: PHAsset, side: CGFloat) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.isNetworkAccessAllowed = false
        let scale = await UIScreen.main.scale
        let size = CGSize(width: side * scale, height: side * scale)
        return await withCheckedContinuation { cont in
            var resumed = false
            PHImageManager.default().requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { img, info in
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
                let failed = info?[PHImageErrorKey] != nil || (info?[PHImageCancelledKey] as? Bool ?? false)
                if (!degraded || failed) && !resumed { resumed = true; cont.resume(returning: img) }
            }
        }
    }

    static func cgImage(from data: Data, maxPixel: Int = 1024) -> CGImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let o: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(src, 0, o as CFDictionary)
    }
}
