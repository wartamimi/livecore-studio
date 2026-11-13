#if os(macOS)
import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Every still-image format this Mac can open (0.61.0). ImageIO decodes the raster formats the
/// system knows (PNG, JPEG, HEIC/HEIF, AVIF, WebP, TIFF, GIF, BMP, ICO, ICNS, TGA, PSD, OpenEXR,
/// JPEG 2000, camera RAW…, depending on the macOS version); vector files (PDF, EPS, SVG on macOS
/// versions whose NSImage reads SVG) are rasterised through NSImage.
public enum ImageFormats {
    /// Types ImageIO can read on this Mac.
    public static let rasterTypes: [UTType] = {
        let ids = (CGImageSourceCopyTypeIdentifiers() as? [String]) ?? []
        return ids.compactMap { UTType($0) }
    }()

    /// Types the open panel offers for image inputs.
    public static let contentTypes: [UTType] = {
        var all: [UTType] = [.image] + rasterTypes + [.pdf, .svg]
        if let eps = UTType("com.adobe.encapsulated-postscript") { all.append(eps) }
        var seen = Set<String>()
        return all.filter { seen.insert($0.identifier).inserted }
    }()

    /// File extensions of all those types (folder scans, drag & drop).
    public static let extensions: Set<String> = {
        var e = Set<String>()
        for t in contentTypes { for x in t.tags[.filenameExtension] ?? [] { e.insert(x.lowercased()) } }
        e.formUnion(["jpg", "jpeg", "png", "heic", "heif", "avif", "tif", "tiff", "gif", "bmp", "webp", "pdf", "svg"])
        return e
    }()

    /// Decodes the first frame / page, at most `maxSide` pixels on the long side.
    public static func decode(_ url: URL, maxSide: Int = 3840) -> CGImage? {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,   // honours EXIF orientation
                kCGImageSourceThumbnailMaxPixelSize: maxSide,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
            if let img = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) { return img }
        }
        return rasterizeVector(url, maxSide: maxSide)
    }

    /// PDF / EPS / SVG: NSImage draws the vector at the target size (long side 1920 by default
    /// for vectors without a useful size).
    private static func rasterizeVector(_ url: URL, maxSide: Int) -> CGImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        var size = image.size
        if size.width < 1 || size.height < 1 { size = NSSize(width: 1920, height: 1080) }
        let longSide = max(size.width, size.height)
        let target = min(Double(maxSide), max(1920, longSide))
        let scale = target / longSide
        let w = max(2, Int(size.width * scale)), h = max(2, Int(size.height * scale))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let g = NSGraphicsContext(cgContext: ctx, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = g
        image.draw(in: NSRect(x: 0, y: 0, width: w, height: h), from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()
    }
}
#endif
