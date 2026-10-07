// DeviceHubProSimBridge: the only code in Device Hub Pro that names private CoreSimulator
// selectors. It gives the Kit a small, message-shaped API over four things:
//
// - loading CoreSimulator (dlopen, never linked) and resolving a simulator by
//   UDID in the default or a given device set;
// - the main screen's IOSurface and its frame / surface / properties callbacks;
// - touch, button and key input through the simulator's dtuhidd service;
// - the GSEvents SpringBoard takes on its PurpleWorkspacePort (rotation, lock).
//
// Nothing that crosses this header is a private object: callers pass strings and
// numbers and get IOSurfaces, plain value objects and NSErrors back, so the
// bridge can move into an XPC helper later without changing its callers.
//
// Rules every entry point follows:
// - It must not run on the main queue. Each one asserts that with
//   dispatch_assert_queue_not, which stops the process: ROCK proxy calls are
//   synchronous IPC (a device lookup took 70–498 ms in the spike). The state
//   getters (`isStarted`, `isConnected`, `lastConnectReport`) are not entry
//   points: they never wait and are safe anywhere.
// - Every message to a private object runs inside @try. An NSException raised
//   in Apple's code comes back as an AQSBErrorException NSError; Swift could not
//   catch it otherwise.
//
// Which private selector and function comes from where is recorded in
// PROVENANCE.md next to the sources.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

// MARK: - Errors

FOUNDATION_EXPORT NSErrorDomain const AQSBErrorDomain;
/// The name of the NSException behind an AQSBErrorException error.
FOUNDATION_EXPORT NSErrorUserInfoKey const AQSBExceptionNameKey;
/// The reason of the NSException behind an AQSBErrorException error.
FOUNDATION_EXPORT NSErrorUserInfoKey const AQSBExceptionReasonKey;

typedef NS_ERROR_ENUM(AQSBErrorDomain, AQSBError) {
    /// CoreSimulator could not be loaded (`dlopen` failed).
    AQSBErrorLoadFailed = 1,
    /// A class, selector or function the bridge needs is missing: the private
    /// surface moved (a new CoreSimulator) and the bridge needs an update.
    AQSBErrorAPIUnavailable = 2,
    /// Apple's code raised an NSException; see AQSBExceptionNameKey/ReasonKey.
    AQSBErrorException = 3,
    /// No simulator with that UDID in the device set.
    AQSBErrorDeviceNotFound = 4,
    /// The simulator exists but is not booted.
    AQSBErrorDeviceNotBooted = 5,
    /// The booted simulator has no main screen (display class 0) to stream.
    AQSBErrorScreenNotFound = 6,
    /// The simulator's bootstrap namespace has no such service, or the lookup failed.
    AQSBErrorServiceLookupFailed = 7,
    /// dtuhidd did not answer the readiness barrier after every retry.
    AQSBErrorHIDUnresponsive = 8,
    /// An argument was out of range (for example a touch ratio outside 0...1).
    AQSBErrorInvalidArgument = 9,
    /// A wait (barrier, flush) ran out of time.
    AQSBErrorTimedOut = 10,
    /// `disconnect` cancelled the HID connect in progress.
    AQSBErrorCancelled = 11,
    /// A mach message could not be sent (a kernel error other than a timeout).
    AQSBErrorSendFailed = 12,
} NS_SWIFT_NAME(SimBridgeError);

// MARK: - Loader

/// Loads CoreSimulator into this process. SimulatorKit is never loaded: the
/// three mechanisms the bridge uses live in CoreSimulator (which re-exports
/// CoreSimDeviceIO) and libxpc.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeLoader)
@interface AQSBLoader : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// The system-wide CoreSimulator the bridge loads.
@property (class, readonly, copy) NSString *coreSimulatorPath;

/// dlopens CoreSimulator once per process; later calls return the first
/// result. Must not run on the main queue.
+ (BOOL)loadCoreSimulatorWithError:(NSError **)error NS_SWIFT_NAME(loadCoreSimulator());

