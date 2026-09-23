#import "ObjCException.h"

NSErrorDomain const ObjCExceptionErrorDomain = @"ObjCExceptionErrorDomain";

@implementation ObjCException

+ (BOOL)performBlock:(NS_NOESCAPE void (^)(void))block error:(NSError **)error {
    @try {
        block();
        return YES;
    } @catch (NSException *exception) {
        if (error) {
            *error = [NSError errorWithDomain:ObjCExceptionErrorDomain
                                         code:0
                                     userInfo:@{
                NSLocalizedDescriptionKey: [NSString stringWithFormat:@"%@: %@", exception.name, exception.reason ?: @""],
            }];
        }
        return NO;
    }
}

@end
