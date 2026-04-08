#import "NLLogDetailViewController.h"
#import <WebKit/WebKit.h>

// ---------------------------------------------------------------------------
#pragma mark - NLLogEntry
// ---------------------------------------------------------------------------

@implementation NLLogEntry

- (instancetype)initWithDictionary:(NSDictionary *)dict {
    if (self = [super init]) {
        _guid = dict[@"id"];
        _timestamp = [dict[@"timestamp"] doubleValue];
        _method = dict[@"method"];
        _url = dict[@"url"];
        _status = [dict[@"status"] integerValue];
        _app = dict[@"app"];
        _durationMs = [dict[@"duration_ms"] doubleValue];
        _reqHeaders = dict[@"req_headers"];
        _reqBodyBase64 = dict[@"req_body_base64"];
        _resHeaders = dict[@"res_headers"];
        _resBodyBase64 = dict[@"res_body_base64"];
    }
    return self;
}

- (NSString *)hostFromURL {
    NSURL *u = [NSURL URLWithString:self.url];
    return u.host ?: @"—";
}

- (NSString *)pathFromURL {
    NSURL *u = [NSURL URLWithString:self.url];
    NSString *p = u.path;
    if (u.query) p = [p stringByAppendingFormat:@"?%@", u.query];
    return (p && p.length > 0) ? p : @"/";
}

- (NSString *)statusText {
    if (self.status == 0) return @"—";
    return [NSString stringWithFormat:@"%ld", (long)self.status];
}

- (NSString *)durationText {
    if (self.durationMs <= 0) return @"—";
    if (self.durationMs < 1000) return [NSString stringWithFormat:@"%.0f ms", self.durationMs];
    return [NSString stringWithFormat:@"%.2f s", self.durationMs / 1000.0];
}

- (NSString *)toCurlCommand {
    NSMutableString *curl = [NSMutableString stringWithFormat:@"curl -X %@ '%@'", self.method ?: @"GET", self.url ?: @""];
    
    for (NSString *key in self.reqHeaders) {
        NSString *val = [NSString stringWithFormat:@"%@", self.reqHeaders[key]];
        val = [val stringByReplacingOccurrencesOfString:@"'" withString:@"'\\'"];
        [curl appendFormat:@" \\ \n  -H '%@: %@'", key, val];
    }
    
    if (self.reqBodyBase64.length > 0) {
        NSData *data = [[NSData alloc] initWithBase64EncodedString:self.reqBodyBase64 options:0];
        if (data) {
            NSString *body = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (body) {
                body = [body stringByReplacingOccurrencesOfString:@"'" withString:@"'\\'"];
                [curl appendFormat:@" \\ \n  --data '%@'", body];
            }
        }
    }
    
    return curl;
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Detail View Controller
// ---------------------------------------------------------------------------

@interface NLLogDetailViewController () <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UISegmentedControl *segmentedControl;
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSArray *currentSections; // Array of section dicts
@end

@implementation NLLogDetailViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
    
    // --- Segmented Control ---
    self.segmentedControl = [[UISegmentedControl alloc] initWithItems:@[@"Overview", @"Request", @"Response"]];
    self.segmentedControl.selectedSegmentIndex = 0;
    [self.segmentedControl addTarget:self action:@selector(segmentChanged:) forControlEvents:UIControlEventValueChanged];
    self.navigationItem.titleView = self.segmentedControl;
    
    // --- Single Action Menu Button ---
    UIBarButtonItem *actionBtn = [[UIBarButtonItem alloc]
        initWithImage:[UIImage systemImageNamed:@"ellipsis.circle"]
        style:UIBarButtonItemStylePlain
        target:self action:@selector(showActions)];
    
    self.navigationItem.rightBarButtonItem = actionBtn;
    
    // --- Table View (grouped style) ---
    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    self.tableView.estimatedRowHeight = 44;
    self.tableView.rowHeight = UITableViewAutomaticDimension;
    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"Cell"];
    [self.view addSubview:self.tableView];
    
    [self rebuildData];
}

- (void)segmentChanged:(UISegmentedControl *)sender {
    [self rebuildData];
}

