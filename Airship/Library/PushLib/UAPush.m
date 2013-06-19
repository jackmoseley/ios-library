/*
 Copyright 2009-2012 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binaryform must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided withthe distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC``AS IS'' AND ANY EXPRESS OR
 IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
 MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO
 EVENT SHALL URBAN AIRSHIP INC OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT,
 INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING,
 BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
 DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF
 LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE
 OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
 ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
 */

#import <UIKit/UIKit.h>

#import "UAPush.h"
#import "UAPush+Internal.h"

#import "UAirship.h"
#import "UAViewUtils.h"
#import "UAAnalytics.h"
#import "UAEvent.h"
#import "UADeviceRegistrationData.h"
#import "UADeviceRegistrationPayload.h"
#import "UAPushNotificationHandler.h"
#import "UAUtils.h"

#import "UA_SBJsonWriter.h"

UAPushSettingsKey *const UAPushEnabledSettingsKey = @"UAPushEnabled";
UAPushSettingsKey *const UAPushAliasSettingsKey = @"UAPushAlias";
UAPushSettingsKey *const UAPushTagsSettingsKey = @"UAPushTags";
UAPushSettingsKey *const UAPushBadgeSettingsKey = @"UAPushBadge";
UAPushSettingsKey *const UAPushQuietTimeSettingsKey = @"UAPushQuietTime";
UAPushSettingsKey *const UAPushQuietTimeEnabledSettingsKey = @"UAPushQuietTimeEnabled";
UAPushSettingsKey *const UAPushTimeZoneSettingsKey = @"UAPushTimeZone";
UAPushSettingsKey *const UAPushDeviceTokenDeprecatedSettingsKey = @"UAPushDeviceToken";
UAPushSettingsKey *const UAPushDeviceCanEditTagsKey = @"UAPushDeviceCanEditTags";
UAPushSettingsKey *const UAPushNeedsUnregistering = @"UAPushNeedsUnregistering";

UAPushUserInfoKey *const UAPushUserInfoRegistration = @"Registration";
UAPushUserInfoKey *const UAPushUserInfoPushEnabled = @"PushEnabled";

NSString *const UAPushQuietTimeStartKey = @"start";
NSString *const UAPushQuietTimeEndKey = @"end";

@implementation UAPush 
//Internal
@synthesize defaultPushHandler;
@synthesize hasEnteredBackground;

//Public
@synthesize delegate;
@synthesize notificationTypes;
@synthesize autobadgeEnabled = autobadgeEnabled_;

// Public - UserDefaults
@dynamic pushEnabled;
@synthesize deviceToken;
@synthesize deviceTokenHasChanged;
@dynamic alias;
@dynamic tags;
@dynamic quietTime;
@dynamic timeZone;
@dynamic quietTimeEnabled;
@synthesize retryOnConnectionError;


SINGLETON_IMPLEMENTATION(UAPush)

static Class _uiClass;

// Self refers to the class at this point in execution
// The self == check is because that a sublcass that does not implement this method
// forwards it up the chain. It will only be called once by this class
+ (void)initialize {
    if (self == [UAPush class]) {
        [self registerNSUserDefaults];
    }
}

-(void)dealloc {
    RELEASE_SAFELY(defaultPushHandler);
    self.deviceAPIClient = nil;
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [super dealloc];
}

- (id)init {
    self = [super init];
    if (self) {
        //init with default delegate implementation
        // released when replaced
        defaultPushHandler = [[NSClassFromString(PUSH_DELEGATE_CLASS) alloc] init];
        delegate = defaultPushHandler;
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                                 selector:@selector(applicationDidBecomeActive) 
                                                     name:UIApplicationDidBecomeActiveNotification 
                                                   object:[UIApplication sharedApplication]];
        // Only for observing the first call to app background
        [[NSNotificationCenter defaultCenter] addObserver:self 
                                              selector:@selector(applicationDidEnterBackground) 
                                                  name:UIApplicationDidEnterBackgroundNotification 
                                                object:[UIApplication sharedApplication]];
        
        self.deviceAPIClient = [[[UADeviceAPIClient alloc] init] autorelease];
    }
    return self;
}

