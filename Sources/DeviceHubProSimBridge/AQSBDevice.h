// Resolving a simulator by UDID, shared by the screen and HID paths.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Loads CoreSimulator if needed, then finds `udid` in the device set at
/// `deviceSetPath` (nil: the default set) through the shared service context
/// for `developerDir`. With `requireBooted`, a device that is not booted fails
/// with AQSBErrorDeviceNotBooted. Returns the SimDevice, or nil and `error`.
id _Nullable AQSBResolveDevice(NSString *udid,
                               NSString *_Nullable deviceSetPath,
                               NSString *developerDir,
                               BOOL requireBooted,
                               NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
