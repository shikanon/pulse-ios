import XCTest
import ImageIO
import UniformTypeIdentifiers
@testable import Pulse

final class GameImageOptimizerTests: XCTestCase {
    private func frame(width: Int, red: CGFloat, alpha: CGFloat = 1) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: width, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(red: red, green: 0.3, blue: 1 - red, alpha: alpha)
        context.fill(CGRect(x: 0, y: 0, width: width / 2, height: width))
        return try XCTUnwrap(context.makeImage())
    }

    func testOversizedGIFKeepsFramesTimingLoopAndTransparentBackground() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.gif.identifier as CFString, 2, nil))
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 3]] as CFDictionary)
        for (index, delay) in [0.12, 0.28].enumerated() {
            CGImageDestinationAddImage(destination, try frame(width: 640, red: CGFloat(index)),
                [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: delay]] as CFDictionary)
        }
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try GameImageOptimizer.prepare(data: data as Data, fileName: "cat.jpeg", mediaType: "image/jpeg", maximumBytes: 120_000)
        XCTAssertEqual(result.mediaType, "image/gif")
        XCTAssertEqual(result.fileName, "cat.gif")
        XCTAssertLessThanOrEqual(result.data.count, 120_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        let global = try XCTUnwrap(CGImageSourceCopyProperties(source, nil) as? [CFString: Any])
        XCTAssertEqual((global[kCGImagePropertyGIFDictionary] as? [CFString: Any])?[kCGImagePropertyGIFLoopCount] as? Int, 3)
        var pixels: [Data] = []
        for (index, delay) in [0.12, 0.28].enumerated() {
            let properties = try XCTUnwrap(CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any])
            let gif = try XCTUnwrap(properties[kCGImagePropertyGIFDictionary] as? [CFString: Any])
            XCTAssertEqual(try XCTUnwrap(gif[kCGImagePropertyGIFDelayTime] as? Double), delay, accuracy: 0.02)
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertLessThanOrEqual(image.width, 512)
            XCTAssertEqual(properties[kCGImagePropertyHasAlpha] as? Bool, true)
            pixels.append(try XCTUnwrap(image.dataProvider?.data) as Data)
        }
        XCTAssertNotEqual(pixels[0], pixels[1], "Compression must not repeat the first frame")
    }

    func testLargePNGIsDownsampledWithoutRemovingAlpha() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try frame(width: 2048, red: 1), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try GameImageOptimizer.prepare(data: data as Data, fileName: "doge.png", mediaType: "image/png", maximumBytes: 50_000)
        let source = try XCTUnwrap(CGImageSourceCreateWithData(result.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertLessThanOrEqual(image.width, 1024)
        XCTAssertLessThanOrEqual(result.data.count, 50_000)
        XCTAssertEqual(CGImageSourceGetCount(source), 1)
        XCTAssertEqual(result.mediaType, "image/png")
    }

    func testInvalidImagesAndImpossibleBudgetsFailInsteadOfReturningStaticPlaceholder() {
        XCTAssertThrowsError(try GameImageOptimizer.prepare(data: Data([1, 2, 3]), fileName: "bad.gif", mediaType: "image/gif", maximumBytes: 10_000))
        XCTAssertThrowsError(try GameImageOptimizer.prepare(data: Data(repeating: 1, count: 100), fileName: "large.mp4", mediaType: "video/mp4", maximumBytes: 99))
    }

    func testLargeJPEGStaysJPEGInsteadOfExpandingIntoPNG() throws {
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try frame(width: 2048, red: 1), [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let result = try GameImageOptimizer.prepare(data: data as Data, fileName: "frog.jpg", mediaType: "image/jpeg", maximumBytes: 512 * 1024)
        XCTAssertEqual(result.mediaType, "image/jpeg")
        XCTAssertLessThan(result.data.count, data.length)
    }
}
