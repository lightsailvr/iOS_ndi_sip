//  NDISender.mm

#import "NDISender.h"
#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>

#import <atomic>
#import <os/lock.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

static os_log_t senderLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lsvr.stereondi", "NDISender");
    });
    return log;
}

#pragma mark - Color metadata

// The NDI SDK exposes color metadata only via the per-frame
// `p_metadata` XML string — `NDIlib_video_frame_v2_t` itself carries
// no dedicated colorimetry field. UYVY 4:2:2 progressive is BT.709
// limited by NDI convention (the SDK assumes this on both the send
// and recv sides for the Standard SDK), so the XML tag below is a
// defensive *explicit* declaration: receivers that read the metadata
// see exactly what we intend, and receivers that ignore it still get
// the right answer from the implicit UYVY default.
//
// The double-attribute form (`color_format` + `color_range`) is the
// shape used by the public NDI tools' metadata stream; if a future
// SDK version specifies a canonical tag in `Processing.NDI.utilities.h`
// we should switch to that. For Standard SDK 5.x there is no such
// canonical tag in the headers — confirmed by ripgrep over
// Vendor/include/.
//
// String literal storage means the C-string lifetime is the program's
// lifetime, which trivially outlives the synchronous send call.
static const char *const kColorMetadataBT709Limited =
    "<ndi_color_info color_format=\"BT.709\" color_range=\"limited\" />";

#pragma mark - NDISender

