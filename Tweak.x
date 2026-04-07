#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <syslog.h>
#import <WebKit/WebKit.h>
#import <Security/SecureTransport.h>
#import <Network/Network.h>
#import <substrate.h>
#import "NLURLProtocol.h"

// ---------------------------------------------------------------------------
// Entitlement Sandbox Checks
// ---------------------------------------------------------------------------
typedef struct __SecTask *SecTaskRef;
extern SecTaskRef SecTaskCreateFromSelf(CFAllocatorRef allocator);
extern CFTypeRef SecTaskCopyValueForEntitlement(SecTaskRef task, CFStringRef entitlement, CFErrorRef *error);

static BOOL isWebBrowserApp() {
    SecTaskRef task = SecTaskCreateFromSelf(kCFAllocatorDefault);
    if (!task) return NO;
    
    BOOL isBrowser = NO;
    CFTypeRef value = SecTaskCopyValueForEntitlement(task, CFSTR("com.apple.developer.web-browser"), nil);
    if (value) {
        if (CFGetTypeID(value) == CFBooleanGetTypeID()) {
            isBrowser = CFBooleanGetValue((CFBooleanRef)value);
        }
        CFRelease(value);
    }
    CFRelease(task);
    return isBrowser;
}

#define LOG_FILENAME  @"com.minh.netlogger.logs.txt"
#define NL_DOMAIN     CFSTR("com.minh.netlogger")
#define TAG           "NetLogger"

// ---------------------------------------------------------------------------
// Log writer
// ---------------------------------------------------------------------------

static NSString *getLogPath() {
    NSString *home = NSHomeDirectory();
    NSString *caches = [home stringByAppendingPathComponent:@"Library/Caches"];
    NSFileManager *fm = [NSFileManager defaultManager];
    NSError *error;
    if (![fm fileExistsAtPath:caches]) {
        BOOL success = [fm createDirectoryAtPath:caches withIntermediateDirectories:YES attributes:nil error:&error];
        if (!success) {
            NSLog(@"[NetLogger-Debug] Failed to create Caches dir: %@", error);
        }
    }
    NSString *path = [caches stringByAppendingPathComponent:LOG_FILENAME];
    // NSLog(@"[NetLogger-Debug] Log Path is: %@", path);
    return path;
}

