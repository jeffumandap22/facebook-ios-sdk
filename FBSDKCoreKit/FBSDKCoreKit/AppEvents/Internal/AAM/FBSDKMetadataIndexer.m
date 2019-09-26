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

#import "FBSDKMetadataIndexer.h"

#import <objc/runtime.h>
#import <sys/sysctl.h>
#import <sys/utsname.h>

#import <UIKit/UIKit.h>

#import <FBSDKCoreKit/FBSDKCoreKit+Internal.h>

static const int FBSDKMetadataIndexerMaxTextLength              = 100;
static const int FBSDKMetadataIndexerMaxIndicatorLength         = 100;
static const int FBSDKMetadataIndexerMaxValue                   = 5;

static NSString * const FIELD_K                                 = @"k";
static NSString * const FIELD_V                                 = @"v";
static NSString * const FIELD_K_DELIMITER                       = @",";

FBSDKAppEventUserDataType FBSDKAppEventRule1                    = @"r1";
FBSDKAppEventUserDataType FBSDKAppEventRule2                    = @"r2";

static NSMutableDictionary<NSString *, NSDictionary<NSString *, NSString *> *> *FBSDKMetadataIndexerRules;
static NSMutableDictionary<NSString *, NSMutableArray<NSString *> *> *FBSDKMetadataIndexerStore;
static dispatch_queue_t serialQueue;

@implementation FBSDKMetadataIndexer

+ (void)initialize
{
    serialQueue = dispatch_queue_create("com.facebook.appevents.MetadataIndexer", DISPATCH_QUEUE_SERIAL);
}

+ (void)load
{
    [self initStore];
    [self loadAndSetup];
}

+ (void)initStore
{
    FBSDKMetadataIndexerStore = [[NSMutableDictionary alloc] init];
    NSString *userData = [[NSUserDefaults standardUserDefaults] stringForKey:@"com.facebook.appevents.UserDataStore.userData"];
    if (userData) {
        NSMutableDictionary<NSString *, NSString *> * hashedUserData = (NSMutableDictionary<NSString *, NSString *> *)[NSJSONSerialization JSONObjectWithData:[userData dataUsingEncoding:NSUTF8StringEncoding]
                                                                                                                                                      options:NSJSONReadingMutableContainers
                                                                                                                                                        error:nil];
        for (NSString *key in FBSDKMetadataIndexerRules) {
            if (hashedUserData[key].length > 0) {
                FBSDKMetadataIndexerStore[key] = [NSMutableArray arrayWithArray:[hashedUserData[key] componentsSeparatedByString:FIELD_K_DELIMITER]];
            }
        }
    }

    for (NSString *key in FBSDKMetadataIndexerRules) {
        if (!FBSDKMetadataIndexerStore[key]) {
            FBSDKMetadataIndexerStore[key] = [[NSMutableArray alloc] init];
        }
    }
}

+ (void)loadAndSetup
{
    FBSDKGraphRequest *request = [[FBSDKGraphRequest alloc]
                                  initWithGraphPath:[NSString stringWithFormat:@"%@?fields=aam_rules", [FBSDKSettings appID]]
                                  HTTPMethod:FBSDKHTTPMethodGET];
    [request startWithCompletionHandler:^(FBSDKGraphRequestConnection *connection, id result, NSError *error) {
        if (error) {
            return;
        }

        if ([result isKindOfClass:[NSDictionary class]]) {
            NSString *json = [(NSDictionary *)result objectForKey:@"aam_rules"];
            if (json) {
                [FBSDKMetadataIndexer constructRules:[FBSDKBasicUtility objectForJSONString:json error:nil]];
                BOOL isR1Enabled = (nil != [FBSDKMetadataIndexerRules objectForKey:FBSDKAppEventRule1]);
                BOOL isR2Enabled = (nil != [FBSDKMetadataIndexerRules objectForKey:FBSDKAppEventRule2]);
                if (!isR1Enabled) {
                    [FBSDKMetadataIndexerStore removeObjectForKey:FBSDKAppEventRule1];
                    [FBSDKUserDataStore setHashData:nil forType:FBSDKAppEventRule1];
                }
                if (!isR2Enabled) {
                    [FBSDKMetadataIndexerStore removeObjectForKey:FBSDKAppEventRule2];
                    [FBSDKUserDataStore setHashData:nil forType:FBSDKAppEventRule2];
                }
                if (isR1Enabled || isR2Enabled) {
                    [self setupMetadataIndexing];
                }
            }
        }
    }];
}

