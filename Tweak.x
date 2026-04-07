#import <Foundation/Foundation.h>

#define PREFS_DOMAIN @"com.minh.netlogger"
#define LOG_PATH @"/var/mobile/Library/Preferences/com.minh.netlogger.logs.txt"

// Check if the current app is in the user-selected list
static BOOL isAppEnabled() {
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:
        @"/var/mobile/Library/Preferences/com.minh.netlogger.plist"];
    if (![prefs[@"enabled"] boolValue]) return NO;
    NSArray *selectedApps = prefs[@"selectedApps"];
    if (!selectedApps || selectedApps.count == 0) return NO;
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier];
    return [selectedApps containsObject:bundleID];
}

// Append a log entry to the shared log file
static void writeLog(NSString *entry) {
    NSString *logPath = LOG_PATH;
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logPath]) {
        [fm createFileAtPath:logPath contents:nil attributes:nil];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) return;
    [fh seekToEndOfFile];
    NSString *line = [entry stringByAppendingString:@"\n---\n"];
    [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}

%hook NSURLSession

- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {

    if (!isAppEnabled()) return %orig;

    void (^hookedHandler)(NSData *, NSURLResponse *, NSError *) =
        ^(NSData *data, NSURLResponse *response, NSError *error) {

        NSHTTPURLResponse *httpResp = (NSHTTPURLResponse *)response;
        NSString *method  = request.HTTPMethod ?: @"GET";
        NSString *url     = request.URL.absoluteString ?: @"(unknown)";
        NSString *status  = httpResp ? [NSString stringWithFormat:@"%ld", (long)httpResp.statusCode] : @"?";

        NSString *bodyStr = @"(no body / binary)";
        if (data.length > 0 && data.length < 8192) {
            NSString *decoded = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
            if (decoded) bodyStr = decoded;
        }

        // Build log entry with timestamp
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        NSString *ts = [df stringFromDate:[NSDate date]];

        NSString *logEntry = [NSString stringWithFormat:
            @"[%@] %@ %@\nStatus: %@\nApp: %@\nResponse:\n%@",
            ts, method, url, status,
            [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown",
            bodyStr];

        writeLog(logEntry);

        if (completionHandler) completionHandler(data, response, error);
    };

    return %orig(request, hookedHandler);
}

%end
