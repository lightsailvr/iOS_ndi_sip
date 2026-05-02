//  GoldenImage.swift
//
//  Helpers for the compositor's golden-image tests.
//
//   - loadReference(named:): reads `<name>.png` from the test bundle's
//     `Goldens/` resource subdirectory.
//   - write(_:named:to:): re-emits a PNG into a directory passed by
//     the test (typically `stereondiTests/Goldens/` resolved from
//     `__FILE__`-relative path or `STEREONDI_GOLDENS_DIR` env var).
//   - compare(_:against:tolerance:): per-pixel max-channel diff. A
//     pixel "fails" when |Δr|, |Δg|, or |Δb| > tolerance * 255. We
//     ignore the alpha channel because the compositor always writes
//     opaque output.
//
//  The reference PNGs are not generated on this Linux CI VM (no Metal
//  available); the test harness has an `--update-references` env-var
//  path so the user runs them once on Mac to seed the goldens.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum GoldenImageError: Error {
    case missingReference(String)
    case decodeFailed(String)
    case dimensionMismatch(referenceSize: CGSize, candidateSize: CGSize)
    case pngEncodeFailed
    case writeFailed(URL, Error?)
    case unsupportedColorFormat
}

struct GoldenComparisonResult {
    let passed: Bool
    let worstChannelDiff: Int
    let failingPixelCount: Int
    let totalPixelCount: Int
}

enum GoldenImage {

    static func loadReference(named name: String,
                              bundle: Bundle = Bundle(for: HelperToken.self)) throws -> CGImage {
        let url = bundle.url(forResource: name,
                             withExtension: "png",
                             subdirectory: "Goldens")
            ?? bundle.url(forResource: name, withExtension: "png")
        guard let url else {
            throw GoldenImageError.missingReference(name)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw GoldenImageError.decodeFailed(url.path)
        }
        return image
    }

    static func write(_ image: CGImage,
                      named name: String,
                      toDirectory directory: URL) throws {
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(name).png")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.png.identifier as CFString,
                                                         1,
                                                         nil) else {
            throw GoldenImageError.pngEncodeFailed
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw GoldenImageError.writeFailed(url, nil)
        }
    }

    static func compare(_ candidate: CGImage,
                        against reference: CGImage,
                        tolerance: Double) -> GoldenComparisonResult {
        let refSize = CGSize(width: reference.width, height: reference.height)
        let candSize = CGSize(width: candidate.width, height: candidate.height)
        guard refSize == candSize else {
            return GoldenComparisonResult(passed: false,
                                          worstChannelDiff: 255,
                                          failingPixelCount: Int(refSize.width * refSize.height),
                                          totalPixelCount: Int(refSize.width * refSize.height))
        }

        guard let refBytes = bgraBytes(from: reference),
              let candBytes = bgraBytes(from: candidate) else {
            return GoldenComparisonResult(passed: false,
                                          worstChannelDiff: 255,
                                          failingPixelCount: Int(refSize.width * refSize.height),
                                          totalPixelCount: Int(refSize.width * refSize.height))
        }

        let totalPixels = reference.width * reference.height
        let threshold = Int((tolerance * 255.0).rounded())
        var worst = 0
        var failing = 0

        refBytes.withUnsafeBytes { refRaw in
            candBytes.withUnsafeBytes { candRaw in
                let refPtr = refRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                let candPtr = candRaw.baseAddress!.assumingMemoryBound(to: UInt8.self)
                for i in 0..<totalPixels {
                    let off = i * 4
                    let dB = abs(Int(refPtr[off]) - Int(candPtr[off]))
                    let dG = abs(Int(refPtr[off + 1]) - Int(candPtr[off + 1]))
                    let dR = abs(Int(refPtr[off + 2]) - Int(candPtr[off + 2]))
                    let pixelWorst = max(dR, max(dG, dB))
                    if pixelWorst > worst { worst = pixelWorst }
                    if pixelWorst > threshold { failing += 1 }
                }
            }
        }

        return GoldenComparisonResult(passed: failing == 0,
                                      worstChannelDiff: worst,
                                      failingPixelCount: failing,
                                      totalPixelCount: totalPixels)
    }

    private static func bgraBytes(from image: CGImage) -> Data? {
        let width = image.width
        let height = image.height
        let bytesPerRow = width * 4
        var data = Data(count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        let success = data.withUnsafeMutableBytes { ptr -> Bool in
            guard let base = ptr.baseAddress,
                  let context = CGContext(data: base,
                                          width: width,
                                          height: height,
                                          bitsPerComponent: 8,
                                          bytesPerRow: bytesPerRow,
                                          space: colorSpace,
                                          bitmapInfo: bitmapInfo) else {
                return false
            }
            context.draw(image,
                         in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return success ? data : nil
    }
}
