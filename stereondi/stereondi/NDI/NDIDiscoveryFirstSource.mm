//  NDIDiscoveryFirstSource.mm

#import "NDIDiscoveryFirstSource.h"
#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>
#import <atomic>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

@implementation NDIDiscoveryFirstSource {
    NDIlib_find_instance_t _findInstance;
    dispatch_queue_t _queue;
    std::atomic<bool> _stopped;
    BOOL _holdsRuntimeRef;
}

static os_log_t firstSourceLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lsvr.stereondi", "NDIDiscoveryFirstSource");
    });
    return log;
}

+ (instancetype)startBrowsing {
    return [[self alloc] initStartBrowsing];
}

- (instancetype)initStartBrowsing {
    self = [super init];
    if (!self) {
        return nil;
    }
    _stopped.store(false, std::memory_order_release);
    _holdsRuntimeRef = [NDIRuntime start];
    if (!_holdsRuntimeRef) {
        os_log_error(firstSourceLog(), "NDIRuntime failed to start; discovery disabled");
        return self;
    }
    NDIlib_find_create_t settings;
    settings.show_local_sources = true;
    settings.p_groups = NULL;
    settings.p_extra_ips = NULL;
    _findInstance = NDIlib_find_create_v2(&settings);
    if (!_findInstance) {
        os_log_error(firstSourceLog(), "NDIlib_find_create_v2 returned null");
        [NDIRuntime stop];
        _holdsRuntimeRef = NO;
        return self;
    }
    _queue = dispatch_queue_create("com.lsvr.stereondi.discovery.first",
                                   DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)waitForFirstSource:(NSTimeInterval)timeout
                completion:(void (^)(NSString *_Nullable, NSString *_Nullable))completion {
    if (!_findInstance || !_queue) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, nil); });
        return;
    }
    NDIlib_find_instance_t findInstance = _findInstance;
    __weak typeof(self) weakSelf = self;
    dispatch_async(_queue, ^{
        const NSTimeInterval deadline = [NSDate timeIntervalSinceReferenceDate] + MAX(timeout, 0.0);
        NSString *foundName = nil;
        NSString *foundURL = nil;
        while (true) {
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf->_stopped.load(std::memory_order_acquire)) {
                break;
            }
            NSTimeInterval remaining = deadline - [NSDate timeIntervalSinceReferenceDate];
            if (remaining <= 0) {
                break;
            }
            const uint32_t waitMs = (uint32_t)MIN(remaining * 1000.0, 500.0);
            NDIlib_find_wait_for_sources(findInstance, waitMs);

            uint32_t numSources = 0;
            const NDIlib_source_t *sources =
                NDIlib_find_get_current_sources(findInstance, &numSources);
            if (sources != NULL && numSources > 0) {
                const NDIlib_source_t *first = &sources[0];
                if (first->p_ndi_name != NULL) {
                    foundName = [NSString stringWithUTF8String:first->p_ndi_name];
                }
                if (first->p_url_address != NULL) {
                    foundURL = [NSString stringWithUTF8String:first->p_url_address];
                }
                break;
            }
        }
        dispatch_async(dispatch_get_main_queue(), ^{
            completion(foundName, foundURL);
        });
    });
}

- (void)stop {
    if (_stopped.exchange(true, std::memory_order_acq_rel)) {
        return;
    }
    if (_findInstance) {
        NDIlib_find_destroy(_findInstance);
        _findInstance = NULL;
    }
    if (_holdsRuntimeRef) {
        [NDIRuntime stop];
        _holdsRuntimeRef = NO;
    }
}

- (void)dealloc {
    [self stop];
}

@end

NS_ASSUME_NONNULL_END
