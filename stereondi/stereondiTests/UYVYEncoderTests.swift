//  UYVYEncoderTests.swift
//
//  Pure-color sanity tests for UYVYEncoder's BT.709 limited-range
//  RGB → packed UYVY 4:2:2 conversion. Each test fills a small BGRA
//  source texture, runs the compute kernel into an MTLBuffer, and
//  inspects the (U, Y0, V, Y1) byte quartets.
//
//  These are integration tests against the live Metal default library
//  (the kernel is `bgra_to_uyvy_bt709`). On Linux CI MTLCreateSystem-
//  DefaultDevice() returns nil, so each test exits cleanly via an
//  Issue.record + early return.
//
//  Reference values (BT.709 limited, 8-bit):
//    white  (1,1,1) → Y=235, Cb=128, Cr=128
//    black  (0,0,0) → Y=16,  Cb=128, Cr=128
//    red    (1,0,0) → Y≈63,  Cb≈102, Cr≈240
//    blue   (0,0,1) → Y≈32,  Cb≈240, Cr≈118
//
//  We allow ±1 LSB tolerance to absorb fixed-point round-trip in the
//  kernel's `clamp(round(x), 0, 255)` step.

import CoreVideo
import Foundation
import Metal
import Testing
@testable import stereondi

@MainActor
struct UYVYEncoderTests {

    private static let textureWidth = 16
    private static let textureHeight = 4

    @Test
    func encodesSolidWhiteToBT709Limited() throws {
        guard let context = try makeContext() else { return }
        try fillTexture(context.source, color: SIMD4(1, 1, 1, 1))

        let bytes = try runEncode(context: context)

        for (offset, label) in pairOffsets() {
            let (U, Y0, V, Y1) = quartet(bytes, at: offset)
            #expect(approxEqual(Y0, 235), "\(label) Y0=\(Y0), expected 235")
            #expect(approxEqual(Y1, 235), "\(label) Y1=\(Y1), expected 235")
            #expect(approxEqual(U, 128),  "\(label) U=\(U), expected 128")
            #expect(approxEqual(V, 128),  "\(label) V=\(V), expected 128")
        }
    }

    @Test
    func encodesSolidBlackToBT709Limited() throws {
        guard let context = try makeContext() else { return }
        try fillTexture(context.source, color: SIMD4(0, 0, 0, 1))

        let bytes = try runEncode(context: context)

        for (offset, label) in pairOffsets() {
            let (U, Y0, V, Y1) = quartet(bytes, at: offset)
            #expect(approxEqual(Y0, 16),  "\(label) Y0=\(Y0), expected 16")
            #expect(approxEqual(Y1, 16),  "\(label) Y1=\(Y1), expected 16")
            #expect(approxEqual(U, 128),  "\(label) U=\(U), expected 128")
            #expect(approxEqual(V, 128),  "\(label) V=\(V), expected 128")
        }
    }

    @Test
    func encodesPureRedToBT709Limited() throws {
        guard let context = try makeContext() else { return }
        try fillTexture(context.source, color: SIMD4(1, 0, 0, 1))

        let bytes = try runEncode(context: context)

        for (offset, label) in pairOffsets() {
            let (U, Y0, V, Y1) = quartet(bytes, at: offset)
            #expect(approxEqual(Y0, 63),  "\(label) Y0=\(Y0), expected ~63")
            #expect(approxEqual(Y1, 63),  "\(label) Y1=\(Y1), expected ~63")
            #expect(approxEqual(U, 102),  "\(label) U=\(U), expected ~102")
            #expect(approxEqual(V, 240),  "\(label) V=\(V), expected ~240")
        }
    }

    @Test
    func encodesPureBlueToBT709Limited() throws {
        guard let context = try makeContext() else { return }
        try fillTexture(context.source, color: SIMD4(0, 0, 1, 1))

        let bytes = try runEncode(context: context)

        for (offset, label) in pairOffsets() {
            let (U, Y0, V, Y1) = quartet(bytes, at: offset)
            #expect(approxEqual(Y0, 32),  "\(label) Y0=\(Y0), expected ~32")
            #expect(approxEqual(Y1, 32),  "\(label) Y1=\(Y1), expected ~32")
            #expect(approxEqual(U, 240),  "\(label) U=\(U), expected ~240")
            #expect(approxEqual(V, 118),  "\(label) V=\(V), expected ~118")
        }
    }

