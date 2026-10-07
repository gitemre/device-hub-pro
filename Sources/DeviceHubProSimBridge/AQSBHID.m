#import "AQSBDevice.h"
#import "AQSBGuard.h"
#import "AQSBPrivateAPI.h"

#import <dlfcn.h>
#import <mach/mach_time.h>
#import <os/lock.h>
#import <xpc/xpc.h>

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

/// dtuhidd's digitizer service. Touch, buttons and keys all go to it; the
/// envelope's featureIdentifier names it too.
static const char *const kDigitizerService = "com.apple.coredevice.feature.remote.hid.digitizer";
/// CoreSimulator's error domain; code 405 means the runtime does not vend the service.
static NSString *const kSimErrorDomain = @"com.apple.CoreSimulator.SimError";
static const NSInteger kSimErrorServiceUnsupported = 405;

static double AQSBNowMilliseconds(void) {
    static mach_timebase_info_data_t timebase;
    if (timebase.denom == 0) {
        mach_timebase_info(&timebase);
    }
    return (double)mach_absolute_time() * timebase.numer / timebase.denom / 1e6;
}

static dispatch_time_t AQSBDeadline(NSTimeInterval seconds) {
    return dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC));
}

/// The libxpc simulator entry points, found once with dlsym.
typedef struct {
    AQSBEndpointCreateMachPort4SimFn endpointFromPort;
    AQSBConnectionEnableSim2Host4SimFn enableSim2Host;
} AQSBXPCSimSymbols;

static BOOL AQSBLookUpXPCSimSymbols(AQSBXPCSimSymbols *symbols) {
    static dispatch_once_t once;
    static AQSBXPCSimSymbols found;
    dispatch_once(&once, ^{
        found.endpointFromPort = (AQSBEndpointCreateMachPort4SimFn)dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
        found.enableSim2Host = (AQSBConnectionEnableSim2Host4SimFn)dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    });
    *symbols = found;
    return found.endpointFromPort != NULL && found.enableSim2Host != NULL;
}

/// The plain-XPC envelope dtuhidd decodes: {messageType, isBarrier, featureIdentifier, payload}.
static xpc_object_t AQSBEnvelope(const char *messageType, bool isBarrier, xpc_object_t payload) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", messageType);
    xpc_dictionary_set_bool(message, "isBarrier", isBarrier);
    xpc_dictionary_set_string(message, "featureIdentifier", kDigitizerService);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

/// A barrier carrying keyboard usage 0 ("no event"), so dtuhidd answers
/// without the guest seeing a key press.
static xpc_object_t AQSBBarrierMessage(void) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", 0);
    xpc_dictionary_set_uint64(payload, "state", 2);
    return AQSBEnvelope("IndigoKeyboardButtonEvent", true, payload);
}

/// Per-connection health, flipped by the connection's event handler. Its own
/// object so a late error from a cancelled connection cannot mark a newer one.
@interface AQSBConnectionHealth : NSObject
@property (atomic) BOOL broken;
@end

@implementation AQSBConnectionHealth
@end

// MARK: - Connect report

@implementation AQSBHIDConnectReport

- (instancetype)initWithAttempts:(NSInteger)attempts barrier:(double)barrier total:(double)total {
    if ((self = [super init])) {
        _attempts = attempts;
        _barrierMilliseconds = barrier;
        _totalMilliseconds = total;
    }
    return self;
}

- (NSString *)description {
    return [NSString stringWithFormat:@"<AQSBHIDConnectReport attempts=%ld barrier=%.1fms total=%.1fms>",
                                      (long)_attempts, _barrierMilliseconds, _totalMilliseconds];
}

@end

// MARK: - HID

