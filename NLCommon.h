#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, NLBlacklistPolicy) {
    NLPolicyNone   = -1,  // No rule matched
    NLPolicyDirect = 0,   // Allow traffic, skip logging
    NLPolicyReject = 1    // Block request entirely
};

extern BOOL isAppEnabled(void);
extern BOOL isNoCachingEnabled(void);
extern BOOL isSocketCaptureEnabled(void);
extern NLBlacklistPolicy getBlacklistPolicy(NSString *host);
extern NSData *applyMitmRules(NSData *responseData, NSURLRequest *request);
extern NSMutableURLRequest *applyMitmRequestRules(NSMutableURLRequest *request);
extern NSURLResponse *applyMitmResponseRules(NSURLResponse *response, NSURLRequest *request);
extern NSString *buildEntry(NSURLRequest *request, NSData *data, NSURLResponse *response, double durationMs);
extern void appendLine(NSString *line);
