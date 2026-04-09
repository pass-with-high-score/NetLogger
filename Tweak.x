#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <syslog.h>
#import <WebKit/WebKit.h>
#import <Security/SecureTransport.h>
#import <Network/Network.h>
#import <substrate.h>
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <mach-o/nlist.h>
#import "NLURLProtocol.h"
#import "NLCommon.h"

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
    CFPropertyListRef blRules = CFPreferencesCopyAppValue(CFSTR("blacklistRules"), NL_DOMAIN);
    CFPropertyListRef nocache = CFPreferencesCopyAppValue(CFSTR("noCachingEnabled"), NL_DOMAIN);
    CFPropertyListRef socketCap = CFPreferencesCopyAppValue(CFSTR("socketCaptureEnabled"), NL_DOMAIN);
    
    if (en)   r[@"enabled"]      = (__bridge_transfer id)en;
    if (apps) r[@"selectedApps"] = (__bridge_transfer id)apps;
    if (bl)   r[@"blacklistedDomains"] = (__bridge_transfer id)bl;
    if (blRules) r[@"blacklistRules"] = (__bridge_transfer id)blRules;
    if (nocache) r[@"noCachingEnabled"] = (__bridge_transfer id)nocache;
    if (socketCap) r[@"socketCaptureEnabled"] = (__bridge_transfer id)socketCap;
    
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

BOOL isNoCachingEnabled(void) {
    NSDictionary *prefs = readPrefs();
    return [prefs[@"noCachingEnabled"] boolValue];
}

BOOL isSocketCaptureEnabled(void) {
    NSDictionary *prefs = readPrefs();
    return [prefs[@"socketCaptureEnabled"] boolValue];
}

// ---------------------------------------------------------------------------
// Blacklist Rule Engine (Shadowrocket-style)
// ---------------------------------------------------------------------------
// Filter types: 0=Domain (exact), 1=Domain Suffix, 2=Domain Keyword
// Policy: 0=Direct (skip log), 1=Reject (block request)

static BOOL matchesBlacklistRule(NSString *host, NSDictionary *rule) {
    if (![rule[@"enabled"] boolValue]) return NO;
    
    NSString *pattern = [rule[@"domain"] lowercaseString];
    if (!pattern || pattern.length == 0) return NO;
    
    NSInteger filterType = [rule[@"filter_type"] integerValue];
    
    switch (filterType) {
        case 0: // Domain — exact match
            return [host isEqualToString:pattern];
        case 1: // Domain Suffix — host ends with pattern
            if ([host isEqualToString:pattern]) return YES;
            return [host hasSuffix:[NSString stringWithFormat:@".%@", pattern]];
        case 2: // Domain Keyword — host contains pattern
            return [host containsString:pattern];
        default:
            return NO;
    }
}

NLBlacklistPolicy getBlacklistPolicy(NSString *host) {
    if (!host || host.length == 0) return NLPolicyNone;
    
    NSString *lowerHost = [host lowercaseString];
    NSDictionary *prefs = readPrefs();
    
    // Try new rule format first
    NSArray *rules = prefs[@"blacklistRules"];
    if ([rules isKindOfClass:[NSArray class]] && rules.count > 0) {
        for (NSDictionary *rule in rules) {
            if (![rule isKindOfClass:[NSDictionary class]]) continue;
            if (matchesBlacklistRule(lowerHost, rule)) {
                NSInteger policy = [rule[@"policy"] integerValue];
                return (policy == 1) ? NLPolicyReject : NLPolicyDirect;
            }
        }
        return NLPolicyNone;
    }
    
    // Fallback: old CSV format (blacklistedDomains) — treated as Direct
    NSString *blacklistString = prefs[@"blacklistedDomains"];
    if (blacklistString && blacklistString.length > 0) {
        NSArray *domains = [blacklistString componentsSeparatedByString:@","];
        for (NSString *d in domains) {
            NSString *trimmed = [d stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]].lowercaseString;
            if (trimmed.length > 0 && [lowerHost containsString:trimmed]) {
                return NLPolicyDirect;
            }
        }
    }
    
    return NLPolicyNone;
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

// Sửa gói tin đi (Request Body / Request Header)
NSMutableURLRequest *applyMitmRequestRules(NSMutableURLRequest *request) {
    if (!isAppEnabled()) return request;
    NSArray *rules = readMitmRules();
    if (!rules.count) return request;
    
    NSString *urlString = request.URL.absoluteString;
    if (!urlString) return request;
    
    for (NSDictionary *rule in rules) {
        if (![rule[@"enabled"] boolValue]) continue;
        
        NSString *pattern = rule[@"url_pattern"];
        NSInteger type = [rule[@"rule_type"] integerValue]; // 0: Res Body, 1: Req Body, 2: Req Header, 3: Res Header, 4: Req URL
        
        if (pattern.length > 0 && [urlString containsString:pattern]) {
            NSString *key = rule[@"key_path"];
            NSString *val = rule[@"new_value"];
            
            if (type == 1 && request.HTTPBody && key.length > 0) { // Request Body
                id json = [NSJSONSerialization JSONObjectWithData:request.HTTPBody options:NSJSONReadingMutableContainers error:nil];
                if ([json isKindOfClass:[NSMutableDictionary class]]) {
                    setNestedValue((NSMutableDictionary *)json, key, val);
                    NSData *newData = [NSJSONSerialization dataWithJSONObject:json options:0 error:nil];
                    if (newData) request.HTTPBody = newData;
                }
            }
            else if (type == 2 && key.length > 0) { // Request Header
                [request setValue:val forHTTPHeaderField:key];
            }
            else if (type == 4 && key.length > 0) { // Request URL Rewrite
                if (!val) val = @""; // Ngừa lỗi nil
                NSString *newUrlString = [urlString stringByReplacingOccurrencesOfString:key withString:val];
                NSURL *newURL = [NSURL URLWithString:newUrlString];
                if (newURL) {
                    request.URL = newURL;
                    urlString = newUrlString; // Cập nhật để rule sau (nếu có) chồng lên tiếp
                }
            }
        }
    }
    return request;
}

