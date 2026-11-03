#if defined(__APPLE__)
#import "LCSyphonProbe.h"
#import "SyphonClientBase.h"
#import "SyphonServerDirectory.h"
#import "SyphonSubclassing.h"
#import <IOSurface/IOSurface.h>

@implementation LCSyphonProbe {
    SyphonClientBase *_client;
}

+ (NSArray<NSString *> *)serverTitles {
    NSMutableArray *titles = [NSMutableArray array];
    for (NSDictionary *d in [SyphonServerDirectory sharedDirectory].servers) {
        NSString *app = d[SyphonServerDescriptionAppNameKey] ?: @"";
        NSString *name = d[SyphonServerDescriptionNameKey] ?: @"";
        [titles addObject:[NSString stringWithFormat:@"%@ – %@", app, name]];
    }
    return titles;
}

- (nullable instancetype)initWithServerNamed:(NSString *)name {
    self = [super init];
    if (!self) return nil;
    NSArray *matches = [[SyphonServerDirectory sharedDirectory] serversMatchingName:name appName:nil];
    if (matches.count == 0) return nil;
    _client = [[SyphonClientBase alloc] initWithServerDescription:matches.firstObject options:nil newFrameHandler:nil];
    if (!_client) return nil;
    return self;
}

- (BOOL)hasNewFrame { return _client.hasNewFrame; }
- (BOOL)isValid { return _client.isValid; }

- (BOOL)readFrameWidth:(size_t *)width height:(size_t *)height pixelFormat:(OSType *)format centerBGRA:(uint32_t *)pixel {
    IOSurfaceRef s = [_client newSurface];
    if (!s) return NO;
    *width = IOSurfaceGetWidth(s);
    *height = IOSurfaceGetHeight(s);
    *format = IOSurfaceGetPixelFormat(s);
    BOOL ok = NO;
    if (IOSurfaceLock(s, kIOSurfaceLockReadOnly, NULL) == kIOReturnSuccess) {
        uint8_t *base = IOSurfaceGetBaseAddress(s);
        size_t bpr = IOSurfaceGetBytesPerRow(s);
        if (base && *width > 0 && *height > 0) {
            *pixel = *(uint32_t *)(base + (*height / 2) * bpr + (*width / 2) * 4);
            ok = YES;
        }
        IOSurfaceUnlock(s, kIOSurfaceLockReadOnly, NULL);
    }
    CFRelease(s);
    return ok;
}

- (void)stop { [_client stop]; _client = nil; }
@end
#endif
