//
//  SIPManager.mm
//  Bandwidth Voice Ref App
//
//  Copyright © 2016 Bandwidth. All rights reserved.
//

#import "SIPManager.h"
#import "BWSoftphoneDelegate.h"
#import "CurrentCallHolder.h"

#include "ali_mac_str_utils.h"
#import "ali_xml_parser2_interface.h"
#include "Softphone.h"
#include "SoftphoneObserverProxy.h"

#import <UIKit/UIKit.h>
#import <AVFoundation/AVFoundation.h>
#import "Bandwidth_Voice_Ref_App-Swift.h"

// MARK: - Class methods

@interface SIPManager ()

@property(nonatomic) RegistrationState registrationState;

@end

@implementation SIPManager {
    NSString *sipAccountXmlFormat;
    ali::string license;
    ali::xml::tree _sipAccount;
    Softphone::Instance *_softphone;
    /// a C++ class which converts the callbacks into ObjectiveC selector invocations
    SoftphoneObserverProxy *_softphoneObserverProxy;
    id<CallDelegate> callDelegate;
}

+ (instancetype)sharedManager
{
    static dispatch_once_t pred = 0;
    __strong static id _sharedManager = nil;
    dispatch_once(&pred, ^{
        _sharedManager = [[self alloc] init];
    });
    return _sharedManager;
}

- (id)init {
    self = [super init];
    
    if (self) {
        sipAccountXmlFormat = @"<account id=\"sip\">"
            "<username>%@</username>"
            "<password>%@</password>"
            "<host>%@</host>"
            "</account>";

        license = "<root><saas><identifier>"
                "libsoftphone.saas.bandwith.android"
                "</identifier></saas></root>";
    }
    
    return self;
}

/**
 Register with the SIP registrar using the credentials stored in the user
 
 - parameter user: the user object containing the credentials
 */
- (void)registerWithUser:(User*)user {
    
    // If we don't have a BWAccount object, create a new registration
            
    //registrationState = RegistrationState.Registering
    
    ali::xml::tree licenseXml;
    
    int errorIndex = 0;
    NSString *sipAccountXml = [NSString stringWithFormat:sipAccountXmlFormat, user.endpoint.credentials.username, user.password, user.endpoint.credentials.realm];
    bool success = ali::xml::parse(_sipAccount, ali::mac::str::from_nsstring(sipAccountXml), &errorIndex);
    ali_assert(success);
    
    success = ali::xml::parse(licenseXml, license, &errorIndex);
    ali_assert(success);
    
    // initialize the SDK with the SaaS license
    success = Softphone::init(licenseXml);
    
    // obtain the SDK instance
    _softphone = Softphone::instance();
    
    Softphone::Preferences & preferences = _softphone->settings()->getPreferences();
    preferences.trafficLogging.set(true);
    
    _softphoneObserverProxy = new SoftphoneObserverProxy([[BWSoftphoneDelegate alloc] initWithSipManager:self]);
    _softphone->setObserver(_softphoneObserverProxy);
    
    if (_softphone->registration()->getAccount("sip") == NULL) {
    
        _softphone->registration()->saveAccount(_sipAccount);
    
        _softphone->registration()->updateAll();
    }
    
    _softphone->state()->update(_softphone->state()->Active);
}

- (void) unregister {
    _softphone->registration()->deleteAccount("sip");
    _softphone->registration()->updateAll();

}

- (void) answerIncomingCall
{
    Call::State::Type cs = _softphone->calls()->getState([CurrentCallHolder get]);

    if(cs != Call::State::IncomingRinging && cs != Call::State::IncomingIgnored)
        return;
    
    _softphone->calls()->answerIncoming([CurrentCallHolder get], Call::DesiredMedia::voiceOnly());
}

- (void) rejectIncomingCall
{
    Call::State::Type cs = _softphone->calls()->getState([CurrentCallHolder get]);
    
    if(cs != Call::State::IncomingRinging && cs != Call::State::IncomingIgnored)
        return;
    
    _softphone->calls()->rejectIncoming([CurrentCallHolder get]);
    _softphone->calls()->close([CurrentCallHolder get]);
}