#pragma mark -
#pragma mark Device Token Get/Set Methods

- (NSString*)parseDeviceToken:(NSString*)tokenStr {
    return [[[tokenStr stringByReplacingOccurrencesOfString:@"<" withString:@""]
             stringByReplacingOccurrencesOfString:@">" withString:@""]
            stringByReplacingOccurrencesOfString:@" " withString:@""];
}

#pragma mark -
#pragma mark Get/Set Methods

- (BOOL)autobadgeEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UAPushBadgeSettingsKey];
}

- (void)setAutobadgeEnabled:(BOOL)autobadgeEnabled {
    [[NSUserDefaults standardUserDefaults] setBool:autobadgeEnabled forKey:UAPushBadgeSettingsKey];
}


- (NSString *)alias {
    return [[NSUserDefaults standardUserDefaults] stringForKey:UAPushAliasSettingsKey];
}

- (void)setAlias:(NSString *)alias {
    [[NSUserDefaults standardUserDefaults] setObject:alias forKey:UAPushAliasSettingsKey];
}

- (BOOL)canEditTagsFromDevice {
   return [[NSUserDefaults standardUserDefaults] boolForKey:UAPushDeviceCanEditTagsKey];
}

- (void)setCanEditTagsFromDevice:(BOOL)canEditTagsFromDevice {
    [[NSUserDefaults standardUserDefaults] setBool:canEditTagsFromDevice forKey:UAPushDeviceCanEditTagsKey];
}

- (NSArray *)tags {
    NSArray *currentTags = [[NSUserDefaults standardUserDefaults] objectForKey:UAPushTagsSettingsKey];
    if (!currentTags) {
        currentTags = [NSArray array];
    }
    return currentTags;
}

- (void)setTags:(NSArray *)tags {
    [[NSUserDefaults standardUserDefaults] setObject:tags forKey:UAPushTagsSettingsKey];
}

- (void)addTagsToCurrentDevice:(NSArray *)tags {
    NSMutableSet *updatedTags = [NSMutableSet setWithArray:[self tags]];
    [updatedTags addObjectsFromArray:tags];
    [self setTags:[updatedTags allObjects]];
}

- (BOOL)pushEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UAPushEnabledSettingsKey];
}

- (void)setPushEnabled:(BOOL)enabled {
    //if the value has actually changed
    if (enabled != self.pushEnabled) {
        [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:UAPushEnabledSettingsKey];
        // Set the flag to indicate that an unRegistration (DELETE)call is needed. This
        // flag is checked on updateRegistration calls, and is used to prevent
        // API calls on every app init when the device is already unregistered.
        // It is cleared on successful unregistration

        if (enabled) {
            UA_LDEBUG(@"registering for remote notifcations");
            [[UIApplication sharedApplication] registerForRemoteNotificationTypes:notificationTypes];
        } else {
            [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UAPushNeedsUnregistering];
            //note: we don't want to use the wrapper method here, because otherwise it will blow away the existing notificationTypes
            [[UIApplication sharedApplication] registerForRemoteNotificationTypes:UIRemoteNotificationTypeNone];
            [self updateRegistration];
        }
    }
}

- (NSDictionary *)quietTime {
    return [[NSUserDefaults standardUserDefaults] dictionaryForKey:UAPushQuietTimeSettingsKey];
}

- (void)setQuietTime:(NSMutableDictionary *)quietTime {
    [[NSUserDefaults standardUserDefaults] setObject:quietTime forKey:UAPushQuietTimeSettingsKey];
}

- (BOOL)quietTimeEnabled {
    return [[NSUserDefaults standardUserDefaults] boolForKey:UAPushQuietTimeEnabledSettingsKey];
}

- (void)setQuietTimeEnabled:(BOOL)quietTimeEnabled {
    [[NSUserDefaults standardUserDefaults] setBool:quietTimeEnabled forKey:UAPushQuietTimeEnabledSettingsKey];
}

- (NSString *)tz {
    return [[self timeZone] name];
}

- (void)setTz:(NSString *)tz {
    NSTimeZone* timeZone = [NSTimeZone timeZoneWithName:tz];
    self.timeZone = timeZone;
}