void appendLine(NSString *text) {
    NSString *logPath = getLogPath();
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:logPath]) {
        BOOL success = [fm createFileAtPath:logPath contents:nil attributes:@{NSFilePosixPermissions: @(0666)}];
        if (!success) {
            NSLog(@"[NetLogger-Debug] Failed to create log file at path: %@", logPath);
            return;
        }
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:logPath];
    if (!fh) {
        NSLog(@"[NetLogger-Debug] Cannot open log file for writing at path: %@", logPath);
        return;
    }
    [fh seekToEndOfFile];
    [fh writeData:[[text stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
    
    // Uncomment to see every log written
    // NSLog(@"[NetLogger-Debug] Wrote line to %@", logPath);
}

// ---------------------------------------------------------------------------
// Preferences
// ---------------------------------------------------------------------------

static NSDictionary *readPrefs() {
    static NSDictionary *cachedPrefs = nil;
    static NSTimeInterval lastReadTime = 0;
    
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (cachedPrefs && (now - lastReadTime < 2.0)) {
        return cachedPrefs;
    }
    
    NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"];
    if (!d) d = [NSDictionary dictionaryWithContentsOfFile:@"/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"];
    
    if (d) {
        cachedPrefs = d;
        lastReadTime = now;
        return d;
    }

    CFPreferencesAppSynchronize(NL_DOMAIN);
    NSMutableDictionary *r = [NSMutableDictionary dictionary];
    CFPropertyListRef en   = CFPreferencesCopyAppValue(CFSTR("enabled"), NL_DOMAIN);
    CFPropertyListRef apps = CFPreferencesCopyAppValue(CFSTR("selectedApps"), NL_DOMAIN);
    CFPropertyListRef bl   = CFPreferencesCopyAppValue(CFSTR("blacklistedDomains"), NL_DOMAIN);
    if (en)   r[@"enabled"]      = (__bridge_transfer id)en;
    if (apps) r[@"selectedApps"] = (__bridge_transfer id)apps;
    if (bl)   r[@"blacklistedDomains"] = (__bridge_transfer id)bl;
    
    cachedPrefs = r.count ? r : nil;
    lastReadTime = now;
    return cachedPrefs;
}

BOOL isAppEnabled(void) {
    NSDictionary *prefs = readPrefs();
    if (![prefs[@"enabled"] boolValue]) return NO;
    NSArray *sel = prefs[@"selectedApps"];
    if (!sel.count) return NO;
    return [sel containsObject:[[NSBundle mainBundle] bundleIdentifier] ?: @""];
}

// ---------------------------------------------------------------------------
// MitM Response Modifier
// ---------------------------------------------------------------------------

static NSArray *readMitmRules() {
    NSDictionary *prefs = readPrefs();
    NSArray *rules = prefs[@"mitmRules"];
    if (![rules isKindOfClass:[NSArray class]]) return nil;
    return rules;
}

// Đặt giá trị vào nested key path (vd: "data.user.is_vip")
static void setNestedValue(NSMutableDictionary *dict, NSString *keyPath, id value) {
    NSArray *keys = [keyPath componentsSeparatedByString:@"."];
    NSMutableDictionary *current = dict;
    
    for (NSUInteger i = 0; i < keys.count - 1; i++) {
        id next = current[keys[i]];
        if ([next isKindOfClass:[NSDictionary class]]) {
            NSMutableDictionary *mutable = [next mutableCopy];
            current[keys[i]] = mutable;
            current = mutable;
        } else {
            return; // Path không tồn tại, bỏ qua
        }
    }
    current[[keys lastObject]] = value;
}

// Parse giá trị từ string sang đúng kiểu dữ liệu
static id parseValue(NSString *valueStr) {
    if (!valueStr) return @"";
    NSString *lower = [valueStr lowercaseString];
    if ([lower isEqualToString:@"true"]) return @YES;
    if ([lower isEqualToString:@"false"]) return @NO;
    if ([lower isEqualToString:@"null"]) return [NSNull null];
    
    // Thử parse số
    NSNumberFormatter *f = [[NSNumberFormatter alloc] init];
    f.numberStyle = NSNumberFormatterDecimalStyle;
    NSNumber *num = [f numberFromString:valueStr];
    if (num) return num;
    
    // Mặc định là string
    return valueStr;
}

// Áp dụng tất cả MitM rules lên response data
NSData *applyMitmRules(NSData *originalData, NSURLRequest *request) {
    if (!originalData || !request.URL) return originalData;
    
    NSArray *rules = readMitmRules();
    if (!rules || rules.count == 0) return originalData;
    
    NSString *urlString = request.URL.absoluteString;
    BOOL matched = NO;
    
    // Tìm rules khớp với URL
    NSMutableArray *matchedRules = [NSMutableArray array];
    for (NSDictionary *rule in rules) {
        if (![rule isKindOfClass:[NSDictionary class]]) continue;
        if (![rule[@"enabled"] boolValue]) continue;
        NSString *pattern = rule[@"url_pattern"];
        if (pattern && [urlString containsString:pattern]) {
            [matchedRules addObject:rule];
            matched = YES;
        }
    }
    
    if (!matched) return originalData;
    
    // Parse JSON gốc
    NSError *parseError = nil;
    id jsonObj = [NSJSONSerialization JSONObjectWithData:originalData
                                               options:NSJSONReadingMutableContainers
                                                 error:&parseError];
    if (parseError || ![jsonObj isKindOfClass:[NSDictionary class]]) {
        return originalData; // Không phải JSON, bỏ qua
    }
    
    NSMutableDictionary *json = (NSMutableDictionary *)jsonObj;
    
    // Áp dụng từng rule
    for (NSDictionary *rule in matchedRules) {
        NSString *keyPath = rule[@"key_path"];
        NSString *valueStr = rule[@"new_value"];
        if (!keyPath || keyPath.length == 0) continue;
        
        id newValue = parseValue(valueStr);
        setNestedValue(json, keyPath, newValue);
        
        NSLog(@"[NetLogger-MitM] ✅ URL: %@ | Đổi '%@' → %@", urlString, keyPath, newValue);
    }
    
    // Đóng gói lại
    NSData *modifiedData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
    return modifiedData ?: originalData;
}

// ---------------------------------------------------------------------------
// Build log entry
// ---------------------------------------------------------------------------

NSString *buildEntry(NSURLRequest *request, NSData *data, NSURLResponse *response, double durationMs) {
    if (!request || !request.URL) return nil;
    
    // Check blacklist
    NSDictionary *prefs = readPrefs();
    NSString *blacklistString = prefs[@"blacklistedDomains"];
    if (blacklistString && blacklistString.length > 0) {
        NSString *host = request.URL.host.lowercaseString;
        if (host) {
            NSArray *domains = [blacklistString componentsSeparatedByString:@","];
            for (NSString *d in domains) {
                NSString *trimmed = [d stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
                if (trimmed.length > 0 && [host containsString:trimmed]) {
                    return nil; // Blocked by blacklist
                }
            }
        }
    }

    NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
    
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"id"] = [[NSUUID UUID] UUIDString];
    dict[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
    dict[@"method"] = request.HTTPMethod ?: @"GET";
    dict[@"url"] = request.URL.absoluteString ?: @"(unknown)";
    dict[@"status"] = http ? @(http.statusCode) : @(0);
    dict[@"app"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    dict[@"duration_ms"] = @(durationMs);
    
    if (request.allHTTPHeaderFields) {
        dict[@"req_headers"] = request.allHTTPHeaderFields;
    }
    
    NSData *reqBodyData = request.HTTPBody;
    if (reqBodyData.length > 0 && reqBodyData.length < 1024 * 1024) {
        dict[@"req_body_base64"] = [reqBodyData base64EncodedStringWithOptions:0];
    }
    
    if (http && http.allHeaderFields) {
        dict[@"res_headers"] = http.allHeaderFields;
    }
    
    if (data.length > 0 && data.length < 1024 * 1024) {
        dict[@"res_body_base64"] = [data base64EncodedStringWithOptions:0];
    }
    
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:&error];
    if (!jsonData) return nil;
    
    return [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
}

// ---------------------------------------------------------------------------
// Delegate proxy — captures delegate-based NSURLSession traffic
// (the common pattern in most modern apps)
// ---------------------------------------------------------------------------

@interface NLDelegateProxy : NSObject <NSURLSessionDataDelegate, NSURLSessionTaskDelegate>
- (instancetype)initWithDelegate:(id<NSURLSessionDelegate>)delegate;
@end

@implementation NLDelegateProxy {
    id<NSURLSessionDelegate> _real;
    NSMutableDictionary<NSNumber *, NSMutableData *> *_bodies;
    NSMutableDictionary<NSNumber *, NSNumber *> *_startTimes;
}

- (instancetype)initWithDelegate:(id<NSURLSessionDelegate>)delegate {
    if ((self = [super init])) {
        _real       = delegate;
        _bodies     = [NSMutableDictionary dictionary];
        _startTimes = [NSMutableDictionary dictionary];
    }
    return self;
}

// Forward any selector we don't implement ourselves to the real delegate
- (BOOL)respondsToSelector:(SEL)sel {
    return [super respondsToSelector:sel] || [_real respondsToSelector:sel];
}

- (id)forwardingTargetForSelector:(SEL)sel {
    if ([_real respondsToSelector:sel]) return _real;
    return nil;
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)task
    didReceiveData:(NSData *)data {
    NSNumber *tid = @(task.taskIdentifier);
    if (!_startTimes[tid]) _startTimes[tid] = @(CFAbsoluteTimeGetCurrent());
    if (!_bodies[tid]) _bodies[tid] = [NSMutableData data];
    [_bodies[tid] appendData:data];
    if ([_real respondsToSelector:@selector(URLSession:dataTask:didReceiveData:)])
        [(id<NSURLSessionDataDelegate>)_real URLSession:session dataTask:task didReceiveData:data];
}

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    if (!error) {
        NSNumber *tid = @(task.taskIdentifier);
        double startTime = [_startTimes[tid] doubleValue];
        double durationMs = startTime > 0 ? (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0 : 0;
        NSString *entry = buildEntry(task.currentRequest ?: task.originalRequest,
                                     _bodies[tid], task.response, durationMs);
        if (entry) appendLine(entry);
        [_bodies removeObjectForKey:tid];
        [_startTimes removeObjectForKey:tid];
    }
    if ([_real respondsToSelector:@selector(URLSession:task:didCompleteWithError:)])
        [(id<NSURLSessionTaskDelegate>)_real URLSession:session task:task didCompleteWithError:error];
}

@end

// ---------------------------------------------------------------------------
// C-Level Hooks (Security & Network)
// ---------------------------------------------------------------------------

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// 1. SSLWrite
static OSStatus (*orig_SSLWrite)(SSLContextRef context, const void *data, size_t dataLength, size_t *processed);
static OSStatus hook_SSLWrite(SSLContextRef context, const void *data, size_t dataLength, size_t *processed) {
    if (isAppEnabled() && data && dataLength > 0) {
        NSData *d = [NSData dataWithBytes:data length:MIN(dataLength, 1024)];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s && ([s hasPrefix:@"GET "] || [s hasPrefix:@"POST "])) {
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
            NSDictionary *dict = @{
                @"url": @"[RAW C-Level Request]",
                @"status": @(0),
                @"method": @"RAW",
                @"app": app,
                @"source": @"SSLWrite",
                @"duration_ms": @(0),
                @"req_body": s
            };
            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        }
    }
    return orig_SSLWrite(context, data, dataLength, processed);
}

// 2. SSLRead
static OSStatus (*orig_SSLRead)(SSLContextRef context, void *data, size_t dataLength, size_t *processed);
static OSStatus hook_SSLRead(SSLContextRef context, void *data, size_t dataLength, size_t *processed) {
    OSStatus status = orig_SSLRead(context, data, dataLength, processed);
    if (isAppEnabled() && status == noErr && processed && *processed > 0 && data) {
        NSData *d = [NSData dataWithBytes:data length:MIN(*processed, 1024)];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s && [s containsString:@"HTTP/1."]) {
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
            NSDictionary *dict = @{
                @"url": @"[RAW C-Level Response]",
                @"status": @(200),
                @"method": @"RAW",
                @"app": app,
                @"source": @"SSLRead",
                @"duration_ms": @(0),
                @"res_body": s
            };
            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        }
    }
    return status;
}

#pragma clang diagnostic pop

// ---------------------------------------------------------------------------
// NSURLSession hooks
// ---------------------------------------------------------------------------

static const char kProxyKey = 0;

%hook NSURLSession

// ── Delegate-based sessions (most apps) ─────────────────────────────────────
+ (NSURLSession *)sessionWithConfiguration:(NSURLSessionConfiguration *)config
                                  delegate:(id<NSURLSessionDelegate>)delegate
                             delegateQueue:(NSOperationQueue *)queue {
    if (delegate && isAppEnabled()) {
        NLDelegateProxy *proxy = [[NLDelegateProxy alloc] initWithDelegate:delegate];
        NSURLSession *session = %orig(config, proxy, queue);
        // Retain proxy for the session's lifetime
        objc_setAssociatedObject(session, &kProxyKey, proxy, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        return session;
    }
    return %orig;
}

// ── Completion-handler-based sessions (shared session, simple calls) ─────────
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
                            completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        double durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0;
        // MitM: Sửa response trước khi log và trả về cho app
        NSData *finalData = (e == nil && d != nil) ? applyMitmRules(d, request) : d;
        NSString *entry = buildEntry(request, finalData, r, durationMs);
        if (entry) appendLine(entry);
        if (completionHandler) completionHandler(finalData, r, e);
    };
    return %orig(request, h);
}

- (NSURLSessionDataTask *)dataTaskWithURL:(NSURL *)url
                        completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    NSMutableURLRequest *fakeReq = [NSMutableURLRequest requestWithURL:url];
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        double durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0;
        NSData *finalData = (e == nil && d != nil) ? applyMitmRules(d, fakeReq) : d;
        NSString *entry = buildEntry(fakeReq, finalData, r, durationMs);
        if (entry) appendLine(entry);
        if (completionHandler) completionHandler(finalData, r, e);
    };
    return %orig(url, h);
}

