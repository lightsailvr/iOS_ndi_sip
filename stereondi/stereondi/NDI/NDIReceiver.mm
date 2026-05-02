//  NDIReceiver.mm

#import "NDIReceiver.h"
#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>

#import <QuartzCore/QuartzCore.h>
#import <atomic>
#import <os/lock.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

static os_log_t receiverLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lsvr.stereondi", "NDIReceiver");
    });
    return log;
}

#pragma mark - NDIReceiverContext (refcounted lifetime carrier)

// Owns the recv + framesync pair. The NDIReceiver keeps a strong reference
// while connected; each in-flight NDIVideoFrame also retains the context via
// a heap-allocated release ref-con bridged into the CVPixelBuffer release
// callback. This guarantees `NDIlib_framesync_free_video` is always called
// against a still-live framesync, even if the receiver disconnected before
// Metal / Core Image released the buffer.
@interface NDIReceiverContext : NSObject {
@public
    NDIlib_recv_instance_t recv;
    NDIlib_framesync_instance_t framesync;
    BOOL holdsRuntimeRef;
}
@end

@implementation NDIReceiverContext
- (void)dealloc {
    if (framesync) {
        NDIlib_framesync_destroy(framesync);
        framesync = NULL;
    }
    if (recv) {
        NDIlib_recv_destroy(recv);
        recv = NULL;
    }
    if (holdsRuntimeRef) {
        [NDIRuntime stop];
        holdsRuntimeRef = NO;
    }
}
@end

#pragma mark - Frame release ref-con

namespace {
struct ReleaseRefCon {
    __strong NDIReceiverContext *context;
    NDIlib_video_frame_v2_t frame;
};
}

static void NDIReleasePixelBufferBytes(void *releaseRefCon, const void * /*baseAddress*/) {
    ReleaseRefCon *ref = static_cast<ReleaseRefCon *>(releaseRefCon);
    if (!ref) {
        return;
    }
    if (ref->context && ref->context->framesync) {
        NDIlib_framesync_free_video(ref->context->framesync, &ref->frame);
    }
    ref->context = nil;
    delete ref;
}

#pragma mark - NDIVideoFrame

@implementation NDIVideoFrame {
    CVPixelBufferRef _pixelBuffer;
}

- (instancetype)initWithPixelBuffer:(CVPixelBufferRef)pixelBuffer
                              width:(NSInteger)width
                             height:(NSInteger)height
                          frameRate:(double)frameRate
                    timecodeSeconds:(NSTimeInterval)timecode
                       isInterlaced:(BOOL)isInterlaced
                           hasAlpha:(BOOL)hasAlpha {
    self = [super init];
    if (!self) {
        return nil;
    }
    _pixelBuffer = (CVPixelBufferRef)CFRetain(pixelBuffer);
    _width = width;
    _height = height;
    _frameRate = frameRate;
    _timecodeSeconds = timecode;
    _isInterlaced = isInterlaced;
    _hasAlpha = hasAlpha;
    return self;
}

- (void)dealloc {
    if (_pixelBuffer) {
        CFRelease(_pixelBuffer);
        _pixelBuffer = NULL;
    }
}

@end

#pragma mark - NDIReceiver

@implementation NDIReceiver {
    NDIReceiverContext *_context;
    os_unfair_lock _lifecycleLock;
    std::atomic<NSInteger> _state;
    NSString *_currentSourceName;
    NSString *_currentSourceURL;

    // Wall-clock snap of the most recent successful frame. Stored as
    // a uint64_t bitcast of CFTimeInterval (double) so it can be
    // updated atomically from the latestFrame thread without taking
    // the lifecycle lock for every frame.
    std::atomic<uint64_t> _lastFrameTimeBits;

    // Most recent frame's properties — populated on every successful
    // capture so the SwiftUI side can read dimensions / interlace /
    // alpha for warning banners without retaining the frame itself.
    std::atomic<NSInteger> _lastFrameWidth;
    std::atomic<NSInteger> _lastFrameHeight;
    std::atomic<bool> _lastFrameInterlaced;
    std::atomic<bool> _lastFrameHasAlpha;

    // uint64_t bitcast of the last observed frame rate (double). Slice
    // #13 surfaces this on the per-eye StatusRow; same atomic-packing
    // trick as _lastFrameTimeBits so a main-actor read from a
    // background latestFrame call sees a consistent value lock-free.
    std::atomic<uint64_t> _lastFrameRateBits;
}

