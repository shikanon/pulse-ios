import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates a bounded game copy before upload. Animated inputs stay animated;
/// a failed conversion never silently substitutes the first frame.
enum GameImageOptimizer {
    struct Prepared: Sendable {
        let data: Data
        let fileName: String
        let mediaType: String
    }

    static func prepare(data: Data, fileName: String, mediaType: String, maximumBytes: Int) throws -> Prepared {
        guard data.count <= PrivateAssetUploadPolicy.maximumBytes, maximumBytes > 0 else {
            throw PulseAPIError(message: "This material is too large. Choose a smaller file.")
        }
        guard mediaType.hasPrefix("image/") else {
            guard data.count <= maximumBytes else {
                throw PulseAPIError(message: "This audio or video exceeds the remaining game budget. Choose a shorter or compressed file.")
            }
            return Prepared(data: data, fileName: fileName, mediaType: mediaType)
        }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let sourceType = CGImageSourceGetType(source),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16384, height <= 16384 else {
            throw PulseAPIError(message: "This image could not be prepared. Choose another image or GIF.")
        }
        let count = CGImageSourceGetCount(source)
        guard count > 0, count <= 300 else {
            throw PulseAPIError(message: "This animation has too many frames. Choose a shorter GIF.")
        }
        let animated = count > 1
        let originalType = sourceType as String
        let webReady = [UTType.gif.identifier, UTType.png.identifier, UTType.jpeg.identifier, UTType.webP.identifier].contains(originalType)
        let limit = animated ? 512 : 1024
        if webReady && data.count <= maximumBytes && max(width, height) <= limit {
            let type = UTType(originalType)
            return Prepared(data: data, fileName: renamed(fileName, extension: type?.preferredFilenameExtension ?? "png"), mediaType: type?.preferredMIMEType ?? mediaType)
        }
        let opaquePhoto = originalType == UTType.jpeg.identifier ||
            ((originalType == UTType.heic.identifier || originalType == UTType.heif.identifier) && properties[kCGImagePropertyHasAlpha] as? Bool != true)
        let outputType = animated ? UTType.gif : (opaquePhoto ? UTType.jpeg : UTType.png)
        let outputBudget = webReady ? min(maximumBytes, data.count) : maximumBytes
        let sizes = animated ? [512, 384, 256, 192, 128, 96] : [1024, 768, 512, 384, 256, 192, 128]
        for size in sizes {
            try Task.checkCancellation()
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, outputType.identifier as CFString, count, nil) else { break }
            if animated {
                let global = CGImageSourceCopyProperties(source, nil) as? [CFString: Any]
                let gif = global?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                let loop = gif?[kCGImagePropertyGIFLoopCount] as? Int ?? 0
                CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: loop]] as CFDictionary)
            }
            for index in 0..<count {
                try Task.checkCancellation()
                try autoreleasepool {
                    let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                        kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: min(size, max(width, height)),
                        kCGImageSourceShouldCacheImmediately: true]
                    guard let image = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else {
                        throw PulseAPIError(message: "An animation frame could not be read. Choose another GIF.")
                    }
                    var frameProperties: [CFString: Any] = [:]
                    if outputType == UTType.jpeg {
                        frameProperties[kCGImageDestinationLossyCompressionQuality] = 0.82
                    }
                    if animated {
                        let frame = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
                        let gif = frame?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
                        let png = frame?[kCGImagePropertyPNGDictionary] as? [CFString: Any]
                        let delay = (gif?[kCGImagePropertyGIFUnclampedDelayTime] as? Double)
                            ?? (gif?[kCGImagePropertyGIFDelayTime] as? Double)
                            ?? (png?[kCGImagePropertyAPNGUnclampedDelayTime] as? Double)
                            ?? 0.1
                        frameProperties[kCGImagePropertyGIFDictionary] = [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]
                    }
                    CGImageDestinationAddImage(destination, image, frameProperties as CFDictionary)
                }
            }
            if CGImageDestinationFinalize(destination), output.length <= outputBudget {
                return Prepared(data: output as Data, fileName: renamed(fileName, extension: outputType.preferredFilenameExtension!), mediaType: outputType.preferredMIMEType!)
            }
        }
        throw PulseAPIError(message: "This image cannot fit the game budget while preserving its animation and readability. Choose a shorter GIF or remove another material.")
    }

    private static func renamed(_ name: String, extension suffix: String) -> String {
        ((name as NSString).deletingPathExtension as NSString).lastPathComponent + "." + suffix
    }
}