- (NSURLSessionUploadTask *)uploadTaskWithRequest:(NSURLRequest *)request
                                         fromData:(NSData *)bodyData
                                completionHandler:(void (^)(NSData *, NSURLResponse *, NSError *))completionHandler {
    if (!isAppEnabled()) return %orig;
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    void (^h)(NSData *, NSURLResponse *, NSError *) = ^(NSData *d, NSURLResponse *r, NSError *e) {
        double durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0;
        NSData *finalData = (e == nil && d != nil) ? applyMitmRules(d, request) : d;
        NSString *entry = buildEntry(request, finalData, r, durationMs);
        if (entry) appendLine(entry);
        if (completionHandler) completionHandler(finalData, r, e);
    };
    return %orig(request, bodyData, h);
}

%end

// ---------------------------------------------------------------------------
// NSURLConnection hooks (Legacy API — used by older apps & SDKs)
// ---------------------------------------------------------------------------

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"

%hook NSURLConnection

// ── Synchronous request ─────────────────────────────────────────────────────
+ (NSData *)sendSynchronousRequest:(NSURLRequest *)request
                 returningResponse:(NSURLResponse **)response
                             error:(NSError **)error {
    if (!isAppEnabled()) return %orig;
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    NSData *data = %orig;
    double durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0;
    NSURLResponse *resp = response ? *response : nil;
    NSData *finalData = (data != nil) ? applyMitmRules(data, request) : data;
    NSString *entry = buildEntry(request, finalData, resp, durationMs);
    if (entry) appendLine(entry);
    // Nếu MitM đã sửa data, phải trả lại data mới cho app
    if (finalData != data && response) {
        return finalData;
    }
    return data;
}