+ (instancetype)receiver {
    return [[self alloc] init];
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _lifecycleLock = OS_UNFAIR_LOCK_INIT;
    _state.store(NDIReceiverStateIdle, std::memory_order_release);
    _lastFrameTimeBits.store(0, std::memory_order_release);
    _lastFrameWidth.store(0, std::memory_order_release);
    _lastFrameHeight.store(0, std::memory_order_release);
    _lastFrameInterlaced.store(false, std::memory_order_release);
    _lastFrameHasAlpha.store(false, std::memory_order_release);
    _lastFrameRateBits.store(0, std::memory_order_release);
    return self;
}

- (void)dealloc {
    [self disconnect];
}

- (NDIReceiverState)state {
    return (NDIReceiverState)_state.load(std::memory_order_acquire);
}

- (nullable NSString *)currentSourceName {
    os_unfair_lock_lock(&_lifecycleLock);
    NSString *name = [_currentSourceName copy];
    os_unfair_lock_unlock(&_lifecycleLock);
    return name;
}

- (NSTimeInterval)lastFrameTimestamp {
    uint64_t bits = _lastFrameTimeBits.load(std::memory_order_acquire);
    NSTimeInterval value = 0;
    static_assert(sizeof(uint64_t) == sizeof(NSTimeInterval),
                  "lastFrameTimestamp atomic packing requires 64-bit double");
    memcpy(&value, &bits, sizeof(value));
    return value;
}

- (NSTimeInterval)timeSinceLastFrame {
    NSTimeInterval last = self.lastFrameTimestamp;
    if (last == 0.0) {
        return INFINITY;
    }
    return CACurrentMediaTime() - last;
}

- (NSInteger)lastFrameWidth {
    return _lastFrameWidth.load(std::memory_order_acquire);
}

- (NSInteger)lastFrameHeight {
    return _lastFrameHeight.load(std::memory_order_acquire);
}

- (BOOL)lastFrameInterlaced {
    return _lastFrameInterlaced.load(std::memory_order_acquire) ? YES : NO;
}

- (BOOL)lastFrameHasAlpha {
    return _lastFrameHasAlpha.load(std::memory_order_acquire) ? YES : NO;
}

- (double)lastFrameRate {
    uint64_t bits = _lastFrameRateBits.load(std::memory_order_acquire);
    double value = 0;
    static_assert(sizeof(uint64_t) == sizeof(double),
                  "lastFrameRate atomic packing requires 64-bit double");
    memcpy(&value, &bits, sizeof(value));
    return value;
}

// Atomically swap state; if the value actually changed, fire the
// onStateChange callback on the main thread. Safe to call from any
// thread (the latestFrame path uses this to flip
// .connecting → .live and .stalled → .live).
- (void)transitionToState:(NDIReceiverState)newState {
    NSInteger previous = _state.exchange((NSInteger)newState,
                                         std::memory_order_acq_rel);
    if (previous == (NSInteger)newState) {
        return;
    }
    void (^callback)(NDIReceiverState) = self.onStateChange;
    if (!callback) {
        return;
    }
    if ([NSThread isMainThread]) {
        callback(newState);
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            callback(newState);
        });
    }
}