- (void)copyContent {
    NSMutableString *text = [NSMutableString string];
    for (NSDictionary *section in self.currentSections) {
        [text appendFormat:@"── %@ ──\n", section[@"title"]];
        for (NSDictionary *row in section[@"rows"]) {
            if (row[@"label"]) {
                [text appendFormat:@"%@: %@\n", row[@"label"], row[@"value"]];
            } else {
                [text appendFormat:@"%@\n", row[@"value"]];
            }
        }
        [text appendString:@"\n"];
    }
    [UIPasteboard generalPasteboard].string = text;
    
    [self showToast:@"Copied!"];
}

- (void)showActions {
    if (!self.logEntry) return;

    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Options" message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    
    // 1. Replay
    [sheet addAction:[UIAlertAction actionWithTitle:@"Replay Request" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self replayRequest];
    }]];
    
    // 2. Copy Raw Content
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy Screen Content" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self copyContent];
    }]];
    
    // 3. Copy cURL
    [sheet addAction:[UIAlertAction actionWithTitle:@"Copy cURL" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSString *curl = [self.logEntry toCurlCommand];
        if (curl) {
            [UIPasteboard generalPasteboard].string = curl;
            [self showToast:@"Copied cURL!"];
        }
    }]];
    
    // 4. Share Text
    [sheet addAction:[UIAlertAction actionWithTitle:@"Share Log as Text" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSMutableString *text = [NSMutableString string];
        for (NSDictionary *section in self.currentSections) {
            [text appendFormat:@"── %@ ──\n", section[@"title"]];
            for (NSDictionary *row in section[@"rows"]) {
                if (row[@"label"]) {
                    [text appendFormat:@"%@: %@\n", row[@"label"], row[@"value"]];
                } else {
                    [text appendFormat:@"%@\n", row[@"value"]];
                }
            }
            [text appendString:@"\n"];
        }
        UIActivityViewController *activity = [[UIActivityViewController alloc] initWithActivityItems:@[text] applicationActivities:nil];
        if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
            activity.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
        }
        [self presentViewController:activity animated:YES completion:nil];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Block Domain" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *action) {
        [self blockDomain];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Export Raw Response (.bin)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        [self exportBinaryResponse];
    }]];
    
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        sheet.popoverPresentationController.barButtonItem = self.navigationItem.rightBarButtonItem;
    }
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)replayRequest {
    if (!self.logEntry || !self.logEntry.url) return;
    NSURL *url = [NSURL URLWithString:self.logEntry.url];
    if (!url) return;
    
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod = self.logEntry.method ?: @"GET";
    
    if (self.logEntry.reqHeaders) {
        for (NSString *key in self.logEntry.reqHeaders) {
            [req setValue:[NSString stringWithFormat:@"%@", self.logEntry.reqHeaders[key]] forHTTPHeaderField:key];
        }
    }
    
    if (self.logEntry.reqBodyBase64) {
        req.HTTPBody = [[NSData alloc] initWithBase64EncodedString:self.logEntry.reqBodyBase64 options:0];
    }
    
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Replaying" message:@"Sending request..." preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:alert animated:YES completion:nil];
    
    NSTimeInterval start = [[NSDate date] timeIntervalSince1970];
    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *res, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [alert dismissViewControllerAnimated:YES completion:^{
                NSTimeInterval duration = ([[NSDate date] timeIntervalSince1970] - start) * 1000.0;
                NSString *msg = @"";
                if (err) {
                    msg = [NSString stringWithFormat:@"Error: %@", err.localizedDescription];
                } else {
                    NSHTTPURLResponse *http = (NSHTTPURLResponse *)res;
                    msg = [NSString stringWithFormat:@"Status: %ld\nDuration: %.0f ms\nBytes: %lu", (long)http.statusCode, duration, (unsigned long)data.length];
                }
                UIAlertController *resAlert = [UIAlertController alertControllerWithTitle:@"Replay Result" message:msg preferredStyle:UIAlertControllerStyleAlert];
                [resAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:resAlert animated:YES completion:nil];
            }];
        });
    }] resume];
}

