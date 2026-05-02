//  NDISender.h
//
//  ObjC++ wrapper around a single NDIlib_send_* instance. Advertises a
//  full-bandwidth NDI source on the LAN and accepts UYVY 4:2:2 video
//  frames from the Metal-side compositor → UYVYEncoder pipeline.
//
//  The advertised stream name on the network resolves to
//  `<machine-name> (<streamName>)` — the SDK supplies the
//  machine-name prefix automatically; we only pass the suffix.
//
//  Thread safety:
//    - -startWithName:groups:, -stop, -isRunning and -currentStreamName
//      are safe to call from any thread; main is typical.
//    - -sendUYVYFrame:... is safe to call from any thread (intended for
//      a Metal command-buffer's addCompletedHandler, which fires on a
//      background GPU completion queue). Sends are serialized on an
//      os_unfair_lock so concurrent callers don't race the SDK pointer.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDISender : NSObject

/// Start advertising. Calling -startWithName:groups: on a sender that
/// is already running tears the existing instance down first, so it is
/// the canonical way to rename the stream or change groups.
///
/// `streamName` is the human-readable suffix shown in NDI receivers
/// (e.g. "Stereo Preview"); the SDK prepends the iPad's machine name.
/// `groups` is a comma-separated NDI groups list; nil/empty selects
/// the SDK default ("Public").
///
/// Returns YES on successful create + NDIRuntime start, NO otherwise.
- (BOOL)startWithName:(NSString *)streamName groups:(nullable NSString *)groups;

/// Send a single video frame in UYVY 4:2:2 BT.709 limited progressive.
///
/// `uyvyData.length` must equal `stride * height`. `stride` is the
/// inter-line stride in bytes (typically `width * 2` for packed UYVY).
/// `frameRateNumerator` / `frameRateDenominator` set the advertised
/// rate, e.g. 60000/1000 for 60p, 60000/1001 for 59.94p.
///
/// `NDIlib_send_send_video_v2` is documented to copy the frame into
/// the SDK's internal queue before returning, so the caller is free
/// to recycle `uyvyData` after this call returns.
- (void)sendUYVYFrame:(NSData *)uyvyData
                width:(NSInteger)width
               height:(NSInteger)height
               stride:(NSInteger)stride
   frameRateNumerator:(int32_t)frameRateNumerator
 frameRateDenominator:(int32_t)frameRateDenominator;

/// Tear down the underlying NDIlib_send instance and drop the
/// NDIRuntime ref. Safe to call when not running.
- (void)stop;

@property (nonatomic, readonly) BOOL isRunning;
@property (nonatomic, copy, readonly, nullable) NSString *currentStreamName;

@end

NS_ASSUME_NONNULL_END