@implementation AQSBHID {
    NSString *_udid;
    NSString *_deviceSetPath;
    NSString *_developerDir;
    /// Serialises connects, so one runs at a time. It is held across the slow
    /// part (device lookup, barrier, backoff) and nothing else takes it.
    NSObject *_connectGate;
    /// Guards every ivar below. It is held only to read or write them, never
    /// across IPC, a wait or a sleep, so the getters, `flush` and `disconnect`
    /// never wait for a connect in progress.
    os_unfair_lock _stateLock;
    /// The installed connection, or nil.
    xpc_connection_t _connection;
    AQSBConnectionHealth *_health;
    AQSBHIDConnectReport *_lastConnectReport;
    /// Bumped by every `disconnect`. A connect that sees it move gives up.
    uint64_t _generation;
    /// The connect in progress: the connection it is testing (a `disconnect`
    /// takes and cancels it, which answers the barrier with an error) and the
    /// semaphore that cuts its backoff and reply-tail waits short.
    xpc_connection_t _pending;
    dispatch_semaphore_t _pendingWake;
}

- (instancetype)initWithUDID:(NSString *)udid deviceSetPath:(NSString *)deviceSetPath developerDir:(NSString *)developerDir {
    if ((self = [super init])) {
        _udid = [udid copy];
        _deviceSetPath = [deviceSetPath copy];
        _developerDir = [developerDir copy];
        _connectGate = [NSObject new];
        _stateLock = OS_UNFAIR_LOCK_INIT;
        // idb's SimulatorDTUHIDTransport timing (DTUHIDTiming).
        _livenessAttempts = 5;
        _livenessTimeout = 4;
        _retryBackoff = 4;
        _replyTail = 0.2;
    }
    return self;
}

/// The installed connection while it is healthy, else nil. Never waits.
- (nullable xpc_connection_t)liveConnection {
    os_unfair_lock_lock(&_stateLock);
    xpc_connection_t live = (_connection && !_health.broken) ? _connection : nil;
    os_unfair_lock_unlock(&_stateLock);
    return live;
}

- (BOOL)isConnected {
    return [self liveConnection] != nil;
}

- (AQSBHIDConnectReport *)lastConnectReport {
    os_unfair_lock_lock(&_stateLock);
    AQSBHIDConnectReport *report = _lastConnectReport;
    os_unfair_lock_unlock(&_stateLock);
    return report;
}

- (BOOL)connectWithError:(NSError **)error {
    AQSBEnterBridge();
    return [self connectionConnectingIfNeeded:error] != nil;
}

/// The live connection, connecting first when there is none.
- (nullable xpc_connection_t)connectionConnectingIfNeeded:(NSError **)error {
    xpc_connection_t live = [self liveConnection];
    if (live) {
        return live;
    }
    @synchronized(_connectGate) {
        // Another caller may have connected while this one waited at the gate.
        live = [self liveConnection];
        if (live) {
            return live;
        }
        return [self gatedConnectWithError:error];
    }
}

/// Runs under `_connectGate`. Drops a broken connection, then makes the
/// attempts with a fresh wake semaphore registered for `disconnect`.
- (nullable xpc_connection_t)gatedConnectWithError:(NSError **)error {
    AQSBXPCSimSymbols symbols;
    if (!AQSBLookUpXPCSimSymbols(&symbols)) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorAPIUnavailable,
                                   @"libxpc has no xpc_endpoint_create_mach_port_4sim / xpc_connection_enable_sim2host_4sim", nil);
        }
        return nil;
    }
    dispatch_semaphore_t wake = dispatch_semaphore_create(0);
    os_unfair_lock_lock(&_stateLock);
    uint64_t generation = _generation;
    xpc_connection_t broken = _connection;
    _connection = nil;
    _health = nil;
    _pendingWake = wake;
    os_unfair_lock_unlock(&_stateLock);
    if (broken) {
        xpc_connection_cancel(broken);
    }

    xpc_connection_t connection = [self attemptWithSymbols:symbols generation:generation wake:wake error:error];

    os_unfair_lock_lock(&_stateLock);
    if (_pendingWake == wake) {
        _pendingWake = nil;
    }
    os_unfair_lock_unlock(&_stateLock);
    return connection;
}

/// Whether no `disconnect` came since the connect read `generation`.
- (BOOL)isCurrentGeneration:(uint64_t)generation {
    os_unfair_lock_lock(&_stateLock);
    BOOL current = _generation == generation;
    os_unfair_lock_unlock(&_stateLock);
    return current;
}

