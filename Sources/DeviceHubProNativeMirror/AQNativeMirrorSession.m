// Native (CoreDevice media-stream) screen stream of one iPhone.
//
// Vendored from ipb's Sources/mirror.m (https://github.com/ipbtools/ipb, MIT,
// copyright 2026 Borealin and ipbtools contributors; pinned commit
// f2e85a6d60c45f18e6f9f2a306f709ffb9710392, licence text in fastinput/LICENSE).
// Taken: the media-stream negotiation and socket setup (runMirror), the
// in-process frame sink (InProcSink, the VCImageQueue start hook), the
// product-type screen table and the content-rectangle detection. Stripped: every
// HID / input path, the window and menus, CSV output, screenshots, scrolling, the
// Xcode display-size database lookup and the command line. Changed: private symbols are resolved
// with dlopen / dlsym / NSClassFromString (nothing private is linked), frames go to
// a latest-only handler on a private queue, and the state lives in a session
// object. See fastinput/PROVENANCE.md.

#import "AQNativeMirrorSession.h"
#import "AQNativeMirrorTuning.h"
#import <CoreMedia/CoreMedia.h>
#import <objc/runtime.h>
#include <xpc/xpc.h>
#include <uuid/uuid.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <net/if.h>
#include <dlfcn.h>
#include <errno.h>
#include <unistd.h>
#include <time.h>

NSErrorDomain const AQNativeMirrorErrorDomain = @"com.devicehubpro.nativemirror";

// MARK: - Shapes of the private classes (compile time only; never linked)

typedef void *AQRemote;
@interface AQNegotiatorShape : NSObject
- (instancetype)initWithMode:(long)mode options:(NSDictionary *)o error:(NSError **)e;
- (BOOL)createOffer;
- (NSData *)offer;
- (BOOL)setAnswer:(NSData *)a withError:(NSError **)e;
- (id)generateMediaStreamConfigurationWithError:(NSError **)e;
- (id)generateMediaStreamInitOptionsWithError:(NSError **)e;
@end
@interface AQVideoStreamShape : NSObject
- (instancetype)initWithNetworkSockets:(id)socks options:(id)opts error:(NSError **)e;
- (BOOL)configure:(id)cfg error:(NSError **)e;
- (void)setDelegate:(id)d;
- (void)start;
- (void)stop;
@end
@interface AQImageQueueShape : NSObject
- (long long)streamToken;
- (id)streamOutput;
- (void)setStreamOutput:(id)o;
@end
@interface AQStreamOutputShape : NSObject
- (instancetype)initWithStreamToken:(long long)t clientProcessID:(int)pid delegate:(id)d delegateQueue:(dispatch_queue_t)q;
@end

// MARK: - Symbols resolved at run time

static void (*sAddBundle)(NSBundle *);
static void (*sInitServices)(void);
static AQRemote (*sRCCreate)(int, dispatch_queue_t, uint64_t, uint64_t);
static void (*sRCSetHandler)(AQRemote, xpc_handler_t);
static void (*sRCActivate)(AQRemote);
static xpc_object_t (*sRCSendSync)(AQRemote, xpc_object_t);
static void (*sRCCancel)(AQRemote);

static NSString *AQLoadFrameworks(void) {
    static NSString *problem;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *core = dlopen("/Library/Developer/PrivateFrameworks/CoreDevice.framework/Versions/A/CoreDevice", RTLD_NOW);
        if (!core) { problem = @"CoreDevice is not installed"; return; }
        if (!dlopen("/System/Library/PrivateFrameworks/AVConference.framework/Versions/A/AVConference", RTLD_NOW)) {
            problem = @"AVConference is not available"; return;
        }
        sAddBundle = dlsym(core, "_coredevice_xpc_add_bundle");
        sInitServices = dlsym(core, "_coredevice_xpc_init_services");
        sRCCreate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_create_with_connected_fd");
        sRCSetHandler = dlsym(RTLD_DEFAULT, "xpc_remote_connection_set_event_handler");
        sRCActivate = dlsym(RTLD_DEFAULT, "xpc_remote_connection_activate");
        sRCSendSync = dlsym(RTLD_DEFAULT, "xpc_remote_connection_send_message_with_reply_sync");
        sRCCancel = dlsym(RTLD_DEFAULT, "xpc_remote_connection_cancel");
        if (!sAddBundle || !sInitServices || !sRCCreate || !sRCSetHandler || !sRCActivate || !sRCSendSync || !sRCCancel) {
            problem = @"the CoreDevice service entry points are missing"; return;
        }
        if (!NSClassFromString(@"AVCMediaStreamNegotiator") || !NSClassFromString(@"AVCVideoStream")
            || !NSClassFromString(@"VCImageQueue") || !NSClassFromString(@"VCStreamOutput")) {
            problem = @"the media-stream classes are missing"; return;
        }
        sAddBundle([NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"]);
        sInitServices();
    });
    return problem;
}