- (NSTimeZone *)timeZone {
    NSString* timeZoneName = [[NSUserDefaults standardUserDefaults] stringForKey:UAPushTimeZoneSettingsKey];
    return [NSTimeZone timeZoneWithName:timeZoneName];
}

- (void)setTimeZone:(NSTimeZone *)timeZone {
    [[NSUserDefaults standardUserDefaults] setObject:[timeZone name] forKey:UAPushTimeZoneSettingsKey];
}

- (NSTimeZone *)defaultTimeZoneForQuietTime {
    return [NSTimeZone localTimeZone];
}


#pragma mark -
#pragma mark Private methods

- (Class)uiClass {
    if (!_uiClass) {
        _uiClass = NSClassFromString(PUSH_UI_CLASS);
    }
    
    if (!_uiClass) {
        UA_LDEBUG(@"Push UI class not found.");
    }
    
    return _uiClass;
}

- (NSString *)getTagFromUrl:(NSURL *)url {
    return [[url.relativePath componentsSeparatedByString:@"/"] lastObject];
}

#pragma mark -
#pragma mark APNS wrapper
- (void)registerForRemoteNotificationTypes:(UIRemoteNotificationType)types {
    self.notificationTypes = types;
    
    if (self.pushEnabled) {
        [[UIApplication sharedApplication] registerForRemoteNotificationTypes:notificationTypes];
    }
}

#pragma mark -
#pragma mark UA Device API Payload

- (UADeviceRegistrationPayload *)registrationPayload {
    
    NSString *alias =  self.alias;
    NSArray *tags = nil;
    
    if (self.canEditTagsFromDevice) {
        tags = [self tags];
        // If there are no tags, and tags are editable, send an 
        // empty array
        if (!tags) {
            tags = [NSArray array];
        }
    }
    
    NSString* tz = nil;
    NSDictionary *quietTime = nil;
    if (self.timeZone.name != nil && self.quietTimeEnabled) {
        tz = self.timeZone.name;
        quietTime = self.quietTime;
    }

    NSNumber *badge = nil;
    
    if ([self autobadgeEnabled]) {
        badge = [NSNumber numberWithInteger:[[UIApplication sharedApplication] applicationIconBadgeNumber]];
    }

    UADeviceRegistrationPayload *payload = [UADeviceRegistrationPayload payloadWithAlias:alias
                                                                                withTags:tags
                                                                            withTimeZone:tz
                                                                           withQuietTime:quietTime
                                                                               withBadge:badge];
    return payload;
}

#pragma mark -
#pragma Registration Data Model

- (UADeviceRegistrationData *)registrationData {
    return [UADeviceRegistrationData dataWithDeviceToken:self.deviceToken
                                             withPayload:[self registrationPayload]
                                             pushEnabled:self.pushEnabled];
}


#pragma mark -
#pragma mark Open APIs - Property Setters

- (void)updateAlias:(NSString *)value {
    self.alias = value;
    [self updateRegistration];
}

- (void)updateTags:(NSMutableArray *)value {
    self.tags = value;
    [self updateRegistration];
}

- (void)setQuietTimeFrom:(NSDate *)from to:(NSDate *)to withTimeZone:(NSTimeZone *)timezone {
    if (!from || !to) {
        UA_LDEBUG(@"Set Quiet Time - parameter is nil. from: %@ to: %@", from, to);
        return;
    }
    if(!timezone){
        timezone = [self defaultTimeZoneForQuietTime];
    }
    NSCalendar *cal = [[[NSCalendar alloc] initWithCalendarIdentifier:NSGregorianCalendar] autorelease];
    NSString *fromStr = [NSString stringWithFormat:@"%d:%02d",
                         [cal components:NSHourCalendarUnit fromDate:from].hour,
                         [cal components:NSMinuteCalendarUnit fromDate:from].minute];
    
    NSString *toStr = [NSString stringWithFormat:@"%d:%02d",
                       [cal components:NSHourCalendarUnit fromDate:to].hour,
                       [cal components:NSMinuteCalendarUnit fromDate:to].minute];
    
    self.quietTime = [NSMutableDictionary dictionaryWithObjectsAndKeys:
                      fromStr, UAPushQuietTimeStartKey,
                      toStr, UAPushQuietTimeEndKey, nil];
    
    self.timeZone = timezone;
}

