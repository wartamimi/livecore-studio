#import "LCZoomSDK.h"

@implementation LCZoomParticipant
@end

#if LIVECORE_ZOOM
#import <ZoomSDK/ZoomSDK.h>

// Per-renderer delegate: knows which user its frames belong to.
@interface LCZoomRenderDelegate : NSObject <ZoomSDKRendererDelegate>
@property (nonatomic) unsigned int userID;
@property (nonatomic, weak) LCZoomSDK *owner;
@end

@interface LCZoomSDK () <ZoomSDKAuthDelegate, ZoomSDKMeetingServiceDelegate, ZoomSDKMeetingActionControllerDelegate,
                         ZoomSDKMeetingRecordDelegate, ZoomSDKAudioRawDataDelegate,
                         ZoomSDKVirtualVideoSourceDelegate, ZoomSDKVirtualAudioMicDelegate>
@property (nonatomic, readwrite) LCZoomState state;
@property (nonatomic, readwrite) LCZoomRawState rawState;
@property (nonatomic, readwrite, copy) NSString *errorMessage;
@property (nonatomic, readwrite, copy) NSArray<LCZoomParticipant *> *participants;
@end

@implementation LCZoomRenderDelegate
- (void)onRawDataReceived:(ZoomSDKYUVRawDataI420 *)data {
    LCZoomSDK *o = self.owner;
    if (!data || !o.onVideo) return;
    int w = (int)[data getStreamWidth], h = (int)[data getStreamHeight];
    char *y = [data getYBuffer], *u = [data getUBuffer], *v = [data getVBuffer];
    if (!y || !u || !v || w < 2 || h < 2) return;
    o.onVideo(self.userID, w, h, (uint8_t *)y, (uint8_t *)u, (uint8_t *)v, w, w / 2, ![data isLimitedI420]);
}
- (void)onSubscribedUserDataOn {}
- (void)onSubscribedUserDataOff {}
- (void)onRendererBeDestroyed {}
- (void)onShareCursorDataReceived:(ZoomSDKShareCursorData *)info {}
@end

@implementation LCZoomSDK {
    BOOL _initialized;
    NSMutableDictionary<NSNumber *, ZoomSDKRenderer *> *_renderers;
    NSMutableDictionary<NSNumber *, LCZoomRenderDelegate *> *_renderDelegates;
    NSMutableSet<NSNumber *> *_wanted;           // users to subscribe once raw data is allowed
    ZoomSDKRawDataSender *_videoSender;
    ZoomSDKAudioRawDataSender *_audioSender;
    BOOL _videoSending, _audioSending;
    BOOL _audioSubscribed;
}

+ (BOOL)isAvailable { return YES; }

+ (instancetype)shared {
    static LCZoomSDK *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LCZoomSDK alloc] init]; });
    return s;
}

- (instancetype)init {
    if ((self = [super init])) {
        _renderers = [NSMutableDictionary dictionary];
        _renderDelegates = [NSMutableDictionary dictionary];
        _wanted = [NSMutableSet set];
        _errorMessage = @"";
        _participants = @[];
    }
    return self;
}

- (NSString *)version { return [[ZoomSDK sharedSDK] getSDKVersionNumber] ?: @""; }
- (BOOL)canSendVideo { return _videoSender != nil && _videoSending; }
- (BOOL)canSendAudio { return _audioSender != nil && _audioSending; }

- (void)changed {
    void (^cb)(void) = self.onChange;
    if (!cb) return;
    if ([NSThread isMainThread]) cb(); else dispatch_async(dispatch_get_main_queue(), cb);
}

- (void)fail:(NSString *)message {
    self.errorMessage = message;
    self.state = LCZoomStateFailed;
    [self changed];
}

// MARK: Auth