static NSError *AQSBCancelledError(void) {
    return AQSBMakeError(AQSBErrorCancelled, @"disconnect cancelled the dtuhidd connect in progress", nil);
}

/// Each attempt repeats the service lookup: it fails while dtuhidd's job is
/// mid-respawn, which is the very state being retried out of (idb). Between
/// its blocking steps the loop checks for a `disconnect`.
- (nullable xpc_connection_t)attemptWithSymbols:(AQSBXPCSimSymbols)symbols
                                     generation:(uint64_t)generation
                                           wake:(dispatch_semaphore_t)wake
                                          error:(NSError **)error {
    double started = AQSBNowMilliseconds();
    NSInteger attempts = MAX(1, self.livenessAttempts);
    NSError *lastFailure = nil;
    for (NSInteger attempt = 1; attempt <= attempts; attempt++) {
        if (attempt > 1) {
            // A disconnect signals `wake` and ends the wait early.
            dispatch_semaphore_wait(wake, AQSBDeadline(self.retryBackoff));
        }
        if (![self isCurrentGeneration:generation]) {
            if (error) {
                *error = AQSBCancelledError();
            }
            return nil;
        }
        NSError *attemptError = nil;
        id<AQSBSimDevice> device = AQSBResolveDevice(_udid, _deviceSetPath, _developerDir, YES, &attemptError);
        if (!device) {
            // No device, not booted, or no CoreSimulator: asking again will not help.
            if (error) {
                *error = attemptError;
            }
            return nil;
        }

        __block mach_port_t port = MACH_PORT_NULL;
        __block NSError *lookupError = nil;
        if (!AQSBGuarded(@"-[SimDevice lookup:error:]", &attemptError, ^{
                NSError *inner = nil;
                port = [device lookup:@(kDigitizerService) error:&inner];
                lookupError = inner;
            })) {
            if (error) {
                *error = attemptError;
            }
            return nil;
        }
        if (port == MACH_PORT_NULL) {
            NSError *failure = AQSBMakeError(AQSBErrorServiceLookupFailed,
                                             [NSString stringWithFormat:@"%s lookup failed", kDigitizerService], lookupError);
            if ([lookupError.domain isEqualToString:kSimErrorDomain] && lookupError.code == kSimErrorServiceUnsupported) {
                // The runtime does not vend dtuhidd at all (an older runtime).
                if (error) {
                    *error = failure;
                }
                return nil;
            }
            lastFailure = failure;
            continue;
        }

        // The endpoint consumes the lookup's send right; both creators return +1.
        void *rawEndpoint = symbols.endpointFromPort(port, 0, 0);
        if (!rawEndpoint) {
            lastFailure = AQSBMakeError(AQSBErrorServiceLookupFailed, @"xpc_endpoint_create_mach_port_4sim returned NULL", nil);
            continue;
        }
        xpc_endpoint_t endpoint = (__bridge_transfer xpc_endpoint_t)rawEndpoint;
        xpc_connection_t connection = xpc_connection_create_from_endpoint(endpoint);
        if (!connection) {
            lastFailure = AQSBMakeError(AQSBErrorServiceLookupFailed, @"xpc_connection_create_from_endpoint returned NULL", nil);
            continue;
        }
        // Without this the service observes the peer but never a payload (idb).
        symbols.enableSim2Host((__bridge void *)connection);
        AQSBConnectionHealth *health = [AQSBConnectionHealth new];
        xpc_connection_set_event_handler(connection, ^(xpc_object_t event) {
            if (xpc_get_type(event) == XPC_TYPE_ERROR) {
                health.broken = YES;
            }
        });
        xpc_connection_resume(connection);

        // Publish the candidate, so a disconnect from here on cancels it.
        os_unfair_lock_lock(&_stateLock);
        BOOL current = _generation == generation;
        if (current) {
            _pending = connection;
        }
        os_unfair_lock_unlock(&_stateLock);
        if (!current) {
            xpc_connection_cancel(connection);
            if (error) {
                *error = AQSBCancelledError();
            }
            return nil;
        }

        double barrierStarted = AQSBNowMilliseconds();
        NSError *barrierError = nil;
        BOOL answered = [self waitForLivenessOn:connection error:&barrierError];
        double barrier = AQSBNowMilliseconds() - barrierStarted;
        if (answered) {
            // Time for dtuhidd to open its devices after it activated (idb's reply tail).
            dispatch_semaphore_wait(wake, AQSBDeadline(self.replyTail));
        }
        // Install or drop the candidate in one step with the generation
        // check. A disconnect that already ran took it and cancelled it.
        os_unfair_lock_lock(&_stateLock);
        BOOL stillOurs = _pending == connection;
        if (stillOurs) {
            _pending = nil;
            if (answered) {
                _connection = connection;
                _health = health;
                _lastConnectReport = [[AQSBHIDConnectReport alloc] initWithAttempts:attempt
                                                                            barrier:barrier
                                                                              total:AQSBNowMilliseconds() - started];
            }
        }
        os_unfair_lock_unlock(&_stateLock);
        if (!stillOurs) {
            if (error) {
                *error = AQSBCancelledError();
            }
            return nil;
        }
        if (answered) {
            return connection;
        }
        xpc_connection_cancel(connection);
        lastFailure = barrierError;
    }
    if (error) {
        *error = AQSBMakeError(AQSBErrorHIDUnresponsive,
                               [NSString stringWithFormat:@"dtuhidd did not answer after %ld attempts", (long)attempts],
                               lastFailure);
    }
    return nil;
}

