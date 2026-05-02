//  FrameTypes.swift
//
//  Pure data types and protocol seams flowing between NDIReceiver,
//  FramePairer, and StereoCompositor. Two seams worth calling out:
//
//   - VideoFrameSource: anything that can hand the compositor a
//     CVPixelBuffer + dimensions. NDIVideoFrame conforms (extension
//     below). Tests substitute a mock conformance that wraps a
//     synthetically generated CVPixelBuffer without involving the
//     ObjC NDI bridge.
//
//   - VideoFrameReceiving: anything FramePairer can pull a "latest
//     frame" out of on each display tick. NDIReceiver conforms via
//     the nonisolated `currentFrame()` adapter. Tests substitute a
//     fake receiver so pair-sequence behavior is exercisable on
//     macOS without Metal or NDI.
//
//  StereoFramePair is the per-tick output. `@unchecked Sendable`
//  because the underlying CVPixelBuffer-backed VideoFrameSource
//  objects are immutable post-create — the pixel-buffer bytes are
//  read-only and the width/height/pixelBuffer accessors are
//  side-effect-free reads.

import CoreVideo
import Foundation

// `nonisolated` so conformances on ObjC classes (NDIVideoFrame,
// NDIReceiver) — which carry no Swift actor isolation — satisfy the
// requirements without an isolation mismatch under the project's
// `SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor` setting.
protocol VideoFrameSource: AnyObject {
    nonisolated var pixelBuffer: CVPixelBuffer { get }
    nonisolated var width: Int { get }
    nonisolated var height: Int { get }
}

protocol VideoFrameReceiving: AnyObject {
    nonisolated func currentFrame() -> (any VideoFrameSource)?
}

struct StereoFramePair: @unchecked Sendable {
    let left: (any VideoFrameSource)?
    let right: (any VideoFrameSource)?
    /// Per-eye status as observed by the FramePairer at this tick.
    /// Populated by the pairer in slice #12; older callers that
    /// constructed `StereoFramePair` without status get `.empty`
    /// defaults via the convenience initializer below.
    let leftStatus: ReceiverWatchdog.SideStatus
    let rightStatus: ReceiverWatchdog.SideStatus
    let hostTime: CFTimeInterval

    init(left: (any VideoFrameSource)?,
         right: (any VideoFrameSource)?,
         leftStatus: ReceiverWatchdog.SideStatus = .empty,
         rightStatus: ReceiverWatchdog.SideStatus = .empty,
         hostTime: CFTimeInterval) {
        self.left = left
        self.right = right
        self.leftStatus = leftStatus
        self.rightStatus = rightStatus
        self.hostTime = hostTime
    }
}

// MARK: - NDIVideoFrame conformance

// `nonisolated` extension because NDIVideoFrame is an ObjC class with
// no Swift actor isolation. Without this annotation the extension
// would inherit the project's MainActor default, conflicting with the
// nonisolated protocol requirements.
extension NDIVideoFrame: VideoFrameSource {
    // NDIVideoFrame already exposes `pixelBuffer`, `width`, and `height`
    // with the right shapes; this is a marker conformance so the
    // compositor and pairer can talk to it via the protocol.
}

// MARK: - NDIReceiver conformance

extension NDIReceiver: VideoFrameReceiving {
    nonisolated func currentFrame() -> (any VideoFrameSource)? {
        // -latestFrame is documented thread-safe (NDIlib_FrameSync's
        // capture call is non-blocking and safe from any thread); fine
        // to call from CADisplayLink on main or from a background actor.
        return latestFrame()
    }
}
