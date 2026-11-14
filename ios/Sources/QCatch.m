#import "QCatch.h"

@implementation QCatch
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block {
    @try {
        block();
        return nil;
    } @catch (NSException *e) {
        return [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
    }
}
@end