@implementation NDISender {
    NDIlib_send_instance_t _send;
    // The SDK does not deep-copy the create-struct C strings, so the
    // sender's lifetime requires we hold backing storage alive for
    // p_ndi_name and p_groups for as long as `_send` exists.
    NSData *_streamNameUTF8;
    NSData *_groupsUTF8;
    NSString *_currentStreamName;

    os_unfair_lock _sendLock;
    std::atomic<bool> _holdsRuntimeRef;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _sendLock = OS_UNFAIR_LOCK_INIT;
    _send = NULL;
    _holdsRuntimeRef.store(false, std::memory_order_release);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (BOOL)isRunning {
    os_unfair_lock_lock(&_sendLock);
    BOOL running = (_send != NULL);
    os_unfair_lock_unlock(&_sendLock);
    return running;
}

- (nullable NSString *)currentStreamName {
    os_unfair_lock_lock(&_sendLock);
    NSString *name = [_currentStreamName copy];
    os_unfair_lock_unlock(&_sendLock);
    return name;
}

- (BOOL)startWithName:(NSString *)streamName groups:(nullable NSString *)groups {
    if (streamName.length == 0) {
        os_log_error(senderLog(), "startWithName called with empty stream name");
        return NO;
    }

    [self stop];

    if (![NDIRuntime start]) {
        os_log_error(senderLog(), "NDIRuntime failed to start; sender disabled");
        return NO;
    }
    _holdsRuntimeRef.store(true, std::memory_order_release);

    // Copy the strings into NSData buffers we own; the SDK keeps the
    // raw char* alive for the lifetime of the send instance.
    NSData *streamNameUTF8 = [streamName dataUsingEncoding:NSUTF8StringEncoding];
    if (streamNameUTF8 == nil) {
        os_log_error(senderLog(), "stream name failed to encode to UTF-8");
        [NDIRuntime stop];
        _holdsRuntimeRef.store(false, std::memory_order_release);
        return NO;
    }
    // Ensure NUL termination — dataUsingEncoding does not include it.
    NSMutableData *streamNameBuf = [NSMutableData dataWithCapacity:streamNameUTF8.length + 1];
    [streamNameBuf appendData:streamNameUTF8];
    [streamNameBuf appendBytes:"" length:1];

    NSMutableData *groupsBuf = nil;
    if (groups.length > 0) {
        NSData *raw = [groups dataUsingEncoding:NSUTF8StringEncoding];
        if (raw != nil) {
            groupsBuf = [NSMutableData dataWithCapacity:raw.length + 1];
            [groupsBuf appendData:raw];
            [groupsBuf appendBytes:"" length:1];
        }
    }

    NDIlib_send_create_t settings;
    settings.p_ndi_name = (const char *)streamNameBuf.bytes;
    settings.p_groups = groupsBuf ? (const char *)groupsBuf.bytes : NULL;
    // Let NDI pace itself off the rate at which we hand it frames; the
    // FramePairer's CADisplayLink already provides our clocking.
    settings.clock_video = false;
    settings.clock_audio = false;

    NDIlib_send_instance_t send = NDIlib_send_create(&settings);
    if (!send) {
        os_log_error(senderLog(), "NDIlib_send_create returned null");
        [NDIRuntime stop];
        _holdsRuntimeRef.store(false, std::memory_order_release);
        return NO;
    }

    os_unfair_lock_lock(&_sendLock);
    _send = send;
    _streamNameUTF8 = [streamNameBuf copy];
    _groupsUTF8 = groupsBuf ? [groupsBuf copy] : nil;
    _currentStreamName = [streamName copy];
    os_unfair_lock_unlock(&_sendLock);

    os_log_info(senderLog(),
                "NDISender started; name='%{public}s' groups='%{public}s'",
                (const char *)streamNameBuf.bytes,
                groupsBuf ? (const char *)groupsBuf.bytes : "(default)");
    return YES;
}

- (void)stop {
    NDIlib_send_instance_t send = NULL;
    os_unfair_lock_lock(&_sendLock);
    send = _send;
    _send = NULL;
    _streamNameUTF8 = nil;
    _groupsUTF8 = nil;
    _currentStreamName = nil;
    os_unfair_lock_unlock(&_sendLock);

    if (send) {
        NDIlib_send_destroy(send);
        os_log_info(senderLog(), "NDISender stopped");
    }
    if (_holdsRuntimeRef.exchange(false, std::memory_order_acq_rel)) {
        [NDIRuntime stop];
    }
}

- (void)sendUYVYFrame:(NSData *)uyvyData
                width:(NSInteger)width
               height:(NSInteger)height
               stride:(NSInteger)stride
   frameRateNumerator:(int32_t)frameRateNumerator
 frameRateDenominator:(int32_t)frameRateDenominator {
    if (uyvyData.length == 0 || width <= 0 || height <= 0 || stride <= 0) {
        return;
    }
    if ((NSInteger)uyvyData.length < stride * height) {
        os_log_error(senderLog(),
                     "sendUYVYFrame data too small: have=%{public}lu need=%{public}ld",
                     (unsigned long)uyvyData.length,
                     (long)(stride * height));
        return;
    }

    os_unfair_lock_lock(&_sendLock);
    NDIlib_send_instance_t send = _send;
    os_unfair_lock_unlock(&_sendLock);
    if (!send) {
        return;
    }

    NDIlib_video_frame_v2_t v;
    v.xres = (int)width;
    v.yres = (int)height;
    v.FourCC = NDIlib_FourCC_video_type_UYVY;
    v.frame_rate_N = (int)frameRateNumerator;
    v.frame_rate_D = (int)frameRateDenominator;
    v.picture_aspect_ratio = (float)width / (float)height;
    v.frame_format_type = NDIlib_frame_format_type_progressive;
    v.timecode = NDIlib_send_timecode_synthesize;
    v.p_data = (uint8_t *)uyvyData.bytes;
    v.line_stride_in_bytes = (int)stride;
    // Explicit BT.709 limited declaration — UYVY 4:2:2 progressive is
    // BT.709 limited by NDI convention, but we declare it explicitly
    // so receivers reading the per-frame metadata don't have to rely
    // on the implicit default (per slice #10 issue AC).
    v.p_metadata = kColorMetadataBT709Limited;
    v.timestamp = NDIlib_recv_timestamp_undefined;

    // Serialize sends so a stop() racing with a send doesn't free `_send`
    // while the SDK is reading from it. NDIlib_send_send_video_v2 copies
    // the frame data into its internal queue before returning, so the
    // caller's NSData is safe to release on return.
    os_unfair_lock_lock(&_sendLock);
    if (_send) {
        NDIlib_send_send_video_v2(_send, &v);
    }
    os_unfair_lock_unlock(&_sendLock);
}

@end

NS_ASSUME_NONNULL_END