- (void)authorizeWithJWT:(NSString *)jwt {
    if (!_initialized) {
        ZoomSDKInitParams *params = [[ZoomSDKInitParams alloc] init];
        params.needCustomizedUI = NO;      // Zoom's own meeting window (chat, gallery...) stays available
        params.enableLog = YES;
        params.zoomDomain = @"zoom.us";
        ZoomSDKError e = [[ZoomSDK sharedSDK] initSDKWithParams:params];
        if (e != ZoomSDKError_Success) { [self fail:[NSString stringWithFormat:@"SDK init failed (%d)", (int)e]]; return; }
        _initialized = YES;
    }
    ZoomSDKAuthService *auth = [[ZoomSDK sharedSDK] getAuthService];
    auth.delegate = self;
    ZoomSDKAuthContext *ctx = [[ZoomSDKAuthContext alloc] init];
    ctx.jwtToken = jwt;
    self.state = LCZoomStateAuthorizing;
    self.errorMessage = @"";
    [self changed];
    ZoomSDKError e = [auth sdkAuth:ctx];
    if (e != ZoomSDKError_Success) [self fail:[NSString stringWithFormat:@"SDK auth call failed (%d)", (int)e]];
}

- (void)onZoomSDKAuthReturn:(ZoomSDKAuthError)returnValue {
    switch (returnValue) {
        case ZoomSDKAuthError_Success:
            self.state = LCZoomStateReady; self.errorMessage = @""; [self changed]; return;
        case ZoomSDKAuthError_KeyOrSecretWrong: [self fail:@"Client ID or Client Secret is wrong."]; return;
        case ZoomSDKAuthError_AccountNotSupport: [self fail:@"This Zoom account does not support the Meeting SDK."]; return;
        case ZoomSDKAuthError_AccountNotEnableSDK: [self fail:@"Meeting SDK is not enabled for this Zoom app/account."]; return;
        case ZoomSDKAuthError_JwtTokenWrong: [self fail:@"SDK token rejected (check the Mac's clock and the credentials)."]; return;
        case ZoomSDKAuthError_Timeout: [self fail:@"Zoom authorization timed out."]; return;
        case ZoomSDKAuthError_NetworkIssue: [self fail:@"Network problem while authorizing with Zoom."]; return;
        default: [self fail:[NSString stringWithFormat:@"Zoom authorization failed (%d).", (int)returnValue]]; return;
    }
}
- (void)onZoomIdentityExpired { [self fail:@"Zoom SDK token expired; authorize again."]; }

// MARK: Meeting

- (void)joinMeeting:(long long)number passcode:(NSString *)passcode displayName:(NSString *)name {
    ZoomSDKMeetingService *ms = [[ZoomSDK sharedSDK] getMeetingService];
    if (!ms) { [self fail:@"Meeting service unavailable (authorize first)."]; return; }
    ms.delegate = self;
    ZoomSDKRawDataController *raw = [[ZoomSDK sharedSDK] getRawDataController];
    // Virtual camera / microphone must be installed before joining.
    ZoomSDKRawDataVideoSourceController *vs = nil;
    if ([raw getRawDataVideoSourceHelper:&vs] == ZoomSDKError_Success && vs)
        [vs setExternalVideoSource:(self.sendVideo ? self : nil) videoDataFormat:ZoomSDKFrameDataFormat_I420_Limited];
    ZoomSDKRawDataAudioSourceController *as = nil;
    if ([raw getRawDataAudioSourceHelper:&as] == ZoomSDKError_Success && as)
        [as setExternalAudioSource:(self.sendAudio ? self : nil)];

    ZoomSDKJoinMeetingElements *p = [[ZoomSDKJoinMeetingElements alloc] init];
    p.userType = ZoomSDKUserType_WithoutLogin;
    p.meetingNumber = number;
    p.displayName = name.length ? name : @"LiveCore Studio";
    p.password = passcode;
    p.isNoVideo = !self.sendVideo;
    p.isNoAudio = NO;
    p.isDirectShare = NO;
    p.displayID = 0;
    self.state = LCZoomStateJoining;
    self.rawState = LCZoomRawStateNotAllowed;
    self.errorMessage = @"";
    [self changed];
    ZoomSDKError e = [ms joinMeeting:p];
    if (e != ZoomSDKError_Success) [self fail:[NSString stringWithFormat:@"Join failed (%d).", (int)e]];
}

