#import "../../YTKACE.h"
#import "../../Runtime/Hooking.h"
#import "../../Runtime/Preferences.h"
#import "../Downloads/DownloadLog.h"
#import "PlaybackWatchdog.hpp"

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

static NSString * const YTKACERecoveryKey = @"YTKACE.Preference.Playback.Recovery";
NSString * const YTKACEPlaybackRecoveryStateDidChange =
    @"YTKACEPlaybackRecoveryStateDidChange";

static IMP OriginalInitializePlayback;
static IMP OriginalQueuePlayerSetState;
static IMP OriginalQueuePlayerFail;
static IMP OriginalHeartbeatResponse;

static const NSTimeInterval YTKACESamplerInterval = 1.0;
static const NSUInteger YTKACEQuietSamplesBeforeStall = 3;
static const double YTKACEHardNudgeRewind = 0.5;

static NSString *YTKACEStateName(ytkace::WatchdogState state) {
    switch (state) {
        case ytkace::WatchdogState::Idle: return @"idle";
        case ytkace::WatchdogState::Watching: return @"watching";
        case ytkace::WatchdogState::Suspect: return @"suspect";
        case ytkace::WatchdogState::Recovering: return @"recovering";
        case ytkace::WatchdogState::Cooldown: return @"cooldown";
        case ytkace::WatchdogState::Surrendered: return @"surrendered";
    }
    return @"?";
}

static NSString *YTKACEActionName(ytkace::WatchdogAction action) {
    switch (action) {
        case ytkace::WatchdogAction::None: return @"none";
        case ytkace::WatchdogAction::Resume: return @"resume";
        case ytkace::WatchdogAction::Nudge: return @"nudge";
        case ytkace::WatchdogAction::Reload: return @"reload";
    }
    return @"?";
}

static id YTKACEIvarValue(id object, NSString *name) {
    if (object == nil) return nil;
    for (Class cls = [object class]; cls != Nil; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar == NULL) continue;
        const char *type = ivar_getTypeEncoding(ivar);
        if (type == NULL || type[0] != '@') return nil;
        return object_getIvar(object, ivar);
    }
    return nil;
}

@interface YTKACERecoveryCoordinator : NSObject
@property(nonatomic, weak) id playbackController;
@property(nonatomic, weak) id queuePlayer;
@property(nonatomic, strong) NSTimer *pendingTimer;
@property(nonatomic, strong) NSTimer *sampler;
@property(nonatomic, strong) NSMutableSet<NSNumber *> *statesSeenWhileAdvancing;
@property(nonatomic, strong) NSNumber *lastRawState;
@property(nonatomic, assign) double lastSampledPosition;
@property(nonatomic, assign) NSUInteger quietSamples;
@end

@implementation YTKACERecoveryCoordinator {
    ytkace::PlaybackWatchdog _watchdog;
}

+ (instancetype)shared {
    static YTKACERecoveryCoordinator *shared;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ shared = [YTKACERecoveryCoordinator new]; });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self != nil) {
        _statesSeenWhileAdvancing = [NSMutableSet set];
        _lastSampledPosition = -1.0;
    }
    return self;
}

- (BOOL)enabled {
    return YTKACEFeatureEnabled(YTKACERecoveryKey);
}

- (double)now {
    return NSDate.timeIntervalSinceReferenceDate;
}

