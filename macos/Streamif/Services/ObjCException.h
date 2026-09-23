#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSErrorDomain const ObjCExceptionErrorDomain;

/// Runs a block and turns an Objective-C exception raised inside it into a
/// Swift error. Swift can't catch these itself, and letting one unwind through
/// a Swift task corrupts the concurrency runtime.
@interface ObjCException : NSObject

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block
               error:(NSError **)error NS_SWIFT_NAME(perform(_:));

@end

NS_ASSUME_NONNULL_END
