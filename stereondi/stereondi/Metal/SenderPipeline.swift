//  SenderPipeline.swift
//
//  Wires the StereoCompositor's offscreen 1920×1080 BGRA render
//  target through the UYVYEncoder compute pass into the NDISender's
//  full-bandwidth UYVY 4:2:2 BT.709 limited progressive output.
//
//  The pipeline is intentionally independent of the on-screen render
//  loop: it allocates its own command buffer per frame (still on the
//  shared command queue, so the GPU schedules both the screen and
//  send work together but the send buffer's completion can never
//  stall the screen buffer's `present`).
//
//  Buffer pool: a 3-deep ring of `.shared` MTLBuffers. The SDK's
//  synchronous `NDIlib_send_send_video_v2` copies the frame data into
//  its internal queue before returning, so a 1-deep pool would
//  technically suffice, but a 3-deep ring is cheap insurance against
//  GPU completion handlers landing out of order across frames.
//
//  v1 frame rate: per the issue, hardcoded 60p (60000/1000). PRD
//  source-rate matching is slice #14 territory.
//
//  Slice #10: stream identity (name + groups) is no longer baked in
//  at init time. Construction allocates the GPU resources but does
//  not start the underlying NDISender; `reconfigure(streamName:groups:)`
//  is the single canonical "(re)create the sender with this identity"
//  entry point. ContentView calls it once at app start (with the
//  defaults from `OutputStreamConfig`), again whenever the operator
//  edits the Settings sheet, and again on each scene-foreground
//  transition (background tears the sender down via `stop()`).
//
//  `reconfigure` delegates to `NDISender.startWithName:groups:`, which
//  is idempotent — it tears the existing instance down and rebuilds,
//  so a rename mid-session is safe and does not require an explicit
//  stop() first.

import Foundation
import Metal

@MainActor
final class SenderPipeline {

    /// Hardcoded 1920×1080 60p per PRD v1 contract; slice #14 may
    /// later thread the source's frame rate through here.
    static let outputWidth = StereoCompositor.senderOutputWidth
    static let outputHeight = StereoCompositor.senderOutputHeight
    static let frameRateNumerator: Int32 = 60_000
    static let frameRateDenominator: Int32 = 1_000

    let sender: NDISender
    let encoder: UYVYEncoder

    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue

    /// Last-applied identity. Retained so a scene-foreground
    /// transition can reuse the same identity without ContentView
    /// having to re-supply it. Nil until the first `reconfigure(...)`.
    private var lastStreamName: String?
    private var lastGroups: String?

    // 3-deep ring of UYVY buffers. Cycled on each send via `(index +
    // 1) % bufferPool.count`. .shared storage so the contents pointer
    // is CPU-readable in the completion handler without an explicit
    // blit / synchronize step (iOS's unified memory makes .shared a
    // free lunch for this access pattern on Apple silicon).
    private var bufferPool: [MTLBuffer] = []
    private var bufferIndex: Int = 0

    init(device: MTLDevice, commandQueue: MTLCommandQueue) throws {
        self.device = device
        self.commandQueue = commandQueue
        self.encoder = try UYVYEncoder(device: device)
        self.sender = NDISender()

        let bytesPerRow = Self.outputWidth * 2
        let length = bytesPerRow * Self.outputHeight
        for _ in 0..<3 {
            guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else {
                throw PipelineError.uyvyBufferAllocationFailed
            }
            bufferPool.append(buffer)
        }
    }

    enum PipelineError: Error {
        case uyvyBufferAllocationFailed
    }

    var isRunning: Bool {
        sender.isRunning
    }

    /// Tear down the running sender and rebuild it with the supplied
    /// identity. This is the single canonical "(re)start the NDI
    /// output" entry point — the underlying `NDISender.startWithName:
    /// groups:` is idempotent (it stops first, then creates), so a
    /// rename or groups change mid-session is safe and does not
    /// require an explicit `stop()` call beforehand.
    ///
    /// Safe to call from main; the sender's send-path is serialized
    /// on its own internal `os_unfair_lock` against any in-flight GPU
    /// completion handler.
    func reconfigure(streamName: String, groups: String?) {
        lastStreamName = streamName
        lastGroups = groups
        _ = sender.start(withName: streamName, groups: groups)
    }

    /// Tear down the sender (typical: scene-background transition).
    /// Retains `lastStreamName` / `lastGroups` so a subsequent
    /// `reconfigure(...)` call (or, on scene-foreground, ContentView
    /// calling `reconfigure(...)` with the current OutputStreamConfig)
    /// can reuse the identity.
    func stop() {
        sender.stop()
    }

    /// Render `pair` through the compositor's offscreen target into
    /// UYVY, then ship the bytes to the NDISender on GPU completion.
    /// Drops the frame silently if the sender is offline or if any
    /// of the GPU resources fail to allocate this tick.
    ///
    /// `alignment` is read fresh on each call (per PRD: HIT changes
    /// reflect in the NDI output within one frame), so the caller can
    /// pass the same long-lived AlignmentState reference every tick.
    func send(pair: StereoFramePair,
              alignment: AlignmentState,
              compositor: StereoCompositor) {
        guard sender.isRunning else { return }
        guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
        commandBuffer.label = "SenderPipeline"

        guard let bgraTex = compositor.renderForSender(pair: pair,
                                                       alignment: alignment,
                                                       commandBuffer: commandBuffer) else {
            return
        }

        let buffer = bufferPool[bufferIndex]
        bufferIndex = (bufferIndex + 1) % bufferPool.count

        let bytesPerRow = Self.outputWidth * 2
        encoder.encode(source: bgraTex,
                       into: buffer,
                       bytesPerRow: bytesPerRow,
                       commandBuffer: commandBuffer)

        // Capture nonisolated locals into the @Sendable completion
        // handler — avoids touching MainActor-isolated `self.*` /
        // `Self.*` from the background GPU completion thread.
        let sender = self.sender
        let outWidth = Self.outputWidth
        let outHeight = Self.outputHeight
        let stride = bytesPerRow
        let rateN = Self.frameRateNumerator
        let rateD = Self.frameRateDenominator
        let length = buffer.length

        commandBuffer.addCompletedHandler { _ in
            // Wrap the .shared buffer's contents pointer in an NSData
            // with bytesNoCopy + .none deallocator: the SDK's
            // synchronous send copies into its own queue before this
            // closure returns, so the bytes-no-copy lifetime is safe
            // for exactly the duration of the `sendUYVYFrame` call.
            let data = Data(bytesNoCopy: buffer.contents(),
                            count: length,
                            deallocator: .none)
            sender.sendUYVYFrame(data,
                                 width: outWidth,
                                 height: outHeight,
                                 stride: stride,
                                 frameRateNumerator: rateN,
                                 frameRateDenominator: rateD)
        }
        commandBuffer.commit()
    }
}