// Sửa Header gói tin về (Response Header)
NSURLResponse *applyMitmResponseRules(NSURLResponse *response, NSURLRequest *request) {
    if (!isAppEnabled() || ![response isKindOfClass:[NSHTTPURLResponse class]]) return response;
    NSArray *rules = readMitmRules();
    if (!rules.count) return response;
    
    NSString *urlString = request.URL.absoluteString ?: response.URL.absoluteString;
    if (!urlString) return response;
    
    NSHTTPURLResponse *httpRes = (NSHTTPURLResponse *)response;
    NSMutableDictionary *headers = [httpRes.allHeaderFields mutableCopy] ?: [NSMutableDictionary dictionary];
    BOOL modified = NO;
    
    for (NSDictionary *rule in rules) {
        if (![rule[@"enabled"] boolValue]) continue;
        
        NSString *pattern = rule[@"url_pattern"];
        NSInteger type = [rule[@"rule_type"] integerValue];
        
        if (pattern.length > 0 && [urlString containsString:pattern]) {
            NSString *key = rule[@"key_path"];
            NSString *val = rule[@"new_value"];
            
            if (type == 3 && key.length > 0) { // Response Header
                if (val.length == 0) {
                    [headers removeObjectForKey:key];
                } else {
                    headers[key] = val;
                }
                modified = YES;
            }
        }
    }
    
    if (modified) {
        NSHTTPURLResponse *newRes = [[NSHTTPURLResponse alloc] initWithURL:httpRes.URL statusCode:httpRes.statusCode HTTPVersion:nil headerFields:headers];
        return newRes ?: response;
    }
    
    return response;
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
        
        NSInteger type = [rule[@"rule_type"] integerValue];
        if (type != 0) continue; // Chỉ xử lý Response Body
        
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
    
    // Check blacklist rules (Direct = skip log, Reject = also skip log since request was blocked)
    NLBlacklistPolicy policy = getBlacklistPolicy(request.URL.host);
    if (policy != NLPolicyNone) {
        return nil; // Filtered by blacklist rule
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
// NSURLSessionConfiguration hooks — Ensures all custom sessions inject NLURLProtocol
// ---------------------------------------------------------------------------

%hook NSURLSessionConfiguration

- (NSArray<Class> *)protocolClasses {
    NSArray *orig = %orig;
    if (isAppEnabled()) {
        NSMutableArray *newClasses = [NSMutableArray arrayWithArray:orig];
        if (![newClasses containsObject:[NLURLProtocol class]]) {
            [newClasses insertObject:[NLURLProtocol class] atIndex:0];
        }
        return newClasses;
    }
    return orig;
}

- (void)setProtocolClasses:(NSArray<Class> *)protocolClasses {
    if (isAppEnabled()) {
        NSMutableArray *newClasses = [NSMutableArray arrayWithArray:protocolClasses];
        if (![newClasses containsObject:[NLURLProtocol class]]) {
            [newClasses insertObject:[NLURLProtocol class] atIndex:0];
        }
        %orig(newClasses);
    } else {
        %orig(protocolClasses);
    }
}

%end

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
// BoringSSL Hooks (Flutter / Dart VM)
// ---------------------------------------------------------------------------
// Flutter dùng BoringSSL riêng bên trong Flutter.framework, không đi qua
// SecureTransport của Apple → SSLWrite/SSLRead không bắt được.
// Hook SSL_write/SSL_read của BoringSSL để capture decrypted traffic.

// BoringSSL API:
//   int SSL_write(SSL *ssl, const void *buf, int num)
//   int SSL_read(SSL *ssl, void *buf, int num)
//   int SSL_CTX_set_alpn_protos(SSL_CTX *ctx, const uint8_t *protos, unsigned protos_len)
typedef void *BORING_SSL;
typedef void *BORING_SSL_CTX;
static int (*orig_boring_SSL_write)(BORING_SSL ssl, const void *buf, int num);
static int (*orig_boring_SSL_read)(BORING_SSL ssl, void *buf, int num);
static int (*orig_boring_SSL_CTX_set_alpn_protos)(BORING_SSL_CTX ctx, const uint8_t *protos, unsigned protos_len);

// ── ALPN Downgrade: Force HTTP/1.1 ──
// Flutter mặc định negotiate HTTP/2 (binary frames) → hooks không parse được.
// Thay ALPN list bằng chỉ http/1.1 để force plaintext HTTP → parse đầy đủ.
static const uint8_t kHTTP11Only[] = {0x08, 'h','t','t','p','/','1','.','1'};

static int hook_boring_SSL_CTX_set_alpn_protos(BORING_SSL_CTX ctx, const uint8_t *protos, unsigned protos_len) {
    if (isAppEnabled()) {
        return orig_boring_SSL_CTX_set_alpn_protos(ctx, kHTTP11Only, sizeof(kHTTP11Only));
    }
    return orig_boring_SSL_CTX_set_alpn_protos(ctx, protos, protos_len);
}

static int hook_boring_SSL_write(BORING_SSL ssl, const void *buf, int num) {
    if (isAppEnabled() && buf && num > 0) {
        NSData *d = [NSData dataWithBytes:buf length:MIN(num, 2048)];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s && ([s hasPrefix:@"GET "] || [s hasPrefix:@"POST "] ||
                  [s hasPrefix:@"PUT "] || [s hasPrefix:@"DELETE "] ||
                  [s hasPrefix:@"PATCH "] || [s hasPrefix:@"HEAD "] ||
                  [s hasPrefix:@"OPTIONS "])) {
            // Parse HTTP request line to extract method + URL
            NSString *method = @"RAW";
            NSString *path = @"";
            NSString *host = @"";
            NSRange firstLine = [s rangeOfString:@"\r\n"];
            if (firstLine.location != NSNotFound) {
                NSString *requestLine = [s substringToIndex:firstLine.location];
                NSArray *parts = [requestLine componentsSeparatedByString:@" "];
                if (parts.count >= 2) {
                    method = parts[0];
                    path = parts[1];
                }
                // Extract Host header
                NSRange hostRange = [s rangeOfString:@"Host: " options:NSCaseInsensitiveSearch];
                if (hostRange.location != NSNotFound) {
                    NSUInteger start = hostRange.location + hostRange.length;
                    NSRange eol = [s rangeOfString:@"\r\n" options:0 range:NSMakeRange(start, s.length - start)];
                    if (eol.location != NSNotFound) {
                        host = [s substringWithRange:NSMakeRange(start, eol.location - start)];
                    }
                }
            }

            NSString *url = host.length > 0 ? [NSString stringWithFormat:@"https://%@%@", host, path] : path;
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

            // Extract body (after \r\n\r\n)
            NSString *body = nil;
            NSRange bodyStart = [s rangeOfString:@"\r\n\r\n"];
            if (bodyStart.location != NSNotFound) {
                NSUInteger offset = bodyStart.location + 4;
                if (offset < s.length) {
                    body = [s substringFromIndex:offset];
                }
            }

            // Extract headers
            NSMutableDictionary *headers = [NSMutableDictionary dictionary];
            if (firstLine.location != NSNotFound) {
                NSString *headerBlock = s;
                if (bodyStart.location != NSNotFound) {
                    headerBlock = [s substringToIndex:bodyStart.location];
                }
                NSArray *headerLines = [headerBlock componentsSeparatedByString:@"\r\n"];
                for (NSUInteger i = 1; i < headerLines.count; i++) {
                    NSString *line = headerLines[i];
                    NSRange colon = [line rangeOfString:@": "];
                    if (colon.location != NSNotFound) {
                        headers[[line substringToIndex:colon.location]] = [line substringFromIndex:colon.location + 2];
                    }
                }
            }

            NSMutableDictionary *dict = [@{
                @"id": [[NSUUID UUID] UUIDString],
                @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                @"url": url,
                @"status": @(0),
                @"method": method,
                @"app": app,
                @"source": @"BoringSSL",
                @"duration_ms": @(0),
                @"req_headers": headers,
            } mutableCopy];
            if (body.length > 0) {
                dict[@"req_body_base64"] = [[body dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            }

            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        } else {
            // Non-HTTP/1.x data (HTTP/2 binary frames hoặc binary protocol)
            // Log raw để user thấy hook đang hoạt động
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
            const uint8_t *bytes = (const uint8_t *)buf;
            NSMutableString *hex = [NSMutableString string];
            for (int i = 0; i < MIN(num, 32); i++) [hex appendFormat:@"%02x ", bytes[i]];

            NSDictionary *dict = @{
                @"id": [[NSUUID UUID] UUIDString],
                @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                @"url": [NSString stringWithFormat:@"raw://ssl-write/%@/%d-bytes", app, num],
                @"status": @(0),
                @"method": @"RAW-WRITE",
                @"app": app,
                @"source": @"BoringSSL-Raw",
                @"duration_ms": @(0),
                @"req_body_base64": [d base64EncodedStringWithOptions:0],
                @"req_headers": @{@"X-Raw-Hex": hex, @"X-Raw-Size": @(num).stringValue},
            };
            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        }
    }
    return orig_boring_SSL_write(ssl, buf, num);
}

static int hook_boring_SSL_read(BORING_SSL ssl, void *buf, int num) {
    int ret = orig_boring_SSL_read(ssl, buf, num);
    if (isAppEnabled() && ret > 0 && buf) {
        NSData *d = [NSData dataWithBytes:buf length:MIN(ret, 4096)];
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        if (s && [s hasPrefix:@"HTTP/"]) {
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
            NSInteger statusCode = 0;
            NSString *url = @"[Flutter Response]";

            // Parse "HTTP/1.1 200 OK"
            NSRange firstLine = [s rangeOfString:@"\r\n"];
            if (firstLine.location != NSNotFound) {
                NSString *statusLine = [s substringToIndex:firstLine.location];
                NSArray *parts = [statusLine componentsSeparatedByString:@" "];
                if (parts.count >= 2) {
                    statusCode = [parts[1] integerValue];
                }
            }

            // Extract response headers
            NSMutableDictionary *headers = [NSMutableDictionary dictionary];
            NSRange bodyStart = [s rangeOfString:@"\r\n\r\n"];
            if (firstLine.location != NSNotFound) {
                NSString *headerBlock = bodyStart.location != NSNotFound ? [s substringToIndex:bodyStart.location] : s;
                NSArray *headerLines = [headerBlock componentsSeparatedByString:@"\r\n"];
                for (NSUInteger i = 1; i < headerLines.count; i++) {
                    NSString *line = headerLines[i];
                    NSRange colon = [line rangeOfString:@": "];
                    if (colon.location != NSNotFound) {
                        headers[[line substringToIndex:colon.location]] = [line substringFromIndex:colon.location + 2];
                    }
                }
            }

            // Extract body
            NSString *body = nil;
            if (bodyStart.location != NSNotFound) {
                NSUInteger offset = bodyStart.location + 4;
                if (offset < s.length) {
                    body = [s substringFromIndex:offset];
                }
            }

            NSMutableDictionary *dict = [@{
                @"id": [[NSUUID UUID] UUIDString],
                @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                @"url": url,
                @"status": @(statusCode),
                @"method": @"FLUTTER",
                @"app": app,
                @"source": @"BoringSSL",
                @"duration_ms": @(0),
                @"res_headers": headers,
            } mutableCopy];
            if (body.length > 0) {
                dict[@"res_body_base64"] = [[body dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0];
            }

            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        } else if (ret > 0) {
            // Non-HTTP/1.x response (HTTP/2 binary hoặc binary data)
            NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
            const uint8_t *bytes = (const uint8_t *)buf;
            NSMutableString *hex = [NSMutableString string];
            for (int i = 0; i < MIN(ret, 32); i++) [hex appendFormat:@"%02x ", bytes[i]];

            NSDictionary *dict = @{
                @"id": [[NSUUID UUID] UUIDString],
                @"timestamp": @([[NSDate date] timeIntervalSince1970]),
                @"url": [NSString stringWithFormat:@"raw://ssl-read/%@/%d-bytes", app, ret],
                @"status": @(0),
                @"method": @"RAW-READ",
                @"app": app,
                @"source": @"BoringSSL-Raw",
                @"duration_ms": @(0),
                @"res_body_base64": [d base64EncodedStringWithOptions:0],
                @"res_headers": @{@"X-Raw-Hex": hex, @"X-Raw-Size": @(ret).stringValue},
            };
            NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
            if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
        }
    }
    return ret;
}

// ---------------------------------------------------------------------------
// Mach-O Symbol Table Scanner
// ---------------------------------------------------------------------------
// dlsym chỉ tìm được exported symbols. Flutter release builds thường đánh dấu
// BoringSSL symbols là hidden visibility → dlsym fail.
// Đọc trực tiếp Mach-O nlist (symbol table) để tìm cả local/hidden symbols.

static void *findSymbolInImage(uint32_t imageIndex, const char *symbolName) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
    if (!header || header->magic != MH_MAGIC_64) return NULL;

    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);

    const uint8_t *ptr = (const uint8_t *)(header + 1);
    const struct symtab_command *symtab_cmd = NULL;
    const struct segment_command_64 *linkedit_seg = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SYMTAB) {
            symtab_cmd = (const struct symtab_command *)lc;
        } else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit_seg = seg;
        }
        ptr += lc->cmdsize;
    }

    if (!symtab_cmd || !linkedit_seg) return NULL;

    // linkedit_base: chuyển file offset → memory address
    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);

    for (uint32_t i = 0; i < symtab_cmd->nsyms; i++) {
        uint32_t strx = symtab[i].n_un.n_strx;
        if (strx == 0) continue;
        // Bỏ qua debug/stab symbols
        if (symtab[i].n_type & N_STAB) continue;
        // Chỉ quan tâm defined symbols (có address)
        if ((symtab[i].n_type & N_TYPE) == N_UNDF) continue;
        if (symtab[i].n_value == 0) continue;

        const char *name = strtab + strx;
        // Mach-O symbols có prefix underscore: _SSL_write
        if (name[0] == '_' && strcmp(name + 1, symbolName) == 0) {
            return (void *)(symtab[i].n_value + slide);
        }
        if (strcmp(name, symbolName) == 0) {
            return (void *)(symtab[i].n_value + slide);
        }
    }

    return NULL;
}