    // MARK: - Test infrastructure

    private struct Context {
        let device: MTLDevice
        let queue: MTLCommandQueue
        let encoder: UYVYEncoder
        let source: MTLTexture
        let uyvy: MTLBuffer
        let bytesPerRow: Int
    }

    private func makeContext() throws -> Context? {
        guard let device = MTLCreateSystemDefaultDevice() else {
            Issue.record("No Metal device available; skipping UYVYEncoder test")
            return nil
        }
        guard let queue = device.makeCommandQueue() else {
            Issue.record("Metal command queue creation failed; skipping")
            return nil
        }

        let encoder = try UYVYEncoder(device: device)

        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: Self.textureWidth,
            height: Self.textureHeight,
            mipmapped: false
        )
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let source = device.makeTexture(descriptor: descriptor) else {
            Issue.record("Source MTLTexture allocation failed; skipping")
            return nil
        }

        let bytesPerRow = Self.textureWidth * 2
        let length = bytesPerRow * Self.textureHeight
        guard let uyvy = device.makeBuffer(length: length, options: .storageModeShared) else {
            Issue.record("UYVY MTLBuffer allocation failed; skipping")
            return nil
        }

        return Context(device: device,
                       queue: queue,
                       encoder: encoder,
                       source: source,
                       uyvy: uyvy,
                       bytesPerRow: bytesPerRow)
    }

    /// Fills `texture` (.bgra8Unorm) with a solid color in linear 0..1
    /// floating-point space. Channels are written in B, G, R, A byte
    /// order to match the BGRA storage layout the GPU samples.
    private func fillTexture(_ texture: MTLTexture, color: SIMD4<Float>) throws {
        let width = texture.width
        let height = texture.height
        let bytesPerRow = width * 4
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let b = UInt8(clamping: Int((color.z * 255.0).rounded()))
        let g = UInt8(clamping: Int((color.y * 255.0).rounded()))
        let r = UInt8(clamping: Int((color.x * 255.0).rounded()))
        let a = UInt8(clamping: Int((color.w * 255.0).rounded()))
        for y in 0..<height {
            for x in 0..<width {
                let off = y * bytesPerRow + x * 4
                bytes[off]     = b
                bytes[off + 1] = g
                bytes[off + 2] = r
                bytes[off + 3] = a
            }
        }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            texture.replace(region: MTLRegionMake2D(0, 0, width, height),
                            mipmapLevel: 0,
                            withBytes: base,
                            bytesPerRow: bytesPerRow)
        }
    }

    private func runEncode(context: Context) throws -> [UInt8] {
        guard let cb = context.queue.makeCommandBuffer() else {
            Issue.record("Command buffer creation failed")
            return []
        }
        context.encoder.encode(source: context.source,
                               into: context.uyvy,
                               bytesPerRow: context.bytesPerRow,
                               commandBuffer: cb)
        cb.commit()
        cb.waitUntilCompleted()

        let count = context.uyvy.length
        var bytes = [UInt8](repeating: 0, count: count)
        bytes.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            memcpy(base, context.uyvy.contents(), count)
        }
        return bytes
    }

    /// Returns (U, Y0, V, Y1) at byte offset `offset` in the buffer.
    private func quartet(_ bytes: [UInt8], at offset: Int) -> (UInt8, UInt8, UInt8, UInt8) {
        return (bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    /// Sample three UYVY pair offsets per row across rows 0, 1, and 2:
    /// the first, middle and last pair, to catch any misindexing
    /// that would only show up at edges.
    private func pairOffsets() -> [(offset: Int, label: String)] {
        let bytesPerRow = Self.textureWidth * 2
        let pairsPerRow = Self.textureWidth / 2
        let rows = [0, 1, 2]
        let pairCols = [0, pairsPerRow / 2, pairsPerRow - 1]
        var out: [(Int, String)] = []
        for r in rows {
            for c in pairCols {
                out.append((r * bytesPerRow + c * 4, "row=\(r) pair=\(c)"))
            }
        }
        return out
    }

    private func approxEqual(_ value: UInt8, _ expected: UInt8, tolerance: Int = 1) -> Bool {
        return abs(Int(value) - Int(expected)) <= tolerance
    }
}
