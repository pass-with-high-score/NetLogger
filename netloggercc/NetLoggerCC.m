#import "NetLoggerCC.h"
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>

@implementation NetLoggerCC

- (UIImage *)iconGlyph {
    return [UIImage imageNamed:@"icon" inBundle:[NSBundle bundleForClass:[self class]] compatibleWithTraitCollection:nil];
}

- (UIColor *)selectedColor {
    return [UIColor systemGreenColor];
}

- (BOOL)isSelected {
    NSString *path = @"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist";
    NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:path];
    if (dict && dict[@"enabled"]) {
        return [dict[@"enabled"] boolValue];
    }
    return NO;
}

- (void)setSelected:(BOOL)selected {
    [super setSelected:selected];
    
    NSString *path = @"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist";
    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:path] ?: [NSMutableDictionary dictionary];
    dict[@"enabled"] = @(selected);
    [dict writeToFile:path atomically:YES];
    
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions : @(0644)} ofItemAtPath:path error:nil];
    
    // Make CFPreferences aware
    CFPreferencesSetAppValue(CFSTR("enabled"), (selected ? kCFBooleanTrue : kCFBooleanFalse), CFSTR("com.minh.netlogger"));
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));
    
    // Notify Settings app to reload
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(), CFSTR("com.minh.netlogger/ReloadPrefs"), NULL, NULL, YES);
}

@end
