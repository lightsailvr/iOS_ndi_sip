//  NDIReceiver.h
//
//  ObjC++ wrapper around a single NDIlib_recv_* instance + its FrameSync.
//  Pull-based: callers ask for `latestFrame` at their display cadence and
//  get back an NDIVideoFrame (CVPixelBuffer-backed, zero-copy where the
//  source format permits) or nil if no frame is currently buffered.
//
//  Thread safety:
//    - +receiver, -connectToSourceName:urlAddress:, -disconnect,
//      -kickReconnect, -state and -currentSourceName are main-actor-only
//      from Swift.
//    - -latestFrame is callable from any thread (intended for the MTKView
//      draw callback). The underlying NDIlib_FrameSync is documented as
//      thread-safe by the NDI SDK; only the connect/disconnect lifecycle
//      is internally serialized.
//
//  Slice #12 additions:
//    - NDIReceiverStateStalled — the receiver has gone ≥2 s without a
//      frame but the underlying recv instance is still wired up (no
//      explicit disconnect). Callers (FramePairer, ReceiverWatchdog) use
//      this to distinguish a zombie source from one that explicitly
//      went away.
//    - lastFrameTimestamp / timeSinceLastFrame — wall-clock snap of the
//      most recent successful capture; the watchdog polls this to flip
//      a live receiver into stalled at the 2 s mark.
//    - kickReconnect — tear down the current recv+framesync and recreate
//      against the last (name, url). Safe to call repeatedly; no-op when
//      the receiver is .idle.
//    - onStateChange — main-thread callback invoked whenever state
//      transitions. The watchdog hooks this to drive its
//      reconnecting/stalled/live status surface for the overlays.
//    - lastFrameWidth / lastFrameHeight / lastFrameInterlaced /
//      lastFrameHasAlpha — surfaced so SessionStatus can render the
//      resolution-mismatch / interlaced / alpha warning banners
//      without the SwiftUI side reaching into NDIVideoFrame for them.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIVideoFrame : NSObject

@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) double frameRate;
@property (nonatomic, readonly) NSTimeInterval timecodeSeconds;

/// True when the source presented this frame as interlaced (the
/// FrameSync was asked to deinterlace upstream; this flag tells the
/// SwiftUI side whether a deinterlace warning banner is warranted).
@property (nonatomic, readonly) BOOL isInterlaced;

/// True when the source FourCC carries an alpha channel (BGRA today;
/// future codecs likewise). The compositor's BGRA fragment shader
/// premultiplies against black for sources flagged this way; a banner
/// surfaces the condition for the operator's awareness.
@property (nonatomic, readonly) BOOL hasAlpha;

@end

typedef NS_ENUM(NSInteger, NDIReceiverState) {
    NDIReceiverStateIdle = 0,
    NDIReceiverStateConnecting,
    NDIReceiverStateLive,
    /// ≥2 s without a frame, no explicit disconnect. Distinct from
    /// .disconnected: the underlying recv+framesync is still wired up
    /// and a fresh frame can flip us back to .live without a reconnect.
    NDIReceiverStateStalled,
    NDIReceiverStateDisconnected,
};

@interface NDIReceiver : NSObject

+ (instancetype)receiver;

- (void)connectToSourceName:(NSString *)name urlAddress:(NSString *)urlAddress;
- (void)disconnect;

/// Tear down the current recv+framesync and recreate against the last
/// (name, url) pair. No-op when the receiver is .idle. Used by the
/// ReceiverWatchdog's 2 s retry loop and by NetworkResilience's
/// interface-change handler.
- (void)kickReconnect;

- (nullable NDIVideoFrame *)latestFrame;

@property (nonatomic, readonly) NDIReceiverState state;
@property (nonatomic, copy, readonly, nullable) NSString *currentSourceName;

/// CACurrentMediaTime() of the most recent successful latestFrame
/// capture. 0 until the first frame arrives. Read this on any thread;
/// it's a single 64-bit atomic.
@property (nonatomic, readonly) NSTimeInterval lastFrameTimestamp;

/// Convenience: now - lastFrameTimestamp. Returns +INFINITY when no
/// frame has been seen yet (so the stall-threshold comparison is
/// always true on a fresh receiver). Read on any thread.
@property (nonatomic, readonly) NSTimeInterval timeSinceLastFrame;

/// Source dimensions, interlace, and alpha as observed on the most
/// recent successful capture. 0/false until the first frame arrives.
@property (nonatomic, readonly) NSInteger lastFrameWidth;
@property (nonatomic, readonly) NSInteger lastFrameHeight;
@property (nonatomic, readonly) BOOL lastFrameInterlaced;
@property (nonatomic, readonly) BOOL lastFrameHasAlpha;

/// Source frame rate (frame_rate_N / frame_rate_D) as observed on the
/// most recent successful capture. 0 until the first frame arrives.
/// Read on any thread; backed by a single 64-bit atomic bitcast so the
/// watchdog reads a consistent value without taking the lifecycle lock.
/// Slice #13: surfaced on the per-eye StatusRow as "<W>×<H> @ <fps> fps".
@property (nonatomic, readonly) double lastFrameRate;

/// Main-thread callback fired on every state transition. The block is
/// retained by the receiver; assign nil (or `nil` again) to detach.
@property (nonatomic, copy, nullable) void (^onStateChange)(NDIReceiverState newState);

@end

NS_ASSUME_NONNULL_END