+ (void)constructRules:(NSDictionary<NSString *, id> *)rules
{
    if (!FBSDKMetadataIndexerRules) {
        FBSDKMetadataIndexerRules = [[NSMutableDictionary alloc] init];
    }

    for (NSString *key in rules) {
        NSDictionary<NSString *, NSString *> *value = [self dictionaryValueOf:rules[key]];
        if (value && value[FIELD_K].length > 0 && value[FIELD_V].length > 0) {
            FBSDKMetadataIndexerRules[key] = value;
        }
    }
}

+ (void)setupMetadataIndexing
{
    void (^block)(UIView *) = ^(UIView *view) {
        // Indexing when the view is removed from window and conforms to UITextInput, and skip UIFieldEditor, which is an internval view of UITextField
        if (![view window] && ![NSStringFromClass([view class]) isEqualToString:@"UIFieldEditor"] && [view conformsToProtocol:@protocol(UITextInput)]) {
            NSString *text = [FBSDKViewHierarchy getText:view];
            NSString *placeholder = [FBSDKViewHierarchy getHint:view];
            BOOL secureTextEntry = [self checkSecureTextEntry:view];
            NSArray<NSString *> *labels = [self getLabelsOfView:view];
            UIKeyboardType keyboardType = [self getKeyboardType:view];
            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^(void) {
                [self getMetadataWithText:[self normalizedValue:text]
                              placeholder:[self normalizeField:placeholder]
                                   labels:labels
                          secureTextEntry:secureTextEntry
                                inputType:keyboardType];
            });
        }
    };

    [FBSDKSwizzler swizzleSelector:@selector(didMoveToWindow) onClass:[UIView class] withBlock:block named:@"metadataIndexingUIView"];

    // iOS 12: UITextField implements didMoveToWindow without calling parent implementation
    if (@available(iOS 12, *)) {
        [FBSDKSwizzler swizzleSelector:@selector(didMoveToWindow) onClass:[UITextField class] withBlock:block named:@"metadataIndexingUITextField"];
    } else {
        [FBSDKSwizzler swizzleSelector:@selector(didMoveToWindow) onClass:[UIControl class] withBlock:block named:@"metadataIndexingUIControl"];
    }
}

+ (NSArray<UIView *> *)getSiblingViewsOfView:(UIView *)view
{
    NSObject *parent = [FBSDKViewHierarchy getParent:view];
    if (parent) {
        NSArray<id> *views = [FBSDKViewHierarchy getChildren:parent];
        if (views) {
            NSMutableArray<id> *siblings = [NSMutableArray arrayWithArray:views];
            [siblings removeObject:view];
            return [siblings copy];
        }
    }
    return nil;
}

+ (NSArray<NSString *> *)getLabelsOfView:(UIView *)view
{
    NSMutableArray<NSString *> *labels = [[NSMutableArray alloc] init];

    NSString *placeholder = [self normalizeField:[FBSDKViewHierarchy getHint:view]];
    if (placeholder) {
        [labels addObject:placeholder];
    }

    NSArray<id> *siblingViews = [self getSiblingViewsOfView:view];
    for (id sibling in siblingViews) {
        if ([sibling isKindOfClass:[UILabel class]]) {
            NSString *text = [self normalizeField:[FBSDKViewHierarchy getText:sibling]];
            if (text) {
                [labels addObject:text];
            }
        }
    }
    return [labels copy];
}

+ (BOOL)checkSecureTextEntry:(UIView *)view
{
    if ([view isKindOfClass:[UITextField class]]) {
        return ((UITextField *)view).secureTextEntry;
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return ((UITextView *)view).secureTextEntry;
    }

    return NO;
}

+ (UIKeyboardType)getKeyboardType:(UIView *)view
{
    if ([view isKindOfClass:[UITextField class]]) {
        return ((UITextField *)view).keyboardType;
    }
    if ([view isKindOfClass:[UITextView class]]) {
        return ((UITextView *)view).keyboardType;
    }

    return UIKeyboardTypeDefault;
}