- (void)exportBinaryResponse {
    if (!self.logEntry.resBodyBase64 || self.logEntry.resBodyBase64.length == 0) {
        [self showToast:@"No Response Body"];
        return;
    }
    NSData *data = [[NSData alloc] initWithBase64EncodedString:self.logEntry.resBodyBase64 options:0];
    if (!data) return;
    
    NSString *fileName = [NSString stringWithFormat:@"/var/mobile/Downloads/dump_%ld.bin", (long)[[NSDate date] timeIntervalSince1970]];
    [data writeToFile:fileName atomically:YES];
    
    // Attempt to open Filza directly
    NSURL *filzaUrl = [NSURL URLWithString:[NSString stringWithFormat:@"filza://%@", fileName]];
    if ([[UIApplication sharedApplication] canOpenURL:filzaUrl]) {
        [[UIApplication sharedApplication] openURL:filzaUrl options:@{} completionHandler:nil];
    } else {
        [self showToast:@"Saved to Downloads!"];
    }
}

- (void)blockDomain {
    if (!self.logEntry || !self.logEntry.url) return;
    NSURL *u = [NSURL URLWithString:self.logEntry.url];
    if (!u || !u.host) return;
    NSString *host = u.host;
    
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("blacklistedDomains"), CFSTR("com.minh.netlogger"));
    NSString *current = ref ? (__bridge_transfer NSString *)ref : @"";
    NSString *newBlacklist = current.length > 0 ? [NSString stringWithFormat:@"%@, %@", current, host] : host;
    
    CFPreferencesSetAppValue(CFSTR("blacklistedDomains"), (__bridge CFStringRef)newBlacklist, CFSTR("com.minh.netlogger"));
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"] ?: [NSMutableDictionary dictionary];
    dict[@"blacklistedDomains"] = newBlacklist;
    [dict writeToFile:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist" atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist" error:nil];
    
    [self showToast:[NSString stringWithFormat:@"Blocked %@", host]];
}

- (void)showToast:(NSString *)message {
    UILabel *toast = [[UILabel alloc] init];
    toast.text = [NSString stringWithFormat:@" %@ ", message];
    toast.font = [UIFont boldSystemFontOfSize:14];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.75];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.layer.cornerRadius = 16;
    toast.clipsToBounds = YES;
    [toast sizeToFit];
    CGRect f = toast.frame;
    f.size.width += 32;
    f.size.height += 16;
    toast.frame = f;
    toast.center = CGPointMake(self.view.center.x, self.view.frame.size.height - 100);
    [self.view addSubview:toast];
    [UIView animateWithDuration:0.3 delay:1.0 options:0 animations:^{ toast.alpha = 0; } completion:^(BOOL f) { [toast removeFromSuperview]; }];
}

// ---------------------------------------------------------------------------
#pragma mark - Build Data
// ---------------------------------------------------------------------------

- (NSArray *)headerRowsFromDict:(NSDictionary *)headers {
    if (!headers || headers.count == 0) return nil;
    NSMutableArray *rows = [NSMutableArray array];
    for (NSString *key in [headers.allKeys sortedArrayUsingSelector:@selector(caseInsensitiveCompare:)]) {
        [rows addObject:@{@"label": key, @"value": [NSString stringWithFormat:@"%@", headers[key]], @"wrap": @YES}];
    }
    return rows;
}