- (void) hangupCall
{
    _softphone->calls()->hangup([CurrentCallHolder get]);
}

- (BOOL) makeCallTo:(NSString *) number
{
    Softphone::EventHistory::CallEvent::Pointer newCall = Softphone::EventHistory::CallEvent::create("sip",ali::generic_peer_address(ali::mac::str::from_nsstring(number)));
    
    
    Softphone::EventHistory::EventStream::Pointer stream = Softphone::EventHistory::EventStream::load(Softphone::EventHistory::StreamQuery::legacyCallHistoryStreamKey);
    
    newCall->setStream(stream);
    
    newCall->transients["dialAction"] = "voiceCall";
    
    Softphone::Instance::Events::PostResult::Type const result = _softphone->events()->post(newCall);
    
    if(result != Softphone::Instance::Events::PostResult::Success)
    {
        // report failure
    } else {
        [CurrentCallHolder acquire:newCall];
    }
    
    return result == Softphone::Instance::Events::PostResult::Success;
}

- (void) startDigit:(NSString*)digit {
    _softphone->audio()->dtmfOn([digit characterAtIndex:0]);
}

- (void) stopDigit {
    _softphone->audio()->dtmfOff();
}

- (void) setSpeakerEnabled:(BOOL)enabled {
    _softphone->audio()->setCallAudioRoute(enabled ? AudioRoute::Type::Speaker : AudioRoute::Type::Headset);
}

- (void) setMute:(BOOL)enabled {
    _softphone->audio()->setMuted(enabled);
}

- (BWCall*) getCurrentCall {
    return [SIPManager callEventToBWCall:[CurrentCallHolder get]->asCall() withLastState:[CurrentCallHolder getLastState]];
}

- (void)onRegistrationStateChanged:(RegistrationState) state
                        forAccount:(NSString*)accountId;
{
    NSLog(@"INFO: onRegistrationStateChanged: %@", [SIPManager regStateToString:state]);
    
    self.registrationState = state;
}

- (void)onIncomingCall
{
    NSLog(@"INFO: onIncomingCall from:%s", [CurrentCallHolder get]->getRemoteUser().getGenericUri().c_str());
    
    dispatch_async(dispatch_get_main_queue(),  ^{
        
        // Make sure we are sending the notification in the main thread
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"SIPManager.CallReceivedNotification"
                                                            object:nil];
    });
}

- (void)onCallStateChanged:(CallState) state
{
    NSLog(@"INFO: onCallStateChanged %@", [BWCall callStateToString:state]);
    
    if (callDelegate != NULL) {
        [callDelegate onCallStateChanged:[self getCurrentCall]];
    }
    
    if (Call::State::isTerminal([CurrentCallHolder getLastState])) {
        _softphone->calls()->close([CurrentCallHolder get]);
    }
}

+ (NSString*)regStateToString:(RegistrationState) state
{
    NSString *regStateStr;
    
    switch (state) {
        
        case NotRegistered:
            regStateStr = @"Not registered";
            break;
        case Registering:
            regStateStr = @"Registering";
            break;
        case Registered:
            regStateStr = @"Registered";
            break;
    }
    
    return regStateStr;
}

- (void)setCallDelegate:(id<CallDelegate>)delegate {
    callDelegate = delegate;
}

+(BWCall*) callEventToBWCall:(Softphone::EventHistory::CallEvent&) callEvent
               withLastState:(Call::State::Type) lastState {
    BWCall *bwCall = [[BWCall alloc] init];
    bwCall.isIncoming = (callEvent.getDirection() == Softphone::EventHistory::Direction::Type::Incoming);
    bwCall.remoteUri = ali::mac::str::to_nsstring(callEvent.getRemoteUser().getTransportUri().get());
    bwCall.lastState = [BWSoftphoneDelegate acrobbitsCallStateToBWCallState:lastState];
    
    return bwCall;
}

@end