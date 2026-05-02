//  NDIReceiver.mm

#import "NDIReceiver.h"
#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>

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
                    timecodeSeconds:(NSTimeInterval)timecode {
    self = [super init];
    if (!self) {
        return nil;
    }
    _pixelBuffer = (CVPixelBufferRef)CFRetain(pixelBuffer);
    _width = width;
    _height = height;
    _frameRate = frameRate;
    _timecodeSeconds = timecode;
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

- (void)connectToSourceName:(NSString *)name urlAddress:(NSString *)urlAddress {
    if (name.length == 0 && urlAddress.length == 0) {
        os_log_error(receiverLog(), "connectToSourceName called with empty name and url");
        return;
    }

    [self disconnect];

    BOOL holdsRuntimeRef = [NDIRuntime start];
    if (!holdsRuntimeRef) {
        os_log_error(receiverLog(), "NDIRuntime failed to start; receiver disabled");
        _state.store(NDIReceiverStateDisconnected, std::memory_order_release);
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
    // UYVY where source is YUV; BGRA where source has alpha. Slice #4's
    // compositor will sample UYVY directly via Metal — no conversion to BGRA
    // unless the source forces it.
    createSettings.color_format = NDIlib_recv_color_format_UYVY_BGRA;
    createSettings.bandwidth = NDIlib_recv_bandwidth_highest;
    createSettings.allow_video_fields = false;
    createSettings.p_ndi_recv_name = "Stereo NDI Preview";

    NDIlib_recv_instance_t recv = NDIlib_recv_create_v3(&createSettings);
    if (!recv) {
        os_log_error(receiverLog(), "NDIlib_recv_create_v3 returned null");
        [NDIRuntime stop];
        _state.store(NDIReceiverStateDisconnected, std::memory_order_release);
        return;
    }

    NDIlib_framesync_instance_t framesync = NDIlib_framesync_create(recv);
    if (!framesync) {
        os_log_error(receiverLog(), "NDIlib_framesync_create returned null");
        NDIlib_recv_destroy(recv);
        [NDIRuntime stop];
        _state.store(NDIReceiverStateDisconnected, std::memory_order_release);
        return;
    }

    NDIReceiverContext *context = [[NDIReceiverContext alloc] init];
    context->recv = recv;
    context->framesync = framesync;
    context->holdsRuntimeRef = holdsRuntimeRef;

    os_unfair_lock_lock(&_lifecycleLock);
    _context = context;
    _currentSourceName = [name copy];
    os_unfair_lock_unlock(&_lifecycleLock);

    _state.store(NDIReceiverStateConnecting, std::memory_order_release);
    os_log_info(receiverLog(),
                "NDIReceiver connecting to '%{public}s' @ %{public}s",
                cName ? cName : "(no name)",
                cURL ? cURL : "(no url)");
}

- (void)disconnect {
    NDIReceiverContext *context = nil;
    os_unfair_lock_lock(&_lifecycleLock);
    context = _context;
    _context = nil;
    _currentSourceName = nil;
    os_unfair_lock_unlock(&_lifecycleLock);

    _state.store(NDIReceiverStateIdle, std::memory_order_release);

    // Releasing the context here drops the receiver's strong ref; in-flight
    // frames retain the context separately via their pixel-buffer release
    // callbacks, so framesync_destroy / recv_destroy run only after the last
    // CVPixelBuffer is released.
    (void)context;
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
    switch (video.FourCC) {
        case NDIlib_FourCC_video_type_UYVY:
            pixelFormat = kCVPixelFormatType_422YpCbCr8;
            break;
        case NDIlib_FourCC_video_type_BGRA:
            pixelFormat = kCVPixelFormatType_32BGRA;
            break;
        default:
            os_log_error(receiverLog(),
                         "Unsupported NDI FourCC 0x%{public}x in slice #2; dropping frame",
                         (unsigned)video.FourCC);
            NDIlib_framesync_free_video(context->framesync, &video);
            return nil;
    }

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

    if (_state.load(std::memory_order_acquire) == NDIReceiverStateConnecting) {
        _state.store(NDIReceiverStateLive, std::memory_order_release);
    }

    const double frameRate = video.frame_rate_D > 0
        ? (double)video.frame_rate_N / (double)video.frame_rate_D
        : 0.0;
    // NDI timecode is 100-ns intervals.
    const NSTimeInterval timecodeSeconds = (NSTimeInterval)video.timecode * 1.0e-7;

    NDIVideoFrame *frame = [[NDIVideoFrame alloc] initWithPixelBuffer:pixelBuffer
                                                                width:(NSInteger)width
                                                               height:(NSInteger)height
                                                            frameRate:frameRate
                                                      timecodeSeconds:timecodeSeconds];
    CFRelease(pixelBuffer);
    return frame;
}

@end

NS_ASSUME_NONNULL_END