- (void)disableQuietTime {
    self.quietTimeEnabled = NO;
    [self updateRegistration];
}

#pragma mark -
#pragma mark Open APIs

+ (void)land {
    
    // not much teardown to do here, but implement anyway for the future
    if (g_sharedUAPush) {
        RELEASE_SAFELY(g_sharedUAPush);
    }
}

#pragma mark -
#pragma mark Open APIs - Custom UI

+ (void)useCustomUI:(Class)customUIClass {
    _uiClass = customUIClass;
}

#pragma mark -
#pragma mark Open APIs - UI Display

+ (void)openApnsSettings:(UIViewController *)viewController
                animated:(BOOL)animated {
    [[[UAPush shared] uiClass] openApnsSettings:viewController animated:animated];
}

+ (void)openTokenSettings:(UIViewController *)viewController
                 animated:(BOOL)animated {
    [[[UAPush shared] uiClass] openTokenSettings:viewController animated:animated];
}

+ (void)closeApnsSettingsAnimated:(BOOL)animated {
    [[[UAPush shared] uiClass] closeApnsSettingsAnimated:animated];
}

+ (void)closeTokenSettingsAnimated:(BOOL)animated {
    [[[UAPush shared] uiClass] closeTokenSettingsAnimated:animated];
}

#pragma mark -
#pragma mark Open APIs - UA Registration Tags APIs

- (void)addTagToCurrentDevice:(NSString *)tag {
    [self addTagsToCurrentDevice:[NSArray arrayWithObject:tag]];
}

- (void)removeTagFromCurrentDevice:(NSString *)tag {
    [self removeTagsFromCurrentDevice:[NSArray arrayWithObject:tag]];
}

- (void)removeTagsFromCurrentDevice:(NSArray *)tags {
    NSMutableArray *mutableTags = [NSMutableArray arrayWithArray:[[NSUserDefaults standardUserDefaults] objectForKey:UAPushTagsSettingsKey]];
    [mutableTags removeObjectsInArray:tags];
    [[NSUserDefaults standardUserDefaults] setObject:mutableTags forKey:UAPushTagsSettingsKey];
}

- (void)enableAutobadge:(BOOL)autobadge {
    self.autobadgeEnabled = autobadge;
}

- (void)setBadgeNumber:(NSInteger)badgeNumber {

    if ([[UIApplication sharedApplication] applicationIconBadgeNumber] == badgeNumber) {
        return;
    }

    UA_LDEBUG(@"Change Badge from %d to %d", [[UIApplication sharedApplication] applicationIconBadgeNumber], badgeNumber);

    [[UIApplication sharedApplication] setApplicationIconBadgeNumber:badgeNumber];

    // if the device token has already been set then
    // we are post-registration and will need to make
    // and update call
    if (self.autobadgeEnabled && self.deviceToken) {
        UA_LDEBUG(@"Sending autobadge update to UA server");
        [self updateRegistrationForcefully:YES  ];
    }
}

- (void)resetBadge {
    [self setBadgeNumber:0];
}