/// Round-trips a barrier: every step before it succeeds even when no daemon
/// can run, so an answered barrier is the only proof of a live dtuhidd.
- (BOOL)waitForLivenessOn:(xpc_connection_t)connection error:(NSError **)error {
    dispatch_semaphore_t answered = dispatch_semaphore_create(0);
    __block NSString *peerError = nil;
    xpc_connection_send_message_with_reply(connection, AQSBBarrierMessage(),
                                           dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^(xpc_object_t reply) {
        if (xpc_get_type(reply) == XPC_TYPE_ERROR) {
            const char *description = xpc_dictionary_get_string(reply, XPC_ERROR_KEY_DESCRIPTION);
            peerError = description ? @(description) : @"unknown XPC error";
        }
        dispatch_semaphore_signal(answered);
    });
    if (dispatch_semaphore_wait(answered, AQSBDeadline(self.livenessTimeout)) != 0) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorTimedOut,
                                   [NSString stringWithFormat:@"no barrier reply within %.1f s", self.livenessTimeout], nil);
        }
        return NO;
    }
    if (peerError) {
        // XPC answered on the peer's behalf: no daemon took the message.
        if (error) {
            *error = AQSBMakeError(AQSBErrorHIDUnresponsive, [NSString stringWithFormat:@"barrier failed: %@", peerError], nil);
        }
        return NO;
    }
    return YES;
}

/// Sends outside every lock: callers keep their events in order by sending
/// from one serial queue, and XPC keeps one thread's messages in order.
- (BOOL)sendMessageType:(const char *)messageType payload:(xpc_object_t)payload error:(NSError **)error {
    xpc_connection_t connection = [self connectionConnectingIfNeeded:error];
    if (!connection) {
        return NO;
    }
    xpc_connection_send_message(connection, AQSBEnvelope(messageType, false, payload));
    return YES;
}

static BOOL AQSBIsRatio(double value) {
    return value >= 0 && value <= 1;
}

static xpc_object_t AQSBDigitizerPoint(double x, double y) {
    xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_double(point, "x", x);
    xpc_dictionary_set_double(point, "y", y);
    return point;
}

- (BOOL)sendTouchAtX:(double)x y:(double)y phase:(AQSBTouchPhase)phase error:(NSError **)error {
    return [self sendTouchAtX:x y:y phase:phase edge:AQSBTouchEdgeNone error:error];
}

