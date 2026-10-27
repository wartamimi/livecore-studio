// LiveCore Studio: a minimal Syphon *client*, used by `livecore-syphon-check` (CI) to prove that
// another process can discover LiveCore's Syphon servers and read their frames, as OBS does.
#pragma once
#if defined(__APPLE__)
#import <Foundation/Foundation.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCSyphonProbe : NSObject
/// "AppName – ServerName" of every server announced so far. The main run loop must be running
/// for announcements to arrive.
+ (NSArray<NSString *> *)serverTitles;
/// Connects to the first server with this name (nil when none is announced yet).
- (nullable instancetype)initWithServerNamed:(NSString *)name;
/// YES once the server has published a frame since the last readFrame call.
@property (readonly) BOOL hasNewFrame;
@property (readonly) BOOL isValid;
/// Size, IOSurface pixel format and the BGRA value of the centre pixel of the current frame.
- (BOOL)readFrameWidth:(size_t *)width height:(size_t *)height pixelFormat:(OSType *)format centerBGRA:(uint32_t *)pixel;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
#endif
