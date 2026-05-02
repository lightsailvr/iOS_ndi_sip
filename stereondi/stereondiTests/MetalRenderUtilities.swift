//  MetalRenderUtilities.swift
//
//  Test helpers for the StereoCompositor golden-image tests:
//
//   - makeRenderTarget(...) — 1920×1080 bgra8Unorm MTLTexture for the
//     compositor to draw into.
//   - makeGradientPixelBuffer(...) — synthetic 960×540 BGRA pixel
//     buffer used as a test "frame" (red horizontal gradient by
//     default; tone customizable per side).
//   - readBackImage(...) — copies a Metal texture's pixels into a
//     CGImage so tests can compare against a bundled reference PNG.
//   - StubVideoFrame — a minimal VideoFrameSource conformance that
//     wraps a CVPixelBuffer for the compositor to sample.

import CoreGraphics
import CoreVideo
import Foundation
import Metal
@testable import stereondi

enum MetalTestSetupError: Error {
    case noMetalDevice
    case noCommandQueue
    case textureCreationFailed
    case pixelBufferCreationFailed(CVReturn)
    case readBackContextFailed
}

enum MetalRenderUtilities {

    static let targetWidth = 1920
    static let targetHeight = 1080
    static let gradientWidth = 960
    static let gradientHeight = 540

    static func makeDevice() throws -> MTLDevice {
        guard let device = MTLCreateSystemDefaultDevice() else {
            throw MetalTestSetupError.noMetalDevice
        }
        return device
    }

    static func makeCommandQueue(device: MTLDevice) throws -> MTLCommandQueue {
        guard let queue = device.makeCommandQueue() else {
            throw MetalTestSetupError.noCommandQueue
        }
        return queue
    }

    static func makeRenderTarget(device: MTLDevice,
                                 width: Int = targetWidth,
                                 height: Int = targetHeight,
                                 pixelFormat: MTLPixelFormat = .bgra8Unorm) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: pixelFormat,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw MetalTestSetupError.textureCreationFailed
        }
        return texture
    }

    enum GradientTone {
        case red
        case green
        case blue

        func color(at u: Double) -> (r: UInt8, g: UInt8, b: UInt8) {
            let v = UInt8(max(0, min(255, Int((u * 255.0).rounded()))))
            switch self {
            case .red:   return (v, 0, 0)
            case .green: return (0, v, 0)
            case .blue:  return (0, 0, v)
            }
        }
    }

    static func makeGradientPixelBuffer(width: Int = gradientWidth,
                                        height: Int = gradientHeight,
                                        tone: GradientTone) throws -> CVPixelBuffer {
        let attrs: [CFString: Any] = [
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ]
        var pb: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault,
                                         width,
                                         height,
                                         kCVPixelFormatType_32BGRA,
                                         attrs as CFDictionary,
                                         &pb)
        guard status == kCVReturnSuccess, let pixelBuffer = pb else {
            throw MetalTestSetupError.pixelBufferCreationFailed(status)
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            throw MetalTestSetupError.pixelBufferCreationFailed(kCVReturnAllocationFailed)
        }
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        for y in 0..<height {
            for x in 0..<width {
                let u = Double(x) / Double(max(width - 1, 1))
                let (r, g, b) = tone.color(at: u)
                let pixel = ptr.advanced(by: y * bytesPerRow + x * 4)
                pixel[0] = b
                pixel[1] = g
                pixel[2] = r
                pixel[3] = 255
            }
        }
        return pixelBuffer
    }

    static func readBackImage(texture: MTLTexture) throws -> CGImage {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.getBytes(base,
                             bytesPerRow: bytesPerRow,
                             from: MTLRegionMake2D(0, 0, width, height),
                             mipmapLevel: 0)
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo: UInt32 = CGBitmapInfo.byteOrder32Little.rawValue
            | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let cgImage = CGImage(width: width,
                                    height: height,
                                    bitsPerComponent: 8,
                                    bitsPerPixel: 32,
                                    bytesPerRow: bytesPerRow,
                                    space: colorSpace,
                                    bitmapInfo: CGBitmapInfo(rawValue: bitmapInfo),
                                    provider: provider,
                                    decode: nil,
                                    shouldInterpolate: false,
                                    intent: .defaultIntent) else {
            throw MetalTestSetupError.readBackContextFailed
        }
        return cgImage
    }
}

// MARK: - Stub frame

/// Minimal VideoFrameSource conformance used in pure-Swift tests
/// (FramePairer logic, compositor goldens). Wraps a CVPixelBuffer
/// without involving the ObjC NDIVideoFrame class.
final class StubVideoFrame: VideoFrameSource {
    let pixelBuffer: CVPixelBuffer
    let width: Int
    let height: Int

    init(pixelBuffer: CVPixelBuffer) {
        self.pixelBuffer = pixelBuffer
        self.width = CVPixelBufferGetWidth(pixelBuffer)
        self.height = CVPixelBufferGetHeight(pixelBuffer)
    }
}
