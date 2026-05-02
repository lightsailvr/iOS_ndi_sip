//  NDIRuntime.mm

#import "NDIRuntime.h"

#import <Processing.NDI.Lib.h>
#import <atomic>
#import <os/log.h>

@implementation NDIRuntime

static std::atomic<int> g_refCount{0};
static os_log_t g_log;

+ (void)initialize {
    if (self == [NDIRuntime class]) {
        g_log = os_log_create("com.lsvr.stereondi", "NDIRuntime");
    }
}

+ (BOOL)start {
    int previous = g_refCount.fetch_add(1, std::memory_order_acq_rel);
    if (previous > 0) {
        return YES;
    }
    if (!NDIlib_is_supported_CPU()) {
        os_log_error(g_log, "NDIlib_is_supported_CPU returned false; aborting NDI start");
        g_refCount.fetch_sub(1, std::memory_order_acq_rel);
        return NO;
    }
    if (!NDIlib_initialize()) {
        os_log_error(g_log, "NDIlib_initialize returned false");
        g_refCount.fetch_sub(1, std::memory_order_acq_rel);
        return NO;
    }
    os_log_info(g_log, "NDIlib_initialize succeeded; version=%{public}s", NDIlib_version());
    return YES;
}

+ (void)stop {
    int previous = g_refCount.fetch_sub(1, std::memory_order_acq_rel);
    if (previous == 1) {
        NDIlib_destroy();
        os_log_info(g_log, "NDIlib_destroy called");
    } else if (previous <= 0) {
        g_refCount.store(0, std::memory_order_release);
    }
}

+ (NSString *)version {
    const char *raw = NDIlib_version();
    if (!raw) {
        return @"unknown";
    }
    return [NSString stringWithUTF8String:raw];
}

+ (BOOL)isSupportedCPU {
    return NDIlib_is_supported_CPU() ? YES : NO;
}

@end