// Tìm và hook SSL_write/SSL_read từ BoringSSL
// Chiến lược:
//   1. dlsym (exported symbols) — thử cả tên gốc và prefixed (BSSL_)
//   2. Mach-O nlist (hidden/local symbols) — thử cả tên gốc và prefixed
//   3. Scan tất cả non-system dylibs (App.framework, third-party libs)
//   4. _dyld_register_func_for_add_image callback (late-loaded frameworks)
//
// Flutter builds BoringSSL with BORINGSSL_PREFIX → symbols có thể bị rename
// thành BSSL_SSL_write thay vì SSL_write. Hoặc bị strip hoàn toàn.

// Symbol name variants to try
static const char *kSSLWriteNames[] = {"SSL_write", "BSSL_SSL_write", NULL};
static const char *kSSLReadNames[]  = {"SSL_read",  "BSSL_SSL_read", NULL};
static const char *kSSLAlpnNames[]  = {
    "SSL_CTX_set_alpn_protos", "BSSL_SSL_CTX_set_alpn_protos",
    "SSL_set_alpn_protos", "BSSL_SSL_set_alpn_protos", NULL
};

// Helper: tìm symbol bằng dlsym hoặc nlist trong 1 image, thử nhiều tên
static void findBoringSymbols(uint32_t imageIndex, const char *imagePath,
                              void **out_write, void **out_read, void **out_alpn) {
    // ── dlsym (exported symbols) ──
    void *handle = dlopen(imagePath, RTLD_NOLOAD | RTLD_LAZY);
    if (handle) {
        for (int i = 0; kSSLWriteNames[i] && !*out_write; i++)
            *out_write = dlsym(handle, kSSLWriteNames[i]);
        for (int i = 0; kSSLReadNames[i] && !*out_read; i++)
            *out_read = dlsym(handle, kSSLReadNames[i]);
        for (int i = 0; kSSLAlpnNames[i] && !*out_alpn; i++)
            *out_alpn = dlsym(handle, kSSLAlpnNames[i]);
        dlclose(handle);
        if (*out_write && *out_read) {
            NSLog(@"[NetLogger] BoringSSL found via dlsym in: %s (w=%p r=%p a=%p)", imagePath, *out_write, *out_read, *out_alpn);
            return;
        }
        NSLog(@"[NetLogger] dlsym partial (write=%p read=%p) — trying nlist...", *out_write, *out_read);
    }

    // ── nlist (hidden/local/prefixed symbols) ──
    for (int i = 0; kSSLWriteNames[i] && !*out_write; i++) {
        void *p = findSymbolInImage(imageIndex, kSSLWriteNames[i]);
        if (p) { *out_write = p; break; }
    }
    for (int i = 0; kSSLReadNames[i] && !*out_read; i++) {
        void *p = findSymbolInImage(imageIndex, kSSLReadNames[i]);
        if (p) { *out_read = p; break; }
    }
    for (int i = 0; kSSLAlpnNames[i] && !*out_alpn; i++) {
        void *p = findSymbolInImage(imageIndex, kSSLAlpnNames[i]);
        if (p) { *out_alpn = p; break; }
    }
    if (*out_write && *out_read) {
        NSLog(@"[NetLogger] BoringSSL found via nlist in: %s (w=%p r=%p a=%p)", imagePath, *out_write, *out_read, *out_alpn);
    }
}

