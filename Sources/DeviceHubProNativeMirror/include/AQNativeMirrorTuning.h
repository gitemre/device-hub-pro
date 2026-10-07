#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Name of the diagnostic environment variable that tunes a native mirror session.
FOUNDATION_EXPORT NSString *const AQNativeMirrorTuningEnvironmentKey;

/// Parses a tuning string: `target.key=value` entries separated by semicolons
/// (`config.jitterBufferMode=3;options.someKey=true`). Returns one dictionary
/// per valid entry, in order, with `target` and `key` (NSString) and `value`
/// (NSNumber for true/false/yes/no, integers and decimals; NSString otherwise).
/// Blank and malformed entries (no dot, no equals sign, empty target or key)
/// are skipped. A nil or empty string gives an empty array.
FOUNDATION_EXPORT NSArray<NSDictionary<NSString *, id> *> *AQNativeMirrorParseTuning(NSString *_Nullable spec);

/// Sets each entry whose target is `target` on `object` with key-value coding,
/// only when the object has a setter for the key (a dictionary takes any key).
/// Never throws. Logs key names only, to stderr. Returns the indexes of the
/// entries (in `entries`) that were applied.
FOUNDATION_EXPORT NSIndexSet *AQNativeMirrorApplyTuning(NSArray<NSDictionary<NSString *, id> *> *entries,
                                                        NSString *target, id _Nullable object);

NS_ASSUME_NONNULL_END
