// Objective-C exception guard. Some capture drivers (notably legacy DAL plug-ins of capture
// cards) throw NSExceptions from AVCaptureDevice setters; Swift cannot catch those, so calls that
// may throw are run through this shim. Empty on non-Apple platforms.
#pragma once
#if defined(__APPLE__)
#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Runs `block`. Returns nil on success, or "name: reason" of the NSException it raised.
NSString * _Nullable lc_catch_objc_exception(NS_NOESCAPE void (^block)(void));
NS_ASSUME_NONNULL_END
#endif
