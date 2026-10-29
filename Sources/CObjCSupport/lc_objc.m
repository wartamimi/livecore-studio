#if defined(__APPLE__)
#import "lc_objc.h"

NSString * _Nullable lc_catch_objc_exception(NS_NOESCAPE void (^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @"(no reason)"];
    }
}
#endif