- (BOOL)target:(id)target respondsWithDoubleReturn:(SEL)selector {
    if (![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    return signature != nil && strcmp(signature.methodReturnType, @encode(double)) == 0;
}

- (BOOL)target:(id)target respondsWithDoubleArgument:(SEL)selector {
    if (![target respondsToSelector:selector]) return NO;
    NSMethodSignature *signature = [target methodSignatureForSelector:selector];
    if (signature == nil || signature.numberOfArguments < 3) return NO;
    return strcmp([signature getArgumentTypeAtIndex:2], @encode(double)) == 0;
}

- (double)currentPosition {
    for (id candidate in @[self.queuePlayer ?: NSNull.null,
                           self.playbackController ?: NSNull.null]) {
        if (candidate == NSNull.null) continue;
        for (NSString *name in @[@"currentMediaTime", @"currentTimeSeconds"]) {
            SEL selector = NSSelectorFromString(name);
            if (![self target:candidate respondsWithDoubleReturn:selector]) continue;
            return ((double (*)(id, SEL))objc_msgSend)(candidate, selector);
        }
    }
    return -1.0;
}

- (BOOL)currentlyLive {
    for (id candidate in @[self.playbackController ?: NSNull.null,
                           self.queuePlayer ?: NSNull.null]) {
        if (candidate == NSNull.null) continue;
        for (NSString *name in @[@"isLiveStream", @"isLive"]) {
            SEL selector = NSSelectorFromString(name);
            if (![candidate respondsToSelector:selector]) continue;
            return ((BOOL (*)(id, SEL))objc_msgSend)(candidate, selector);
        }
    }
    return NO;
}

- (void)cancelTimers {
    [self.pendingTimer invalidate];
    self.pendingTimer = nil;
}

- (void)armTimerIn:(NSTimeInterval)delay {
    [self cancelTimers];
    self.pendingTimer = [NSTimer scheduledTimerWithTimeInterval:delay
                                                        repeats:NO
                                                          block:^(NSTimer *timer) {
        (void)timer;
        [self dispatch:ytkace::WatchdogEvent::TimerFired position:[self currentPosition]];
    }];
}

- (void)startSampler {
    if (self.sampler != nil) return;
    self.quietSamples = 0;
    self.lastSampledPosition = -1.0;
    self.sampler = [NSTimer scheduledTimerWithTimeInterval:YTKACESamplerInterval
                                                   repeats:YES
                                                     block:^(NSTimer *timer) {
        (void)timer;
        [self sample];
    }];
}

- (void)stopSampler {
    [self.sampler invalidate];
    self.sampler = nil;
}

- (void)sample {
    if (![self enabled]) {
        [self dispatch:ytkace::WatchdogEvent::FeatureDisabled position:-1.0];
        [self stopSampler];
        return;
    }
    const double position = [self currentPosition];
    if (position < 0.0) return;
    const BOOL advanced = self.lastSampledPosition < 0.0 ||
        (position - self.lastSampledPosition) >= 0.25;
    if (advanced) {
        self.quietSamples = 0;
        if (self.lastRawState != nil) {
            [self.statesSeenWhileAdvancing addObject:self.lastRawState];
        }
        self.lastSampledPosition = position;
        [self dispatch:ytkace::WatchdogEvent::ProgressObserved position:position];
        return;
    }
    self.lastSampledPosition = position;
    const BOOL expectedToPlay = self.lastRawState != nil &&
        [self.statesSeenWhileAdvancing containsObject:self.lastRawState];
    if (!expectedToPlay) return;
    self.quietSamples += 1;
    if (self.quietSamples < YTKACEQuietSamplesBeforeStall) return;
    self.quietSamples = 0;
    [self dispatch:ytkace::WatchdogEvent::StalledState position:position];
}

- (void)dispatch:(ytkace::WatchdogEvent)event position:(double)position {
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self dispatch:event position:position];
        });
        return;
    }
    _watchdog.setLive([self currentlyLive]);
    const ytkace::WatchdogState before = _watchdog.state();
    const ytkace::WatchdogOutcome outcome =
        _watchdog.handle(event, [self now], position);
    const ytkace::WatchdogState after = _watchdog.state();

    if (outcome.cancelTimers) [self cancelTimers];
    if (outcome.armTimerIn >= 0.0) [self armTimerIn:outcome.armTimerIn];
    if (outcome.action != ytkace::WatchdogAction::None) [self apply:outcome.action];

    if (before != after) {
        YTKACEDownloadLog(@"recovery", @"%@ -> %@ action=%@ attempts=%d live=%d",
                          YTKACEStateName(before), YTKACEStateName(after),
                          YTKACEActionName(outcome.action),
                          _watchdog.attemptsInWindow([self now]),
                          [self currentlyLive]);
        [NSNotificationCenter.defaultCenter
            postNotificationName:YTKACEPlaybackRecoveryStateDidChange
                          object:nil];
    }
    if (after == ytkace::WatchdogState::Idle ||
        after == ytkace::WatchdogState::Surrendered) {
        [self stopSampler];
    }
}

