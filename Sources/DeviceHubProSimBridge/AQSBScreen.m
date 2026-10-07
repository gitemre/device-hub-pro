#import "AQSBDevice.h"
#import "AQSBGuard.h"
#import "AQSBPrivateAPI.h"

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

/// The display class of the device's own panel. TV-out, wireless and the
/// resizable display are other classes and have no surface until something
/// connects to them.
static const uint16_t kMainDisplayClass = 0;

/// `object` as an IOSurface, or nil. The surfaces arrive through the ROCK proxy
/// as `id`, so check before trusting the type.
static IOSurface *AQSBAsSurface(id object) {
    if (!object) {
        return nil;
    }
    if ([object isKindOfClass:[IOSurface class]]) {
        return object;
    }
    if (CFGetTypeID((__bridge CFTypeRef)object) == IOSurfaceGetTypeID()) {
        return (IOSurface *)object;
    }
    return nil;
}

// MARK: - Properties

@implementation AQSBScreenProperties

- (instancetype)initWithScreenType:(uint64_t)screenType
                          screenID:(uint32_t)screenID
                     uiOrientation:(uint32_t)uiOrientation
                         pixelSize:(CGSize)pixelSize {
    if ((self = [super init])) {
        _screenType = screenType;
        _screenID = screenID;
        _uiOrientation = uiOrientation;
        _pixelSize = pixelSize;
    }
    return self;
}

/// Reads the four values from a SimScreenProperties proxy. A property the
/// proxy does not answer stays 0; a raise fails the read.
+ (nullable instancetype)propertiesFromProxy:(id)proxy error:(NSError **)error {
    if (!proxy) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorAPIUnavailable, @"the screen vends no properties", nil);
        }
        return nil;
    }
    __block uint64_t screenType = 0;
    __block uint32_t screenID = 0;
    __block uint32_t uiOrientation = 0;
    __block CGSize pixelSize = CGSizeZero;
    BOOL ok = AQSBGuarded(@"SimScreenProperties", error, ^{
        id<AQSBSimScreenProperties> properties = proxy;
        if ([properties respondsToSelector:@selector(screenType)]) {
            screenType = [properties screenType];
        }
        if ([properties respondsToSelector:@selector(screenID)]) {
            screenID = [properties screenID];
        }
        if ([properties respondsToSelector:@selector(uiOrientation)]) {
            uiOrientation = [properties uiOrientation];
        }
        if ([properties respondsToSelector:@selector(pixelSize)]) {
            pixelSize = [properties pixelSize];
        }
    });
    if (!ok) {
        return nil;
    }
    return [[AQSBScreenProperties alloc] initWithScreenType:screenType
                                                   screenID:screenID
                                              uiOrientation:uiOrientation
                                                  pixelSize:pixelSize];
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<AQSBScreenProperties type=%llu id=%u uiOrientation=%u pixelSize=%.0fx%.0f>",
                                      _screenType, _screenID, _uiOrientation, _pixelSize.width, _pixelSize.height];
}

@end

// MARK: - Screen

/// device.io → ioPorts → the descriptor whose state has display class 0 and
/// that vends the SimScreen callbacks.
static id AQSBFindMainScreen(id<AQSBSimDevice> device, NSError **error) {
    __block NSArray *ports = nil;
    if (!AQSBGuarded(@"-[SimDevice io] / -ioPorts", error, ^{
            id<AQSBSimDeviceIO> io = [device io];
            ports = [io respondsToSelector:@selector(ioPorts)] ? [io ioPorts] : nil;
        })) {
        return nil;
    }
    if (ports.count == 0) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorScreenNotFound, @"the simulator has no IO ports", nil);
        }
        return nil;
    }
    for (id<AQSBSimDeviceIOPort> port in ports) {
        __block id descriptor = nil;
        __block uint16_t displayClass = UINT16_MAX;
        NSError *portError = nil;
        BOOL ok = AQSBGuarded(@"IO port descriptor", &portError, ^{
            if (![port respondsToSelector:@selector(descriptor)]) {
                return;
            }
            id<AQSBSimDisplayDescriptor> candidate = [port descriptor];
            if (![candidate respondsToSelector:AQSB_SEL_REGISTER_SCREEN] ||
                ![candidate respondsToSelector:AQSB_SEL_UNREGISTER_SCREEN] ||
                ![candidate respondsToSelector:@selector(state)]) {
                return;
            }
            id<AQSBSimDisplayDescriptorState> state = [candidate state];
            if ([state respondsToSelector:@selector(displayClass)]) {
                displayClass = [state displayClass];
                descriptor = candidate;
            }
        });
        // One port that raises does not hide the others.
        if (ok && descriptor && displayClass == kMainDisplayClass) {
            return descriptor;
        }
    }
    if (error) {
        *error = AQSBMakeError(AQSBErrorScreenNotFound,
                               [NSString stringWithFormat:@"no display of class 0 with SimScreen callbacks among %lu IO ports",
                                                          (unsigned long)ports.count],
                               nil);
    }
    return nil;
}

@interface AQSBScreen ()
/// Mirrors `_token != nil` for readers that must not wait for a
/// registration in progress. Atomic.
@property (readwrite, getter=isStarted) BOOL started;
/// The queue the callbacks run on while started, else nil. Atomic.
@property (nullable) dispatch_queue_t callbackQueue;
@end

@implementation AQSBScreen {
    /// The SimDevice, kept so its IO client (and the proxies) stay alive.
    id _device;
    /// The display descriptor: a ROCK proxy conforming to SimScreen.
    id<AQSBSimScreen, AQSBSimDisplayDescriptor> _screen;
    /// The registration token while started, else nil. Guarded by
    /// @synchronized(self), which is held across the register and unregister IPC.
    NSUUID *_token;
}

