//
//  ObjCExceptionCatcher.h
//  Core/Media
//
//  The @try/@catch seam Swift cannot express: AVAudioPlayerNode's play()/
//  stop() raise ObjC NSExceptions ("required condition is false:
//  _engine->IsRunning()") that Swift do/catch can NEVER catch — unhandled,
//  one aborts the process. This shim converts that abort into an NSError the
//  caller logs and absorbs (PTTPlayer drops the spurt instead of the
//  process). Exposed to Swift via Beacon/Beacon-Bridging-Header.h.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Run `block`, catching any NSException it raises. Returns nil on success,
/// or an NSError (domain "BeaconObjCException") carrying the exception name
/// as its description and the exception reason as its failure reason. The
/// block does not escape.
NSError * _Nullable BeaconCatchException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
