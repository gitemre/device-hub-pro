#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// Errors of a native mirror session (`AQNativeMirrorErrorDomain`).
FOUNDATION_EXPORT NSErrorDomain const AQNativeMirrorErrorDomain;

typedef NS_ENUM(NSInteger, AQNativeMirrorErrorCode) {
    /// A private framework, symbol or class this Mac does not have.
    AQNativeMirrorErrorFrameworksMissing = 1000,
    /// The arguments are not usable (a malformed UUID or address).
    AQNativeMirrorErrorInvalidArgument = 2000,
    /// CoreDevice refused the media-stream service, or the device rejected the stream.
    AQNativeMirrorErrorServiceRefused = 3000,
    /// The phone's tunnel interface or address is not there (not connected).
    AQNativeMirrorErrorTunnelDown = 4000,
    /// The stream did not start or the negotiation failed.
    AQNativeMirrorErrorStream = 6000,
    /// No frame arrived for 12 seconds.
    AQNativeMirrorErrorStall = 7000,
};

/// A view-only screen stream of one iPhone through the CoreDevice media-stream
/// service (the path Device Hub uses). Every private symbol is resolved at run
/// time (dlopen, dlsym, NSClassFromString): nothing private is linked, and a
/// Mac without the frameworks gets `AQNativeMirrorErrorFrameworksMissing`.
///
/// Vendored from ipb's mirror (see PROVENANCE.md); it receives frames only and
/// sends nothing to the phone. One session at a time per process.
@interface AQNativeMirrorSession : NSObject

/// Called for the newest frame, on a private serial queue, with the rectangle
/// of the frame that holds the screen (the encoder pads the rest; top-left
/// origin, pixels). Latest only: a slow handler skips frames, it never queues them.
@property (atomic, copy, nullable) void (^frameHandler)(CVPixelBufferRef frame, CGRect contentRect);
/// Called once, on the same queue, when a started stream fails or stalls.
@property (atomic, copy, nullable) void (^errorHandler)(NSError *error);

- (instancetype)initWithCoreDeviceUUID:(NSString *)coreDeviceUUID
                                  utun:(NSString *)utun
                                hostIP:(NSString *)hostIP
                              deviceIP:(NSString *)deviceIP
                           productType:(NSString *)productType NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Negotiates and starts the stream on a background queue and calls
/// `completion` there: nil when frames may now arrive, else the error (the
/// session has released everything then). Needs a GUI login session.
- (void)startWithCompletion:(void (^)(NSError *_Nullable error))completion;
/// Ends the stream. Idempotent; returns at once.
- (void)stop;
/// Ends the stream and waits at most `timeout` seconds for it to be released.
- (void)stopAndWait:(NSTimeInterval)timeout;

@end

NS_ASSUME_NONNULL_END