// ── Debug: liệt kê symbols liên quan SSL/TLS trong image ──
// Gọi khi không tìm được symbols để xác định binary có bị strip hay prefix khác.
static void logSSLSymbolsInImage(uint32_t imageIndex) {
    const struct mach_header_64 *header = (const struct mach_header_64 *)_dyld_get_image_header(imageIndex);
    if (!header || header->magic != MH_MAGIC_64) return;

    intptr_t slide = _dyld_get_image_vmaddr_slide(imageIndex);
    const uint8_t *ptr = (const uint8_t *)(header + 1);
    const struct symtab_command *symtab_cmd = NULL;
    const struct segment_command_64 *linkedit_seg = NULL;

    for (uint32_t i = 0; i < header->ncmds; i++) {
        const struct load_command *lc = (const struct load_command *)ptr;
        if (lc->cmd == LC_SYMTAB) symtab_cmd = (const struct symtab_command *)lc;
        else if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *seg = (const struct segment_command_64 *)lc;
            if (strcmp(seg->segname, SEG_LINKEDIT) == 0) linkedit_seg = seg;
        }
        ptr += lc->cmdsize;
    }

    if (!symtab_cmd || !linkedit_seg) {
        NSLog(@"[NetLogger] No symtab in image #%u — fully stripped", imageIndex);
        return;
    }

    uintptr_t linkedit_base = (uintptr_t)slide + linkedit_seg->vmaddr - linkedit_seg->fileoff;
    const struct nlist_64 *symtab = (const struct nlist_64 *)(linkedit_base + symtab_cmd->symoff);
    const char *strtab = (const char *)(linkedit_base + symtab_cmd->stroff);

    NSLog(@"[NetLogger] Image #%u has %u symbols total — scanning for SSL/TLS...", imageIndex, symtab_cmd->nsyms);

    int found = 0;
    for (uint32_t i = 0; i < symtab_cmd->nsyms && found < 30; i++) {
        uint32_t strx = symtab[i].n_un.n_strx;
        if (strx == 0) continue;
        if (symtab[i].n_type & N_STAB) continue;

        const char *name = strtab + strx;
        if (strcasestr(name, "ssl") || strcasestr(name, "boring") ||
            strcasestr(name, "tls") || strcasestr(name, "x509") ||
            strcasestr(name, "BSSL")) {
            NSLog(@"[NetLogger]   sym[%u]: %s (type=0x%x val=0x%llx)",
                  i, name, symtab[i].n_type, (unsigned long long)symtab[i].n_value);
            found++;
        }
    }
    if (found == 0) {
        NSLog(@"[NetLogger] No SSL/TLS/BoringSSL symbols found — binary fully stripped");
    }
}