- (NSDictionary *)decodeBase64:(NSString *)base64 {
    if (!base64 || base64.length == 0) return nil;
    NSData *data = [[NSData alloc] initWithBase64EncodedString:base64 options:0];
    if (!data) return @{@"display": @"(Invalid Base64)", @"raw": @"(Invalid Base64)"};
    
    NSString *result = nil;
    
    // Try JSON pretty print
    id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    if (json) {
        NSData *pretty = [NSJSONSerialization dataWithJSONObject:json options:NSJSONWritingPrettyPrinted error:nil];
        if (pretty) result = [[NSString alloc] initWithData:pretty encoding:NSUTF8StringEncoding];
    }
    
    if (!result) {
        result = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    }
    
    if (!result) {
        NSUInteger peekLen = MIN(data.length, (NSUInteger)256);
        NSData *peekData = [data subdataWithRange:NSMakeRange(0, peekLen)];
        NSString *s = [NSString stringWithFormat:@"(Binary Data - %lu bytes)\n\nHex Dump (First %lu bytes):\n%@\n\nUse 'Export Raw Response' in Options menu to save full file.", (unsigned long)data.length, (unsigned long)peekLen, [peekData description]];
        return @{@"display": s, @"raw": s};
    }
    
    NSString *rawResult = result;
    
    // Truncate to prevent UI lag on massive bodies
    static const NSUInteger kMaxDisplayLength = 20000;
    if (result.length > kMaxDisplayLength) {
        result = [NSString stringWithFormat:@"%@\n\n── Truncated ──\nShowing %lu of %lu characters.\nTAP THIS BLOCK to copy FULL content to clipboard.",
            [result substringToIndex:kMaxDisplayLength],
            (unsigned long)kMaxDisplayLength,
            (unsigned long)result.length];
    }
    
    return @{@"display": result, @"raw": rawResult};
}

- (void)rebuildData {
    NSMutableArray *sections = [NSMutableArray array];
    NLLogEntry *e = self.logEntry;
    if (!e) { self.currentSections = @[]; [self.tableView reloadData]; return; }
    
    NSInteger idx = self.segmentedControl.selectedSegmentIndex;
    
    if (idx == 0) {
        // ── Overview ──
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
        NSDate *d = [NSDate dateWithTimeIntervalSince1970:e.timestamp];
        
        [sections addObject:@{
            @"title": @"General",
            @"rows": @[
                @{@"label": @"URL",    @"value": e.url ?: @"—", @"wrap": @YES},
                @{@"label": @"Host",   @"value": [e hostFromURL], @"wrap": @YES},
                @{@"label": @"Path",   @"value": [e pathFromURL], @"wrap": @YES},
                @{@"label": @"Method", @"value": e.method ?: @"—"},
                @{@"label": @"Status", @"value": [e statusText], @"statusColor": @YES},
                @{@"label": @"Duration", @"value": [e durationText]},
            ]
        }];
        
        [sections addObject:@{
            @"title": @"Metadata",
            @"rows": @[
                @{@"label": @"App",  @"value": e.app ?: @"—"},
                @{@"label": @"Time", @"value": [df stringFromDate:d]},
                @{@"label": @"ID",   @"value": e.guid ?: @"—", @"wrap": @YES},
            ]
        }];
        
        if ([e.method isEqualToString:@"DIAGNOSTIC"]) {
            [sections addObject:@{
                @"title": @"Note",
                @"rows": @[@{@"value": @"This is a diagnostic event generated on app start."}]
            }];
        }
        
    } else if (idx == 1) {
        // ── Request ──
        NSArray *headerRows = [self headerRowsFromDict:e.reqHeaders];
        if (headerRows) {
            [sections addObject:@{
                @"title": [NSString stringWithFormat:@"Headers (%lu)", (unsigned long)e.reqHeaders.count],
                @"rows": headerRows
            }];
        } else {
            [sections addObject:@{@"title": @"Headers", @"rows": @[@{@"value": @"No request headers captured."}]}];
        }
        
        NSDictionary *bodyDict = [self decodeBase64:e.reqBodyBase64];
        if (bodyDict) {
            [sections addObject:@{
                @"title": @"Body",
                @"rows": @[@{@"value": bodyDict[@"display"], @"rawValue": bodyDict[@"raw"], @"mono": @YES}]
            }];
        } else {
            [sections addObject:@{@"title": @"Body", @"rows": @[@{@"value": @"No request body."}]}];
        }
        
    } else if (idx == 2) {
        // ── Response ──
        NSArray *headerRows = [self headerRowsFromDict:e.resHeaders];
        if (headerRows) {
            [sections addObject:@{
                @"title": [NSString stringWithFormat:@"Headers (%lu)", (unsigned long)e.resHeaders.count],
                @"rows": headerRows
            }];
        } else {
            [sections addObject:@{@"title": @"Headers", @"rows": @[@{@"value": @"No response headers captured."}]}];
        }
        
        NSDictionary *bodyDict = [self decodeBase64:e.resBodyBase64];
        
        NSString *contentType = e.resHeaders[@"Content-Type"] ?: e.resHeaders[@"content-type"];
        contentType = [contentType lowercaseString];
        BOOL isMedia = ([contentType hasPrefix:@"image/"] || [contentType hasPrefix:@"video/"] || [contentType hasPrefix:@"audio/"]);
        if (isMedia && e.resBodyBase64.length > 0) {
            [sections addObject:@{
                @"title": @"Media Preview",
                @"rows": @[@{@"value": @"Tap to preview media", @"action": @"previewMedia", @"contentType": contentType}]
            }];
        }

        BOOL isHTML = (contentType && [contentType containsString:@"html"]);
        if (isHTML && e.resBodyBase64.length > 0) {
            [sections addObject:@{
                @"title": @"HTML Preview",
                @"rows": @[@{@"value": @"Tap to render HTML", @"action": @"previewHTML"}]
            }];
        }
        
        if (bodyDict) {
            [sections addObject:@{
                @"title": @"Body",
                @"rows": @[@{@"value": bodyDict[@"display"], @"rawValue": bodyDict[@"raw"], @"mono": @YES}]
            }];
        } else {
            [sections addObject:@{@"title": @"Body", @"rows": @[@{@"value": @"No response body."}]}];
        }
    }
    
    self.currentSections = sections;
    [self.tableView reloadData];
}

