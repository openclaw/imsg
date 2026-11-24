#import <Foundation/Foundation.h>
#include <dlfcn.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

static NSUInteger failures;

static void check(BOOL ok, NSString *message) {
    if (ok) {
        printf("OK: %s\n", message.UTF8String);
    } else {
        fprintf(stderr, "FAIL: %s\n", message.UTF8String);
        failures++;
    }
}

static id effectAt(NSAttributedString *body, NSUInteger index) {
    return [body attribute:@"__kIMTextEffectAttributeName" atIndex:index effectiveRange:NULL];
}

int main(void) {
    @autoreleasepool {
        if ([[NSProcessInfo processInfo] operatingSystemVersion].majorVersion < 15) {
            printf("TextEffectTests skipped (text effects need macOS 15)\n");
            return 0;
        }

        NSString *text = @"calm then loud and wobbly";
        NSArray *formatting = @[
            @{@"start": @10, @"length": @4, @"styles": @[@"bloom", @"bold"]},
            @{@"start": @19, @"length": @6, @"styles": @[@"somersault"]},
            @{@"start": @0, @"length": @4, @"styles": @[@"sparkle"]}
        ];
        NSAttributedString *body = buildFormattedAttributed(text, formatting, 0);

        check([effectAt(body, 10) isEqual:@6], @"bloom marks its range with effect type 6");
        check([[body attribute:@"__kIMTextBoldAttributeName" atIndex:12 effectiveRange:NULL] isEqual:@1],
              @"an effect combines with a style on the same range");
        check([effectAt(body, 20) isEqual:@7], @"somersault, which the picker hides, is type 7");
        check(effectAt(body, 0) == nil, @"an unknown effect name leaves the range plain");
        check(effectAt(body, 15) == nil, @"text outside every range carries no effect");
        check([body.string isEqualToString:text], @"the message text is unchanged");

        // The table must agree with Messages' own name lookup wherever this
        // macOS still ships it, so a renumbering in a future release fails here.
        void *utilities = dlopen(
            "/System/Library/PrivateFrameworks/IMSharedUtilities.framework/IMSharedUtilities",
            RTLD_NOW);
        long (*typeFromName)(NSString *) =
            utilities ? (long (*)(NSString *))dlsym(utilities, "IMTextEffectTypeFromName") : NULL;
        if (typeFromName) {
            NSDictionary *internalNames = @{
                @"shake": @"shakeHorizontal", @"nod": @"shakeVertical", @"ripple": @"bounce"
            };
            [textEffectTypes() enumerateKeysAndObjectsUsingBlock:^(NSString *name, NSNumber *type, BOOL *stop) {
                NSString *internal = internalNames[name] ?: name;
                check(typeFromName(internal) == type.longValue,
                      [NSString stringWithFormat:@"%@ matches IMTextEffectTypeFromName(%@)", name, internal]);
            }];
        } else {
            printf("IMTextEffectTypeFromName unavailable; table not cross-checked\n");
        }

        if (failures) return 1;
        printf("TextEffectTests passed\n");
        return 0;
    }
}