// ── Install hooks khi tìm được symbols ──
static BOOL g_boringSSLHooked = NO;

static void installBoringSSLHooks(void *ssl_write, void *ssl_read, void *ssl_alpn) {
    if (g_boringSSLHooked) return;

    NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";

    if (ssl_write && ssl_read) {
        MSHookFunction(ssl_write, (void *)hook_boring_SSL_write, (void **)&orig_boring_SSL_write);
        MSHookFunction(ssl_read,  (void *)hook_boring_SSL_read,  (void **)&orig_boring_SSL_read);
        g_boringSSLHooked = YES;
        NSLog(@"[NetLogger] BoringSSL SSL_write/SSL_read hooks installed!");
    }

    if (ssl_alpn) {
        MSHookFunction(ssl_alpn, (void *)hook_boring_SSL_CTX_set_alpn_protos, (void **)&orig_boring_SSL_CTX_set_alpn_protos);
        NSLog(@"[NetLogger] BoringSSL ALPN hook installed — forcing HTTP/1.1");
    }

    // Diagnostic vào log file — encode status in URL để user thấy trong UI
    NSDictionary *diag = @{
        @"id": [[NSUUID UUID] UUIDString],
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"method": @"DIAGNOSTIC",
        @"url": [NSString stringWithFormat:@"diagnostic://boringssl/%@/w=%s/r=%s/a=%s",
            app,
            ssl_write ? "OK" : "MISS",
            ssl_read ? "OK" : "MISS",
            ssl_alpn ? "OK" : "MISS"],
        @"status": @(ssl_write && ssl_read ? 200 : 0),
        @"app": app,
        @"source": [NSString stringWithFormat:@"BoringSSL: write=%s read=%s alpn=%s",
            ssl_write ? "OK" : "MISS", ssl_read ? "OK" : "MISS", ssl_alpn ? "OK" : "MISS"],
    };
    NSData *jd = [NSJSONSerialization dataWithJSONObject:diag options:0 error:nil];
    if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
}

