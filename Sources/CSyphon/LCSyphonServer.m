#if defined(__APPLE__)
#import "LCSyphonServer.h"
#import "SyphonServerBase.h"
#import "SyphonSubclassing.h"
#import <IOSurface/IOSurface.h>

#if !__has_feature(objc_arc)
#error "CSyphon must be compiled with ARC"
#endif

/// Blit-only Syphon server: our frames are already BGRA in IOSurfaces of the output size, so a
/// GPU copy into Syphon's shared surface is all that is needed (no OpenGL, no shaders).
@interface LCSyphonBlitServer : SyphonServerBase
@end
@implementation LCSyphonBlitServer
@end

@implementation LCSyphonServer {
    LCSyphonBlitServer *_server;
    id<MTLDevice> _device;
    id<MTLCommandQueue> _queue;
    id<MTLTexture> _surfaceTexture;
    NSString *_name;
}

- (nullable instancetype)initWithName:(NSString *)name device:(id<MTLDevice>)device {
    self = [super init];
    if (!self) return nil;
    _name = [name copy];
    _device = device;
    _queue = [device newCommandQueue];
    _server = [[LCSyphonBlitServer alloc] initWithName:name options:nil];
    if (!_server || !_queue) return nil;
    return self;
}

- (NSString *)name { return _name; }

- (BOOL)hasClients {
    @synchronized (self) { return _server.hasClients; }
}

- (id<MTLTexture>)targetForWidth:(NSUInteger)width height:(NSUInteger)height {
    if (_surfaceTexture && _surfaceTexture.width == width && _surfaceTexture.height == height) return _surfaceTexture;
    _surfaceTexture = nil;
    IOSurfaceRef surface = [_server newSurfaceForWidth:width height:height options:nil];
    if (!surface) return nil;
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                 width:width height:height mipmapped:NO];
    d.usage = MTLTextureUsageShaderRead | MTLTextureUsageRenderTarget;
    _surfaceTexture = [_device newTextureWithDescriptor:d iosurface:surface plane:0];
    CFRelease(surface);
    return _surfaceTexture;
}

- (void)publishPixelBuffer:(CVPixelBufferRef)pixelBuffer {
    @synchronized (self) {
        if (!_server || !_server.hasClients) return;
        if (CVPixelBufferGetPixelFormatType(pixelBuffer) != kCVPixelFormatType_32BGRA) return;
        IOSurfaceRef src = CVPixelBufferGetIOSurface(pixelBuffer);
        if (!src) return;
        NSUInteger w = CVPixelBufferGetWidth(pixelBuffer), h = CVPixelBufferGetHeight(pixelBuffer);
        id<MTLTexture> dst = [self targetForWidth:w height:h];
        if (!dst) return;
        MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                     width:w height:h mipmapped:NO];
        d.usage = MTLTextureUsageShaderRead;
        id<MTLTexture> srcTex = [_device newTextureWithDescriptor:d iosurface:src plane:0];
        id<MTLCommandBuffer> cb = [_queue commandBuffer];
        id<MTLBlitCommandEncoder> blit = [cb blitCommandEncoder];
        if (!srcTex || !cb || !blit) return;
        [blit copyFromTexture:srcTex sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0, 0, 0)
                   sourceSize:MTLSizeMake(w, h, 1) toTexture:dst destinationSlice:0 destinationLevel:0
            destinationOrigin:MTLOriginMake(0, 0, 0)];
        [blit endEncoding];
        // Keep the source buffer alive until the GPU has read it (the compositor's pool reuses it).
        CVPixelBufferRetain(pixelBuffer);
        LCSyphonBlitServer *server = _server;
        [cb addCompletedHandler:^(id<MTLCommandBuffer> _Nonnull buffer) {
            CVPixelBufferRelease(pixelBuffer);
            [server publish];
        }];
        [cb commit];
    }
}

- (void)stop {
    @synchronized (self) {
        _surfaceTexture = nil;
        [_server stop];
        _server = nil;
    }
}

- (void)dealloc { [_server stop]; }
@end
#endif