+ (void)getMetadataWithText:(NSString *)text
                placeholder:(NSString *)placeholder
                     labels:(NSArray<NSString *> *)labels
            secureTextEntry:(BOOL)secureTextEntry
                  inputType:(UIKeyboardType)inputType
{
    if (secureTextEntry ||
        [placeholder containsString:@"password"] ||
        text.length == 0 ||
        text.length > FBSDKMetadataIndexerMaxTextLength ||
        placeholder.length >= FBSDKMetadataIndexerMaxIndicatorLength) {
        return;
    }

    for (NSString *key in FBSDKMetadataIndexerRules) {
        NSDictionary<NSString *, NSString *> *rule = FBSDKMetadataIndexerRules[key];
        BOOL isRuleKMatched = [self checkMetadataHint:placeholder matchRuleK:rule[FIELD_K]]
        || [self checkMetadataLabels:labels matchRuleK:rule[FIELD_K]];
        BOOL isRuleVMatched = [self checkMetadataText:text matchRuleV:rule[FIELD_V]];
        if (isRuleKMatched && isRuleVMatched) {
            [FBSDKMetadataIndexer checkAndAppendData:text forKey:key];
        }
    }
}

#pragma mark - Helper Methods

+ (void)checkAndAppendData:(NSString *)data
                    forKey:(NSString *)key
{
    NSString *hashData = [FBSDKUtility SHA256Hash:data];
    dispatch_async(serialQueue, ^{
        if (hashData.length == 0 || [FBSDKMetadataIndexerStore[key] containsObject:hashData]) {
            return;
        }

        while (FBSDKMetadataIndexerStore[key].count >= FBSDKMetadataIndexerMaxValue) {
            [FBSDKMetadataIndexerStore[key] removeObjectAtIndex:0];
        }
        [FBSDKMetadataIndexerStore[key] addObject:hashData];
        [FBSDKUserDataStore setHashData:[FBSDKMetadataIndexerStore[key] componentsJoinedByString:@","]
                                forType:key];
    });
}

+ (BOOL)checkMetadataLabels:(NSArray<NSString *> *)labels
                 matchRuleK:(NSString *)ruleK
{
    for (NSString *label in labels) {
        if ([self checkMetadataHint:label matchRuleK:ruleK]) {
            return YES;
        }
    }
    return NO;
}

+ (BOOL)checkMetadataHint:(NSString *)hint
               matchRuleK:(NSString *)ruleK
{
    if (hint.length > 0 && ruleK) {
        NSArray<NSString *> *items = [ruleK componentsSeparatedByString:@","];
        for (NSString *item in items) {
            if ([hint containsString:item]) {
                return YES;
            }
        }
    }
    return NO;
}

+ (BOOL)checkMetadataText:(NSString *)text
               matchRuleV:(NSString *)ruleV
{
    if (text.length > 0 && ruleV) {
        NSRegularExpression *regex = [[NSRegularExpression alloc] initWithPattern:ruleV
                                                                          options:NSRegularExpressionCaseInsensitive
                                                                            error:nil];
        NSUInteger matches = [regex numberOfMatchesInString:text options:0 range:NSMakeRange(0, text.length)];

        NSString *prunedText = [[text componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"+- ()."]] componentsJoinedByString:@""];
        NSUInteger prunedMatches = [regex numberOfMatchesInString:prunedText options:0 range:NSMakeRange(0, prunedText.length)];

        return matches > 0 || prunedMatches > 0;
    }
    return NO;
}

+ (NSString *)normalizeField:(NSString *)field
{
    if (!field) {
        return nil;
    }
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"[_-]|\\s"
                                                                           options:NSRegularExpressionCaseInsensitive
                                                                             error:nil];
    return [regex stringByReplacingMatchesInString:field
                                           options:0
                                             range:NSMakeRange(0, field.length)
                                      withTemplate:@""].lowercaseString;
}

+ (NSString *)normalizedValue:(NSString *)value
{
    if (!value) {
        return nil;
    }
    return [value stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
}

+ (NSDictionary *)dictionaryValueOf:(id)object
{
    if ([object isKindOfClass:[NSDictionary class]]) {
        return (NSDictionary *)object;
    }
    return nil;
}

@end