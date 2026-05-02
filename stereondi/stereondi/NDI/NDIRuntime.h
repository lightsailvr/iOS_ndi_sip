//  NDIRuntime.h
//
//  Process-wide lifecycle wrapper around NDIlib_initialize / NDIlib_destroy.
//  Idempotent and thread-safe; safe to call from any actor.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIRuntime : NSObject

+ (BOOL)start;
+ (void)stop;
+ (NSString *)version;
+ (BOOL)isSupportedCPU;

@end

NS_ASSUME_NONNULL_END
