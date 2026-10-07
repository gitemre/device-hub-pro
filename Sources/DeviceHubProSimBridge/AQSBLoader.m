#import "AQSBDevice.h"
#import "AQSBGuard.h"
#import "AQSBPrivateAPI.h"

#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <objc/runtime.h>

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

/// System-wide since Xcode 11; the same path on Xcode 26 and 27.
static NSString *const kCoreSimulatorPath = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";

/// dlopens CoreSimulator once; later calls return the first result.
static BOOL AQSBLoadCoreSimulator(NSError **error) {
    static dispatch_once_t once;
    static NSError *loadError;
    dispatch_once(&once, ^{
        void *handle = dlopen(kCoreSimulatorPath.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
        if (!handle) {
            const char *reason = dlerror();
            loadError = AQSBMakeError(AQSBErrorLoadFailed,
                                      [NSString stringWithFormat:@"dlopen %@ failed: %s", kCoreSimulatorPath, reason ?: "unknown"],
                                      nil);
            return;
        }
        // The handle stays open for the life of the process: CoreSimulator
        // registers ObjC classes, which cannot be unloaded.
        if (!objc_lookUpClass("SimServiceContext") || !objc_lookUpClass("SimDevice")) {
            loadError = AQSBMakeError(AQSBErrorAPIUnavailable,
                                      @"CoreSimulator loaded but defines no SimServiceContext/SimDevice", nil);
        }
    });
    if (loadError) {
        if (error) {
            *error = loadError;
        }
        return NO;
    }
    return YES;
}

@implementation AQSBLoader

+ (NSString *)coreSimulatorPath {
    return kCoreSimulatorPath;
}

+ (BOOL)loadCoreSimulatorWithError:(NSError **)error {
    AQSBEnterBridge();
    return AQSBLoadCoreSimulator(error);
}

+ (NSString *)loadedCoreSimulatorVersion {
    Class simDevice = objc_lookUpClass("SimDevice");
    if (!simDevice) {
        return nil;
    }
    id version = [NSBundle bundleForClass:simDevice].infoDictionary[@"CFBundleVersion"];
    return [version isKindOfClass:[NSString class]] ? version : nil;
}

+ (BOOL)simulatorKitLoaded {
    uint32_t count = _dyld_image_count();
    for (uint32_t index = 0; index < count; index++) {
        const char *name = _dyld_get_image_name(index);
        if (name && strstr(name, "/SimulatorKit.framework/")) {
            return YES;
        }
    }
    return NO;
}

@end

id AQSBResolveDevice(NSString *udid, NSString *deviceSetPath, NSString *developerDir, BOOL requireBooted, NSError **error) {
    if (!AQSBLoadCoreSimulator(error)) {
        return nil;
    }
    id<AQSBSimServiceContextClass> contextClass = (id<AQSBSimServiceContextClass>)objc_lookUpClass("SimServiceContext");
    if (![contextClass respondsToSelector:@selector(sharedServiceContextForDeveloperDir:error:)]) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorAPIUnavailable, @"+[SimServiceContext sharedServiceContextForDeveloperDir:error:] is missing", nil);
        }
        return nil;
    }

    __block id<AQSBSimServiceContext> context = nil;
    __block NSError *serviceError = nil;
    if (!AQSBGuarded(@"sharedServiceContextForDeveloperDir:error:", error, ^{
            NSError *inner = nil;
            context = [contextClass sharedServiceContextForDeveloperDir:developerDir error:&inner];
            serviceError = inner;
        })) {
        return nil;
    }
    if (!context) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorLoadFailed,
                                   [NSString stringWithFormat:@"no CoreSimulator service context for %@", developerDir],
                                   serviceError);
        }
        return nil;
    }

    __block id<AQSBSimDeviceSet> set = nil;
    if (!AQSBGuarded(deviceSetPath ? @"deviceSetWithPath:error:" : @"defaultDeviceSetWithError:", error, ^{
            NSError *inner = nil;
            set = deviceSetPath ? [context deviceSetWithPath:deviceSetPath error:&inner]
                                : [context defaultDeviceSetWithError:&inner];
            serviceError = inner;
        })) {
        return nil;
    }
    if (!set) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorDeviceNotFound,
                                   [NSString stringWithFormat:@"no device set at %@", deviceSetPath ?: @"(default)"],
                                   serviceError);
        }
        return nil;
    }

    NSString *wanted = udid.uppercaseString;
    __block id<AQSBSimDevice> device = nil;
    __block uint64_t state = 0;
    __block NSString *stateString = nil;
    if (!AQSBGuarded(@"-[SimDeviceSet devices]", error, ^{
            for (id<AQSBSimDevice> candidate in [set devices]) {
                if ([[candidate UDID].UUIDString isEqualToString:wanted]) {
                    device = candidate;
                    state = [candidate state];
                    stateString = [candidate stateString];
                    break;
                }
            }
        })) {
        return nil;
    }
    if (!device) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorDeviceNotFound,
                                   [NSString stringWithFormat:@"no simulator %@ in %@", udid, deviceSetPath ?: @"the default device set"],
                                   nil);
        }
        return nil;
    }
    if (requireBooted && state != AQSBSimDeviceStateBooted) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorDeviceNotBooted,
                                   [NSString stringWithFormat:@"simulator %@ is %@, not booted", udid, stateString ?: @"not booted"],
                                   nil);
        }
        return nil;
    }
    return device;
}