- (void)leave {
    [self teardownRaw];
    [[[ZoomSDK sharedSDK] getMeetingService] leaveMeetingWithCmd:LeaveMeetingCmd_Leave];
}

- (void)onMeetingStatusChange:(ZoomSDKMeetingStatus)state meetingError:(ZoomSDKMeetingError)error EndReason:(EndMeetingReason)reason {
    switch (state) {
        case ZoomSDKMeetingStatus_Connecting:
        case ZoomSDKMeetingStatus_WaitingForHost:
        case ZoomSDKMeetingStatus_InWaitingRoom:
        case ZoomSDKMeetingStatus_Reconnecting:
            self.state = LCZoomStateJoining;
            self.errorMessage = state == ZoomSDKMeetingStatus_WaitingForHost ? @"Waiting for the host to start the meeting."
                              : state == ZoomSDKMeetingStatus_InWaitingRoom ? @"In the waiting room." : @"";
            break;
        case ZoomSDKMeetingStatus_InMeeting: {
            self.state = LCZoomStateInMeeting;
            self.errorMessage = @"";
            ZoomSDKMeetingService *ms = [[ZoomSDK sharedSDK] getMeetingService];
            [ms getMeetingActionController].delegate = self;
            [ms getRecordController].delegate = self;
            [self refreshParticipants];
            [self tryStartRaw];
            break;
        }
        case ZoomSDKMeetingStatus_Failed:
            [self teardownRaw];
            self.state = LCZoomStateFailed;
            // A localization key; the UI turns it into a readable explanation (see zoom.meeting_error.* strings).
            self.errorMessage = [NSString stringWithFormat:@"zoom.meeting_error.%d", (int)error];
            break;
        case ZoomSDKMeetingStatus_Ended:
        case ZoomSDKMeetingStatus_Idle:
            [self teardownRaw];
            self.state = [[[ZoomSDK sharedSDK] getAuthService] isAuthorized] ? LCZoomStateReady : LCZoomStateNotAuthorized;
            self.participants = @[];
            break;
        default:
            break;
    }
    [self changed];
}

- (void)refreshParticipants {
    ZoomSDKMeetingActionController *ac = [[[ZoomSDK sharedSDK] getMeetingService] getMeetingActionController];
    ZoomSDKUserInfo *me = [ac getMyself];
    NSMutableArray *list = [NSMutableArray array];
    for (NSNumber *n in [ac getParticipantsList] ?: @[]) {
        ZoomSDKUserInfo *u = [ac getUserByUserID:n.unsignedIntValue];
        if (!u) continue;
        LCZoomParticipant *p = [[LCZoomParticipant alloc] init];
        p.userID = [u getUserID];
        p.name = [u getUserName] ?: @"";
        p.isHost = [u isHost];
        p.videoOn = [u isVideoOn];
        p.isMe = me && [me getUserID] == p.userID;
        [list addObject:p];
    }
    self.participants = list;
}

- (void)onUserJoin:(NSArray *)array { [self refreshParticipants]; [self changed]; }
- (void)onUserLeft:(NSArray *)array { [self refreshParticipants]; [self changed]; }
- (void)onUserVideoStatusChange:(BOOL)videoOn UserID:(unsigned int)userID { [self refreshParticipants]; [self changed]; }

// MARK: Raw data (needs the local-recording privilege from the host)

- (void)tryStartRaw {
    ZoomSDKMeetingRecordController *rc = [[[ZoomSDK sharedSDK] getMeetingService] getRecordController];
    if ([rc startRawRecording] == ZoomSDKError_Success) {
        self.rawState = LCZoomRawStateAllowed;
        [self subscribeAudio];
        for (NSNumber *n in [_wanted copy]) [self startRenderer:n.unsignedIntValue];
    } else if (self.rawState != LCZoomRawStateRequested) {
        self.rawState = LCZoomRawStateNotAllowed;
    }
    [self changed];
}

