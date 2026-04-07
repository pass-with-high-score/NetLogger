#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// Force-load AltList framework so ATLApplicationListMultiSelectionController
// is available when Preferences.app looks it up by class name from the plist.
__attribute__((constructor)) static void loadAltList() {
    // Rootless (Dopamine) path first, then rootful fallback
    if (!dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY | RTLD_GLOBAL)) {
        dlopen("/Library/Frameworks/AltList.framework/AltList", RTLD_LAZY | RTLD_GLOBAL);
    }
}

#define LOG_PATH @"/var/tmp/com.minh.netlogger.logs.txt"

// ---------------------------------------------------------------------------
#pragma mark - Log Viewer
// ---------------------------------------------------------------------------

@interface NetLoggerLogViewerController : PSListController
@property (nonatomic, strong) UITextView *logTextView;
@end

@implementation NetLoggerLogViewerController

- (NSArray *)specifiers {
    // We don't use PSListController specifiers — returning empty list
    // so the underlying tableView is empty and our textView sits on top.
    if (!_specifiers) _specifiers = [NSMutableArray array];
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Network Logs";

    // Full-screen text view over the (empty) tableView
    self.logTextView = [[UITextView alloc] initWithFrame:self.view.bounds];
    self.logTextView.autoresizingMask =
        UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.logTextView.editable = NO;
    self.logTextView.font = [UIFont fontWithName:@"Menlo" size:11] ?:
                            [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
    self.logTextView.textContainerInset = UIEdgeInsetsMake(12, 12, 12, 12);
    [self.view addSubview:self.logTextView];

    // Toolbar: Refresh | spacer | Clear
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(reloadLogs)];
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"Clear" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItems = @[clearBtn, refreshBtn];

    [self reloadLogs];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLogs];
}

- (void)reloadLogs {
    NSString *content = [NSString stringWithContentsOfFile:LOG_PATH
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (content.length == 0) {
        self.logTextView.text = @"No logs yet.\n\nMake sure:\n"
            @"• NetLogger is enabled\n"
            @"• At least one app is selected\n"
            @"• The selected app has made network requests";
        return;
    }
    self.logTextView.text = content;
    // Scroll to bottom to show latest entry
    dispatch_async(dispatch_get_main_queue(), ^{
        NSRange bottom = NSMakeRange(content.length > 0 ? content.length - 1 : 0, 1);
        [self.logTextView scrollRangeToVisible:bottom];
    });
}

- (void)clearLog {
    UIAlertController *alert = [UIAlertController
        alertControllerWithTitle:@"Clear Logs"
        message:@"Delete all captured network logs?"
        preferredStyle:UIAlertControllerStyleAlert];

    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
        style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Clear"
        style:UIAlertActionStyleDestructive handler:^(UIAlertAction *_) {
            [@"" writeToFile:LOG_PATH atomically:YES encoding:NSUTF8StringEncoding error:nil];
            [self reloadLogs];
        }]];

    [self presentViewController:alert animated:YES completion:nil];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Main Settings Controller
// ---------------------------------------------------------------------------

@interface NetLoggerPreferencesListController : PSListController
@end

@implementation NetLoggerPreferencesListController

- (NSArray *)specifiers {
    if (!_specifiers)
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    return _specifiers;
}

// Called whenever the user changes any setting — write a /var/tmp mirror so
// sandboxed app processes can read the current state without cfprefsd issues.
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [self syncSettingsFile];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self syncSettingsFile]; // also sync on back navigation
}

- (void)syncSettingsFile {
    // Read current values from cfprefsd
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));

    NSMutableDictionary *settings = [NSMutableDictionary dictionary];

    CFPropertyListRef en = CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.minh.netlogger"));
    if (en) { settings[@"enabled"] = (__bridge_transfer id)en; }

    CFPropertyListRef apps = CFPreferencesCopyAppValue(CFSTR("selectedApps"), CFSTR("com.minh.netlogger"));
    if (apps) { settings[@"selectedApps"] = (__bridge_transfer id)apps; }

    NSString *path = @"/var/tmp/com.minh.netlogger.settings.plist";
    [settings writeToFile:path atomically:YES];

    // Make it world-readable
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)}
                                     ofItemAtPath:path error:nil];
}

@end