// ---------------------------------------------------------------------------
#pragma mark - UITableView
// ---------------------------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.currentSections.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    return self.currentSections[section][@"title"];
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    return [self.currentSections[section][@"rows"] count];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *row = self.currentSections[indexPath.section][@"rows"][indexPath.row];
    
    NSString *label = row[@"label"];
    NSString *value = row[@"value"];
    BOOL isMono = [row[@"mono"] boolValue];
    BOOL hasStatusColor = [row[@"statusColor"] boolValue];
    
    if (label) {
        BOOL shouldWrap = [row[@"wrap"] boolValue];
        
        if (shouldWrap) {
            // Subtitle style: key on top, value wraps below
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
            cell.textLabel.text = label;
            cell.textLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
            if (@available(iOS 13.0, *)) cell.textLabel.textColor = [UIColor secondaryLabelColor];
            
            cell.detailTextLabel.text = value;
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByCharWrapping;
            cell.selectionStyle = UITableViewCellSelectionStyleDefault;
            return cell;
        } else {
            // Value1 style: key left, short value right
            UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
            cell.textLabel.text = label;
            cell.textLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightMedium];
            cell.detailTextLabel.text = value;
            cell.detailTextLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightRegular];
            cell.detailTextLabel.numberOfLines = 0;
            cell.detailTextLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
            cell.selectionStyle = UITableViewCellSelectionStyleNone;
            
            if (hasStatusColor && self.logEntry) {
                NSInteger s = self.logEntry.status;
                if (s >= 200 && s < 300) cell.detailTextLabel.textColor = [UIColor systemGreenColor];
                else if (s >= 300 && s < 400) cell.detailTextLabel.textColor = [UIColor systemOrangeColor];
                else if (s >= 400) cell.detailTextLabel.textColor = [UIColor systemRedColor];
            }
            return cell;
        }
    } else {
        // Full-width content row (headers dump, body, notes)
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"Cell" forIndexPath:indexPath];
        cell.textLabel.text = value;
        cell.textLabel.numberOfLines = 0;
        cell.textLabel.lineBreakMode = NSLineBreakByWordWrapping;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        
        if (isMono) {
            cell.textLabel.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
        } else {
            cell.textLabel.font = [UIFont systemFontOfSize:14];
            if (@available(iOS 13.0, *)) {
                cell.textLabel.textColor = [UIColor secondaryLabelColor];
            }
        }
        
        return cell;
    }
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    NSDictionary *row = self.currentSections[indexPath.section][@"rows"][indexPath.row];
    
    NSString *action = row[@"action"];
    if (action && [action isEqualToString:@"previewMedia"]) {
        [self previewMedia:row[@"contentType"]];
        return;
    }
    if (action && [action isEqualToString:@"previewHTML"]) {
        [self previewHTML];
        return;
    }
    
    NSString *value = row[@"rawValue"] ?: row[@"value"];
    if (!value) return;
    
    [UIPasteboard generalPasteboard].string = value;
    [self showToast:@"Copied!"];
    
    // Brief feedback
    UITableViewCell *cell = [tableView cellForRowAtIndexPath:indexPath];
    cell.backgroundColor = [UIColor colorWithRed:0.2 green:0.8 blue:0.4 alpha:0.15];
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 300 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
        [UIView animateWithDuration:0.3 animations:^{
            if (@available(iOS 13.0, *)) {
                cell.backgroundColor = [UIColor secondarySystemGroupedBackgroundColor];
            } else {
                cell.backgroundColor = [UIColor whiteColor];
            }
        }];
    });
}