- (BOOL)sendTouchAtX:(double)x y:(double)y phase:(AQSBTouchPhase)phase edge:(AQSBTouchEdge)edge error:(NSError **)error {
    AQSBEnterBridge();
    if (!AQSBIsRatio(x) || !AQSBIsRatio(y) || phase > AQSBTouchPhaseEnded || edge > AQSBTouchEdgeRight) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorInvalidArgument,
                                   [NSString stringWithFormat:@"touch (%f, %f) phase %llu edge %llu is out of range",
                                                              x, y, (unsigned long long)phase, (unsigned long long)edge],
                                   nil);
        }
        return NO;
    }
    // A single contact omits pointTwo entirely (idb's XPCEncoder does the same).
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", AQSBDigitizerPoint(x, y));
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", edge);
    xpc_dictionary_set_uint64(payload, "target", 0);
    return [self sendMessageType:"IndigoDigitizerEvent" payload:payload error:error];
}

- (BOOL)sendTwoFingerTouchAtX:(double)x
                            y:(double)y
                      secondX:(double)secondX
                      secondY:(double)secondY
                        phase:(AQSBTouchPhase)phase
                        error:(NSError **)error {
    AQSBEnterBridge();
    if (!AQSBIsRatio(x) || !AQSBIsRatio(y) || !AQSBIsRatio(secondX) || !AQSBIsRatio(secondY) || phase > AQSBTouchPhaseEnded) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorInvalidArgument,
                                   [NSString stringWithFormat:@"two-finger touch (%f, %f) (%f, %f) phase %llu is out of range",
                                                              x, y, secondX, secondY, (unsigned long long)phase],
                                   nil);
        }
        return NO;
    }
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "pointOne", AQSBDigitizerPoint(x, y));
    xpc_dictionary_set_value(payload, "pointTwo", AQSBDigitizerPoint(secondX, secondY));
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", AQSBTouchEdgeNone);
    xpc_dictionary_set_uint64(payload, "target", 0);
    return [self sendMessageType:"IndigoDigitizerEvent" payload:payload error:error];
}

- (BOOL)sendButtonWithUsagePage:(uint32_t)usagePage usage:(uint32_t)usage down:(BOOL)down error:(NSError **)error {
    AQSBEnterBridge();
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usagePage", usagePage);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    // dtuhidd's HIDButtonState is 1-based: 1 down, 2 up (0 fails to decode).
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    return [self sendMessageType:"IndigoButtonEvent" payload:payload error:error];
}

- (BOOL)sendKeyWithUsage:(uint32_t)usage down:(BOOL)down error:(NSError **)error {
    AQSBEnterBridge();
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    return [self sendMessageType:"IndigoKeyboardButtonEvent" payload:payload error:error];
}

- (BOOL)flushWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    AQSBEnterBridge();
    os_unfair_lock_lock(&_stateLock);
    xpc_connection_t connection = _connection;
    os_unfair_lock_unlock(&_stateLock);
    if (!connection) {
        return YES;
    }
    dispatch_semaphore_t sent = dispatch_semaphore_create(0);
    xpc_connection_send_barrier(connection, ^{
        dispatch_semaphore_signal(sent);
    });
    if (dispatch_semaphore_wait(sent, AQSBDeadline(timeout)) != 0) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorTimedOut, [NSString stringWithFormat:@"flush did not finish within %.1f s", timeout], nil);
        }
        return NO;
    }
    return YES;
}

- (void)disconnect {
    AQSBEnterBridge();
    // Take everything under the lock; cancel and wake outside it. Whoever
    // takes a connection out of an ivar is the one that cancels it.
    os_unfair_lock_lock(&_stateLock);
    _generation += 1;
    xpc_connection_t connection = _connection;
    xpc_connection_t pending = _pending;
    dispatch_semaphore_t wake = _pendingWake;
    _connection = nil;
    _health = nil;
    _pending = nil;
    os_unfair_lock_unlock(&_stateLock);
    if (connection) {
        xpc_connection_cancel(connection);
    }
    if (pending) {
        xpc_connection_cancel(pending);
    }
    if (wake) {
        dispatch_semaphore_signal(wake);
    }
}

- (void)dealloc {
    if (_connection) {
        xpc_connection_cancel(_connection);
    }
    if (_pending) {
        xpc_connection_cancel(_pending);
    }
}

@end