- (instancetype)initWithUDID:(NSString *)udid
               deviceSetPath:(NSString *)deviceSetPath
                developerDir:(NSString *)developerDir
                       error:(NSError **)error {
    AQSBEnterBridge();
    if ((self = [super init])) {
        _device = AQSBResolveDevice(udid, deviceSetPath, developerDir, YES, error);
        if (!_device) {
            return nil;
        }
        _screen = AQSBFindMainScreen(_device, error);
        if (!_screen) {
            return nil;
        }
        __block id proxy = nil;
        if (!AQSBGuarded(@"-[SimScreen screenProperties]", error, ^{
                proxy = [self->_screen screenProperties];
            })) {
            return nil;
        }
        _initialProperties = [AQSBScreenProperties propertiesFromProxy:proxy error:error];
        if (!_initialProperties) {
            return nil;
        }
    }
    return self;
}

- (IOSurface *)currentSurfaceWithError:(NSError **)error {
    AQSBEnterBridge();
    __block id surface = nil;
    if (!AQSBGuarded(@"-[SimDisplayIOSurfaceRenderable framebufferSurface]", error, ^{
            if ([self->_screen respondsToSelector:@selector(framebufferSurface)]) {
                surface = [self->_screen framebufferSurface];
            }
        })) {
        return nil;
    }
    IOSurface *typed = AQSBAsSurface(surface);
    if (!typed && error) {
        *error = AQSBMakeError(AQSBErrorScreenNotFound, @"the display vends no framebuffer surface", nil);
    }
    return typed;
}

- (AQSBScreenProperties *)currentPropertiesWithError:(NSError **)error {
    AQSBEnterBridge();
    __block id proxy = nil;
    if (!AQSBGuarded(@"-[SimScreen screenProperties]", error, ^{
            proxy = [self->_screen screenProperties];
        })) {
        return nil;
    }
    return [AQSBScreenProperties propertiesFromProxy:proxy error:error];
}

- (BOOL)startWithQueue:(dispatch_queue_t)queue
          frameHandler:(void (^)(void))frameHandler
        surfaceHandler:(void (^)(IOSurface *))surfaceHandler
     propertiesHandler:(void (^)(AQSBScreenProperties *))propertiesHandler
                 error:(NSError **)error {
    AQSBEnterBridge();
    // CoreSimulator delivers with dispatch_sync onto `queue`; registering from
    // that same queue could wait on itself.
    dispatch_assert_queue_not(queue);
    @synchronized(self) {
        if (_token) {
            if (error) {
                *error = AQSBMakeError(AQSBErrorInvalidArgument, @"the screen is already started", nil);
            }
            return NO;
        }
        NSUUID *token = [NSUUID UUID];
        // The blocks capture only the caller's handlers, never self: CoreSimulator
        // keeps them until unregistration, and self must stay free to go away.
        void (^frame)(void) = [frameHandler copy];
        void (^surfaces)(id, id) = ^(id framebuffer, __unused id masked) {
            surfaceHandler(AQSBAsSurface(framebuffer));
        };
        void (^properties)(id) = ^(id proxy) {
            AQSBScreenProperties *read = [AQSBScreenProperties propertiesFromProxy:proxy error:NULL];
            if (read) {
                propertiesHandler(read);
            }
        };
        id<AQSBSimScreen> screen = _screen;
        BOOL registered = AQSBGuarded(@"registerScreenCallbacksWithUUID:…", error, ^{
            [screen registerScreenCallbacksWithUUID:token
                                      callbackQueue:queue
                                      frameCallback:frame
                            surfacesChangedCallback:surfaces
                          propertiesChangedCallback:properties];
        });
        if (!registered) {
            // The raise may have come after the remote side installed the
            // callbacks; roll back so nothing stays registered under the token.
            AQSBGuarded(@"unregisterScreenCallbacksWithUUID: (rollback)", NULL, ^{
                [screen unregisterScreenCallbacksWithUUID:token];
            });
            return NO;
        }
        AQSBCountScreenRegister();
        _token = token;
        self.callbackQueue = queue;
        self.started = YES;
        return YES;
    }
}

- (void)stop {
    AQSBEnterBridge();
    dispatch_queue_t queue = self.callbackQueue;
    if (queue) {
        // A handler runs inside CoreSimulator's dispatch_sync onto `queue`,
        // with its notify thread blocked; unregistering from there is the
        // same self-wait `start` refuses. Hop to another queue first.
        dispatch_assert_queue_not(queue);
    }
    @synchronized(self) {
        if (!_token) {
            return;
        }
        NSUUID *token = _token;
        id<AQSBSimScreen> screen = _screen;
        AQSBGuarded(@"unregisterScreenCallbacksWithUUID:", NULL, ^{
            [screen unregisterScreenCallbacksWithUUID:token];
        });
        AQSBCountScreenUnregister();
        _token = nil;
        self.callbackQueue = nil;
        self.started = NO;
    }
}

- (void)dealloc {
    // A safety net for a caller that forgot `stop`. The last release can land
    // anywhere, the callback queue included, so the unregister goes out from
    // a utility queue rather than from here. The block keeps the device (and
    // with it the proxies) alive until it has run.
    if (!_token) {
        return;
    }
    NSUUID *token = _token;
    id<AQSBSimScreen> screen = _screen;
    id device = _device;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        AQSBGuarded(@"unregisterScreenCallbacksWithUUID: (dealloc)", NULL, ^{
            [screen unregisterScreenCallbacksWithUUID:token];
        });
        AQSBCountScreenUnregister();
        (void)device;
    });
}

@end