- (void)requestRawData {
    ZoomSDKMeetingRecordController *rc = [[[ZoomSDK sharedSDK] getMeetingService] getRecordController];
    ZoomSDKError e = [rc requestLocalRecordingPrivilege];
    if (e == ZoomSDKError_Success) { self.rawState = LCZoomRawStateRequested; self.errorMessage = @""; }
    else self.errorMessage = [NSString stringWithFormat:@"Could not ask the host for recording permission (%d). Ask the host to allow local recording for you.", (int)e];
    [self changed];
}

- (void)onRecordPrivilegeChange:(BOOL)canRec {
    if (canRec) [self tryStartRaw];
    else { [self stopRenderers]; self.rawState = LCZoomRawStateNotAllowed; [self changed]; }
}

- (void)subscribeAudio {
    if (_audioSubscribed) return;
    ZoomSDKAudioRawDataHelper *h = nil;
    if ([[[ZoomSDK sharedSDK] getRawDataController] getAudioRawDataHelper:&h] == ZoomSDKError_Success && h)
        _audioSubscribed = [h subscribe:ZoomSDKSessionSource_CurrentSession delegate:self] == ZoomSDKError_Success;
}

- (void)onMixedAudioRawDataReceived:(ZoomSDKAudioRawData *)data {
    void (^cb)(const int16_t *, int, int, int) = self.onMixedAudio;
    if (!data || !cb) return;
    int ch = (int)MAX([data getChannelNum], 1);
    int frames = (int)([data getBufferLen] / (2 * ch));
    cb((const int16_t *)[data getBuffer], frames, ch, (int)[data getSampleRate]);
}
- (void)onOneWayAudioRawDataReceived:(ZoomSDKAudioRawData *)data userID:(unsigned int)userID {}
- (void)onShareAudioRawDataReceived:(ZoomSDKAudioRawData *)data userID:(unsigned int)userID {}
- (void)onOneWayInterpreterAudioRawDataReceived:(ZoomSDKAudioRawData *)data strLanguageName:(NSString *)languageName {}

- (void)subscribeUser:(unsigned int)userID {
    [_wanted addObject:@(userID)];
    if (self.rawState == LCZoomRawStateAllowed) [self startRenderer:userID];
}

- (void)unsubscribeUser:(unsigned int)userID {
    [_wanted removeObject:@(userID)];
    ZoomSDKRenderer *r = _renderers[@(userID)];
    if (r) {
        [r unSubscribe];
        [[[ZoomSDK sharedSDK] getRawDataController] destroyRender:r];
        [_renderers removeObjectForKey:@(userID)];
        [_renderDelegates removeObjectForKey:@(userID)];
    }
}

- (void)startRenderer:(unsigned int)userID {
    if (_renderers[@(userID)]) return;
    ZoomSDKRenderer *r = nil;
    if ([[[ZoomSDK sharedSDK] getRawDataController] createRender:&r] != ZoomSDKError_Success || !r) return;
    LCZoomRenderDelegate *d = [[LCZoomRenderDelegate alloc] init];
    d.userID = userID; d.owner = self;
    r.delegate = d;
    [r setResolution:ZoomSDKResolution_720P];
    if ([r subscribe:userID rawDataType:ZoomSDKRawDataType_Video] == ZoomSDKError_Success) {
        _renderers[@(userID)] = r;
        _renderDelegates[@(userID)] = d;
    } else {
        [[[ZoomSDK sharedSDK] getRawDataController] destroyRender:r];
    }
}

