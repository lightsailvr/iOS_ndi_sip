//  NDIDiscovery.h
//
//  ObjC++ wrapper around NDIlib_find_*. Holds a single long-lived find
//  instance, runs a serial background find loop, and exposes a
//  thread-safe snapshot of the currently-discovered NDI sources to
//  Swift via NSArray<NDISource *>. Notifies the main thread when the
//  list changes so SwiftUI / Observation can refresh.
//
//  Lifecycle:
//    - +shared returns the process-wide singleton (cheap; does not start
//      browsing). Call -start to begin the find loop and -stop to tear it
//      down. -start is idempotent.
//    - The find loop holds an NDIRuntime ref while running so that
//      NDIlib_initialize stays in effect for the duration.
//
//  Thread safety:
//    - +shared, -start, -stop are safe to call from any thread; main is
//      typical.
//    - -currentSources is callable from any thread (snapshot guarded by
//      an os_unfair_lock).
//    - onSourcesChanged is always invoked on dispatch_get_main_queue().

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDISource : NSObject

@property (nonatomic, copy, readonly) NSString *name;
@property (nonatomic, copy, readonly) NSString *urlAddress;

- (instancetype)initWithName:(NSString *)name
                  urlAddress:(NSString *)urlAddress NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

@end

@interface NDIDiscovery : NSObject

+ (instancetype)shared;

- (void)start;
- (void)stop;

- (NSArray<NDISource *> *)currentSources;

@property (nonatomic, copy, nullable) void (^onSourcesChanged)(NSArray<NDISource *> *sources);

@end

NS_ASSUME_NONNULL_END
