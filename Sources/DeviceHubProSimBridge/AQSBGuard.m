#import "AQSBGuard.h"

#import <stdatomic.h>

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

NSErrorDomain const AQSBErrorDomain = @"com.devicehubpro.SimBridge";
NSErrorUserInfoKey const AQSBExceptionNameKey = @"AQSBExceptionName";
NSErrorUserInfoKey const AQSBExceptionReasonKey = @"AQSBExceptionReason";

static _Atomic uint64_t gEntryCount = 0;
static _Atomic uint64_t gGuardedCallCount = 0;
static _Atomic uint64_t gExceptionCount = 0;
static _Atomic uint64_t gScreenRegisterCount = 0;
static _Atomic uint64_t gScreenUnregisterCount = 0;

void AQSBEnterBridge(void) {
    // Every private call behind an entry point is synchronous IPC to
    // CoreSimulatorService or a ROCK proxy; on the main queue it would stall
    // the UI (and deadlock if the service ever calls back on main).
    dispatch_assert_queue_not(dispatch_get_main_queue());
    atomic_fetch_add_explicit(&gEntryCount, 1, memory_order_relaxed);
}

BOOL AQSBGuarded(NSString *what, NSError **error, NS_NOESCAPE void (^body)(void)) {
    atomic_fetch_add_explicit(&gGuardedCallCount, 1, memory_order_relaxed);
    @try {
        body();
        return YES;
    } @catch (id raised) {
        atomic_fetch_add_explicit(&gExceptionCount, 1, memory_order_relaxed);
        NSString *name = @"(not an NSException)";
        NSString *reason = [raised description] ?: @"";
        if ([raised isKindOfClass:[NSException class]]) {
            NSException *exception = raised;
            name = exception.name;
            reason = exception.reason ?: @"";
        }
        if (error) {
            *error = [NSError errorWithDomain:AQSBErrorDomain
                                         code:AQSBErrorException
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@ raised %@: %@", what, name, reason],
                                         AQSBExceptionNameKey: name,
                                         AQSBExceptionReasonKey: reason,
                                     }];
        }
        return NO;
    }
}

NSError *AQSBMakeError(AQSBError code, NSString *description, NSError *underlying) {
    NSMutableDictionary *info = [NSMutableDictionary dictionaryWithObject:description forKey:NSLocalizedDescriptionKey];
    if (underlying) {
        info[NSUnderlyingErrorKey] = underlying;
    }
    return [NSError errorWithDomain:AQSBErrorDomain code:code userInfo:info];
}

void AQSBCountScreenRegister(void) {
    atomic_fetch_add_explicit(&gScreenRegisterCount, 1, memory_order_relaxed);
}

void AQSBCountScreenUnregister(void) {
    atomic_fetch_add_explicit(&gScreenUnregisterCount, 1, memory_order_relaxed);
}

@implementation AQSBDiagnostics

+ (uint64_t)entryCount {
    return atomic_load_explicit(&gEntryCount, memory_order_relaxed);
}

+ (uint64_t)guardedCallCount {
    return atomic_load_explicit(&gGuardedCallCount, memory_order_relaxed);
}

+ (uint64_t)exceptionCount {
    return atomic_load_explicit(&gExceptionCount, memory_order_relaxed);
}

+ (uint64_t)screenRegisterCount {
    return atomic_load_explicit(&gScreenRegisterCount, memory_order_relaxed);
}

+ (uint64_t)screenUnregisterCount {
    return atomic_load_explicit(&gScreenUnregisterCount, memory_order_relaxed);
}

@end
