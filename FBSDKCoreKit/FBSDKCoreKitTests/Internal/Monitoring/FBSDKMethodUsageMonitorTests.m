// Copyright (c) 2014-present, Facebook, Inc. All rights reserved.
//
// You are hereby granted a non-exclusive, worldwide, royalty-free license to use,
// copy, modify, and distribute this software in source code or binary form for use
// in connection with the web services and APIs provided by Facebook.
//
// As with any software that integrates with the Facebook platform, your use of
// this software is subject to the Facebook Developer Principles and Policies
// [http://developers.facebook.com/policy/]. This copyright notice shall be
// included in all copies or substantial portions of the software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
// FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
// COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
// IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
// CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

#import <XCTest/XCTest.h>

#import <OCMock/OCMock.h>

#import "FBSDKCoreKit+Internal.h"

@interface FBSDKMethodUsageMonitorEntry (Testing)

@property (nonatomic) SEL method;
@property (nonatomic) NSDictionary<NSString *, id> * _Nullable parameters;

@end

@interface FBSDKMonitor (Testing)

@property (class, nonatomic, readonly) NSMutableArray<FBSDKMonitorEntry *> *entries;

+ (void)disable;
+ (void)flush;

@end

@interface FBSDKMethodUsageMonitorTests : XCTestCase
@end

@implementation FBSDKMethodUsageMonitorTests

- (void)setUp
{
  [super setUp];

  [FBSDKMonitor enable];
}

- (void)tearDown
{
  [super tearDown];

  [FBSDKMonitor flush];
  [FBSDKMonitor disable];
}

- (void)testRecordingMethodUsage
{
  [FBSDKMethodUsageMonitor record:@selector(viewDidLoad)];

  FBSDKMethodUsageMonitorEntry *entry = (FBSDKMethodUsageMonitorEntry *) FBSDKMonitor.entries.firstObject;

  XCTAssertEqual([entry method], @selector(viewDidLoad),
                 @"Entry should contain the captured method");
  XCTAssertNil([entry parameters],
               @"Entry should not have default parameters");
}

- (void)testRecordingMethodUsageWithParameters
{
  [FBSDKMethodUsageMonitor record:@selector(viewDidAppear:)
                       parameters:@{@"animated":@YES}];

  FBSDKMethodUsageMonitorEntry *entry = (FBSDKMethodUsageMonitorEntry *) FBSDKMonitor.entries.firstObject;

    XCTAssertEqual([entry method], @selector(viewDidAppear:),
                   @"Entry should contain the captured method");
    XCTAssertEqualObjects([entry parameters], @{@"animated":@YES},
                   @"Entry should contain the captured parameters");
}

@end