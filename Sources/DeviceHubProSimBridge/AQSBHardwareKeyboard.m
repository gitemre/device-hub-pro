#import "AQSBDevice.h"
#import "AQSBGuard.h"
#import "AQSBPrivateAPI.h"

#if !__has_feature(objc_arc)
#error "DeviceHubProSimBridge is written for ARC"
#endif

@implementation AQSBHardwareKeyboard

+ (BOOL)setConnected:(BOOL)connected
        keyboardType:(uint8_t)keyboardType
                udid:(NSString *)udid
       deviceSetPath:(NSString *)deviceSetPath
        developerDir:(NSString *)developerDir
               error:(NSError **)error {
    AQSBEnterBridge();
    id device = AQSBResolveDevice(udid, deviceSetPath, developerDir, YES, error);
    if (!device) {
        return NO;
    }
    SEL selector = @selector(setHardwareKeyboardEnabled:keyboardType:error:);
    if (![device respondsToSelector:selector]) {
        if (error) {
            *error = AQSBMakeError(AQSBErrorAPIUnavailable,
                                   @"SimDevice has no -setHardwareKeyboardEnabled:keyboardType:error: in this CoreSimulator", nil);
        }
        return NO;
    }
    __block BOOL ok = NO;
    __block NSError *inner = nil;
    if (!AQSBGuarded(@"-[SimDevice setHardwareKeyboardEnabled:keyboardType:error:]", error, ^{
            NSError *callError = nil;
            ok = [(id<AQSBSimDeviceHardwareKeyboard>)device setHardwareKeyboardEnabled:connected
                                                                          keyboardType:keyboardType
                                                                                 error:&callError];
            inner = callError;
        })) {
        return NO;
    }
    if (!ok && error) {
        *error = AQSBMakeError(AQSBErrorSendFailed, @"SimDevice refused the hardware keyboard change", inner);
    }
    return ok;
}

@end
