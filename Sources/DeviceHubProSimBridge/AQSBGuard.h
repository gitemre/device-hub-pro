// The bridge's two safety rails: the exception guard every private call runs
// in, and the off-main assertion every public entry point starts with.

#import <Foundation/Foundation.h>

#import "DeviceHubProSimBridge.h"

NS_ASSUME_NONNULL_BEGIN

/// Starts a public entry point: stops the process if it runs on the main queue
/// (dispatch_assert_queue_not), then counts the entry.
void AQSBEnterBridge(void);

/// Runs `body` inside @try. Returns YES when it returned normally; when it
/// raised, fills `error` with AQSBErrorException (the exception's name and
/// reason in userInfo, `what` in the description) and returns NO.
///
/// ARC is not exception-safe by default (no -fobjc-arc-exceptions), so objects
/// the body retained may leak when it raises. That is acceptable for a path
/// that only raises when Apple changed the private surface.
BOOL AQSBGuarded(NSString *what, NSError *_Nullable *_Nullable error, NS_NOESCAPE void (^body)(void));

/// A bridge error with a description and an optional underlying error.
NSError *AQSBMakeError(AQSBError code, NSString *description, NSError *_Nullable underlying);

/// Counters behind AQSBDiagnostics.
void AQSBCountScreenRegister(void);
void AQSBCountScreenUnregister(void);

NS_ASSUME_NONNULL_END
