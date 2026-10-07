#import "AQSBDevice.h"
#import "AQSBGuard.h"
#import "AQSBPrivateAPI.h"

#import <mach/mach.h>

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

/// SpringBoard's GSEvent port in the simulator's bootstrap namespace.
static NSString *const kPurpleWorkspacePort = @"PurpleWorkspacePort";

// The GSEvent wire format idb sends (SimulatorPurpleHID.swift): one mach
// message, 108 bytes long in a 112-byte buffer, holding the header and a
// GSEventRecord whose type sits right after the header.
static const uint32_t kGSEventTypeDeviceOrientationChanged = 50;
static const uint32_t kGSEventTypeLockDevice = 1014;
/// ORed into the type: the event comes from the host.
static const uint32_t kGSEventHostFlag = 0x20000;
static const mach_msg_id_t kGSEventMachMessageID = 0x7B;
static const mach_msg_size_t kGSEventMessageSize = 108;
static const size_t kGSEventTypeOffset = 0x18;
static const size_t kGSEventRecordInfoSizeOffset = 0x48;
static const size_t kGSEventRecordInfoOffset = 0x4C;

/// The buffer the message is built in; the union aligns it for the header.
typedef union {
    mach_msg_header_t header;
    uint8_t bytes[112];
} AQSBPurpleMessage;

static void AQSBPurpleWrite(AQSBPurpleMessage *message, size_t offset, uint32_t value) {
    // Little-endian, the host order of every Mac that runs simulators.
    memcpy(message->bytes + offset, &value, sizeof(value));
}

@implementation AQSBPurple {
    NSString *_udid;
    NSString *_deviceSetPath;
    NSString *_developerDir;
}

- (instancetype)initWithUDID:(NSString *)udid deviceSetPath:(NSString *)deviceSetPath developerDir:(NSString *)developerDir {
    if ((self = [super init])) {
        _udid = [udid copy];
        _deviceSetPath = [deviceSetPath copy];
        _developerDir = [developerDir copy];
        // idb's SimulatorPurpleHIDTransport.defaultSendTimeoutMs.
        _sendTimeout = 2;
    }
    return self;
}

- (BOOL)sendOrientation:(uint32_t)orientation error:(NSError **)error {
    AQSBEnterBridge();
    if (orientation < 1 || orientation > 4) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorInvalidArgument,
                                   [NSString stringWithFormat:@"orientation %u is not 1 through 4", orientation], nil);
        }
        return NO;
    }
    AQSBPurpleMessage message;
    memset(&message, 0, sizeof(message));
    AQSBPurpleWrite(&message, kGSEventTypeOffset, kGSEventTypeDeviceOrientationChanged | kGSEventHostFlag);
    AQSBPurpleWrite(&message, kGSEventRecordInfoSizeOffset, sizeof(uint32_t));
    AQSBPurpleWrite(&message, kGSEventRecordInfoOffset, orientation);
    return [self send:&message error:error];
}

- (BOOL)sendLockWithError:(NSError **)error {
    AQSBEnterBridge();
    AQSBPurpleMessage message;
    memset(&message, 0, sizeof(message));
    // No record info: the type alone says "lock".
    AQSBPurpleWrite(&message, kGSEventTypeOffset, kGSEventTypeLockDevice | kGSEventHostFlag);
    return [self send:&message error:error];
}

/// Looks the port up, fills in the header and sends with MACH_SEND_TIMEOUT:
/// on a timeout the kernel guarantees nothing was queued.
- (BOOL)send:(AQSBPurpleMessage *)message error:(NSError **)error {
    id<AQSBSimDevice> device = AQSBResolveDevice(_udid, _deviceSetPath, _developerDir, YES, error);
    if (!device) {
        return NO;
    }
    __block mach_port_t port = MACH_PORT_NULL;
    __block NSError *lookupError = nil;
    if (!AQSBGuarded(@"-[SimDevice lookup:error:] (PurpleWorkspacePort)", error, ^{
            NSError *inner = nil;
            port = [device lookup:kPurpleWorkspacePort error:&inner];
            lookupError = inner;
        })) {
        return NO;
    }
    if (port == MACH_PORT_NULL) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorServiceLookupFailed,
                                   [NSString stringWithFormat:@"%@ lookup failed", kPurpleWorkspacePort], lookupError);
        }
        return NO;
    }

    message->header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message->header.msgh_size = kGSEventMessageSize;
    message->header.msgh_remote_port = port;
    message->header.msgh_local_port = MACH_PORT_NULL;
    message->header.msgh_id = kGSEventMachMessageID;
    NSTimeInterval seconds = self.sendTimeout;
    mach_msg_timeout_t timeout = (mach_msg_timeout_t)MAX(1.0, MIN(seconds * 1000.0, 60000.0));
    kern_return_t result = mach_msg(&message->header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, kGSEventMessageSize, 0,
                                    MACH_PORT_NULL, timeout, MACH_PORT_NULL);
    // The lookup handed this process a send right of its own; COPY_SEND left
    // it in place whether or not the message went out.
    mach_port_deallocate(mach_task_self(), port);

    if (result == MACH_MSG_SUCCESS) {
        return YES;
    }
    if (error) {
        NSString *detail = [NSString stringWithFormat:@"%@ send: %s (0x%x)", kPurpleWorkspacePort, mach_error_string(result), result];
        *error = AQSBMakeError(result == MACH_SEND_TIMED_OUT ? AQSBErrorTimedOut : AQSBErrorSendFailed, detail, nil);
    }
    return NO;
}

@end
