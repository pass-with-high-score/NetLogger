#import "NLURLProtocol.h"
#import "NLCommon.h"

static NSString *const NLProtocolHandledKey = @"NLProtocolHandledKey";

@interface NLURLProtocol ()
@property(nonatomic, strong) NSURLSessionDataTask *task;
@property(nonatomic, strong) NSMutableData *mutableData;
@property(nonatomic, strong) NSURLResponse *response;
@property(nonatomic, assign) CFAbsoluteTime startTime;
@property(nonatomic, assign) BOOL shouldBuffer;

- (void)handleResponse:(NSURLResponse *)response
     completionHandler:
         (void (^)(NSURLSessionResponseDisposition))completionHandler;
- (void)handleData:(NSData *)data;
- (void)handleCompleteWithError:(NSError *)error;
@end

// ── Shared Session Manager (Tránh tạo NSURLSession cho mỗi request gây cạn tài
// nguyên) ──
@interface NLSharedSessionManager : NSObject <NSURLSessionDataDelegate>
@property(nonatomic, strong) NSURLSession *session;
@property(nonatomic, strong)
    NSMutableDictionary<NSNumber *, NLURLProtocol *> *taskMap;
@property(nonatomic, strong) NSLock *lock;
+ (instancetype)sharedManager;
- (void)registerProtocol:(NLURLProtocol *)protocol
                 forTask:(NSURLSessionDataTask *)task;
- (void)unregisterProtocolForTask:(NSURLSessionDataTask *)task;
@end

@implementation NLSharedSessionManager

+ (instancetype)sharedManager {
  static NLSharedSessionManager *shared = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    shared = [[self alloc] init];
  });
  return shared;
}

- (instancetype)init {
  if (self = [super init]) {
    _taskMap = [NSMutableDictionary dictionary];
    _lock = [[NSLock alloc] init];

    NSURLSessionConfiguration *config =
        [NSURLSessionConfiguration defaultSessionConfiguration];
    NSOperationQueue *queue = [[NSOperationQueue alloc] init];
    queue.maxConcurrentOperationCount = 20; // Giới hạn concurrent operations
    _session = [NSURLSession sessionWithConfiguration:config
                                             delegate:self
                                        delegateQueue:queue];
  }
  return self;
}

- (void)registerProtocol:(NLURLProtocol *)protocol
                 forTask:(NSURLSessionDataTask *)task {
  [_lock lock];
  _taskMap[@(task.taskIdentifier)] = protocol;
  [_lock unlock];
}

- (void)unregisterProtocolForTask:(NSURLSessionDataTask *)task {
  [_lock lock];
  [_taskMap removeObjectForKey:@(task.taskIdentifier)];
  [_lock unlock];
}

- (void)URLSession:(NSURLSession *)session
              dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveResponse:(NSURLResponse *)response
     completionHandler:
         (void (^)(NSURLSessionResponseDisposition))completionHandler {
  [_lock lock];
  NLURLProtocol *p = _taskMap[@(dataTask.taskIdentifier)];
  [_lock unlock];
  if (p)
    [p handleResponse:response completionHandler:completionHandler];
  else
    completionHandler(NSURLSessionResponseAllow);
}

- (void)URLSession:(NSURLSession *)session
          dataTask:(NSURLSessionDataTask *)dataTask
    didReceiveData:(NSData *)data {
  [_lock lock];
  NLURLProtocol *p = _taskMap[@(dataTask.taskIdentifier)];
  [_lock unlock];
  [p handleData:data];
}

- (void)URLSession:(NSURLSession *)session
                    task:(NSURLSessionTask *)task
    didCompleteWithError:(NSError *)error {
  [_lock lock];
  NLURLProtocol *p = _taskMap[@(task.taskIdentifier)];
  [_lock unlock];
  [p handleCompleteWithError:error];
  [self unregisterProtocolForTask:(NSURLSessionDataTask *)task];
}

@end

@implementation NLURLProtocol