- (void)stopRenderers {
    for (NSNumber *n in _renderers.allKeys) {
        ZoomSDKRenderer *r = _renderers[n];
        [r unSubscribe];
        [[[ZoomSDK sharedSDK] getRawDataController] destroyRender:r];
    }
    [_renderers removeAllObjects];
    [_renderDelegates removeAllObjects];
}

- (void)teardownRaw {
    [self stopRenderers];
    [_wanted removeAllObjects];
    if (_audioSubscribed) {
        ZoomSDKAudioRawDataHelper *h = nil;
        if ([[[ZoomSDK sharedSDK] getRawDataController] getAudioRawDataHelper:&h] == ZoomSDKError_Success && h)
            [h unSubscribe:ZoomSDKSessionSource_CurrentSession];
        _audioSubscribed = NO;
    }
    if (self.rawState == LCZoomRawStateAllowed)
        [[[[ZoomSDK sharedSDK] getMeetingService] getRecordController] stopRawRecording];
    self.rawState = LCZoomRawStateNotAllowed;
}

// MARK: Virtual camera (Program out)

- (void)onInitialize:(ZoomSDKRawDataSender *)sender supportedCapabilityList:(NSArray *)capabilityList suggestCapability:(ZoomSDKVideoCapabilityItem *)suggestCap {
    _videoSender = sender;
}
- (void)onPropertyChange:(NSArray *)supportedCapabilityList suggestCapability:(ZoomSDKVideoCapabilityItem *)suggestCap {}
- (void)onStartSend { _videoSending = YES; }
- (void)onStopSend { _videoSending = NO; }
- (void)onUninitialize { _videoSending = NO; _videoSender = nil; }

- (void)sendI420:(uint8_t *)data width:(int)width height:(int)height {
    ZoomSDKRawDataSender *s = _videoSender;
    if (!s || !_videoSending) return;
    [s sendRawData:(char *)data width:(unsigned)width height:(unsigned)height
        dataLength:(unsigned)(width * height * 3 / 2) rotation:ZoomSDKLOCAL_DEVICE_ROTATION_ACTION_0];
}

// MARK: Virtual microphone (bus out)

- (void)onMicInitialize:(ZoomSDKAudioRawDataSender *)rawdataSender { _audioSender = rawdataSender; }
- (void)onMicStartSend { _audioSending = YES; }
- (void)onMicStopSend { _audioSending = NO; }
- (void)onMicUninitialized { _audioSending = NO; _audioSender = nil; }

- (void)sendAudio:(const int16_t *)samples frames:(int)frames {
    ZoomSDKAudioRawDataSender *s = _audioSender;
    if (!s || !_audioSending || frames <= 0) return;
    [s send:(char *)samples dataLength:(unsigned)(frames * 2) sampleRate:48000 channel:ZoomSDKAudioChannel_Mono];
}

@end

#else  // Built without the Zoom SDK.

@implementation LCZoomSDK
+ (BOOL)isAvailable { return NO; }
+ (instancetype)shared { static LCZoomSDK *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [[LCZoomSDK alloc] init]; }); return s; }
- (LCZoomState)state { return LCZoomStateNotAuthorized; }
- (LCZoomRawState)rawState { return LCZoomRawStateNotAllowed; }
- (NSString *)errorMessage { return @"This build does not include the Zoom SDK."; }
- (NSArray<LCZoomParticipant *> *)participants { return @[]; }
- (NSString *)version { return @""; }
- (BOOL)canSendVideo { return NO; }
- (BOOL)canSendAudio { return NO; }
- (void)authorizeWithJWT:(NSString *)jwt {}
- (void)joinMeeting:(long long)number passcode:(NSString *)passcode displayName:(NSString *)name {}
- (void)leave {}
- (void)requestRawData {}
- (void)subscribeUser:(unsigned int)userID {}
- (void)unsubscribeUser:(unsigned int)userID {}
- (void)sendI420:(uint8_t *)data width:(int)width height:(int)height {}
- (void)sendAudio:(const int16_t *)samples frames:(int)frames {}
@end

#endif
