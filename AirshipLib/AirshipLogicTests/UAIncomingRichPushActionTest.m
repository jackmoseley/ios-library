/*
 Copyright 2009-2015 Urban Airship Inc. All rights reserved.

 Redistribution and use in source and binary forms, with or without
 modification, are permitted provided that the following conditions are met:

 1. Redistributions of source code must retain the above copyright notice, this
 list of conditions and the following disclaimer.

 2. Redistributions in binary form must reproduce the above copyright notice,
 this list of conditions and the following disclaimer in the documentation
 and/or other materials provided with the distribution.

 THIS SOFTWARE IS PROVIDED BY THE URBAN AIRSHIP INC ``AS IS'' AND ANY EXPRESS OR
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

#import <XCTest/XCTest.h>
#import <OCMock/OCMock.h>
#import "UAIncomingRichPushAction.h"
#import "UAActionArguments.h"
#import "UAInbox.h"
#import "UAInboxPushHandler.h"
#import "UAInboxMessageList.h"
#import "UAActionArguments+Internal.h"
#import "UAirship.h"

@interface UAIncomingRichPushActionTest : XCTestCase

@property (nonatomic, strong) UAIncomingRichPushAction *action;
@property (nonatomic, strong) UAActionArguments *arguments;
@property (nonatomic, strong) NSMutableDictionary *notification;
@property (nonatomic, strong) id mockInbox;
@property (nonatomic, strong) id mockPushHandler;
@property (nonatomic, strong) id mockPushHandlerDelegate;
@property (nonatomic, strong) id mockMessageList;
@property (nonatomic, strong) id mockAirship;
@end

@implementation UAIncomingRichPushActionTest

- (void)setUp {
    [super setUp];

    self.action = [[UAIncomingRichPushAction alloc] init];
    self.arguments = [[UAActionArguments alloc] init];
    self.arguments.value = @"rich-push-ID";
    
    self.notification = [NSMutableDictionary dictionaryWithDictionary:@{@"aps": @{}, @"_uamid":@"rich-push-ID"}];
    
    self.arguments = [UAActionArguments argumentsWithValue:@"rich-push-ID"
                                             withSituation:UASituationForegroundPush
                                               metadata:@{UAActionMetadataPushPayloadKey: self.notification}];

    self.mockPushHandler = [OCMockObject niceMockForClass:[UAInboxPushHandler class]];
    self.mockPushHandlerDelegate = [OCMockObject niceMockForProtocol:@protocol(UAInboxPushHandlerDelegate)];
    self.mockMessageList = [OCMockObject niceMockForClass:[UAInboxMessageList class]];
    self.mockInbox = [OCMockObject mockForClass:[UAInbox class]];
    self.mockAirship = [OCMockObject mockForClass:[UAirship class]];

    [[[self.mockAirship stub] andReturn:self.mockAirship] shared];
    [[[self.mockAirship stub] andReturn:self.mockInbox] inbox];

    [[[self.mockInbox stub] andReturn:self.mockMessageList] messageList];
    [[[self.mockInbox stub] andReturn:self.mockPushHandler] pushHandler];

    [[[self.mockPushHandler stub] andReturn:self.mockPushHandlerDelegate] delegate];
}

- (void)tearDown {
    [self.mockAirship stopMocking];
    [self.mockInbox stopMocking];
    [self.mockPushHandler stopMocking];
    [self.mockMessageList stopMocking];
    [self.mockPushHandlerDelegate stopMocking];

    [super tearDown];
}

/**
 * Test accepts argument in situation UASituationForegroundPush.
 */
- (void)testAcceptArgumentsUASituationForegroundPush {
    self.arguments.situation = UASituationForegroundPush;
    XCTAssertTrue([self.action acceptsArguments:self.arguments], @"action should accept valid arguments in UASituationForegroundPush situation");

    self.arguments.value = @[@"RAP-ID"];
    XCTAssertTrue([self.action acceptsArguments:self.arguments], @"action should accept an array that contains a RAP ID");

    self.arguments.value = nil;
    XCTAssertFalse([self.action acceptsArguments:self.arguments], @"action should reject arguments without a RAP ID");

    self.arguments.value = @"RAP-ID";
    self.arguments.metadata = nil;
    XCTAssertFalse([self.action acceptsArguments:self.arguments], @"action should reject arguments without push notification metadata");
}

/**
 * Test accepts argument in situation UASituationLaunchedFromPush.
 */
- (void)testAcceptArgumentsUASituationLaunchedFromPush {
    self.arguments.situation = UASituationLaunchedFromPush;
    XCTAssertTrue([self.action acceptsArguments:self.arguments], @"action should accept valid arguments in UASituationLaunchedFromPush situation");

    self.arguments.value = @[@"RAP-ID"];
    XCTAssertTrue([self.action acceptsArguments:self.arguments], @"action should accept an array that contains a RAP ID");

    self.arguments.value = nil;
    XCTAssertFalse([self.action acceptsArguments:self.arguments], @"action should reject arguments without a RAP ID");

    self.arguments.value = @"RAP-ID";
    self.arguments.metadata = nil;
    XCTAssertFalse([self.action acceptsArguments:self.arguments], @"action should reject arguments without push notification metadata");
}

