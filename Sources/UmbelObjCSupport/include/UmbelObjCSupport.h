#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Error domain for Objective-C exceptions caught by `UmbelCatchingObjCException`.
extern NSErrorDomain const UmbelObjCExceptionErrorDomain;

/// Runs `block`, turning an Objective-C exception it raises into an error.
///
/// Swift cannot catch Objective-C exceptions; uncaught, they end the process.
/// Some system frameworks raise them for runtime faults rather than
/// programming errors — AVFAudio does when an audio device stops delivering —
/// and a player has to survive those. Returns YES when the block ran to the
/// end; on NO, `error` carries the exception's name and reason.
BOOL UmbelCatchingObjCException(NS_NOESCAPE void (^block)(void),
                                NSError *_Nullable *_Nullable error);

NS_ASSUME_NONNULL_END