// ── Asynchronous request ────────────────────────────────────────────────────
+ (void)sendAsynchronousRequest:(NSURLRequest *)request
                          queue:(NSOperationQueue *)queue
              completionHandler:(void (^)(NSURLResponse *, NSData *, NSError *))handler {
    if (!isAppEnabled()) { %orig; return; }
    CFAbsoluteTime startTime = CFAbsoluteTimeGetCurrent();
    void (^wrapped)(NSURLResponse *, NSData *, NSError *) =
        ^(NSURLResponse *resp, NSData *data, NSError *err) {
            double durationMs = (CFAbsoluteTimeGetCurrent() - startTime) * 1000.0;
            NSData *finalData = (err == nil && data != nil) ? applyMitmRules(data, request) : data;
            NSString *entry = buildEntry(request, finalData, resp, durationMs);
            if (entry) appendLine(entry);
            if (handler) handler(resp, finalData, err);
        };
    %orig(request, queue, wrapped);
}

%end

#pragma clang diagnostic pop

// ---------------------------------------------------------------------------
// WKWebView hooks (Web-based apps: Discord, Slack, etc.)
// ---------------------------------------------------------------------------

%hook WKWebView

static BOOL isRegisteringProtocol = NO;

// ── Override handlesURLScheme để bypass giới hạn của registerSchemeForCustomProtocol ──
+ (BOOL)handlesURLScheme:(NSString *)urlScheme {
    if (isRegisteringProtocol) {
        NSString *lower = [urlScheme lowercaseString];
        if ([lower isEqualToString:@"http"] || [lower isEqualToString:@"https"]) {
            return NO; // Lừa WebKit rằng nó không tự handle http/https, để nó cho phép Custom Protocol
        }
    }
    return %orig;
}

