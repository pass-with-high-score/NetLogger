#import "NLLogDetailViewController.h"

@implementation NLLogEntry
- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if (self = [super init]) {
        _guid = dict[@"id"];
        _timestamp = [dict[@"timestamp"] doubleValue];
        _method = dict[@"method"];
        _url = dict[@"url"];
        _status = [dict[@"status"] integerValue];
        _app = dict[@"app"];
        _reqHeaders = dict[@"req_headers"];
        _reqBodyBase64 = dict[@"req_body_base64"];
        _resHeaders = dict[@"res_headers"];
        _resBodyBase64 = dict[@"res_body_base64"];
    }
    return self;
}
@end

@interface NLLogDetailViewController ()
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UITextView *textView;
@end

@implementation NLLogDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor whiteColor];
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    }
    
    // Segmented Control
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Overview", @"Request", @"Response"]];
    self.segmentedControl.selectedSegmentIndex = 0;
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    
    self.navigationItem.titleView = self.segmentedControl;
    
    // Text View
    self.textView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.textView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.textView.editable = NO;
    self.textView.font = [UIFont fontWithName:@"Menlo" size:13] ?: [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
    
    if (@available(iOS 13.0, *)) {
        self.textView.backgroundColor = [UIColor systemBackgroundColor];
        self.textView.textColor = [UIColor labelColor];
    }
    
    self.textView.textContainerInset = UIEdgeInsetsMake(16, 16, 16, 16);
    [self.view addSubview:self.textView];
    
    [self updateContent];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self updateContent];
}

- (NSString *)formatHeaders:(NSDictionary *)headers {
    if (!headers || headers.count == 0) return @"(None)\n";
    NSMutableString *s = [NSMutableString string];
    for (NSString *key in headers) {
        [s appendFormat:@"%@: %@\n", key, headers[key]];
    }
    return s;
}

- (NSString *)decodeBase64ToStringOrJSON:(NSString *)base64 {
    if (!base64 || base64.length == 0) return @"(None / Empty)";
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return @"(Invalid Base64)";
    
    // Try to parse JSON
    NSError *err;
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:&err];
    if (json) {
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (pretty) {
            return [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
        }
    }
    
    // Fallback string
    NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    return s ?: @"(Binary / Unreadable)";
}

- (void)updateContent {
    if (!self.logEntry) return;
    NSMutableString *content = [NSMutableString string];
    
    NSInteger index = self.segmentedControl.selectedSegmentIndex;
    if (index == 0) {
        // Overview
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:self.logEntry.timestamp];
        
        [content appendFormat:@"URL: %@\n\n", self.logEntry.url];
        [content appendFormat:@"Method: %@\n", self.logEntry.method];
        [content appendFormat:@"Status: %ld\n", (long)self.logEntry.status];
        [content appendFormat:@"Time: %@\n", [df stringFromDate:d]];
        [content appendFormat:@"App: %@\n", self.logEntry.app];
        if ([self.logEntry.method isEqualToString:@"DIAGNOSTIC"]) {
            [content appendString:@"\nNote: This is a diagnostic event automatically generated on app start."];
        }
        
    } else if (index == 1) {
        // Request
        [content appendString:@"--- HEADERS ---\n"];
        [content appendString:[self formatHeaders:self.logEntry.reqHeaders]];
        [content appendString:@"\n--- BODY ---\n"];
        [content appendString:[self decodeBase64ToStringOrJSON:self.logEntry.reqBodyBase64]];
        
    } else if (index == 2) {
        // Response
        [content appendString:@"--- HEADERS ---\n"];
        [content appendString:[self formatHeaders:self.logEntry.resHeaders]];
        [content appendString:@"\n--- BODY ---\n"];
        [content appendString:[self decodeBase64ToStringOrJSON:self.logEntry.resBodyBase64]];
    }
    
    self.textView.text = content;
}

@end