/// CFBundleVersion of the CoreSimulator bundle this process loaded (the bundle
/// that defines SimDevice), or nil before a successful load. It can differ
/// from the installed version when an Xcode update replaced CoreSimulator
/// while the process ran.
@property (class, readonly, copy, nullable) NSString *loadedCoreSimulatorVersion;

/// Whether any SimulatorKit image is mapped into this process. The bridge
/// never loads it, so this answers "did anything need it".
@property (class, readonly) BOOL simulatorKitLoaded;

@end

// MARK: - Diagnostics

/// Process-wide counters, for the smoke tool and tests.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeDiagnostics)
@interface AQSBDiagnostics : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Public bridge entry points called so far. Each one asserted it was off the main queue.
@property (class, readonly) uint64_t entryCount;
/// Private calls made inside the exception guard.
@property (class, readonly) uint64_t guardedCallCount;
/// NSExceptions the guard caught and turned into errors.
@property (class, readonly) uint64_t exceptionCount;
/// Screen callback registrations and unregistrations sent to CoreSimulator.
@property (class, readonly) uint64_t screenRegisterCount;
@property (class, readonly) uint64_t screenUnregisterCount;

@end

// MARK: - Screen

/// The main screen's properties as plain values.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeScreenProperties)
@interface AQSBScreenProperties : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// CoreSimulator's screen type; 0 is the device's own panel ("LCD").
@property (readonly) uint64_t screenType;
@property (readonly) uint32_t screenID;
/// UIKit-style interface orientation: 1 portrait, 2 upside down, 3 and 4 the
/// landscapes. The framebuffer itself stays in native portrait.
@property (readonly) uint32_t uiOrientation;
/// The panel size in pixels (native portrait).
@property (readonly) CGSize pixelSize;

@end

/// One simulator's main screen. The instance resolves the device and the
/// class-0 display when it is created; `start` registers the callbacks.
/// Thread-safe; must not be used on the main queue (`started` excepted).
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeScreen)
@interface AQSBScreen : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Resolves `udid` in `deviceSetPath` (nil: the default set) through a service
/// context for `developerDir`, then finds the display whose descriptor state
/// has display class 0 and that vends the SimScreen callbacks.
- (nullable instancetype)initWithUDID:(NSString *)udid
                        deviceSetPath:(nullable NSString *)deviceSetPath
                         developerDir:(NSString *)developerDir
                                error:(NSError **)error NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(udid:deviceSetPath:developerDir:));

/// The properties read when the screen was resolved.
@property (readonly) AQSBScreenProperties *initialProperties;

/// The framebuffer the display vends right now, read synchronously. The
/// simulator rewrites it in place: copy before publishing a frame.
- (nullable IOSurface *)currentSurfaceWithError:(NSError **)error NS_SWIFT_NAME(currentSurface());

/// The screen's properties right now (the interface orientation among them),
/// read synchronously.
- (nullable AQSBScreenProperties *)currentPropertiesWithError:(NSError **)error NS_SWIFT_NAME(currentProperties());

/// Registers the screen callbacks on `queue` (a serial queue the caller owns).
/// CoreSimulator calls them with `dispatch_sync` from its notify thread, so
/// each handler must stay short.
/// - `frameHandler`: once per presented frame; nothing while the screen is idle.
/// - `surfaceHandler`: once right after registering with the current
///   framebuffer, again when the surface is replaced, and with nil when the
///   device went away (shut down).
/// - `propertiesHandler`: when a property changes (rotation).
/// A second start while started fails with AQSBErrorInvalidArgument.
- (BOOL)startWithQueue:(dispatch_queue_t)queue
          frameHandler:(void (NS_SWIFT_SENDABLE ^)(void))frameHandler
        surfaceHandler:(void (NS_SWIFT_SENDABLE ^)(IOSurface *_Nullable framebuffer))surfaceHandler
     propertiesHandler:(void (NS_SWIFT_SENDABLE ^)(AQSBScreenProperties *properties))propertiesHandler
                 error:(NSError **)error
    NS_SWIFT_NAME(start(queue:frameHandler:surfaceHandler:propertiesHandler:));