- (void)handleNotification:(NSDictionary *)notification applicationState:(UIApplicationState)state {
    
    [[UAirship shared].analytics handleNotification:notification inApplicationState:state];

    if (state != UIApplicationStateActive) {
        UA_LTRACE(@"Received a notification for an inactive application state.");
        
        if ([delegate respondsToSelector:@selector(launchedFromNotification:)])
            [delegate launchedFromNotification:notification];
        return;
    }

    UA_LTRACE(@"Received a notification for a foregrounded application.");
    
    // Please refer to the following Apple documentation for full details on handling the userInfo payloads
	// http://developer.apple.com/library/ios/#documentation/NetworkingInternet/Conceptual/RemoteNotificationsPG/ApplePushService/ApplePushService.html#//apple_ref/doc/uid/TP40008194-CH100-SW1
	
	if ([[notification allKeys] containsObject:@"aps"]) { 
		
        NSDictionary *apsDict = [notification objectForKey:@"aps"];
        
		if ([[apsDict allKeys] containsObject:@"alert"]) {

			if ([[apsDict objectForKey:@"alert"] isKindOfClass:[NSString class]] &&
                [delegate respondsToSelector:@selector(displayNotificationAlert:)]) {
                
				// The alert is a single string message so we can display it
                [delegate displayNotificationAlert:[apsDict valueForKey:@"alert"]];

			} else if ([delegate respondsToSelector:@selector(displayLocalizedNotificationAlert:)]) {
				// The alert is a a dictionary with more localization details
				// This should be customized to fit your message details or usage scenario 
                [delegate displayLocalizedNotificationAlert:[apsDict valueForKey:@"alert"]];
			}

		}

        //badge
        NSString *badgeNumber = [apsDict valueForKey:@"badge"];
        if (badgeNumber) {
            
			if (self.autobadgeEnabled) {
				[[UIApplication sharedApplication] setApplicationIconBadgeNumber:[badgeNumber intValue]];
			} else if ([delegate respondsToSelector:@selector(handleBadgeUpdate:)]) {
				[delegate handleBadgeUpdate:[badgeNumber intValue]];
			}
        }
		
        //sound
		NSString *soundName = [apsDict valueForKey:@"sound"];
		if (soundName && [delegate respondsToSelector:@selector(playNotificationSound:)]) {
			[delegate playNotificationSound:[apsDict objectForKey:@"sound"]];
		}
        
	}//aps

	// 
	if([delegate respondsToSelector:@selector(receivedForegroundNotification:)]) {
		[delegate receivedForegroundNotification:notification];
    }
    
}

+ (NSString *)pushTypeString:(UIRemoteNotificationType)types {
    
    //TODO: Localize
    
    //UIRemoteNotificationType types = [[UIApplication sharedApplication] enabledRemoteNotificationTypes];
    
    NSMutableArray *typeArray = [NSMutableArray arrayWithCapacity:3];

    //Use the same order as the Settings->Notifications panel
    if (types & UIRemoteNotificationTypeBadge) {
        [typeArray addObject:@"Badges"];
    }
    
    if (types & UIRemoteNotificationTypeAlert) {
        [typeArray addObject:@"Alerts"];
    }
    
    if (types & UIRemoteNotificationTypeSound) {
        [typeArray addObject:@"Sounds"];
    }
    
    if ([typeArray count] > 0) {
        return [typeArray componentsJoinedByString:@", "];
    }
    
    return @"None";
}

#pragma mark -
#pragma mark UIApplication State Observation

- (void)applicationDidBecomeActive {
    UA_LDEBUG(@"Checking registration status after foreground notification");
    if (hasEnteredBackground) {
        [self updateRegistration];
    }
    else {
        UA_LDEBUG(@"Checking registration on app foreground disabled on app initialization");
    }
}

- (void)applicationDidEnterBackground {
    hasEnteredBackground = YES;
    [[NSNotificationCenter defaultCenter] removeObserver:self 
                                                    name:UIApplicationDidEnterBackgroundNotification 
                                                  object:[UIApplication sharedApplication]];
}

#pragma mark -
#pragma mark UA Registration Methods

/* 
 * Checks the current application state, bails if in the background with the
 * assumption that next app init or isActive notif will call update.
 * Dispatches a registration request to the server if necessary via
 * the Device API client. PushEnabled -> register, !PushEnabled -> unregister.
 */
