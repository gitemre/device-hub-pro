// Our own declarations of the private CoreSimulator selectors the bridge sends.
//
// Nothing here is linked or copied from Apple: classes are found with
// objc_lookUpClass at run time, and these protocols only give the compiler each
// method's signature so every message uses the right calling convention. The
// return and argument types match the runtime type encodings of CoreSimulator
// 1171.7 (`I` → uint32_t, `S` → uint16_t, `Q` → uint64_t). PROVENANCE.md records
// where each selector comes from.
//
// Every message to one of these objects goes through AQSBGuarded (AQSBGuard.h).
// The bridge sends no init-style selector to a private class. If one is ever
// needed, declare it here as a method and send it normally: a raw objc_msgSend
// cast of an init broke ARC's ownership and crashed a spike probe.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <mach/mach.h>

NS_ASSUME_NONNULL_BEGIN

/// The class object of SimServiceContext. Declared as an instance method so the
/// message goes to the class object (its metaclass holds the method).
@protocol AQSBSimServiceContextClass <NSObject>
- (nullable id)sharedServiceContextForDeveloperDir:(NSString *)developerDir error:(NSError **)error;
@end

@protocol AQSBSimServiceContext <NSObject>
- (nullable id)defaultDeviceSetWithError:(NSError **)error;
- (nullable id)deviceSetWithPath:(NSString *)path error:(NSError **)error;
@end

@protocol AQSBSimDeviceSet <NSObject>
- (NSArray *)devices;
@end

/// SimDevice's `state` value for a booted device (SimDeviceState: 0 creating,
/// 1 shutdown, 2 booting, 3 booted, 4 shutting down).
static const uint64_t AQSBSimDeviceStateBooted = 3;

@protocol AQSBSimDevice <NSObject>
- (NSUUID *)UDID;
- (NSString *)name;
- (uint64_t)state;
- (NSString *)stateString;
/// A SimDeviceIOClient.
- (nullable id)io;
/// A send right for `serviceName` in the simulator's bootstrap namespace.
- (mach_port_t)lookup:(NSString *)serviceName error:(NSError **)error;
@end

@protocol AQSBSimDeviceIO <NSObject>
- (nullable NSArray *)ioPorts;
@end

@protocol AQSBSimDeviceIOPort <NSObject>
- (nullable id)descriptor;
@end

/// The display port descriptor (a ROCK remote proxy) and its state.
@protocol AQSBSimDisplayDescriptor <NSObject>
- (nullable id)state;
- (nullable id)framebufferSurface;
@end

@protocol AQSBSimDisplayDescriptorState <NSObject>
- (uint16_t)displayClass;
@end

@protocol AQSBSimScreen <NSObject>
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frameCallback
                surfacesChangedCallback:(void (^)(id _Nullable framebuffer, id _Nullable maskedFramebuffer))surfacesChangedCallback
              propertiesChangedCallback:(void (^)(id _Nullable properties))propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
- (nullable id)screenProperties;
@end

@protocol AQSBSimScreenProperties <NSObject>
- (uint64_t)screenType;
- (uint32_t)screenID;
- (uint32_t)uiOrientation;
- (CGSize)pixelSize;
@end

/// The selectors the screen path needs on the display descriptor; a descriptor
/// that lacks any of them is not a usable SimScreen.
#define AQSB_SEL_REGISTER_SCREEN @selector(registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:)
#define AQSB_SEL_UNREGISTER_SCREEN @selector(unregisterScreenCallbacksWithUUID:)

// libxpc's simulator entry points, looked up with dlsym (never linked).
/// Wraps a mach send right in an XPC endpoint. Returns +1; consumes the right.
typedef void *_Nullable (*AQSBEndpointCreateMachPort4SimFn)(mach_port_t port, uint64_t unused1, uint64_t unused2);
/// Marks a connection simulator-to-host; without it the service sees the peer but no payload.
typedef void (*AQSBConnectionEnableSim2Host4SimFn)(void *connection);

NS_ASSUME_NONNULL_END
