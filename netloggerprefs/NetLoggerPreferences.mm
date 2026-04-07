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

@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(id)arg1;
@property (nonatomic, readonly) NSURL *dataContainerURL;
@end
// ---------------------------------------------------------------------------
#pragma mark - Log Viewer
// ---------------------------------------------------------------------------

#import "NLLogDetailViewController.h"

@interface NetLoggerLogViewerController : PSViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) UITableView *tableView;
@property (nonatomic, strong) NSMutableArray<NLLogEntry *> *logs;
@end

@implementation NetLoggerLogViewerController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Network Logs";
    self.logs = [NSMutableArray array];

    self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.tableView.delegate = self;
    self.tableView.dataSource = self;
    [self.view addSubview:self.tableView];

    // Toolbar: Refresh | spacer | Clear
    UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemRefresh
        target:self action:@selector(reloadLogs)];
    UIBarButtonItem *clearBtn = [[UIBarButtonItem alloc]
        initWithTitle:@"Clear" style:UIBarButtonItemStylePlain
        target:self action:@selector(clearLog)];
    self.navigationItem.rightBarButtonItems = @[clearBtn, refreshBtn];

    [self.tableView registerClass:[UITableViewCell class] forCellReuseIdentifier:@"LogCell"];
    self.tableView.rowHeight = 56;

    [self reloadLogs];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadLogs];
}

- (void)reloadLogs {
    [self.logs removeAllObjects];
    
    NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"];
    NSArray *selectedApps = prefs[@"selectedApps"];
    
    for (NSString *bundleID in selectedApps) {
        if (!bundleID || bundleID.length == 0) continue;
        
        LSApplicationProxy *proxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bundleID];
        if (!proxy || !proxy.dataContainerURL) continue;

        NSString *cachesPath = [[proxy.dataContainerURL path] stringByAppendingPathComponent:@"Library/Caches"];
        NSString *logPath = [cachesPath stringByAppendingPathComponent:@"com.minh.netlogger.logs.txt"];
        
        NSString *content = [NSString stringWithContentsOfFile:logPath encoding:NSUTF8StringEncoding error:nil];
        if (!content || content.length == 0) continue;
        
        NSArray *lines = [content componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]];
        for (NSString *line in lines) {
            if (line.length == 0) continue;
            NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
            if (!data) continue;
            
            NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if ([dict isKindOfClass:[NSDictionary class]]) {
                NLLogEntry *entry = [[NLLogEntry alloc] initWithDictionary:dict];
                [self.logs addObject:entry];
            }
        }
    }
    
    [self.logs sortUsingComparator:^NSComparisonResult(NLLogEntry *a, NLLogEntry *b) {
        if (a.timestamp < b.timestamp) return NSOrderedAscending;
        else if (a.timestamp > b.timestamp) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    
    [self.tableView reloadData];
    
    // Scroll to bottom
    if (self.logs.count > 0) {
        dispatch_async(dispatch_get_main_queue(), ^{
            NSIndexPath *ip = [NSIndexPath indexPathForRow:self.logs.count - 1 inSection:0];
            [self.tableView scrollToRowAtIndexPath:ip atScrollPosition:UITableViewScrollPositionBottom animated:NO];
        });
    }
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
            NSDictionary *prefs = [NSDictionary dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"];
            NSArray *selectedApps = prefs[@"selectedApps"];
            for (NSString *bundleID in selectedApps) {
                LSApplicationProxy *proxy = [NSClassFromString(@"LSApplicationProxy") applicationProxyForIdentifier:bundleID];
                if (!proxy || !proxy.dataContainerURL) continue;
                NSString *cachesPath = [[proxy.dataContainerURL path] stringByAppendingPathComponent:@"Library/Caches"];
                NSString *logPath = [cachesPath stringByAppendingPathComponent:@"com.minh.netlogger.logs.txt"];
                [@"" writeToFile:logPath atomically:YES encoding:NSUTF8StringEncoding error:nil];
            }
            [self reloadLogs];
        }]];

    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Table View Data Source & Delegate

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    if (self.logs.count == 0) {
        UILabel *emptyLabel = [[UILabel alloc] initWithFrame:tableView.bounds];
        emptyLabel.text = @"No logs yet.\n\nMake sure:\n• NetLogger is enabled\n• At least one app is selected\n• Traffic occurred";
        emptyLabel.numberOfLines = 0;
        emptyLabel.textAlignment = NSTextAlignmentCenter;
        emptyLabel.textColor = [UIColor grayColor];
        tableView.backgroundView = emptyLabel;
    } else {
        tableView.backgroundView = nil;
    }
    return self.logs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:@"LogCell" forIndexPath:indexPath];
    if (cell.detailTextLabel == nil) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"LogCell"];
    }
    
    NLLogEntry *entry = self.logs[indexPath.row];
    
    cell.textLabel.text = [NSString stringWithFormat:@"[%@] %@", entry.method, entry.url];
    cell.textLabel.font = [UIFont boldSystemFontOfSize:14];
    cell.textLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    
    NSDateFormatter *df = [[NSDateFormatter alloc] init];
    df.dateFormat = @"HH:mm:ss";
    NSDate *d = [NSDate dateWithTimeIntervalSince1970:entry.timestamp];
    
    cell.detailTextLabel.text = [NSString stringWithFormat:@"Status: %ld | Time: %@ | App: %@", (long)entry.status, [df stringFromDate:d], entry.app ?: @"?"];
    cell.detailTextLabel.textColor = [UIColor grayColor];
    
    if (entry.status >= 200 && entry.status < 300) {
        // success -> no special color for text, or maybe green status?
    } else if (entry.status >= 400 || entry.status == 0) {
        cell.textLabel.textColor = [UIColor systemRedColor];
    } else {
        if (@available(iOS 13.0, *)) {
            cell.textLabel.textColor = [UIColor labelColor];
        } else {
            cell.textLabel.textColor = [UIColor blackColor];
        }
    }
    
    if ([entry.method isEqualToString:@"DIAGNOSTIC"]) {
        cell.textLabel.textColor = [UIColor systemBlueColor];
    }
    
    return cell;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    NLLogEntry *entry = self.logs[indexPath.row];
    NLLogDetailViewController *vc = [[NLLogDetailViewController alloc] init];
    vc.logEntry = entry;
    [self.navigationController pushViewController:vc animated:YES];
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

    NSString *path = @"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist";
    [settings writeToFile:path atomically:YES];

    // Make it world-readable
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)}
                                     ofItemAtPath:path error:nil];
}

@end
