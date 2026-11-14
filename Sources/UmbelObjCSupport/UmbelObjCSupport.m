#import "UmbelObjCSupport.h"

NSErrorDomain const UmbelObjCExceptionErrorDomain = @"UmbelObjCException";

BOOL UmbelCatchingObjCException(NS_NOESCAPE void (^block)(void),
                                NSError *_Nullable *_Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error != NULL) {
            NSString *reason = exception.reason ?: exception.name;
            *error = [NSError errorWithDomain:UmbelObjCExceptionErrorDomain
                                         code:1
                                     userInfo:@{
                                         NSLocalizedDescriptionKey: reason,
                                         @"UmbelExceptionName": exception.name,
                                     }];
        }
        return NO;
    }
}