static NSError *AQError(AQNativeMirrorErrorCode code, NSString *message) {
    return [NSError errorWithDomain:AQNativeMirrorErrorDomain code:code
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

static double AQNow(void) { return clock_gettime_nsec_np(CLOCK_MONOTONIC) / 1e9; }

// MARK: - Screen sizes of the product types

// Generated upstream 2026-09-09 from Xcode's device_traits.db and the simulator
// device types' capabilities.plist (displays[0] width and height).
static const struct { const char *productType; unsigned width, height; } kScreenTable[] = {
    {"iPhone8,1", 750, 1334}, {"iPhone8,2", 1242, 2208}, {"iPhone8,4", 640, 1136},
    {"iPhone9,1", 750, 1334}, {"iPhone9,2", 1242, 2208}, {"iPhone9,3", 750, 1334}, {"iPhone9,4", 1242, 2208},
    {"iPhone10,1", 750, 1334}, {"iPhone10,2", 1242, 2208}, {"iPhone10,3", 1125, 2436},
    {"iPhone10,4", 750, 1334}, {"iPhone10,5", 1242, 2208}, {"iPhone10,6", 1125, 2436},
    {"iPhone12,1", 828, 1792}, {"iPhone12,3", 1125, 2436}, {"iPhone12,5", 1242, 2688}, {"iPhone12,8", 750, 1334},
    {"iPhone13,1", 1080, 2340}, {"iPhone13,2", 1170, 2532}, {"iPhone13,3", 1170, 2532}, {"iPhone13,4", 1284, 2778},
    {"iPhone14,2", 1170, 2532}, {"iPhone14,3", 1284, 2778}, {"iPhone14,4", 1080, 2340}, {"iPhone14,5", 1170, 2532},
    {"iPhone14,6", 750, 1334}, {"iPhone14,7", 1170, 2532}, {"iPhone14,8", 1284, 2778},
    {"iPhone15,2", 1179, 2556}, {"iPhone15,3", 1290, 2796}, {"iPhone15,4", 1179, 2556}, {"iPhone15,5", 1290, 2796},
    {"iPhone16,1", 1179, 2556}, {"iPhone16,2", 1290, 2796},
    {"iPhone17,1", 1206, 2622}, {"iPhone17,2", 1320, 2868}, {"iPhone17,3", 1179, 2556}, {"iPhone17,4", 1290, 2796},
    {"iPhone17,5", 1170, 2532},
    {"iPhone18,1", 1206, 2622}, {"iPhone18,2", 1320, 2868}, {"iPhone18,3", 1206, 2622}, {"iPhone18,4", 1260, 2736},
    {"iPhone18,5", 1170, 2532},
};

// The encoder pads the frame by less than this share per axis (upstream measured
// 14x44, 11x31 and 12x92 pixels); a detection that removed more is not trusted.
#define AQContentDetectMaxShrink 0.08

typedef struct {
    CGSize size;
    CGRect seen, rect;   // pixel coordinates, top-left origin
    unsigned frames;
    double started;
    BOOL frozen;
} AQCrop;

static BOOL AQNonBlack(const uint8_t *base, size_t stride, size_t x, size_t y, OSType format) {
    const uint8_t *p = base + y * stride;
    if (format == kCVPixelFormatType_32BGRA) {
        p += 4 * x;
        return (54u * p[2] + 183u * p[1] + 19u * p[0]) > 10u * 256u;
    }
    unsigned value = p[x];
    return format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        ? value > 16 && (value - 16) * 255u > 10u * 219u : value > 10;
}

// MARK: - The frame sink

@class AQNativeMirrorSession;
@interface AQNativeMirrorSink : NSObject
@property (nonatomic, weak) AQNativeMirrorSession *owner;
@end

@interface AQNativeMirrorSession () {
    NSString *_uuid, *_utun, *_hostIP, *_deviceIP;
    const char *_productType;
    NSString *_productTypeString;
    dispatch_queue_t _setupQueue, _handlerQueue, _delegateQueue;
    NSLock *_lock;
    BOOL _started, _stopped, _reported, _deliveryPending;
    CVPixelBufferRef _latest;
    CGRect _latestRect;
    double _lastFrameAt;
    dispatch_source_t _stallTimer;
    // Delegate queue only.
    AQCrop _crop;
    CMTime _newestPTS;
    // Owned by the setup / teardown path.
    id _stream;
    AQNativeMirrorSink *_sink;
    AQRemote _remote;
    xpc_connection_t _service;
    int _serviceFD, _rtpFD;
    BOOL _torndown;
}
- (void)receiveSampleBuffer:(CMSampleBufferRef)sb;
- (void)mediaError:(NSString *)reason;
- (dispatch_queue_t)delegateQueue;
@end

@implementation AQNativeMirrorSink
- (void)didReceiveSampleBuffer:(CMSampleBufferRef)sb { [self.owner receiveSampleBuffer:sb]; }
- (void)streamOutput:(id)o didReceiveSampleBuffer:(CMSampleBufferRef)sb { [self.owner receiveSampleBuffer:sb]; }
- (void)stream:(id)s didStart:(BOOL)ok error:(NSError *)e {
    if (!ok) [self.owner mediaError:[NSString stringWithFormat:@"stream did not start: %@", e]];
}
- (void)streamDidStop:(id)s { [self.owner mediaError:@"unexpected stream stop"]; }
- (void)vcMediaStreamDidStop:(id)s { [self.owner mediaError:@"unexpected media stream stop"]; }
- (void)streamDidServerDie:(id)s { [self.owner mediaError:@"media server died"]; }
@end

// The image queue's `start` is hooked once per process so the stream's decoded
// frames come to our sink in this process (upstream's in-process path).
static NSLock *sActiveLock;
static __weak AQNativeMirrorSession *sActive;
static __weak AQNativeMirrorSink *sActiveSink;
static IMP sOriginalQueueStart;

static void AQQueueStart(id self, SEL _cmd) {
    AQNativeMirrorSink *sink;
    AQNativeMirrorSession *session;
    [sActiveLock lock];
    sink = sActiveSink;
    session = sActive;
    [sActiveLock unlock];
    AQImageQueueShape *queue = (AQImageQueueShape *)self;
    if (sink && session && ![queue streamOutput]) {
        Class output = NSClassFromString(@"VCStreamOutput");
        id made = [[(id)output alloc] initWithStreamToken:[queue streamToken] clientProcessID:getpid()
                                                 delegate:sink delegateQueue:[session delegateQueue]];
        if (made) [queue setStreamOutput:made];
    }
    ((void (*)(id, SEL))sOriginalQueueStart)(self, _cmd);
}

static BOOL AQInstallQueueHook(void) {
    static dispatch_once_t once;
    static BOOL ok;
    dispatch_once(&once, ^{
        sActiveLock = [NSLock new];
        Class c = NSClassFromString(@"VCImageQueue");
        Method m = c ? class_getInstanceMethod(c, sel_registerName("start")) : NULL;
        if (!m) return;
        sOriginalQueueStart = method_getImplementation(m);
        method_setImplementation(m, (IMP)AQQueueStart);
        ok = YES;
    });
    return ok;
}

// MARK: - The session

@implementation AQNativeMirrorSession

- (instancetype)initWithCoreDeviceUUID:(NSString *)coreDeviceUUID utun:(NSString *)utun hostIP:(NSString *)hostIP
                              deviceIP:(NSString *)deviceIP productType:(NSString *)productType {
    if ((self = [super init])) {
        _uuid = [coreDeviceUUID copy]; _utun = [utun copy]; _hostIP = [hostIP copy]; _deviceIP = [deviceIP copy];
        _productTypeString = [productType copy];
        _productType = _productTypeString.UTF8String ?: "";
        _setupQueue = dispatch_queue_create("com.devicehubpro.nativemirror.setup", DISPATCH_QUEUE_SERIAL);
        _handlerQueue = dispatch_queue_create("com.devicehubpro.nativemirror.frames", DISPATCH_QUEUE_SERIAL);
        _delegateQueue = dispatch_queue_create("com.devicehubpro.nativemirror.delegate", DISPATCH_QUEUE_SERIAL);
        _lock = [NSLock new];
        _newestPTS = kCMTimeInvalid;
        _serviceFD = -1; _rtpFD = -1;
    }
    return self;
}

- (void)dealloc { if (_latest) CVPixelBufferRelease(_latest); }

- (dispatch_queue_t)delegateQueue { return _delegateQueue; }

// MARK: Starting

- (void)startWithCompletion:(void (^)(NSError *))completion {
    [_lock lock];
    BOOL again = _started;
    _started = YES;
    [_lock unlock];
    if (again) { dispatch_async(_setupQueue, ^{ completion(AQError(AQNativeMirrorErrorStream, @"the session was already started")); }); return; }
    dispatch_async(_setupQueue, ^{
        NSError *error = [self performSetup];
        if (error) [self teardown];
        completion(error);
    });
}

- (BOOL)isStopped { [_lock lock]; BOOL s = _stopped; [_lock unlock]; return s; }

#define AQFAIL(code, ...) return AQError((code), [NSString stringWithFormat:@"" __VA_ARGS__])

- (xpc_object_t)actionEnvelope:(const char *)action input:(xpc_object_t)input {
    uuid_t u; uuid_generate(u); char us[37]; uuid_unparse_upper(u, us);
    xpc_object_t m = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(m, "CoreDevice.actionIdentifier", action);
    xpc_dictionary_set_string(m, "CoreDevice.deviceIdentifier", _uuid.UTF8String);
    xpc_dictionary_set_string(m, "CoreDevice.invocationIdentifier", us);
    xpc_object_t ver = xpc_dictionary_create_empty(), comps = xpc_array_create_empty();
    xpc_array_append_value(comps, xpc_uint64_create(642)); xpc_array_append_value(comps, xpc_uint64_create(15));
    xpc_dictionary_set_value(ver, "components", comps); xpc_dictionary_set_int64(ver, "originalComponentsCount", 2);
    xpc_dictionary_set_string(ver, "stringValue", "642.15");
    xpc_dictionary_set_value(m, "CoreDevice.coreDeviceVersion", ver);
    xpc_dictionary_set_int64(m, "CoreDevice.CoreDeviceDDIProtocolVersion", 1);
    xpc_dictionary_set_value(m, "CoreDevice.input", input);
    return m;
}

- (NSError *)performSetup {
    NSString *problem = AQLoadFrameworks();
    if (problem) AQFAIL(AQNativeMirrorErrorFrameworksMissing, "%@", problem);
    if (!AQInstallQueueHook()) AQFAIL(AQNativeMirrorErrorFrameworksMissing, "the image queue could not be hooked");
    uuid_t deviceUUID;
    if (uuid_parse(_uuid.UTF8String, deviceUUID)) AQFAIL(AQNativeMirrorErrorInvalidArgument, "invalid CoreDevice identifier");
    if ([self isStopped]) AQFAIL(AQNativeMirrorErrorStream, "stopped");

    NSString *sessionID = [[NSUUID UUID] UUIDString];
    NSError *e = nil;
    // Diagnostic tuning (DHP_NATIVE_MIRROR_TUNING); unset means no entries and nothing changes.
    NSArray<NSDictionary<NSString *, id> *> *tuning = AQNativeMirrorParseTuning(NSProcessInfo.processInfo.environment[AQNativeMirrorTuningEnvironmentKey]);
    NSMutableDictionary *negotiatorOptions = [NSMutableDictionary dictionary];
    AQNativeMirrorApplyTuning(tuning, @"defaults", NSUserDefaults.standardUserDefaults);
    AQNativeMirrorApplyTuning(tuning, @"negotiator", negotiatorOptions);
    AQNegotiatorShape *neg = [[(id)NSClassFromString(@"AVCMediaStreamNegotiator") alloc] initWithMode:5 options:negotiatorOptions error:&e];  // 5 = CoreDeviceScreenSharing
    if (!neg) AQFAIL(AQNativeMirrorErrorStream, "negotiator init: %@", e);
    if (![neg createOffer]) AQFAIL(AQNativeMirrorErrorStream, "createOffer failed");
    NSData *offer = [neg offer];
    if (!offer.length) AQFAIL(AQNativeMirrorErrorStream, "empty offer");

    // The service socket for the media-stream feature.
    dispatch_queue_t q = dispatch_queue_create("com.devicehubpro.nativemirror.service", DISPATCH_QUEUE_SERIAL);
    xpc_connection_t c = xpc_connection_create("com.apple.CoreDevice.CoreDeviceService", q);
    xpc_connection_set_event_handler(c, ^(xpc_object_t x) {});
    xpc_connection_resume(c);
    _service = c;
    xpc_object_t in0 = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(in0, "featureIdentifier", "com.apple.coredevice.feature.startmediastream");
    xpc_object_t rep = xpc_connection_send_message_with_reply_sync(c,
        [self actionEnvelope:"com.apple.coredevice.action.createservicesocket" input:in0]);
    xpc_object_t out = rep && xpc_get_type(rep) == XPC_TYPE_DICTIONARY ? xpc_dictionary_get_dictionary(rep, "CoreDevice.output") : NULL;
    if (!out) AQFAIL(AQNativeMirrorErrorServiceRefused, "CoreDevice gave no media service (the device or the service is unavailable)");
    int sfd = xpc_dictionary_dup_fd(out, "fileDescriptor");
    uint64_t flags = xpc_dictionary_get_uint64(out, "remoteXPCVersionFlags");
    if (sfd < 0) AQFAIL(AQNativeMirrorErrorServiceRefused, "no service descriptor");
    _serviceFD = sfd;
    AQRemote rc = sRCCreate(sfd, dispatch_queue_create("com.devicehubpro.nativemirror.remote", DISPATCH_QUEUE_SERIAL), flags, 0);
    if (!rc) AQFAIL(AQNativeMirrorErrorServiceRefused, "the media connection could not be created");
    _remote = rc;
    __weak AQNativeMirrorSession *weakSelf = self;
    sRCSetHandler(rc, ^(xpc_object_t ev) {
        if (ev && xpc_get_type(ev) == XPC_TYPE_ERROR) {
            const char *desc = xpc_dictionary_get_string(ev, XPC_ERROR_KEY_DESCRIPTION);
            [weakSelf mediaError:[NSString stringWithFormat:@"media connection: %s", desc ?: "unknown"]];
        }
    });
    sRCActivate(rc);
    if ([self isStopped]) AQFAIL(AQNativeMirrorErrorStream, "stopped");

    // The UDP socket on the tunnel, bound to the host address of the phone's interface.
    int rtp = socket(AF_INET6, SOCK_DGRAM, 0);
    if (rtp < 0) AQFAIL(AQNativeMirrorErrorTunnelDown, "socket: %s", strerror(errno));
    _rtpFD = rtp;
    int one = 1;
    setsockopt(rtp, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    setsockopt(rtp, SOL_SOCKET, SO_REUSEPORT, &one, sizeof one);
    struct sockaddr_in6 la; memset(&la, 0, sizeof la); la.sin6_len = sizeof la; la.sin6_family = AF_INET6;
    if (inet_pton(AF_INET6, _hostIP.UTF8String, &la.sin6_addr) != 1) AQFAIL(AQNativeMirrorErrorInvalidArgument, "bad host address");
    la.sin6_scope_id = if_nametoindex(_utun.UTF8String);
    if (!la.sin6_scope_id) AQFAIL(AQNativeMirrorErrorTunnelDown, "the tunnel interface is not there (is the device connected?)");
    if (bind(rtp, (struct sockaddr *)&la, sizeof la) != 0) AQFAIL(AQNativeMirrorErrorTunnelDown, "bind on the tunnel: %s", strerror(errno));
    socklen_t sl = sizeof la;
    if (getsockname(rtp, (struct sockaddr *)&la, &sl) != 0) AQFAIL(AQNativeMirrorErrorTunnelDown, "getsockname: %s", strerror(errno));
    uint16_t rxport = ntohs(la.sin6_port);
    if (!rxport) AQFAIL(AQNativeMirrorErrorTunnelDown, "no bound port");

    xpc_object_t in = xpc_dictionary_create_empty();
    xpc_dictionary_set_string(in, "receiverIP", _hostIP.UTF8String);
    xpc_dictionary_set_uint64(in, "receiverPort", rxport);
    xpc_dictionary_set_string(in, "senderIP", _deviceIP.UTF8String);
    xpc_dictionary_set_uint64(in, "senderPort", 51000);
    xpc_dictionary_set_uint64(in, "timeout", 30);
    xpc_dictionary_set_string(in, "type", "video");
    xpc_dictionary_set_string(in, "direction", "output");
    xpc_dictionary_set_data(in, "negotiatorOffer", offer.bytes, offer.length);
    xpc_dictionary_set_uint64(in, "clientSupportedFeatures", 972);
    xpc_object_t opts = xpc_dictionary_create_empty();
    uuid_t sessionUU; uuid_parse(sessionID.UTF8String, sessionUU);
    xpc_object_t cv = xpc_dictionary_create_empty();
    xpc_dictionary_set_uuid(cv, "uuid", sessionUU);
    xpc_dictionary_set_value(opts, "avcMediaStreamOptionClientSessionID", cv);
    xpc_dictionary_set_value(in, "options", opts);

    xpc_object_t srep = sRCSendSync(rc, [self actionEnvelope:"com.apple.coredevice.action.mediastreamstart" input:in]);
    if (!srep || xpc_get_type(srep) != XPC_TYPE_DICTIONARY) AQFAIL(AQNativeMirrorErrorServiceRefused, "mediastreamstart: no reply");
    xpc_object_t serr = xpc_dictionary_get_dictionary(srep, "CoreDevice.error");
    if (serr) {
        const char *dom = xpc_dictionary_get_string(serr, "domain");
        AQFAIL(AQNativeMirrorErrorServiceRefused, "the device rejected the stream: %s %lld", dom ?: "?", (long long)xpc_dictionary_get_int64(serr, "code"));
    }
    xpc_object_t so = xpc_dictionary_get_dictionary(srep, "CoreDevice.output");
    if (!so) AQFAIL(AQNativeMirrorErrorServiceRefused, "mediastreamstart: no output");
    size_t alen = 0;
    const void *ans = xpc_dictionary_get_data(so, "negotiatorAnswer", &alen);
    if (!ans) ans = xpc_dictionary_get_data(so, "answer", &alen);
    if (!ans) AQFAIL(AQNativeMirrorErrorServiceRefused, "no answer from the device");
    NSError *ae = nil;
    if (![neg setAnswer:[NSData dataWithBytes:ans length:alen] withError:&ae]) AQFAIL(AQNativeMirrorErrorStream, "setAnswer: %@", ae);
    id cfg = [neg generateMediaStreamConfigurationWithError:&ae];
    if (!cfg) AQFAIL(AQNativeMirrorErrorStream, "generateConfiguration: %@", ae);
    id initOpts = [neg generateMediaStreamInitOptionsWithError:&ae];
    if (!initOpts) AQFAIL(AQNativeMirrorErrorStream, "generateInitOptions: %@", ae);
    AQNativeMirrorApplyTuning(tuning, @"config", cfg);
    if ([self isStopped]) AQFAIL(AQNativeMirrorErrorStream, "stopped");

    // Learn the phone's RTP source without consuming the packet, then connect to it.
    struct timeval ptv = {8, 0};
    setsockopt(rtp, SOL_SOCKET, SO_RCVTIMEO, &ptv, sizeof ptv);
    uint8_t pk[4]; struct sockaddr_in6 peer; socklen_t pl = sizeof peer;
    ssize_t pn = recvfrom(rtp, pk, sizeof pk, MSG_PEEK, (struct sockaddr *)&peer, &pl);
    if (pn <= 0) AQFAIL(AQNativeMirrorErrorStream, "no video from the device within 8 s");
    if (connect(rtp, (struct sockaddr *)&peer, sizeof peer) != 0) AQFAIL(AQNativeMirrorErrorStream, "connect to the video peer: %s", strerror(errno));

    NSMutableDictionary *o2 = [NSMutableDictionary dictionary];
    if ([initOpts isKindOfClass:[NSDictionary class]]) [o2 addEntriesFromDictionary:initOpts];
    o2[@"avcMediaStreamOptionRunInProcess"] = @YES;
    o2[@"avcMediaStreamOptionClientName"] = @"CoreDeviceScreenSharing";
    o2[@"avcMediaStreamOptionClientSessionID"] = [[NSUUID alloc] initWithUUIDString:sessionID];
    AQNativeMirrorApplyTuning(tuning, @"options", o2);
    xpc_object_t socks = xpc_dictionary_create_empty();
    xpc_dictionary_set_fd(socks, "avcKeySharedSocket", rtp);

    _sink = [AQNativeMirrorSink new];
    _sink.owner = self;
    [sActiveLock lock]; sActive = self; sActiveSink = _sink; [sActiveLock unlock];
    NSError *se = nil;
    AQVideoStreamShape *vs = [[(id)NSClassFromString(@"AVCVideoStream") alloc] initWithNetworkSockets:(id)socks options:o2 error:&se];
    if (!vs) AQFAIL(AQNativeMirrorErrorStream, "video stream init: %@", se);
    [vs setDelegate:_sink];
    NSError *ce = nil;
    if (![vs configure:cfg error:&ce]) AQFAIL(AQNativeMirrorErrorStream, "configure: %@", ce);
    _stream = vs;
    [_lock lock]; _lastFrameAt = AQNow(); [_lock unlock];
    NSMutableIndexSet *pending = [NSMutableIndexSet indexSetWithIndexesInRange:NSMakeRange(0, tuning.count)];
    AQApplyRuntimeTuning(tuning, vs, pending);
    [vs start];
    AQApplyRuntimeTuning(tuning, vs, pending);
    [self armStallTimer];
    return nil;
}

// Applies the `avcstream`, `stream` (the conferencing library's own video stream) and
// `receiver` (its video receiver) entries that are still pending; the objects may only
// exist after configure or start, so this runs at both points.
static void AQApplyRuntimeTuning(NSArray<NSDictionary<NSString *, id> *> *tuning, id avcStream, NSMutableIndexSet *pending) {
    if (pending.count == 0) return;
    id inner = nil, receiver = nil;
    @try { inner = [avcStream valueForKey:@"_opaqueStream"]; } @catch (NSException *x) {}
    @try { receiver = [inner valueForKey:@"videoReceiver"]; } @catch (NSException *x) {}
    NSDictionary *objects = @{@"avcstream": avcStream ?: [NSNull null], @"stream": inner ?: [NSNull null], @"receiver": receiver ?: [NSNull null]};
    NSArray *subset = [tuning objectsAtIndexes:pending];
    NSArray<NSNumber *> *subsetIndexes = ({ NSMutableArray *a = [NSMutableArray array]; [pending enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *st) { [a addObject:@(i)]; }]; a; });
    for (NSString *target in objects) {
        id object = objects[target];
        if (object == NSNull.null) continue;
        [AQNativeMirrorApplyTuning(subset, target, object) enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *st) {
            [pending removeIndex:subsetIndexes[i].unsignedIntegerValue];
        }];
    }
}

// MARK: Frames

- (void)resetCropFor:(CGSize)size {
    _crop.size = size; _crop.seen = CGRectNull; _crop.rect = (CGRect){CGPointZero, size};
    _crop.frames = 0; _crop.started = AQNow(); _crop.frozen = NO;
}

- (void)selectRect:(CGRect)rect { _crop.rect = rect; _crop.frozen = YES; }

// Profiles describe the native orientation: transpose on rotation.
- (BOOL)acceptScreenSize:(CGSize)size {
    if ((size.width > size.height) != (_crop.size.width > _crop.size.height)) size = CGSizeMake(size.height, size.width);
    if (size.width <= 0 || size.height <= 0 || size.width > _crop.size.width || size.height > _crop.size.height
        || _crop.size.width - size.width > 64 || _crop.size.height - size.height > 64) return NO;
    [self selectRect:(CGRect){CGPointZero, size}];
    return YES;
}

- (BOOL)selectTableRect {
    for (size_t i = 0; i < sizeof kScreenTable / sizeof kScreenTable[0]; i++) {
        if (strcmp(_productType, kScreenTable[i].productType)) continue;
        return [self acceptScreenSize:CGSizeMake(kScreenTable[i].width, kScreenTable[i].height)];
    }
    return NO;
}

- (void)freezeDetected:(BOOL)forceFull {
    CGRect r = _crop.seen;
    BOOL fallback = forceFull || CGRectIsEmpty(r) || CGRectIsNull(r)
        || r.size.width < _crop.size.width * (1 - AQContentDetectMaxShrink)
        || r.size.height < _crop.size.height * (1 - AQContentDetectMaxShrink);
    [self selectRect:fallback ? (CGRect){CGPointZero, _crop.size} : r];
}

// Scans up to 30 frames / 2 s for the lit area when the table has no entry.
- (void)detectContentRect:(CVPixelBufferRef)frame {
    CGSize size = CGSizeMake(CVPixelBufferGetWidth(frame), CVPixelBufferGetHeight(frame));
    if (!CGSizeEqualToSize(size, _crop.size)) {
        [self resetCropFor:size];
        if ([self selectTableRect]) return;
    }
    if (_crop.frozen) return;
    if (AQNow() - _crop.started >= 2) { [self freezeDetected:NO]; return; }
    OSType format = CVPixelBufferGetPixelFormatType(frame);
    BOOL planar = format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange || format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
    if (!planar && format != kCVPixelFormatType_32BGRA) { [self freezeDetected:YES]; return; }
    if (CVPixelBufferLockBaseAddress(frame, kCVPixelBufferLock_ReadOnly) != kCVReturnSuccess) { [self freezeDetected:YES]; return; }
    const uint8_t *base = planar ? CVPixelBufferGetBaseAddressOfPlane(frame, 0) : CVPixelBufferGetBaseAddress(frame);
    size_t stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(frame, 0) : CVPixelBufferGetBytesPerRow(frame);
    size_t w = (size_t)size.width, h = (size_t)size.height;
    if (!base || !w || !h || stride < w * (planar ? 1 : 4)) {
        CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
        [self freezeDetected:YES]; return;
    }
    size_t left = w, top = h, right = 0, bottom = 0;
    for (size_t x = 0; x < w; x++) {
        for (size_t y = 0;; y = MIN(y + 8, h - 1)) {
            if (AQNonBlack(base, stride, x, y, format)) { left = MIN(left, x); right = x + 1; break; }
            if (y == h - 1) break;
        }
    }
    for (size_t y = 0; y < h; y++) {
        for (size_t x = 0;; x = MIN(x + 8, w - 1)) {
            if (AQNonBlack(base, stride, x, y, format)) { top = MIN(top, y); bottom = y + 1; break; }
            if (x == w - 1) break;
        }
    }
    CVPixelBufferUnlockBaseAddress(frame, kCVPixelBufferLock_ReadOnly);
    if (right > left && bottom > top) {
        CGRect found = CGRectMake(left, top, right - left, bottom - top);
        _crop.seen = CGRectIsNull(_crop.seen) ? found : CGRectUnion(_crop.seen, found);
    }
    if (++_crop.frames >= 30) [self freezeDetected:NO];
}

- (void)receiveSampleBuffer:(CMSampleBufferRef)sb {
    if (!sb) return;
    CVPixelBufferRef pb = CMSampleBufferGetImageBuffer(sb);
    CMTime pts = CMSampleBufferGetOutputPresentationTimeStamp(sb);
    if (!pb || !CMTIME_IS_NUMERIC(pts) || (CMTIME_IS_NUMERIC(_newestPTS) && CMTimeCompare(pts, _newestPTS) <= 0)) return;
    _newestPTS = pts;
    if ([self isStopped]) return;
    [self detectContentRect:pb];
    CGRect rect = _crop.rect;
    CVPixelBufferRetain(pb);
    [_lock lock];
    if (_latest) CVPixelBufferRelease(_latest);   // never queue: the newest frame replaces it
    _latest = pb; _latestRect = rect; _lastFrameAt = AQNow();
    BOOL schedule = !_deliveryPending;
    _deliveryPending = YES;
    [_lock unlock];
    if (!schedule) return;
    dispatch_async(_handlerQueue, ^{
        [self->_lock lock];
        CVPixelBufferRef frame = self->_latest; CGRect r = self->_latestRect;
        self->_latest = NULL; self->_deliveryPending = NO;
        BOOL stopped = self->_stopped;
        [self->_lock unlock];
        if (!frame) return;
        void (^handler)(CVPixelBufferRef, CGRect) = self.frameHandler;
        if (handler && !stopped) handler(frame, r);
        CVPixelBufferRelease(frame);
    });
}

// MARK: Errors and stall

- (void)report:(NSError *)error {
    [_lock lock];
    BOOL first = !_reported && !_stopped;
    if (first) _reported = YES;
    [_lock unlock];
    if (!first) return;
    dispatch_async(_handlerQueue, ^{
        void (^handler)(NSError *) = self.errorHandler;
        if (handler) handler(error);
    });
}

- (void)mediaError:(NSString *)reason { [self report:AQError(AQNativeMirrorErrorStream, reason)]; }

- (void)armStallTimer {
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, _handlerQueue);
    dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
    __weak AQNativeMirrorSession *weakSelf = self;
    dispatch_source_set_event_handler(timer, ^{
        AQNativeMirrorSession *s = weakSelf;
        if (!s) return;
        [s->_lock lock]; double last = s->_lastFrameAt; [s->_lock unlock];
        if (AQNow() - last > 12) [s report:AQError(AQNativeMirrorErrorStall, @"no video frames for 12 seconds")];
    });
    _stallTimer = timer;
    dispatch_resume(timer);
}

