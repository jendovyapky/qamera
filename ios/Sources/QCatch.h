#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// AVFoundation hlásí špatné nastavení výjimkou Objective-C (NSException), kterou Swift nechytí → appka spadne.
// QCatch.run spustí blok a výjimku vrátí jako text (nil = proběhlo v pořádku).
@interface QCatch : NSObject
+ (nullable NSString *)run:(NS_NOESCAPE void (^)(void))block;
@end

NS_ASSUME_NONNULL_END
