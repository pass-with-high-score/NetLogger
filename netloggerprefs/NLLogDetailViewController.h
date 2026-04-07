#import <UIKit/UIKit.h>

@interface NLLogEntry : NSObject
@property (nonatomic, copy) NSString *guid;
@property (nonatomic, assign) NSTimeInterval timestamp;
@property (nonatomic, copy) NSString *method;
@property (nonatomic, copy) NSString *url;
@property (nonatomic, assign) NSInteger status;
@property (nonatomic, copy) NSString *app;
@property (nonatomic, copy) NSDictionary *reqHeaders;
@property (nonatomic, copy) NSString *reqBodyBase64;
@property (nonatomic, copy) NSDictionary *resHeaders;
@property (nonatomic, copy) NSString *resBodyBase64;

- (instancetype)initWithDictionary:(NSDictionary *)dict;
@end

@interface NLLogDetailViewController : UIViewController
@property (nonatomic, strong) NLLogEntry *logEntry;
@end
