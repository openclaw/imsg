#import <Foundation/Foundation.h>
#import "../../Sources/IMsgHelper/IMsgInjected.m"

static NSUInteger failures;

static void check(BOOL condition, NSString *message) {
    if (condition) return;
    fprintf(stderr, "FAIL: %s\n", message.UTF8String);
    failures++;
}

static NSDictionary *placement(NSDictionary *overrides) {
    NSMutableDictionary *value = [@{@"x": @0.5, @"y": @0.5, @"scale": @1, @"rotation": @0}
        mutableCopy];
    [value addEntriesFromDictionary:overrides];
    return value;
}

static NSDictionary *sendSticker(NSString *target, id rawPlacement) {
    NSMutableDictionary *params = [@{
        @"chatGuid": @"iMessage;-;+15550000000", @"filePath": @"/nonexistent/sticker.png",
        @"contentHash": @"00", @"accessibilityLabel": @"Sticker",
        @"pixelWidth": @1, @"pixelHeight": @1, @"placement": rawPlacement
    } mutableCopy];
    if (target) params[@"selectedMessageGuid"] = target;
    return handleSendSticker(1, params);
}

int main(void) {
    @autoreleasepool {
        NSString *error = nil;
        NSDictionary *geometry = stickerPlacementGeometry(
            @{@"x": @0, @"y": @1.25, @"scale": @0.4, @"rotation": @(M_PI_2)}, &error);
        check([geometry isEqual:@{@"sxs": @"0.00000000", @"sys": @"1.25000000",
                                  @"ssa": @"0.40000000", @"sro": @"1.57079633"}],
              @"Placement becomes the geometry strings Messages stores");
        geometry = stickerPlacementGeometry(
            @{@"x": @(-3), @"y": @3, @"scale": @4, @"rotation": @(-M_PI)}, &error);
        check([geometry[@"sxs"] isEqualToString:@"-3.00000000"]
                  && [geometry[@"sro"] isEqualToString:@"-3.14159265"],
              @"Placement accepts its bounds");

        NSDictionary *metadata = @{@"hash": @"abc", @"md5": @"def", @"filename": @"s.png"};
        NSMutableDictionary *placed = [metadata mutableCopy];
        placed[@"placement"] = stickerPlacementGeometry(
            placement(@{@"x": @0.9, @"rotation": @(-0.5)}), nil);
        NSDictionary *info = stickerUserInfo(placed);
        check([info[@"sxs"] isEqualToString:@"0.90000000"]
                  && [info[@"sys"] isEqualToString:@"0.50000000"]
                  && [info[@"ssa"] isEqualToString:@"1.00000000"]
                  && [info[@"sro"] isEqualToString:@"-0.50000000"]
                  && [info[@"spw"] isEqualToString:kDefaultStickerParentPreviewWidth],
              @"Sticker user info carries the placement");
        info = stickerUserInfo(metadata);
        check([info[@"sxs"] isEqualToString:@"0.50000000"]
                  && [info[@"sys"] isEqualToString:@"0.50000000"]
                  && [info[@"ssa"] isEqualToString:@"1.00000000"]
                  && [info[@"sro"] isEqualToString:@"0.00000000"],
              @"A sticker without placement stays centered and unrotated");

        NSArray *invalid = @[
            @"x", @[], @{@"x": @0.5, @"y": @0.5, @"scale": @1},
            placement(@{@"z": @0}), placement(@{@"x": @"0.5"}), placement(@{@"y": @YES}),
            placement(@{@"x": @3.01}), placement(@{@"y": @(-3.01)}), placement(@{@"x": @(NAN)}),
            placement(@{@"scale": @0}), placement(@{@"scale": @0.09}), placement(@{@"scale": @4.01}),
            placement(@{@"scale": @(INFINITY)}), placement(@{@"rotation": @3.15}),
            placement(@{@"rotation": [NSNull null]})
        ];
        for (id value in invalid) {
            error = nil;
            check(!stickerPlacementGeometry(value, &error) && error.length,
                  [@"Placement must be refused: " stringByAppendingString:[value description]]);
        }

        // The handler refuses placement before it reads the file or probes IMCore.
        NSDictionary *response = sendSticker(nil, placement(@{}));
        check([response[@"success"] isEqual:@NO]
                  && [response[@"error"] isEqualToString:@"placement requires selectedMessageGuid"]
                  && [response[@"delivery_disposition"] isEqualToString:@"not_started"],
              @"Placement without a target is refused");
        response = sendSticker(@"parent-guid", placement(@{@"scale": @9}));
        check([response[@"success"] isEqual:@NO]
                  && [response[@"error"] containsString:@"placement scale"]
                  && [response[@"delivery_disposition"] isEqualToString:@"not_started"],
              @"Out-of-range placement is refused before dispatch");

        printf("Bridge sticker placement tests: %lu failure(s)\n", (unsigned long)failures);
        return failures ? 1 : 0;
    }
}
