//  NDIDiscoveryFirstSource.h
//
//  Transient first-source-on-the-LAN discovery helper used by slice #2
//  to wire up a single NDI receive end-to-end. Slice #3's full
//  NDIDiscovery (live-updating list) supersedes this; do not depend on
//  this class beyond the bootstrap path in ContentView.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface NDIDiscoveryFirstSource : NSObject

+ (instancetype)startBrowsing;

- (void)waitForFirstSource:(NSTimeInterval)timeout
                completion:(void (^)(NSString *_Nullable name,
                                     NSString *_Nullable url))completion;

- (void)stop;

@end

NS_ASSUME_NONNULL_END