// ── Scan single image for BoringSSL and hook ──
static BOOL tryHookBoringSSLInImageIndex(uint32_t imageIndex) {
    const char *name = _dyld_get_image_name(imageIndex);
    if (!name) return NO;

    void *ssl_write = NULL, *ssl_read = NULL, *ssl_alpn = NULL;
    findBoringSymbols(imageIndex, name, &ssl_write, &ssl_read, &ssl_alpn);

    if (ssl_write && ssl_read) {
        installBoringSSLHooks(ssl_write, ssl_read, ssl_alpn);
        return YES;
    }
    return NO;
}

// ── dyld callback: hook Flutter.framework khi nó load (có thể sau %ctor) ──
static void onImageAdded(const struct mach_header *mh, intptr_t vmaddr_slide) {
    if (g_boringSSLHooked) return;

    uint32_t imageCount = _dyld_image_count();
    for (uint32_t i = 0; i < imageCount; i++) {
        if ((const struct mach_header *)_dyld_get_image_header(i) != mh) continue;

        const char *name = _dyld_get_image_name(i);
        if (!name) return;
        // Chỉ quan tâm app frameworks, không phải system
        if (strstr(name, "/usr/lib/") || strstr(name, "/System/Library/")) return;

        NSLog(@"[NetLogger] dyld callback: image #%u loaded: %s", i, name);

        if (tryHookBoringSSLInImageIndex(i)) {
            NSLog(@"[NetLogger] BoringSSL hooked via dyld callback for: %s", name);
        }
        return;
    }
}

static void hookBoringSSL(void) {
    uint32_t imageCount = _dyld_image_count();
    uint32_t flutterImageIndex = UINT32_MAX;

    // ── Bước 1: Tìm trong Flutter.framework ──
    for (uint32_t i = 0; i < imageCount; i++) {
        const char *name = _dyld_get_image_name(i);
        if (!name || !strstr(name, "Flutter.framework/Flutter")) continue;

        NSLog(@"[NetLogger] Found Flutter.framework at image #%u: %s", i, name);
        flutterImageIndex = i;
        if (tryHookBoringSSLInImageIndex(i)) return;
        break;
    }

    // ── Bước 2: Nếu chưa tìm được, scan tất cả non-system libraries ──
    if (!g_boringSSLHooked) {
        NSLog(@"[NetLogger] Scanning all non-system libraries for BoringSSL...");
        for (uint32_t i = 0; i < imageCount; i++) {
            const char *name = _dyld_get_image_name(i);
            if (!name) continue;
            if (strstr(name, "/usr/lib/") || strstr(name, "/System/Library/")) continue;
            if (strstr(name, "Flutter.framework")) continue;

            if (tryHookBoringSSLInImageIndex(i)) return;
        }
    }

    // ── Bước 3: Nếu vẫn chưa tìm được, dump symbols để debug ──
    if (!g_boringSSLHooked) {
        if (flutterImageIndex != UINT32_MAX) {
            NSLog(@"[NetLogger] BoringSSL symbols NOT found in Flutter.framework — dumping available symbols...");
            logSSLSymbolsInImage(flutterImageIndex);
        } else {
            NSLog(@"[NetLogger] Flutter.framework NOT loaded yet — registering dyld callback");
        }

        // Ghi diagnostic MISS
        installBoringSSLHooks(NULL, NULL, NULL);

        // ── Bước 4: Đăng ký dyld callback để bắt late-loaded frameworks ──
        _dyld_register_func_for_add_image(onImageAdded);
        NSLog(@"[NetLogger] Registered _dyld_register_func_for_add_image for late BoringSSL detection");
    }
}

// ---------------------------------------------------------------------------
// BSD Socket Interception (TCP/UDP - Transport Layer)
// ---------------------------------------------------------------------------

// Socket address map: fd -> "ip:port"
static NSMutableDictionary *_socketAddrMap = nil;
// Rate limiter
static int _socketLogCount = 0;
static CFAbsoluteTime _socketLogWindowStart = 0;
#define SOCKET_LOG_MAX_PER_SEC 50
#define SOCKET_PAYLOAD_MAX 512

static BOOL socketRateLimitOK(void) {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - _socketLogWindowStart >= 1.0) {
        _socketLogWindowStart = now;
        _socketLogCount = 0;
    }
    if (_socketLogCount >= SOCKET_LOG_MAX_PER_SEC) return NO;
    _socketLogCount++;
    return YES;
}

static NSString *hexDump(const void *buf, size_t len) {
    if (!buf || len == 0) return @"";
    size_t cap = MIN(len, (size_t)SOCKET_PAYLOAD_MAX);
    NSMutableString *hex = [NSMutableString stringWithCapacity:cap * 3];
    const unsigned char *bytes = (const unsigned char *)buf;
    for (size_t i = 0; i < cap; i++) {
        [hex appendFormat:@"%02x ", bytes[i]];
    }
    if (len > cap) [hex appendString:@"..."];
    return hex;
}

static NSString *asciiPreview(const void *buf, size_t len) {
    if (!buf || len == 0) return @"";
    size_t cap = MIN(len, (size_t)SOCKET_PAYLOAD_MAX);
    NSMutableString *ascii = [NSMutableString stringWithCapacity:cap];
    const unsigned char *bytes = (const unsigned char *)buf;
    for (size_t i = 0; i < cap; i++) {
        [ascii appendFormat:@"%c", (bytes[i] >= 32 && bytes[i] < 127) ? bytes[i] : '.'];
    }
    return ascii;
}

