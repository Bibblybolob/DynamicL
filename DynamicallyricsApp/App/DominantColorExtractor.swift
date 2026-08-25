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

        // Network + decode off the main actor.
        let sampled: [Double]? = await Task.detached(priority: .utility) { () -> [Double]? in
            guard let (data, response) = try? await URLSession.shared.data(from: url),
                  let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let source = CGImageSourceCreateWithData(data as CFData, nil)
            else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 24,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
                  let data = thumb.dataProvider?.data,
                  let bytes = CFDataGetBytePtr(data),
                  thumb.bitsPerPixel == 32 || thumb.bitsPerPixel == 24
            else { return nil }

            let bytesPerPixel = thumb.bitsPerPixel / 8
            var r = 0.0, g = 0.0, b = 0.0, count = 0.0
            for y in stride(from: 0, to: thumb.height, by: 2) {
                for x in stride(from: 0, to: thumb.width, by: 2) {
                    let offset = (y * thumb.bytesPerRow) + (x * bytesPerPixel)
                    // Skip near-transparent pixels.
                    if bytesPerPixel == 4 && bytes[offset + 3] < 32 { continue }
                    r += Double(bytes[offset])
                    g += Double(bytes[offset + 1])
                    b += Double(bytes[offset + 2])
                    count += 1
                }
            }
            guard count > 0 else { return nil }
            return [r / count / 255, g / count / 255, b / count / 255]
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