/// Unregisters the callbacks. Idempotent, and safe after the device shut down.
/// Must not run on the callback queue (it asserts, like `start`): a handler
/// that reacts to a nil surface hops to the caller's own queue first.
- (void)stop;

/// Never waits, not even for a `start` or `stop` in progress; safe on any queue.
@property (readonly, getter=isStarted) BOOL started;

@end

// MARK: - HID

typedef NS_ENUM(uint64_t, AQSBTouchPhase) {
    AQSBTouchPhaseBegan = 0,
    AQSBTouchPhaseMoved = 1,
    AQSBTouchPhaseEnded = 2,
} NS_SWIFT_NAME(SimBridgeTouchPhase);

/// The screen edge a contact starts at (IndigoHIDEdge), in the panel's native
/// portrait frame. Edge 0 is an ordinary touch.
typedef NS_ENUM(uint64_t, AQSBTouchEdge) {
    AQSBTouchEdgeNone = 0,
    AQSBTouchEdgeTop = 1,
    AQSBTouchEdgeLeft = 2,
    AQSBTouchEdgeBottom = 3,
    AQSBTouchEdgeRight = 4,
} NS_SWIFT_NAME(SimBridgeTouchEdge);

/// How the last successful connection went.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeHIDConnectReport)
@interface AQSBHIDConnectReport : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

/// Liveness attempts it took (1 when dtuhidd answered at once).
@property (readonly) NSInteger attempts;
/// Round trip of the barrier that answered, in milliseconds.
@property (readonly) double barrierMilliseconds;
/// From the start of `connect` to a usable connection, in milliseconds,
/// retries and backoff included.
@property (readonly) double totalMilliseconds;

@end

/// Input to one simulator through its dtuhidd digitizer service (Xcode 27,
/// CoreSimulator 1155.4 and later).
///
/// The connection is lazy: creating the object connects nothing. The first
/// send (or `connect`) looks the service up, opens the XPC connection and
/// waits for a barrier reply, retrying the way idb does (5 attempts, 4 s reply
/// deadline, 4 s backoff) because dtuhidd starts on demand and can crash-loop
/// early in boot. Connecting sets `com.apple.coredevice.dtuhidd.active` for
/// the life of the simulator's backboardd, which cuts legacy-Indigo clients
/// off, so nothing connects before the user's first input.
///
/// Thread-safe. `connect` and the first send can block for up to about 40 s,
/// but only each other: the connect holds no lock the rest of the class
/// takes, so `connected` and `lastConnectReport` answer at once (and are the
/// only members safe on the main queue), `flush` keeps its own deadline, and
/// `disconnect` from another queue cancels a connect in progress, which then
/// fails with AQSBErrorCancelled.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgeHID)
@interface AQSBHID : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithUDID:(NSString *)udid
               deviceSetPath:(nullable NSString *)deviceSetPath
                developerDir:(NSString *)developerDir NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(udid:deviceSetPath:developerDir:));

/// Liveness attempts before giving up (idb: 5).
@property NSInteger livenessAttempts;
/// Deadline for each barrier reply, in seconds (idb: 4).
@property NSTimeInterval livenessTimeout;
/// Wait between attempts, in seconds (idb: 4; dtuhidd's launchd job has a
/// 10 s minimum runtime, so retrying sooner re-reads a throttled job).
@property NSTimeInterval retryBackoff;
/// Wait after the barrier answers, for the daemon to open its devices (idb: 0.2 s).
@property NSTimeInterval replyTail;

/// Never waits; safe on any queue.
@property (readonly, getter=isConnected) BOOL connected;
/// Never waits; safe on any queue.
@property (readonly, nullable) AQSBHIDConnectReport *lastConnectReport;

/// Connects now if not connected. Returns YES when a live dtuhidd answered.
- (BOOL)connectWithError:(NSError **)error NS_SWIFT_NAME(connect());