static NSString *extractAddress(const struct sockaddr *addr) {
    if (!addr) return @"unknown";
    char ipStr[INET6_ADDRSTRLEN] = {0};
    uint16_t port = 0;
    if (addr->sa_family == AF_INET) {
        const struct sockaddr_in *sin = (const struct sockaddr_in *)addr;
        inet_ntop(AF_INET, &sin->sin_addr, ipStr, sizeof(ipStr));
        port = ntohs(sin->sin_port);
    } else if (addr->sa_family == AF_INET6) {
        const struct sockaddr_in6 *sin6 = (const struct sockaddr_in6 *)addr;
        inet_ntop(AF_INET6, &sin6->sin6_addr, ipStr, sizeof(ipStr));
        port = ntohs(sin6->sin6_port);
    } else {
        return @"unknown";
    }
    return [NSString stringWithFormat:@"%s:%d", ipStr, port];
}


static NSString *getSocketType(int fd) {
    int type = 0;
    socklen_t len = sizeof(type);
    if (getsockopt(fd, SOL_SOCKET, SO_TYPE, &type, &len) == 0) {
        if (type == SOCK_DGRAM) return @"UDP";
    }
    return @"TCP";
}

static NSString *getRemoteAddr(int fd) {
    if (!_socketAddrMap) return @"unknown";
    NSString *addr = _socketAddrMap[@(fd)];
    return addr ?: @"unknown";
}

static void logSocketEvent(NSString *method, NSString *addr, NSString *proto, const void *buf, size_t len) {
    if (!isAppEnabled() || !isSocketCaptureEnabled()) return;
    if (!socketRateLimitOK()) return;
    
    NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *url = [NSString stringWithFormat:@"%@://%@", [proto lowercaseString], addr];
    NSString *hex = hexDump(buf, len);
    NSString *ascii = asciiPreview(buf, len);
    
    NSDictionary *dict = @{
        @"id": [[NSUUID UUID] UUIDString],
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"method": method,
        @"url": url,
        @"status": @(0),
        @"app": app,
        @"source": @"BSD-Socket",
        @"duration_ms": @(0),
        @"req_body": hex,
        @"res_body": ascii,
        @"socket_bytes": @(len)
    };
    
    NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
}

// 1. Hook connect()
static int (*orig_connect)(int, const struct sockaddr *, socklen_t);
static int hook_connect(int fd, const struct sockaddr *addr, socklen_t addrlen) {
    if (isAppEnabled() && isSocketCaptureEnabled() && addr && (addr->sa_family == AF_INET || addr->sa_family == AF_INET6)) {
        NSString *remote = extractAddress(addr);
        if (!_socketAddrMap) _socketAddrMap = [NSMutableDictionary dictionary];
        _socketAddrMap[@(fd)] = remote;
        
        NSString *proto = getSocketType(fd);
        NSString *method = [NSString stringWithFormat:@"%@-CONNECT", proto];
        logSocketEvent(method, remote, proto, NULL, 0);
    }
    return orig_connect(fd, addr, addrlen);
}

// 2. Hook send() - TCP outbound
static ssize_t (*orig_send)(int, const void *, size_t, int);
static ssize_t hook_send(int fd, const void *buf, size_t len, int flags) {
    ssize_t ret = orig_send(fd, buf, len, flags);
    if (ret > 0 && isAppEnabled() && isSocketCaptureEnabled() && buf) {
        NSString *proto = getSocketType(fd);
        NSString *method = [NSString stringWithFormat:@"%@-TX", proto];
        logSocketEvent(method, getRemoteAddr(fd), proto, buf, (size_t)ret);
    }
    return ret;
}

// 3. Hook recv() - TCP inbound
static ssize_t (*orig_recv)(int, void *, size_t, int);
static ssize_t hook_recv(int fd, void *buf, size_t len, int flags) {
    ssize_t ret = orig_recv(fd, buf, len, flags);
    if (ret > 0 && isAppEnabled() && isSocketCaptureEnabled() && buf) {
        NSString *proto = getSocketType(fd);
        NSString *method = [NSString stringWithFormat:@"%@-RX", proto];
        logSocketEvent(method, getRemoteAddr(fd), proto, buf, (size_t)ret);
    }
    return ret;
}

// 4. Hook sendto() - UDP outbound
static ssize_t (*orig_sendto)(int, const void *, size_t, int, const struct sockaddr *, socklen_t);
static ssize_t hook_sendto(int fd, const void *buf, size_t len, int flags, const struct sockaddr *dest, socklen_t destlen) {
    ssize_t ret = orig_sendto(fd, buf, len, flags, dest, destlen);
    if (ret > 0 && isAppEnabled() && isSocketCaptureEnabled() && buf) {
        NSString *addr = dest ? extractAddress(dest) : getRemoteAddr(fd);
        logSocketEvent(@"UDP-TX", addr, @"UDP", buf, (size_t)ret);
    }
    return ret;
}

// 5. Hook recvfrom() - UDP inbound
static ssize_t (*orig_recvfrom)(int, void *, size_t, int, struct sockaddr *, socklen_t *);
static ssize_t hook_recvfrom(int fd, void *buf, size_t len, int flags, struct sockaddr *src, socklen_t *srclen) {
    ssize_t ret = orig_recvfrom(fd, buf, len, flags, src, srclen);
    if (ret > 0 && isAppEnabled() && isSocketCaptureEnabled() && buf) {
        NSString *addr = (src && srclen && *srclen > 0) ? extractAddress(src) : getRemoteAddr(fd);
        logSocketEvent(@"UDP-RX", addr, @"UDP", buf, (size_t)ret);
    }
    return ret;
}

