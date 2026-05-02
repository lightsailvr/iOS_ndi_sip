//  NDIReceiver.h
//
//  ObjC++ wrapper around a single NDIlib_recv_* instance + its FrameSync.
//  Pull-based: callers ask for `latestFrame` at their display cadence and
//  get back an NDIVideoFrame (CVPixelBuffer-backed, zero-copy where the
//  source format permits) or nil if no frame is currently buffered.
//
//  Thread safety:
//    - +receiver, -connectToSourceName:urlAddress:, -disconnect, -state and
//      -currentSourceName are main-actor-only from Swift.
//    - -latestFrame is callable from any thread (intended for the MTKView
//      draw callback). The underlying NDIlib_FrameSync is documented as
//      thread-safe by the NDI SDK; only the connect/disconnect lifecycle
//      is internally serialized.

#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIVideoFrame : NSObject

@property (nonatomic, readonly) CVPixelBufferRef pixelBuffer;
@property (nonatomic, readonly) NSInteger width;
@property (nonatomic, readonly) NSInteger height;
@property (nonatomic, readonly) double frameRate;
@property (nonatomic, readonly) NSTimeInterval timecodeSeconds;

@end

typedef NS_ENUM(NSInteger, NDIReceiverState) {
    NDIReceiverStateIdle = 0,
    NDIReceiverStateConnecting,
    NDIReceiverStateLive,
    NDIReceiverStateDisconnected,
};

@interface NDIReceiver : NSObject

+ (instancetype)receiver;

- (void)connectToSourceName:(NSString *)name urlAddress:(NSString *)urlAddress;
- (void)disconnect;

- (nullable NDIVideoFrame *)latestFrame;

@property (nonatomic, readonly) NDIReceiverState state;
@property (nonatomic, copy, readonly, nullable) NSString *currentSourceName;

@end

NS_ASSUME_NONNULL_END