- (void)connectToSourceName:(NSString *)name urlAddress:(NSString *)urlAddress {
    if (name.length == 0 && urlAddress.length == 0) {
        os_log_error(receiverLog(), "connectToSourceName called with empty name and url");
        return;
    }

    // Capture the request, then route through the shared open path so
    // kickReconnect and the initial connect share the same plumbing.
    [self disconnect];

    os_unfair_lock_lock(&_lifecycleLock);
    _currentSourceName = [name copy];
    _currentSourceURL = [urlAddress copy];
    os_unfair_lock_unlock(&_lifecycleLock);

    [self openContextForName:name urlAddress:urlAddress];
}

- (void)disconnect {
    NDIReceiverContext *context = nil;
    os_unfair_lock_lock(&_lifecycleLock);
    context = _context;
    _context = nil;
    _currentSourceName = nil;
    _currentSourceURL = nil;
    os_unfair_lock_unlock(&_lifecycleLock);

    _lastFrameTimeBits.store(0, std::memory_order_release);
    _lastFrameWidth.store(0, std::memory_order_release);
    _lastFrameHeight.store(0, std::memory_order_release);
    _lastFrameInterlaced.store(false, std::memory_order_release);
    _lastFrameHasAlpha.store(false, std::memory_order_release);
    _lastFrameRateBits.store(0, std::memory_order_release);

    [self transitionToState:NDIReceiverStateIdle];

    // Releasing the context here drops the receiver's strong ref; in-flight
    // frames retain the context separately via their pixel-buffer release
    // callbacks, so framesync_destroy / recv_destroy run only after the last
    // CVPixelBuffer is released.
    (void)context;
}

- (void)kickReconnect {
    NSString *name = nil;
    NSString *url = nil;
    os_unfair_lock_lock(&_lifecycleLock);
    name = [_currentSourceName copy];
    url = [_currentSourceURL copy];
    os_unfair_lock_unlock(&_lifecycleLock);

    if (name.length == 0 && url.length == 0) {
        return;
    }

    // Tear down the current context BUT keep the cached
    // (name, url) so the open path below picks them back up. We
    // reach inside lifecycle ourselves rather than calling -disconnect
    // because the latter clears the cached identifiers.
    NDIReceiverContext *context = nil;
    os_unfair_lock_lock(&_lifecycleLock);
    context = _context;
    _context = nil;
    os_unfair_lock_unlock(&_lifecycleLock);

    _lastFrameTimeBits.store(0, std::memory_order_release);
    _lastFrameWidth.store(0, std::memory_order_release);
    _lastFrameHeight.store(0, std::memory_order_release);
    _lastFrameInterlaced.store(false, std::memory_order_release);
    _lastFrameHasAlpha.store(false, std::memory_order_release);
    _lastFrameRateBits.store(0, std::memory_order_release);
    (void)context;

    [self openContextForName:name urlAddress:url];
}

