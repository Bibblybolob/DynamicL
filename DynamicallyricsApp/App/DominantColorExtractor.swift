import Foundation
import ImageIO
import LyricCore
import UIKit

/// Pulls the dominant color out of album artwork so Album-mode Live
/// Activities can tint themselves per song. Downsampling to a tiny thumbnail
/// makes this effectively free; results are cached per artwork URL.
enum DominantColorExtractor {
    // NSCache is internally thread-safe; the unsafe annotation only silences
    // Swift 6's shared-mutable-state check for the non-Sendable generic.
    private nonisolated(unsafe) static let cache = NSCache<NSURL, RGBBox>()

    @MainActor
    static func cached(for urlString: String) -> RGB? {
        guard let url = URL(string: urlString) else { return nil }
        return cache.object(forKey: url as NSURL)?.value
    }

    /// Extracts (or returns the cached) dominant color for an artwork URL.
    static func extract(from urlString: String) async -> RGB? {
        guard let url = URL(string: urlString) else { return nil }
        if let hit = cache.object(forKey: url as NSURL)?.value { return hit }

        // Network + decode off the main actor. Prefer the same app-group
        // artwork bytes that widgets use, so color and image cannot disagree.
        let sampled: [Double]? = await Task.detached(priority: .utility) { () -> [Double]? in
            let data: Data
            if let cached = await ArtworkRepository.shared.data(for: urlString) {
                data = cached
            } else {
                var request = URLRequest(url: url)
                request.timeoutInterval = 8
                guard let (fetched, response) = try? await URLSession.shared.data(for: request),
                      let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    return nil
                }
                data = fetched
            }
            guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 24,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

            // CGImage byte order is not guaranteed. Draw into a known RGBA
            // bitmap instead of assuming the provider is RGB or BGRA.
            var pixel = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(
                data: &pixel,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return nil }
            context.interpolationQuality = .medium
            context.draw(thumb, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let alpha = Double(pixel[3]) / 255
            guard alpha > 0.05 else { return nil }
            return [
                min(1, Double(pixel[0]) / 255 / alpha),
                min(1, Double(pixel[1]) / 255 / alpha),
                min(1, Double(pixel[2]) / 255 / alpha),
            ]
        }.value

        guard let rgb = sampled else { return nil }
        let color = RGB(r: rgb[0], g: rgb[1], b: rgb[2])
        cache.setObject(RGBBox(value: color), forKey: url as NSURL)
        return color
    }

    private final class RGBBox: NSObject {
        let value: RGB
        init(value: RGB) { self.value = value }
    }
}