// ── loadRequest — bắt mọi request chính mà WebView load ─────────────────────
- (WKNavigation *)loadRequest:(NSURLRequest *)request {
    if (isAppEnabled() && request.URL) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"id"] = [[NSUUID UUID] UUIDString];
        dict[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        dict[@"method"] = request.HTTPMethod ?: @"GET";
        dict[@"url"] = request.URL.absoluteString ?: @"(unknown)";
        dict[@"status"] = @(0); // WebView không có status ngay lúc load
        dict[@"app"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        dict[@"duration_ms"] = @(0);
        dict[@"req_headers"] = request.allHTTPHeaderFields ?: @{};
        // Đánh dấu nguồn gốc
        dict[@"source"] = @"WKWebView";
        
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        if (jsonData) {
            appendLine([[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]);
        }
    }
    return %orig;
}

// ── loadHTMLString — bắt khi app load HTML trực tiếp ────────────────────────
- (WKNavigation *)loadHTMLString:(NSString *)string baseURL:(NSURL *)baseURL {
    if (isAppEnabled() && baseURL) {
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        dict[@"id"] = [[NSUUID UUID] UUIDString];
        dict[@"timestamp"] = @([[NSDate date] timeIntervalSince1970]);
        dict[@"method"] = @"WEBVIEW";
        dict[@"url"] = baseURL.absoluteString ?: @"about:blank";
        dict[@"status"] = @(200);
        dict[@"app"] = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
        dict[@"duration_ms"] = @(0);
        dict[@"source"] = @"WKWebView-HTML";
        
        // Lưu HTML body (giới hạn 512KB)
        if (string.length > 0 && string.length < 512 * 1024) {
            NSData *htmlData = [string dataUsingEncoding:NSUTF8StringEncoding];
            dict[@"res_body_base64"] = [htmlData base64EncodedStringWithOptions:0];
        }
        
        NSData *jsonData = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        if (jsonData) {
            appendLine([[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding]);
        }
    }
    return %orig;
}

%end

// ---------------------------------------------------------------------------
// Constructor diagnostic
// ---------------------------------------------------------------------------

%ctor {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid) return;

    NSDictionary *prefs = readPrefs();
    BOOL masterOn       = [prefs[@"enabled"] boolValue];
    NSArray *selected   = prefs[@"selectedApps"];
    BOOL thisApp        = [selected containsObject:bid];

    if (masterOn && thisApp) {
        NSDictionary *diag = @{
            @"id": [[NSUUID UUID] UUIDString],
            @"timestamp": @([[NSDate date] timeIntervalSince1970]),
            @"method": @"DIAGNOSTIC",
            @"url": [NSString stringWithFormat:@"diagnostic://app-started/%@", bid],
            @"status": @(200),
            @"app": bid
        };
        NSData *d = [NSJSONSerialization dataWithJSONObject:diag options:0 error:nil];
        if (d) {
            appendLine([[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding]);
        }
        
        // Đăng ký toàn cục NSURLProtocol
        [NSURLProtocol registerClass:[NLURLProtocol class]];
        
        // MSHookFunction cho các hàm C-Level API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        MSHookFunction((void *)SSLWrite, (void *)hook_SSLWrite, (void **)&orig_SSLWrite);
        MSHookFunction((void *)SSLRead, (void *)hook_SSLRead, (void **)&orig_SSLRead);
#pragma clang diagnostic pop
        
        // Tự động Quét thẻ bài Entitlement của Ứng dụng. 
        // Triệt để Bỏ qua MỌI Trình Diệt Web (Chrome, Edge, Brave...) tự build C++ Network Custom để chống Panic/SigTrap
        // TUY NHIÊN: Lại trừ Safari ra (com.apple.mobilesafari) vì Safari là hàng zin của Apple, nó xài được và không bị crash!
        if (!isWebBrowserApp() || [bid isEqualToString:@"com.apple.mobilesafari"]) {
            // Đăng ký với WebKit (Sử dụng Private API)
            Class cls = NSClassFromString(@"WKBrowsingContextController");
            SEL sel = NSSelectorFromString(@"registerSchemeForCustomProtocol:");
            if ([cls respondsToSelector:sel]) {
                isRegisteringProtocol = YES;
                #pragma clang diagnostic push
                #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [cls performSelector:sel withObject:@"http"];
                [cls performSelector:sel withObject:@"https"];
                #pragma clang diagnostic pop
                isRegisteringProtocol = NO;
                NSLog(@"[NetLogger] Vô hiệu hoá WKWebView bảo mật ngầm thành công cho %@", bid);
            }
        } else {
            NSLog(@"[NetLogger] Trình duyệt web độc lập phát hiện (%@) - Từ chối hack WKWebView để chống crash.", bid);
        }
    }
}