// Shared open path. Called from -connectToSourceName:urlAddress: and
// -kickReconnect. Caller is responsible for clearing any previous
// context first (and for setting _currentSourceName/_currentSourceURL
// on initial connect).
- (void)openContextForName:(NSString *)name urlAddress:(NSString *)urlAddress {
    BOOL holdsRuntimeRef = [NDIRuntime start];
    if (!holdsRuntimeRef) {
        os_log_error(receiverLog(), "NDIRuntime failed to start; receiver disabled");
        [self transitionToState:NDIReceiverStateDisconnected];
        return;
    }

    // Stable C-string storage for the duration of NDIlib_recv_create_v3.
    const char *cName = name.length > 0 ? name.UTF8String : NULL;
    const char *cURL = urlAddress.length > 0 ? urlAddress.UTF8String : NULL;

    NDIlib_source_t source;
    source.p_ndi_name = cName;
    source.p_url_address = cURL;

    NDIlib_recv_create_v3_t createSettings;
    createSettings.source_to_connect_to = source;
    // UYVY where source is YUV; BGRA where source has alpha. The
    // compositor's BGRA fragment shader pre-multiplies against black
    // unconditionally, which is correct for opaque BGRA (no-op) AND for
    // alpha-bearing BGRA (PRD: "alpha sources premultiplied against
    // black at receive"). Color-space mismatch: NDI's FrameSync
    // converts non-BT.709 sources to BT.709 limited at receive (the
    // SDK promises this for the Standard SDK's UYVY/BGRA color formats),
    // so no additional CPU-side conversion is required here.
    createSettings.color_format = NDIlib_recv_color_format_UYVY_BGRA;
    createSettings.bandwidth = NDIlib_recv_bandwidth_highest;
    // FrameSync is asked to deinterlace upstream (we capture as
    // progressive). Sources that can't be deinterlaced surface their
    // dominant field via FrameSync's fallback; the SwiftUI side
    // detects the residual interlace via NDIVideoFrame.isInterlaced
    // and shows a warning banner.
    createSettings.allow_video_fields = true;
    createSettings.p_ndi_recv_name = "Stereo NDI Preview";

    NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&createSettings);
    if (!recv) {
        os_log_error(receiverLog(), "NDIlib_recv_create_v3 returned null");
        [NDIRuntime stop];
        [self transitionToState:NDIReceiverStateDisconnected];
        return;
    }

    NDIlib_framesync_instance_t framesync = NDIlib_framesync_create(recv);
    if (!framesync) {
        os_log_error(receiverLog(), "NDIlib_framesync_create returned null");
        NDIlib_recv_destroy(recv);
        [NDIRuntime stop];
        [self transitionToState:NDIReceiverStateDisconnected];
        return;
    }

    NDIReceiverContext *context = [[NDIReceiverContext alloc] init];
    context->recv = recv;
    context->framesync = framesync;
    context->holdsRuntimeRef = holdsRuntimeRef;

    os_unfair_lock_lock(&_lifecycleLock);
    _context = context;
    os_unfair_lock_unlock(&_lifecycleLock);

    [self transitionToState:NDIReceiverStateConnecting];
    os_log_info(receiverLog(),
                "NDIReceiver opened context for '%{public}s' @ %{public}s",
                cName ? cName : "(no name)",
                cURL ? cURL : "(no url)");
}

