#ifndef NLLocalization_h
#define NLLocalization_h

#import <Foundation/Foundation.h>

static inline NSString *NLLocalizedString(NSString *key, NSString *fallback) {
    // Try rootless path first
    NSString *path = @"/var/jb/Library/PreferenceBundles/NetLoggerPreferences.bundle";
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) {
        // Fallback to rootful path
        path = @"/Library/PreferenceBundles/NetLoggerPreferences.bundle";
    }
    NSBundle *bundle = [NSBundle bundleWithPath:path];
    if (bundle) {
        return [bundle localizedStringForKey:key value:fallback table:@"Localizable"] ?: fallback;
    }
    return fallback;
}

#endif /* NLLocalization_h */