//  NDIDiscovery.mm

#import "NDIDiscovery.h"
#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>

#import <atomic>
#import <os/lock.h>
#import <os/log.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logging

static os_log_t discoveryLog(void) {
    static os_log_t log;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        log = os_log_create("com.lsvr.stereondi", "NDIDiscovery");
    });
    return log;
}

#pragma mark - NDISource

@implementation NDISource

- (instancetype)initWithName:(NSString *)name urlAddress:(NSString *)urlAddress {
    self = [super init];
    if (!self) {
        return nil;
    }
    _name = [name copy];
    _urlAddress = [urlAddress copy];
    return self;
}

- (BOOL)isEqual:(id)other {
    if (other == self) {
        return YES;
    }
    if (![other isKindOfClass:[NDISource class]]) {
        return NO;
    }
    NDISource *o = (NDISource *)other;
    return [self.name isEqualToString:o.name] &&
           [self.urlAddress isEqualToString:o.urlAddress];
}

- (NSUInteger)hash {
    return self.name.hash ^ self.urlAddress.hash;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<NDISource %p name=%@ url=%@>",
            self, self.name, self.urlAddress];
}

@end

#pragma mark - NDIDiscovery

@implementation NDIDiscovery {
    // Lifecycle state — guarded by @synchronized(self) for start/stop, but the
    // find loop owns the find instance for its entire lifetime. stop just sets
    // _stopRequested; the loop notices, exits, and tears down the instance
    // itself. This avoids racing find_destroy against the loop's in-flight
    // find_wait_for_sources / find_get_current_sources calls (the NDI SDK
    // explicitly forbids async find_get_current_sources).
    dispatch_queue_t _queue;
    std::atomic<bool> _running;
    std::atomic<bool> _stopRequested;

    os_unfair_lock _snapshotLock;
    NSArray<NDISource *> *_snapshot;
}

+ (instancetype)shared {
    static NDIDiscovery *instance;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        instance = [[NDIDiscovery alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (!self) {
        return nil;
    }
    _snapshotLock = OS_UNFAIR_LOCK_INIT;
    _snapshot = @[];
    _running.store(false, std::memory_order_release);
    _stopRequested.store(false, std::memory_order_release);
    return self;
}

- (void)dealloc {
    [self stop];
}

- (void)start {
    @synchronized (self) {
        if (_running.load(std::memory_order_acquire)) {
            return;
        }
        if (![NDIRuntime start]) {
            os_log_error(discoveryLog(), "NDIRuntime failed to start; discovery disabled");
            return;
        }

        NDIlib_find_create_t settings;
        settings.show_local_sources = true;
        settings.p_groups = NULL;
        settings.p_extra_ips = NULL;

        NDIlib_find_instance_t findInstance = NDIlib_find_create_v2(&settings);
        if (!findInstance) {
            os_log_error(discoveryLog(), "NDIlib_find_create_v2 returned null");
            [NDIRuntime stop];
            return;
        }

        _queue = dispatch_queue_create("com.lsvr.stereondi.discovery",
                                       DISPATCH_QUEUE_SERIAL);
        _stopRequested.store(false, std::memory_order_release);
        _running.store(true, std::memory_order_release);

        __weak typeof(self) weakSelf = self;
        dispatch_async(_queue, ^{
            [weakSelf runFindLoopWithInstance:findInstance];
            // The find loop owns the find instance + the runtime ref for its
            // lifetime; tear both down here so stop() never races destroy.
            NDIlib_find_destroy(findInstance);
            [NDIRuntime stop];
            os_log_info(discoveryLog(), "NDIDiscovery find loop exited");
        });

        os_log_info(discoveryLog(), "NDIDiscovery started");
    }
}

- (void)stop {
    @synchronized (self) {
        if (!_running.load(std::memory_order_acquire)) {
            return;
        }
        _stopRequested.store(true, std::memory_order_release);
        _running.store(false, std::memory_order_release);
        _queue = nil;
    }
    os_log_info(discoveryLog(), "NDIDiscovery stop requested");
}

- (NSArray<NDISource *> *)currentSources {
    os_unfair_lock_lock(&_snapshotLock);
    NSArray<NDISource *> *snapshot = _snapshot;
    os_unfair_lock_unlock(&_snapshotLock);
    return snapshot;
}

#pragma mark - Find loop

- (void)runFindLoopWithInstance:(NDIlib_find_instance_t)findInstance {
    while (true) {
        if (_stopRequested.load(std::memory_order_acquire)) {
            break;
        }

        NDIlib_find_wait_for_sources(findInstance, 1000);

        if (_stopRequested.load(std::memory_order_acquire)) {
            break;
        }

        uint32_t count = 0;
        const NDIlib_source_t *raw =
            NDIlib_find_get_current_sources(findInstance, &count);

        NSMutableArray<NDISource *> *next = [NSMutableArray arrayWithCapacity:count];
        for (uint32_t i = 0; i < count; i++) {
            const NDIlib_source_t *src = &raw[i];
            NSString *name = src->p_ndi_name
                ? [NSString stringWithUTF8String:src->p_ndi_name]
                : @"";
            NSString *url = src->p_url_address
                ? [NSString stringWithUTF8String:src->p_url_address]
                : @"";
            if (name.length == 0 && url.length == 0) {
                continue;
            }
            [next addObject:[[NDISource alloc] initWithName:name urlAddress:url]];
        }

        BOOL changed = NO;
        os_unfair_lock_lock(&_snapshotLock);
        if (![_snapshot isEqualToArray:next]) {
            _snapshot = [next copy];
            changed = YES;
        }
        os_unfair_lock_unlock(&_snapshotLock);

        if (changed) {
            NSArray<NDISource *> *toDeliver = [next copy];
            void (^callback)(NSArray<NDISource *> *) = self.onSourcesChanged;
            if (callback) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    callback(toDeliver);
                });
            }
        }
    }
}

@end

NS_ASSUME_NONNULL_END
