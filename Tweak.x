#import <Foundation/Foundation.h>
#import <syslog.h>

// /var/tmp is world-writable — accessible by all sandboxed apps
#define SETTINGS_PATH @"/var/tmp/com.minh.netlogger.settings.plist"
#define LOG_PATH      @"/var/tmp/com.minh.netlogger.logs.txt"
#define NL_DOMAIN     CFSTR("com.minh.netlogger")
#define TAG           "NetLogger"

// ---------------------------------------------------------------------------
// Log writer
// ---------------------------------------------------------------------------

static void appendLine(NSString *text) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:LOG_PATH]) {
        [fm createFileAtPath:LOG_PATH contents:nil attributes:@{NSFilePosixPermissions: @(0666)}];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    if (!fh) { syslog(LOG_ERR, TAG ": cannot open log file"); return; }
    [fh seekToEndOfFile];
    [fh writeData:[[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

// ---------------------------------------------------------------------------
// Preferences — two-tier read:
//   1. /var/tmp mirror written by the pref bundle (reliable, no sandbox issues)
//   2. CFPreferencesCopyAppValue as fallback (in-memory, no disk flush needed)
// ---------------------------------------------------------------------------

static NSDictionary *readPrefs() {
    // Tier 1: mirror file written by NetLoggerPreferences bundle
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:SETTINGS_PATH];
    if (d) return d;

    // Tier 2: ask cfprefsd directly
    CFPreferencesAppSynchronize(NL_DOMAIN);
    NSMutableDictionary *result = [NSMutableDictionary dictionary];

    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), NL_DOMAIN);
    if (en) { result[@"enabled"] = (__bridge_transfer id)en; }

    CFPropertyListRef apps = CFPreferencesCopyAppValue(CFSTR("selectedApps"), NL_DOMAIN);
    if (apps) { result[@"selectedApps"] = (__bridge_transfer id)apps; }

    return result.count ? result : nil;
}

static BOOL isAppEnabled() {
    NSDictionary *prefs = readPrefs();
    if (!prefs) { syslog(LOG_DEBUG, TAG ": no prefs found"); return NO; }
    if (![prefs[@"enabled"] boolValue]) { syslog(LOG_DEBUG, TAG ": switch OFF"); return NO; }
    NSArray *selectedApps = prefs[@"selectedApps"];
    if (!selectedApps.count) { syslog(LOG_DEBUG, TAG ": no apps selected"); return NO; }
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    return [selectedApps containsObject:bid];
}

// ---------------------------------------------------------------------------
// Build log entry
// ---------------------------------------------------------------------------

static NSString *buildEntry(NSURLRequest *request, NSData *data, NSURLResponse *response) {
    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    NSString *body = @"(no body / binary)";
    if (data.length > 0 && data.length < 16384) {
        NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        if (decoded) body = decoded;
    }

    return [NSString stringWithFormat:
        @"[%@] %@ %@\nStatus: %@\nApp: %@\nResponse:\n%@\n---",
        [df stringFromDate:[NSDate date]],
        request.HTTPMethod ?: @"GET",
        request.URL.absoluteString ?: @"(unknown)",
        http ? @(http.statusCode).stringValue : @"?",
        [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
        body];
}

// ---------------------------------------------------------------------------
// NSURLSession hooks
// ---------------------------------------------------------------------------

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        appendLine(buildEntry(request, data, resp));
        if (completionHandler) completionHandler(data, resp, err);
    };
    return %orig(request, h);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
        appendLine(buildEntry(req, data, resp));
        if (completionHandler) completionHandler(data, resp, err);
    };
    return %orig(url, h);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *data, NSURLResponse *resp, NSError *err) {
        appendLine(buildEntry(request, data, resp));
        if (completionHandler) completionHandler(data, resp, err);
    };
    return %orig(request, bodyData, h);
}

%end

// ---------------------------------------------------------------------------
// Constructor — diagnostic on every app launch
// ---------------------------------------------------------------------------

%ctor {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    if (!bundleID) return;

    NSDictionary *prefs    = readPrefs();
    BOOL masterOn          = [prefs[@"enabled"] boolValue];
    NSArray *selected      = prefs[@"selectedApps"];
    BOOL appSelected       = [selected containsObject:bundleID];

    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"yyyy-MM-dd HH:mm:ss";

    NSString *diag = [NSString stringWithFormat:
        @"[%@] DIAGNOSTIC — injected into: %@\n"
        @"  settingsFile    : %@\n"
        @"  masterSwitch    : %@\n"
        @"  selectedApps    : %@\n"
        @"  thisAppSelected : %@\n---",
        [df stringFromDate:[NSDate date]],
        bundleID,
        prefs ? @"found" : @"NOT FOUND",
        masterOn ? @"ON" : @"OFF",
        selected ?: @"(none)",
        appSelected ? @"YES" : @"NO"];

    appendLine(diag);
    syslog(LOG_DEBUG, TAG ": %s", diag.UTF8String);
}