+ (BOOL)canInitWithRequest:(NSURLRequest *)request {
  if (!isAppEnabled())
    return NO;

  // Tránh vòng lặp vô tận (nếu request đã được protocol của chúng ta xử lý rồi)
  if ([NSURLProtocol propertyForKey:NLProtocolHandledKey inRequest:request]) {
    return NO;
  }

  NSString *scheme = [[request.URL scheme] lowercaseString];
  if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"]) {
    return YES;
  }
  return NO;
}

+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request {
  return request;
}

- (void)startLoading {
  NSMutableURLRequest *newRequest = [self.request mutableCopy];
  [NSURLProtocol setProperty:@YES
                      forKey:NLProtocolHandledKey
                   inRequest:newRequest];

  // ==========================================
  // BLACKLIST REJECT POLICY: Block request entirely
  // ==========================================
  NLBlacklistPolicy blPolicy = getBlacklistPolicy(newRequest.URL.host);
  if (blPolicy == NLPolicyReject) {
      [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorCancelled userInfo:@{
          NSLocalizedDescriptionKey: [NSString stringWithFormat:@"[NetLogger] Rejected by blacklist rule: %@", newRequest.URL.host]
      }]];
      return;
  }

  // ==========================================
  // ANTI-CACHE CỰC MẠNH: Dành riêng cho RevenueCat & Các SDK cứng đầu
  // ==========================================
  // Xóa sạch mọi kí hiệu ETag của RevenueCat để dụ Server nhả JSON 200 OK mới tinh
  if (isNoCachingEnabled()) {
      [newRequest setValue:nil forHTTPHeaderField:@"X-RevenueCat-ETag"];
      [newRequest setValue:nil forHTTPHeaderField:@"If-None-Match"];
      [newRequest setValue:nil forHTTPHeaderField:@"If-Modified-Since"];
      newRequest.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  }
  // ==========================================
  
  newRequest = applyMitmRequestRules(newRequest);

  self.startTime = CFAbsoluteTimeGetCurrent();
  self.mutableData = [NSMutableData data];

  self.task = [[NLSharedSessionManager sharedManager].session
      dataTaskWithRequest:newRequest];
  [[NLSharedSessionManager sharedManager] registerProtocol:self
                                                   forTask:self.task];
  [self.task resume];
}

- (void)stopLoading {
  if (self.task) {
    [self.task cancel];
    [[NLSharedSessionManager sharedManager]
        unregisterProtocolForTask:self.task];
    self.task = nil;
  }
}

- (void)handleResponse:(NSURLResponse *)response
     completionHandler:
         (void (^)(NSURLSessionResponseDisposition))completionHandler {
  NSURLResponse *modifiedResponse = applyMitmResponseRules(response, self.request);
  self.response = modifiedResponse;
  NSString *mime = [[modifiedResponse MIMEType] lowercaseString] ?: @"";
  if ([mime containsString:@"json"] || [mime containsString:@"text"] ||
      [mime containsString:@"xml"]) {
    self.shouldBuffer = YES;
  } else {
    self.shouldBuffer = NO;
  }

  [self.client URLProtocol:self
        didReceiveResponse:modifiedResponse
        cacheStoragePolicy:NSURLCacheStorageNotAllowed];
  completionHandler(NSURLSessionResponseAllow);
}

- (void)handleData:(NSData *)data {
  if (self.shouldBuffer) {
    [self.mutableData appendData:data];
  } else {
    [self.client URLProtocol:self didLoadData:data];
  }
}

- (void)handleCompleteWithError:(NSError *)error {
  if (error) {
    if (error.code != NSURLErrorCancelled) {
      [self.client URLProtocol:self didFailWithError:error];
    }
  } else {
    NSData *finalData = nil;
    if (self.shouldBuffer) {
      finalData = applyMitmRules(self.mutableData, self.request);
      if (finalData)
        [self.client URLProtocol:self didLoadData:finalData];
    }

    [self.client URLProtocolDidFinishLoading:self];

    double durationMs = (CFAbsoluteTimeGetCurrent() - self.startTime) * 1000.0;
    NSData *logData = self.shouldBuffer ? (finalData ?: self.mutableData) : nil;
    NSURLRequest *reqToLog = self.task.currentRequest ?: self.request;
    NSString *entry =
        buildEntry(reqToLog, logData, self.response, durationMs);
    if (entry) {
      appendLine(entry);
    }
  }
}

@end