- (void)apply:(ytkace::WatchdogAction)action {
    switch (action) {
        case ytkace::WatchdogAction::None:
            return;
        case ytkace::WatchdogAction::Resume:
            [self performResume];
            return;
        case ytkace::WatchdogAction::Nudge:
            [self seekTo:[self currentPosition]];
            return;
        case ytkace::WatchdogAction::Reload: {
            if ([self performReload]) return;
            const double position = [self currentPosition];
            const double target = position > YTKACEHardNudgeRewind
                ? position - YTKACEHardNudgeRewind : 0.0;
            YTKACEDownloadLog(@"recovery", @"reload unavailable, rewinding instead");
            [self seekTo:target];
            [self performResume];
            return;
        }
    }
}

- (id)activeVideoController {
    id controller = self.playbackController;
    if (controller == nil) return nil;
    NSMutableArray *hosts = [NSMutableArray arrayWithObject:controller];
    id sequencer = YTKACEIvarValue(controller, @"_videoSequencer");
    if (sequencer != nil) [hosts addObject:sequencer];
    for (id host in hosts) {
        for (NSString *name in @[@"activeVideoController", @"contentVideoController"]) {
            SEL selector = NSSelectorFromString(name);
            if (![host respondsToSelector:selector]) continue;
            id value = ((id (*)(id, SEL))objc_msgSend)(host, selector);
            if (value != nil) return value;
        }
    }
    return nil;
}

- (BOOL)performReload {
    id controller = self.playbackController;
    id active = [self activeVideoController];
    if (controller == nil || active == nil) return NO;

    id context = nil;
    Class contextClass = NSClassFromString(@"MLPlayerReloadContext");
    SEL contextInit = NSSelectorFromString(@"initWithStartPlayback:refreshStreamingData:");
    if (contextClass != Nil) {
        id allocated = [contextClass alloc];
        if ([allocated respondsToSelector:contextInit]) {
            context = ((id (*)(id, SEL, BOOL, BOOL))objc_msgSend)(
                allocated, contextInit, YES, YES);
        }
    }

    SEL requiresReload =
        NSSelectorFromString(@"singleVideoController:requiresReloadWithContext:");
    if (context != nil && [controller respondsToSelector:requiresReload]) {
        ((void (*)(id, SEL, id, id))objc_msgSend)(
            controller, requiresReload, active, context);
        YTKACEDownloadLog(@"recovery", @"reload via requiresReloadWithContext");
        return YES;
    }

    SEL fetchAndResolve = NSSelectorFromString(@"fetchPlayerDataAndResolveVideo");
    if ([controller respondsToSelector:fetchAndResolve]) {
        ((void (*)(id, SEL))objc_msgSend)(controller, fetchAndResolve);
        YTKACEDownloadLog(@"recovery", @"reload via fetchPlayerDataAndResolveVideo");
        return YES;
    }

    return NO;
}

- (void)performResume {
    for (NSString *name in @[@"play", @"playVideo", @"resumePlayback"]) {
        SEL selector = NSSelectorFromString(name);
        for (id candidate in @[self.queuePlayer ?: NSNull.null,
                               self.playbackController ?: NSNull.null]) {
            if (candidate == NSNull.null) continue;
            if (![candidate respondsToSelector:selector]) continue;
            NSMethodSignature *signature =
                [candidate methodSignatureForSelector:selector];
            if (signature == nil || signature.numberOfArguments != 2) continue;
            ((void (*)(id, SEL))objc_msgSend)(candidate, selector);
            YTKACEDownloadLog(@"recovery", @"resume via %@ on %@", name,
                              NSStringFromClass([candidate class]));
            return;
        }
    }
    YTKACEDownloadLog(@"recovery", @"resume unavailable");
}