/**
 * Test perform in UASituationForegroundPush situation
 */
- (void)testPerformInUASituationForegroundPush {
    self.arguments.situation = UASituationForegroundPush;
    __block UAActionResult *actionResult = nil;

    // Should retrieve new message list
    [[self.mockMessageList expect] retrieveMessageListWithSuccessBlock:[OCMArg checkWithBlock:^BOOL(id obj) {
        UAInboxMessageListCallbackBlock block = obj;
        block();
        return YES;
    }] withFailureBlock:OCMOCK_ANY];

    // Should notify the RAP notification arrived
    [[self.mockPushHandlerDelegate expect] richPushNotificationArrived:[self.arguments.metadata objectForKey:UAActionMetadataPushPayloadKey]];

    [self.action performWithArguments:self.arguments completionHandler:^(UAActionResult *result) {
        actionResult = result;
    }];

    XCTAssertNotNil(actionResult, @"perform did not call the completion handler");
    XCTAssertEqualObjects(actionResult.value, @"rich-push-ID", @"Results value should be the RAP ID");
    XCTAssertNoThrow([self.mockMessageList verify], @"message list should retrieve new RAPs");
    XCTAssertNoThrow([self.mockPushHandlerDelegate verify], @"handler delegate should be notified of a RAP notification");
}

/**
 * Test perform in UASituationLaunchedFromPush situation
 */
- (void)testPerformInUASituationLaunchedFromPush {
    self.arguments.situation = UASituationLaunchedFromPush;
    __block UAActionResult *actionResult = nil;

    // Should retrieve new message list
    [[self.mockMessageList expect] retrieveMessageListWithSuccessBlock:[OCMArg checkWithBlock:^BOOL(id obj) {
        UAInboxMessageListCallbackBlock block = obj;
        block();
        return YES;
    }] withFailureBlock:OCMOCK_ANY];


    // Should notify the delegate that it was launched with a RAP notification
    [[self.mockPushHandlerDelegate expect] applicationLaunchedWithRichPushNotification:[self.arguments.metadata objectForKey:UAActionMetadataPushPayloadKey]];

    // Should tell the handler there is a launch message
    [[self.mockPushHandler expect] setHasLaunchMessage:YES];

    [self.action performWithArguments:self.arguments completionHandler:^(UAActionResult *result) {
        actionResult = result;
    }];

    XCTAssertNotNil(actionResult, @"perform did not call the completion handler");
    XCTAssertEqualObjects(actionResult.value, @"rich-push-ID", @"Results value should be the RAP ID");
    XCTAssertNoThrow([self.mockMessageList verify], @"message list should retrieve new RAPs");
    XCTAssertNoThrow([self.mockPushHandlerDelegate verify], @"handler delegate should be notified of a RAP notification");
    XCTAssertNoThrow([self.mockPushHandler verify], @"handler should set hasLaunchMessage");
}

/**
 * Test when the message list fails to refresh it returns UIBackgroundFetchResultFailed.
 */
- (void)testMessageListFailedToRefresh {
    self.arguments.situation = UASituationLaunchedFromPush;
    __block UAActionResult *actionResult = nil;

    // Should retrieve new message list, call failure block
    [[self.mockMessageList expect] retrieveMessageListWithSuccessBlock:OCMOCK_ANY withFailureBlock:[OCMArg checkWithBlock:^BOOL(id obj) {
        UAInboxMessageListCallbackBlock block = obj;
        block();
        return YES;
    }] ];


    // Should notify the delegate that it was launched with a RAP notification
    [[self.mockPushHandlerDelegate expect] applicationLaunchedWithRichPushNotification:[self.arguments.metadata objectForKey:UAActionMetadataPushPayloadKey]];

    // Should tell the handler there is a launch message
    [[self.mockPushHandler expect] setHasLaunchMessage:YES];

    [self.action performWithArguments:self.arguments completionHandler:^(UAActionResult *result) {
        actionResult = result;
    }];

    XCTAssertNotNil(actionResult, @"perform did not call the completion handler");
    XCTAssertEqualObjects(actionResult.value, @"rich-push-ID", @"Results value should be the RAP ID");
    XCTAssertEqual(actionResult.fetchResult, UIBackgroundFetchResultFailed, @"Fetch result should be UIBackgroundFetchResultFailed");

    XCTAssertNoThrow([self.mockMessageList verify], @"message list should retrieve new RAPs");
    XCTAssertNoThrow([self.mockPushHandlerDelegate verify], @"handler delegate should be notified of a RAP notification");
    XCTAssertNoThrow([self.mockPushHandler verify], @"handler should set hasLaunchMessage");
}


@end
