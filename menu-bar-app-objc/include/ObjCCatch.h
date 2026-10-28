#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block`; an Objective-C exception it raises is caught and returned (nil when none).
/// Swift cannot catch these: uncaught on a timer they unwind through the run loop, AppKit
/// swallows them, and the timer that raised never fires again.
NSException * _Nullable LDCatchException(NS_NOESCAPE void (^block)(void));

NS_ASSUME_NONNULL_END