- (nullable NDIVideoFrame *)latestFrame {
    // NDIlib_FrameSync is documented as thread-safe; we capture the context
    // pointer under the lifecycle lock, then release the lock before calling
    // capture so a long-running capture cannot block disconnect.
    NDIReceiverContext *context = nil;
    os_unfair_lock_lock(&_lifecycleLock);
    context = _context;
    os_unfair_lock_unlock(&_lifecycleLock);

    if (!context || !context->framesync) {
        return nil;
    }

    NDIlib_video_frame_v2_t video = {};
    NDIlib_framesync_capture_video(context->framesync, &video,
                                   NDIlib_frame_format_type_progressive);

    if (video.p_data == NULL || video.xres <= 0 || video.yres <= 0) {
        // capture_video always returns immediately; an empty frame just means
        // no video has arrived yet (or we're in the warm-up window).
        NDIlib_framesync_free_video(context->framesync, &video);
        return nil;
    }

    OSType pixelFormat = 0;
    BOOL hasAlpha = NO;
    switch (video.FourCC) {
        case NDIlib_FourCC_video_type_UYVY:
            pixelFormat = kCVPixelFormatType_422YpCbCr8;
            break;
        case NDIlib_FourCC_video_type_BGRA:
            pixelFormat = kCVPixelFormatType_32BGRA;
            // BGRA-with-alpha-presence is detected at the frame-format
            // level rather than scanning pixels (per-frame O(W·H) for an
            // O(1) decision is wrong). NDI's BGRA FourCC implies alpha
            // *may* be present, so treat it as such by default — the
            // shader's premultiply-against-black is a no-op when the
            // source is fully opaque.
            hasAlpha = YES;
            break;
        default:
            os_log_error(receiverLog(),
                         "Unsupported NDI FourCC 0x%{public}x; dropping frame",
                         (unsigned)video.FourCC);
            NDIlib_framesync_free_video(context->framesync, &video);
            return nil;
    }

    BOOL isInterlaced =
        (video.frame_format_type == NDIlib_frame_format_type_interleaved ||
         video.frame_format_type == NDIlib_frame_format_type_field_0 ||
         video.frame_format_type == NDIlib_frame_format_type_field_1);

    const size_t width = (size_t)video.xres;
    const size_t height = (size_t)video.yres;
    const size_t bytesPerRow = video.line_stride_in_bytes > 0
        ? (size_t)video.line_stride_in_bytes
        : (pixelFormat == kCVPixelFormatType_422YpCbCr8 ? width * 2 : width * 4);

    auto *refCon = new ReleaseRefCon{context, video};

    NSDictionary *attrs = @{
        (id)kCVPixelBufferMetalCompatibilityKey: @YES,
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };

    CVPixelBufferRef pixelBuffer = NULL;
    CVReturn status = CVPixelBufferCreateWithBytes(
        kCFAllocatorDefault,
        width,
        height,
        pixelFormat,
        video.p_data,
        bytesPerRow,
        NDIReleasePixelBufferBytes,
        refCon,
        (__bridge CFDictionaryRef)attrs,
        &pixelBuffer);

    if (status != kCVReturnSuccess || pixelBuffer == NULL) {
        os_log_error(receiverLog(),
                     "CVPixelBufferCreateWithBytes failed (status=%{public}d)",
                     (int)status);
        refCon->context = nil;
        delete refCon;
        NDIlib_framesync_free_video(context->framesync, &video);
        return nil;
    }

    // Snap the wall clock for stall detection. Stored as a uint64_t
    // bitcast of the double so callers reading from the watchdog
    // thread see a consistent value without taking the lifecycle lock.
    const NSTimeInterval now = CACurrentMediaTime();
    uint64_t bits = 0;
    static_assert(sizeof(uint64_t) == sizeof(NSTimeInterval),
                  "lastFrameTimestamp atomic packing requires 64-bit double");
    memcpy(&bits, &now, sizeof(bits));
    _lastFrameTimeBits.store(bits, std::memory_order_release);
    _lastFrameWidth.store((NSInteger)width, std::memory_order_release);
    _lastFrameHeight.store((NSInteger)height, std::memory_order_release);
    _lastFrameInterlaced.store(isInterlaced ? true : false,
                               std::memory_order_release);
    _lastFrameHasAlpha.store(hasAlpha ? true : false,
                             std::memory_order_release);

    const double frameRate = video.frame_rate_D > 0
        ? (double)video.frame_rate_N / (double)video.frame_rate_D
        : 0.0;
    {
        uint64_t rateBits = 0;
        static_assert(sizeof(uint64_t) == sizeof(double),
                      "lastFrameRate atomic packing requires 64-bit double");
        memcpy(&rateBits, &frameRate, sizeof(rateBits));
        _lastFrameRateBits.store(rateBits, std::memory_order_release);
    }

    // Recovery path: a successful capture out of .stalled means the
    // source resumed without an explicit reconnect. The watchdog will
    // also see this on its next tick, but flipping here keeps the
    // state consistent for any reader that polls between watchdog
    // ticks.
    NSInteger currentState = _state.load(std::memory_order_acquire);
    if (currentState == NDIReceiverStateConnecting ||
        currentState == NDIReceiverStateStalled) {
        [self transitionToState:NDIReceiverStateLive];
    }

    // NDI timecode is 100-ns intervals.
    const NSTimeInterval timecodeSeconds = (NSTimeInterval)video.timecode * 1.0e-7;

    NDIVideoFrame *frame = [[NDIVideoFrame alloc] initWithPixelBuffer:pixelBuffer
                                                                width:(NSInteger)width
                                                               height:(NSInteger)height
                                                            frameRate:frameRate
                                                      timecodeSeconds:timecodeSeconds
                                                         isInterlaced:isInterlaced
                                                             hasAlpha:hasAlpha];
    CFRelease(pixelBuffer);
    return frame;
}

@end

NS_ASSUME_NONNULL_END
