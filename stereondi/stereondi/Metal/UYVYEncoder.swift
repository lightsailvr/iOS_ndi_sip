//  UYVYEncoder.swift
//
//  GPU-side BGRA → packed UYVY 4:2:2 BT.709 limited encoder. Reads
//  the compositor's offscreen render target and writes raw bytes
//  into an MTLBuffer the caller hands in (sized at least
//  bytesPerRow * height bytes). The destination is a buffer (not a
//  texture) because Metal's bgrg422/gbgr422 pixel formats are
//  read-only on Apple silicon, so UYVY has to be assembled byte by
//  byte by the kernel.
//
//  Threadgroup geometry: each thread emits one UYVY pair (two source
//  pixels horizontally). The Metal grid is therefore (width/2 ×
//  height) threads. Source width must be even; this is enforced and
//  documented on `encode(...)`.
//
//  Concurrency note: the encoder is `@MainActor` only because its
//  initializer touches the device's default library. The actual
//  `encode(...)` work is GPU-bound; the caller's command buffer's
//  completion handler is what eventually delivers the bytes to the
//  NDI sender, and that handler runs on a Metal background queue.

import Foundation
import Metal

@MainActor
final class UYVYEncoder {

    enum Error: Swift.Error {
        case defaultLibraryUnavailable
        case kernelFunctionMissing(String)
        case pipelineCreationFailed(Swift.Error)
        case oddSourceWidth(Int)
    }

    private let device: MTLDevice
    private let pipeline: MTLComputePipelineState

    init(device: MTLDevice) throws {
        self.device = device
        guard let library = device.makeDefaultLibrary() else {
            throw Error.defaultLibraryUnavailable
        }
        guard let kernel = library.makeFunction(name: "bgra_to_uyvy_bt709") else {
            throw Error.kernelFunctionMissing("bgra_to_uyvy_bt709")
        }
        do {
            self.pipeline = try device.makeComputePipelineState(function: kernel)
        } catch {
            throw Error.pipelineCreationFailed(error)
        }
    }

    /// Encode `source` into the provided UYVY-formatted MTLBuffer. The
    /// buffer must be at least `bytesPerRow * source.height` bytes.
    /// `bytesPerRow` is typically `source.width * 2`.
    /// Source width must be even (UYVY pairs).
    func encode(source: MTLTexture,
                into uyvyBuffer: MTLBuffer,
                bytesPerRow: Int,
                commandBuffer: MTLCommandBuffer) throws {
        guard source.width % 2 == 0 else {
            throw Error.oddSourceWidth(source.width)
        }

        guard let encoder = commandBuffer.makeComputeCommandEncoder() else {
            return
        }
        encoder.label = "UYVYEncoder"
        encoder.setComputePipelineState(pipeline)
        encoder.setTexture(source, index: 0)
        encoder.setBuffer(uyvyBuffer, offset: 0, index: 0)

        var bprWord = UInt32(bytesPerRow)
        encoder.setBytes(&bprWord, length: MemoryLayout<UInt32>.size, index: 1)

        // Grid is sized in UYVY pairs (width/2) × height. Threadgroup
        // size of 16×16 fits the warp shape on every Apple-silicon
        // GPU we target; non-uniform thread groups are supported on
        // iPad Pro M1+, so dispatchThreads handles ragged edges.
        let pairWidth = source.width / 2
        let height = source.height
        let threadsPerThreadgroup = MTLSize(width: 16, height: 16, depth: 1)
        let threadsPerGrid = MTLSize(width: pairWidth, height: height, depth: 1)

        encoder.dispatchThreads(threadsPerGrid,
                                threadsPerThreadgroup: threadsPerThreadgroup)
        encoder.endEncoding()
    }
}
