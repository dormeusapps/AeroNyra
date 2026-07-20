//
//  ObjCExceptionCatcher.m
//  Core/Media
//

#import "ObjCExceptionCatcher.h"

NSError * _Nullable BeaconCatchException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return [NSError errorWithDomain:@"BeaconObjCException"
                                   code:1
                               userInfo:@{
            NSLocalizedDescriptionKey: exception.name,
            NSLocalizedFailureReasonErrorKey: exception.reason ?: @"",
        }];
    }
}