/// One digitizer contact. `x` and `y` are ratios (0...1) of the native
/// portrait framebuffer, whatever the interface orientation.
- (BOOL)sendTouchAtX:(double)x y:(double)y phase:(AQSBTouchPhase)phase error:(NSError **)error
    NS_SWIFT_NAME(sendTouch(x:y:phase:));

/// One digitizer contact tagged with the screen edge it started at (the
/// event's `edge` field). Edge none is the same as `sendTouch(x:y:phase:)`.
- (BOOL)sendTouchAtX:(double)x y:(double)y phase:(AQSBTouchPhase)phase edge:(AQSBTouchEdge)edge error:(NSError **)error
    NS_SWIFT_NAME(sendTouch(x:y:phase:edge:));

/// Two contacts in one digitizer event (`pointOne` and `pointTwo`), sharing
/// one phase: both go down, move and lift together. Ratios as for one contact.
- (BOOL)sendTwoFingerTouchAtX:(double)x
                            y:(double)y
                      secondX:(double)secondX
                      secondY:(double)secondY
                        phase:(AQSBTouchPhase)phase
                        error:(NSError **)error
    NS_SWIFT_NAME(sendTwoFingerTouch(x:y:secondX:secondY:phase:));

/// A hardware button as a HID usage (Home is page 0x0C, usage 0x40).
- (BOOL)sendButtonWithUsagePage:(uint32_t)usagePage usage:(uint32_t)usage down:(BOOL)down error:(NSError **)error
    NS_SWIFT_NAME(sendButton(usagePage:usage:down:));

/// A keyboard key as a USB HID usage (page 7). Usages are key positions; the
/// simulator's hardware keyboard layout picks the character. Modifiers are
/// keys too (Left Shift 0xE1, Left GUI 0xE3): hold one by sending it down
/// before the key and up after it.
- (BOOL)sendKeyWithUsage:(uint32_t)usage down:(BOOL)down error:(NSError **)error
    NS_SWIFT_NAME(sendKey(usage:down:));

/// Waits until everything sent so far has left this process.
- (BOOL)flushWithTimeout:(NSTimeInterval)timeout error:(NSError **)error NS_SWIFT_NAME(flush(timeout:));

/// Cancels the connection, and a connect in progress on another queue (it
/// fails with AQSBErrorCancelled). The next send connects again. Idempotent.
- (void)disconnect;

@end

// MARK: - GSEvents (Purple)

/// The GSEvents SpringBoard reads from its `PurpleWorkspacePort`: device
/// orientation and lock. Each send looks the port up in the simulator's
/// bootstrap namespace and writes one raw mach message with a send timeout,
/// so there is no connection to open or tear down, and a SpringBoard whose
/// queue is full fails the send (AQSBErrorTimedOut) instead of hanging it.
///
/// Thread-safe (it keeps no state besides its settings); must not be used on
/// the main queue.
NS_SWIFT_SENDABLE
NS_SWIFT_NAME(SimBridgePurple)
@interface AQSBPurple : NSObject

- (instancetype)init NS_UNAVAILABLE;
+ (instancetype)new NS_UNAVAILABLE;

- (instancetype)initWithUDID:(NSString *)udid
               deviceSetPath:(nullable NSString *)deviceSetPath
                developerDir:(NSString *)developerDir NS_DESIGNATED_INITIALIZER
    NS_SWIFT_NAME(init(udid:deviceSetPath:developerDir:));

/// The mach send timeout, in seconds (idb: 2).
@property (atomic) NSTimeInterval sendTimeout;

/// A device-orientation GSEvent carrying `orientation`, 1 through 4 (the
/// value the guest's orientation machinery reads; the Kit pins what each
/// value does). Anything else fails with AQSBErrorInvalidArgument.
- (BOOL)sendOrientation:(uint32_t)orientation error:(NSError **)error NS_SWIFT_NAME(sendOrientation(_:));

/// A lock-device GSEvent.
- (BOOL)sendLockWithError:(NSError **)error NS_SWIFT_NAME(sendLock());

@end

NS_ASSUME_NONNULL_END