// MARK: Stopping

// Runs on the setup queue, after any start in progress.
- (void)teardown {
    if (_torndown) return;
    _torndown = YES;
    [sActiveLock lock];
    if (sActive == self) { sActive = nil; sActiveSink = nil; }
    [sActiveLock unlock];
    [_lock lock]; _stopped = YES; [_lock unlock];
    if (_stallTimer) { dispatch_source_cancel(_stallTimer); _stallTimer = nil; }
    @try { [(AQVideoStreamShape *)_stream stop]; } @catch (NSException *e) {}
    _stream = nil;
    if (_remote && sRCCancel) sRCCancel(_remote);
    if (_service) xpc_connection_cancel(_service);
    if (_serviceFD >= 0) { close(_serviceFD); _serviceFD = -1; }
    if (_rtpFD >= 0) { close(_rtpFD); _rtpFD = -1; }
    [_lock lock];
    if (_latest) { CVPixelBufferRelease(_latest); _latest = NULL; }
    [_lock unlock];
}

- (void)stop {
    [_lock lock]; _stopped = YES; [_lock unlock];
    dispatch_async(_setupQueue, ^{ [self teardown]; });
}

- (void)stopAndWait:(NSTimeInterval)timeout {
    [_lock lock]; _stopped = YES; [_lock unlock];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(_setupQueue, ^{ [self teardown]; dispatch_semaphore_signal(done); });
    dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, (int64_t)(timeout * NSEC_PER_SEC)));
}

@end