// ---------------------------------------------------------------------------
// WebSocket Interception (Real-time WSS)
// ---------------------------------------------------------------------------

@interface NSURLSessionWebSocketMessage (Hooks)
@property (nonatomic, readwrite, copy) NSData *data;
@property (nonatomic, readwrite, copy) NSString *string;
@property (nonatomic, readwrite, assign) NSInteger type;
@end

static void logWebSocketMessage(NSURLSessionTask *task, NSURLSessionWebSocketMessage *message, BOOL isOutbound) {
    if (!isAppEnabled() || !message) return;
    
    NSString *app = [[NSBundle mainBundle] bundleIdentifier] ?: @"unknown";
    NSString *payloadStr = @"";
    
    // NSURLSessionWebSocketMessageTypeString = 1, Data = 0
    if (message.type == 1 && message.string) {
        payloadStr = message.string;
    } else if (message.type == 0 && message.data) {
        payloadStr = [[NSString alloc] initWithData:message.data encoding:NSUTF8StringEncoding];
        if (!payloadStr) payloadStr = [NSString stringWithFormat:@"[Binary Data: %ld bytes]", (long)message.data.length];
    }
    
    NSString *url = task.currentRequest.URL.absoluteString ?: @"wss://[Unknown-Socket]";
    url = [NSString stringWithFormat:@"[%@] %@", isOutbound ? @"TX" : @"RX", url];

    NSDictionary *dict = @{
        @"id": [[NSUUID UUID] UUIDString],
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"url": url,
        @"status": @(101), // HTTP 101 Switching Protocols
        @"method": isOutbound ? @"WSS-TX" : @"WSS-RX",
        @"app": app,
        @"source": @"WebSocket",
        @"duration_ms": @(0),
        @"req_body": isOutbound ? payloadStr : @"",
        @"res_body": isOutbound ? @"" : payloadStr
    };
    
    NSData *jd = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
    if (jd) appendLine([[NSString alloc] initWithData:jd encoding:NSUTF8StringEncoding]);
}

%hook NSURLSessionWebSocketTask

- (void)sendMessage:(NSURLSessionWebSocketMessage *)message completionHandler:(void (^)(NSError * error))completionHandler {
    logWebSocketMessage(self, message, YES);
    %orig;
}

- (void)receiveMessageWithCompletionHandler:(void (^)(NSURLSessionWebSocketMessage * message, NSError * error))completionHandler {
    void (^wrapped)(NSURLSessionWebSocketMessage *, NSError *) = ^(NSURLSessionWebSocketMessage *msg, NSError *err) {
        if (msg && !err) {
            logWebSocketMessage(self, msg, NO);
        }
        if (completionHandler) {
            completionHandler(msg, err);
        }
    };
    %orig(wrapped);
}

%end

// ---------------------------------------------------------------------------
// NSURLSession hooks (for default and shared session methods)
// ---------------------------------------------------------------------------

%hook NSURLSession

// ── Completion-handler-based sessions (shared session, simple calls) ─────────
- (NSURLSessionDataTask *)dataTaskWithRequest:(NSURLRequest *)request
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

    // Settings app (com.apple.Preferences) là đặc biệt: preference bundle chạy bên trong nó,
    // nên user có thể bật masterOn + thêm Settings vào selectedApps SAU KHI process đã khởi động.
    // → Luôn đăng ký hooks cho Settings, dùng isAppEnabled() runtime check để gate logging.
    BOOL isSettingsApp = [bid isEqualToString:@"com.apple.Preferences"];

    if ((masterOn && thisApp) || isSettingsApp) {
        if (thisApp) {
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
        }

        // Đăng ký toàn cục NSURLProtocol
        [NSURLProtocol registerClass:[NLURLProtocol class]];
        
        // MSHookFunction cho các hàm C-Level API
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        MSHookFunction((void *)SSLWrite, (void *)hook_SSLWrite, (void **)&orig_SSLWrite);
        MSHookFunction((void *)SSLRead, (void *)hook_SSLRead, (void **)&orig_SSLRead);
#pragma clang diagnostic pop

        // BoringSSL Hooks (Flutter / Dart apps)
        hookBoringSSL();

        // BSD Socket Hooks (TCP/UDP Transport Layer)
        // CHỈ hook khi user BẬT toggle — tránh Anti-Cheat game Unity/Garena phát hiện
        // hàm connect/send/recv bị patch prologue → SIGILL crash
        // SKIP cho Flutter apps: send()/recv() là syscall wrappers cực ngắn,
        // ellekit không đủ chỗ patch prologue → SIGTRAP crash.
        // Flutter traffic đã được capture qua BoringSSL hooks ở trên.
        if ([prefs[@"socketCaptureEnabled"] boolValue] && !g_boringSSLHooked) {
            MSHookFunction((void *)connect, (void *)hook_connect, (void **)&orig_connect);
            MSHookFunction((void *)send, (void *)hook_send, (void **)&orig_send);
            MSHookFunction((void *)recv, (void *)hook_recv, (void **)&orig_recv);
            MSHookFunction((void *)sendto, (void *)hook_sendto, (void **)&orig_sendto);
            MSHookFunction((void *)recvfrom, (void *)hook_recvfrom, (void **)&orig_recvfrom);
            NSLog(@"[NetLogger] BSD Socket hooks ENABLED for %@", bid);
        } else if ([prefs[@"socketCaptureEnabled"] boolValue] && g_boringSSLHooked) {
            NSLog(@"[NetLogger] BSD Socket hooks SKIPPED for Flutter app %@ (BoringSSL hooks active, send/recv patch unsafe)", bid);
        }
        
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
