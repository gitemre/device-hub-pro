// Diagnostic tuning of a native mirror session from DHP_NATIVE_MIRROR_TUNING.
// Not a user setting: it exists to measure which stream settings change latency.

#import "AQNativeMirrorTuning.h"
#import <objc/runtime.h>

NSString *const AQNativeMirrorTuningEnvironmentKey = @"DHP_NATIVE_MIRROR_TUNING";

static id AQParseValue(NSString *text) {
    NSString *lower = text.lowercaseString;
    if ([lower isEqualToString:@"true"] || [lower isEqualToString:@"yes"]) return @YES;
    if ([lower isEqualToString:@"false"] || [lower isEqualToString:@"no"]) return @NO;
    NSScanner *scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    long long i = 0;
    if ([scanner scanLongLong:&i] && scanner.atEnd) return @(i);
    scanner = [NSScanner scannerWithString:text];
    scanner.charactersToBeSkipped = nil;
    double d = 0;
    if ([scanner scanDouble:&d] && scanner.atEnd) return @(d);
    return text;
}

NSArray<NSDictionary<NSString *, id> *> *AQNativeMirrorParseTuning(NSString *spec) {
    NSMutableArray *out = [NSMutableArray array];
    NSCharacterSet *ws = NSCharacterSet.whitespaceAndNewlineCharacterSet;
    for (NSString *raw in [spec componentsSeparatedByString:@";"]) {
        NSString *entry = [raw stringByTrimmingCharactersInSet:ws];
        NSRange eq = [entry rangeOfString:@"="];
        if (entry.length == 0 || eq.location == NSNotFound) continue;
        NSString *path = [[entry substringToIndex:eq.location] stringByTrimmingCharactersInSet:ws];
        NSString *value = [[entry substringFromIndex:eq.location + 1] stringByTrimmingCharactersInSet:ws];
        NSRange dot = [path rangeOfString:@"."];
        if (dot.location == NSNotFound || dot.location == 0 || dot.location + 1 >= path.length) continue;
        [out addObject:@{@"target": [path substringToIndex:dot.location],
                         @"key": [path substringFromIndex:dot.location + 1],
                         @"value": AQParseValue(value)}];
    }
    return out;
}

NSIndexSet *AQNativeMirrorApplyTuning(NSArray<NSDictionary<NSString *, id> *> *entries, NSString *target, id object) {
    NSMutableIndexSet *applied = [NSMutableIndexSet indexSet];
    [entries enumerateObjectsUsingBlock:^(NSDictionary *entry, NSUInteger idx, BOOL *stop) {
        if (![entry[@"target"] isEqualToString:target]) return;
        NSString *key = entry[@"key"];
        if (!object) { fprintf(stderr, "[AQNativeMirror] tuning %s.%s: no object\n", target.UTF8String, key.UTF8String); return; }
        @try {
            if ([object isKindOfClass:[NSMutableDictionary class]]) {
                ((NSMutableDictionary *)object)[key] = entry[@"value"];
            } else if ([target isEqualToString:@"defaults"]) {
                [NSUserDefaults.standardUserDefaults registerDefaults:@{key: entry[@"value"]}];
            } else {
                NSString *setter = [NSString stringWithFormat:@"set%@%@:", [[key substringToIndex:1] uppercaseString], [key substringFromIndex:1]];
                if (![object respondsToSelector:NSSelectorFromString(setter)]) {
                    fprintf(stderr, "[AQNativeMirror] tuning %s.%s: no setter\n", target.UTF8String, key.UTF8String);
                    return;
                }
                [object setValue:entry[@"value"] forKey:key];
            }
            [applied addIndex:idx];
            fprintf(stderr, "[AQNativeMirror] tuning %s.%s applied\n", target.UTF8String, key.UTF8String);
        } @catch (NSException *exception) {
            fprintf(stderr, "[AQNativeMirror] tuning %s.%s failed: %s\n", target.UTF8String, key.UTF8String, exception.name.UTF8String);
        }
    }];
    return applied;
}