- (void)updateRegistrationForcefully:(BOOL)forcefully {
        
    // if the application is backgrounded, do not send a registration
    if ([UIApplication sharedApplication].applicationState == UIApplicationStateBackground) {
        UA_LDEBUG(@"Skipping DT registration. The app is currently backgrounded.");
        return;
    }
    
    [[NSUserDefaults standardUserDefaults] synchronize];
    
    if (self.pushEnabled) {
        // If there is no device token, wait for the application delegate to update with one.
        if (!self.deviceToken) {
            UA_LDEBUG(@"Device token is nil. Registration will be attempted at a later time");
            return;
        }

        [self.deviceAPIClient
         registerWithData:[self registrationData]
         onSuccess:^{
             UA_LDEBUG(@"Device token registered on Urban Airship successfully.");
             [self notifyObservers:@selector(registerDeviceTokenSucceeded)];
         }
         onFailure:^(UAHTTPRequest *request) {
             [self notifyObservers:@selector(registerDeviceTokenFailed:)
                        withObject:request];
         }
         forcefully:forcefully];
    }
    else {
        // If there is no device token, and push has been enabled then disabled, which occurs in certain circumstances,
        // most notably when a developer registers for UIRemoteNotificationTypeNone and this is the first install of an app
        // that uses push, the DELETE will fail with a 404.
        if (!self.deviceToken) {
            UA_LDEBUG(@"Device token is nil, unregistering with Urban Airship not possible. It is likely the app is already unregistered");
            return;
        }
        // Don't unregister more than once
        if ([[NSUserDefaults standardUserDefaults] boolForKey:UAPushNeedsUnregistering]) {

            [self.deviceAPIClient
             unregisterWithData:[self registrationData]
             onSuccess:^{
                 // note that unregistration is no longer needed
                 [[NSUserDefaults standardUserDefaults] setBool:NO forKey:UAPushNeedsUnregistering];
                 UA_LDEBUG(@"Device token unregistered on Urban Airship successfully.");
                 [self notifyObservers:@selector(unRegisterDeviceTokenSucceeded)];
             }
             onFailure:^(UAHTTPRequest *request) {
                 [UAUtils logFailedRequest:request withMessage:@"unregistering device token"];
                 [self notifyObservers:@selector(unRegisterDeviceTokenFailed:)
                            withObject:request];
             }
             forcefully:forcefully];
        }
        else {
            UA_LDEBUG(@"Device has already been unregistered, no update scheduled");
        }
    }
}

- (void)updateRegistration {
    [self updateRegistrationForcefully:NO];
}

//The new token to register, or nil if updating the existing token 
- (void)registerDeviceToken:(NSData *)token {
    if (!notificationTypes) {
        UA_LDEBUG(@"***ERROR***: attempted to register device token with no notificationTypes set!  \
              Please use [[UAPush shared] registerForRemoteNotificationTypes:] instead of the equivalent method on UIApplication");
        return;
    }
    self.deviceToken = [self parseDeviceToken:[token description]];
    UAEventDeviceRegistration *regEvent = [UAEventDeviceRegistration eventWithContext:nil];
    [[UAirship shared].analytics addEvent:regEvent];
    [self updateRegistration];
}

#pragma mark -
#pragma mark Default Values

// Change the default push enabled value in the registered user defaults
+ (void)setDefaultPushEnabledValue:(BOOL)enabled {
    NSMutableDictionary *dictionary = [NSMutableDictionary dictionaryWithObject:[NSNumber numberWithBool:enabled] forKey:UAPushEnabledSettingsKey];
    [[NSUserDefaults standardUserDefaults] registerDefaults:dictionary];
}

#pragma mark -
#pragma mark NSUserDefaults

+ (void)registerNSUserDefaults {
    // Migration for pre 1.3.0 library quiet time settings
    // This pulls an object, instead of a BOOL
    id quietTimeEnabled = [[NSUserDefaults standardUserDefaults] valueForKey:UAPushQuietTimeEnabledSettingsKey];
    NSDictionary* currentQuietTime = [[NSUserDefaults standardUserDefaults] valueForKey:UAPushQuietTimeSettingsKey];
    if (!quietTimeEnabled && currentQuietTime) {
        [[NSUserDefaults standardUserDefaults] setBool:YES forKey:UAPushQuietTimeEnabledSettingsKey];
    }
    NSMutableDictionary *defaults = [NSMutableDictionary dictionaryWithCapacity:2];
    [defaults setValue:[NSNumber numberWithBool:YES] forKey:UAPushEnabledSettingsKey];
    [defaults setValue:[NSNumber numberWithBool:YES] forKey:UAPushDeviceCanEditTagsKey];
    [[NSUserDefaults standardUserDefaults] registerDefaults:defaults];
}


@end
