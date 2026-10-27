// Objective-C bridge to the Zoom Meeting SDK for macOS.
//
// The SDK is proprietary and is not in this repository: CI downloads it from a private
// repository and builds with LIVECORE_ZOOM=1. Without it this class compiles to a stub whose
// +isAvailable returns NO, so the open-source build never references the SDK.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LCZoomState) {
    LCZoomStateNotAuthorized = 0,
    LCZoomStateAuthorizing,
    LCZoomStateReady,
    LCZoomStateJoining,
    LCZoomStateInMeeting,
    LCZoomStateFailed,
};

typedef NS_ENUM(NSInteger, LCZoomRawState) {
    LCZoomRawStateNotAllowed = 0,
    LCZoomRawStateRequested,
    LCZoomRawStateAllowed,
};

@interface LCZoomParticipant : NSObject
@property (nonatomic) unsigned int userID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isHost;
@property (nonatomic) BOOL videoOn;
@property (nonatomic) BOOL isMe;
@end

@interface LCZoomSDK : NSObject

+ (BOOL)isAvailable;
+ (instancetype)shared;

/// Main thread: state, error or participant list changed.
@property (nonatomic, copy, nullable) void (^onChange)(void);
/// SDK thread: one I420 frame of a subscribed user (planes valid during the call only).
@property (nonatomic, copy, nullable) void (^onVideo)(unsigned int userID, int width, int height,
                                                      uint8_t *y, uint8_t *u, uint8_t *v,
                                                      int yStride, int uvStride, BOOL fullRange);
/// SDK thread: mixed meeting audio (everyone but us), interleaved 16-bit.
@property (nonatomic, copy, nullable) void (^onMixedAudio)(const int16_t *samples, int frames, int channels, int sampleRate);

@property (nonatomic, readonly) LCZoomState state;
@property (nonatomic, readonly) LCZoomRawState rawState;
@property (nonatomic, readonly, copy) NSString *errorMessage;
@property (nonatomic, readonly, copy) NSArray<LCZoomParticipant *> *participants;
@property (nonatomic, readonly, copy) NSString *version;

/// Set before joining: use Program as our camera / a bus as our microphone.
@property (nonatomic) BOOL sendVideo;
@property (nonatomic) BOOL sendAudio;
@property (nonatomic, readonly) BOOL canSendVideo;
@property (nonatomic, readonly) BOOL canSendAudio;

- (void)authorizeWithJWT:(NSString *)jwt;
- (void)joinMeeting:(long long)number passcode:(NSString *)passcode displayName:(NSString *)name;
- (void)leave;
- (void)requestRawData;
- (void)subscribeUser:(unsigned int)userID;
- (void)unsubscribeUser:(unsigned int)userID;
/// Contiguous I420 (Y, then U, then V; strides = width, width/2).
- (void)sendI420:(uint8_t *)data width:(int)width height:(int)height;
/// Mono 16-bit at 48 kHz, at most 100 ms per call.
- (void)sendAudio:(const int16_t *)samples frames:(int)frames;

@end

NS_ASSUME_NONNULL_END