- (void)previewHTML {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:self.logEntry.resBodyBase64 options:0];
    if (!data) { [self showToast:@"No HTML Data"]; return; }
    NSString *html = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!html) { [self showToast:@"Invalid HTML Data"]; return; }

    UIViewController *vc = [[UIViewController alloc] init];
    vc.title = @"HTML Preview";
    vc.view.backgroundColor = [UIColor systemBackgroundColor];

    WKWebView *webView = [[WKWebView alloc] initWithFrame:vc.view.bounds];
    webView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [vc.view addSubview:webView];

    NSURL *baseURL = self.logEntry.url ? [NSURL URLWithString:self.logEntry.url] : nil;
    [webView loadHTMLString:html baseURL:baseURL];

    [self.navigationController pushViewController:vc animated:YES];
}

- (void)previewMedia:(NSString *)contentType {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:self.logEntry.resBodyBase64 options:0];
    if (!data) return;
    
    if ([contentType hasPrefix:@"image/"]) {
        UIImage *img = [UIImage imageWithData:data];
        if (!img) { [self showToast:@"Invalid Image Data"]; return; }
        
        UIViewController *vc = [[UIViewController alloc] init];
        if (@available(iOS 13.0, *)) {
            vc.view.backgroundColor = [UIColor systemBackgroundColor];
        } else {
            vc.view.backgroundColor = [UIColor whiteColor];
        }
        UIImageView *iv = [[UIImageView alloc] initWithImage:img];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        // Support dynamic resizing
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.frame = vc.view.bounds;
        [vc.view addSubview:iv];
        
        [self.navigationController pushViewController:vc animated:YES];
    } else {
        // Video / Audio
        NSString *ext = @"mp4";
        if ([contentType containsString:@"mpeg"]) ext = @"mp3";
        else if ([contentType containsString:@"wav"]) ext = @"wav";
        else if ([contentType containsString:@"m4a"]) ext = @"m4a";
        else if ([contentType containsString:@"mov"]) ext = @"mov";
        
        NSString *path = [NSTemporaryDirectory() stringByAppendingPathComponent:[NSString stringWithFormat:@"preview_%ld.%@", (long)[[NSDate date] timeIntervalSince1970], ext]];
        [data writeToFile:path atomically:YES];
        NSURL *url = [NSURL fileURLWithPath:path];
        
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AVFoundation.framework"] load];
        [[NSBundle bundleWithPath:@"/System/Library/Frameworks/AVKit.framework"] load];
        
        Class AVPlayerViewControllerClass = NSClassFromString(@"AVPlayerViewController");
        Class AVPlayerClass = NSClassFromString(@"AVPlayer");
        if (AVPlayerViewControllerClass && AVPlayerClass) {
            id player = [AVPlayerClass performSelector:@selector(playerWithURL:) withObject:url];
            UIViewController *playerVC = [[AVPlayerViewControllerClass alloc] init];
            [playerVC setValue:player forKey:@"player"];
            [self presentViewController:playerVC animated:YES completion:^{
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [player performSelector:@selector(play)];
#pragma clang diagnostic pop
            }];
        } else {
            [self showToast:@"Cannot play media on this iOS."];
        }
    }
}

@end
