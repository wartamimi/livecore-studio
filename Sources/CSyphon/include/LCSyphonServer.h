// LiveCore Studio: a Syphon server that publishes CVPixelBuffers (BGRA, IOSurface-backed) from
// the compositor. Other apps (OBS "Syphon Client", Resolume, MadMapper, ...) receive the picture.
// Built on the vendored Syphon server code in this target (BSD licence, see License.txt).
#pragma once
#if defined(__APPLE__)
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface LCSyphonServer : NSObject
/// Starts a server named `name` (shown in clients as "LiveCore Studio – name"). Nil on failure.
- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device;
/// Copies `pixelBuffer` into the shared surface on the GPU and announces the new frame.
/// Thread-safe; does nothing while no client is connected.
- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer;
@property (readonly) BOOL hasClients;
@property (readonly, copy) NSString *name;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
#endif