- (void)seekTo:(double)position {
    if (position < 0.0) return;
    for (NSString *name in @[@"seekToMediaTime:", @"seekToTime:"]) {
        SEL selector = NSSelectorFromString(name);
        for (id candidate in @[self.queuePlayer ?: NSNull.null,
                               self.playbackController ?: NSNull.null]) {
            if (candidate == NSNull.null) continue;
            if (![self target:candidate respondsWithDoubleArgument:selector]) continue;
            ((void (*)(id, SEL, double))objc_msgSend)(candidate, selector, position);
            YTKACEDownloadLog(@"recovery", @"seek %.2f via %@ on %@", position, name,
                              NSStringFromClass([candidate class]));
            return;
        }
    }
    YTKACEDownloadLog(@"recovery", @"seek unavailable");
}

- (void)noteController:(id)controller {
    self.playbackController = controller;
}

- (void)notePlayer:(id)player rawState:(long)state {
    self.queuePlayer = player;
    self.lastRawState = @(state);
}

- (void)sessionStarted {
    if (![self enabled]) return;
    [self startSampler];
    [self dispatch:ytkace::WatchdogEvent::PlaybackStarted position:[self currentPosition]];
}

- (void)reportFault:(ytkace::WatchdogEvent)event {
    if (![self enabled]) return;
    [self dispatch:event position:[self currentPosition]];
}

@end

static void YTKACEInitializePlayback(id receiver, SEL selector) {
    if (OriginalInitializePlayback != NULL) {
        ((void (*)(id, SEL))OriginalInitializePlayback)(receiver, selector);
    }
    YTKACERecoveryCoordinator *coordinator = [YTKACERecoveryCoordinator shared];
    [coordinator noteController:receiver];
    [coordinator sessionStarted];
}

static void YTKACEQueuePlayerSetState(id receiver, SEL selector, long state) {
    if (OriginalQueuePlayerSetState != NULL) {
        ((void (*)(id, SEL, long))OriginalQueuePlayerSetState)(receiver, selector, state);
    }
    [[YTKACERecoveryCoordinator shared] notePlayer:receiver rawState:state];
}

static void YTKACEQueuePlayerFail(id receiver, SEL selector, id error) {
    if (OriginalQueuePlayerFail != NULL) {
        ((void (*)(id, SEL, id))OriginalQueuePlayerFail)(receiver, selector, error);
    }
    [[YTKACERecoveryCoordinator shared]
        reportFault:ytkace::WatchdogEvent::ErrorReported];
}

static void YTKACEHeartbeatResponse(id receiver, SEL selector, id response, id request) {
    if (OriginalHeartbeatResponse != NULL) {
        ((void (*)(id, SEL, id, id))OriginalHeartbeatResponse)(
            receiver, selector, response, request);
    }
    SEL stopSelector = NSSelectorFromString(@"stopHeartbeat");
    if (response == nil || ![response respondsToSelector:stopSelector]) return;
    if (!((BOOL (*)(id, SEL))objc_msgSend)(response, stopSelector)) return;
    [[YTKACERecoveryCoordinator shared]
        reportFault:ytkace::WatchdogEvent::ServerStop];
}

void YTKACEInstallPlaybackRecoveryHooks(void) {
    if (!YTKACEFeatureEnabled(YTKACERecoveryKey)) return;

    BOOL initialize = YTKACEInstallInstanceHook(
        @"YTLocalPlaybackController", @"initializePlayback",
        (IMP)YTKACEInitializePlayback, &OriginalInitializePlayback);
    BOOL state = YTKACEInstallInstanceHook(
        @"MLHAMQueuePlayer", @"setState:",
        (IMP)YTKACEQueuePlayerSetState, &OriginalQueuePlayerSetState);
    BOOL failure = YTKACEInstallInstanceHook(
        @"MLHAMQueuePlayer", @"failWithError:",
        (IMP)YTKACEQueuePlayerFail, &OriginalQueuePlayerFail);
    BOOL heartbeat = YTKACEInstallInstanceHook(
        @"YTSingleVideoHeartbeatController", @"handleResponse:forRequest:",
        (IMP)YTKACEHeartbeatResponse, &OriginalHeartbeatResponse);

    YTKACEDownloadLog(@"recovery",
                      @"hooks initialize=%d state=%d failure=%d heartbeat=%d",
                      initialize, state, failure, heartbeat);
}
