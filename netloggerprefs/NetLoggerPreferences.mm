#import <Preferences/PSListController.h>
#import <Preferences/PSSpecifier.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>

// Force-load AltList framework so ATLApplicationListMultiSelectionController
// is available when Preferences.app looks it up by class name from the plist.
__attribute__((constructor)) static void loadAltList() {
  // Rootless (Dopamine) path first, then rootful fallback
  if (!dlopen("/var/jb/Library/Frameworks/AltList.framework/AltList",
              RTLD_LAZY | RTLD_GLOBAL)) {
    dlopen("/Library/Frameworks/AltList.framework/AltList",
           RTLD_LAZY | RTLD_GLOBAL);
  }
}

@interface LSApplicationProxy : NSObject
+ (id)applicationProxyForIdentifier:(id)arg1;
@property(nonatomic, readonly) NSURL *dataContainerURL;
@end
// ---------------------------------------------------------------------------
#pragma mark - Log Viewer
// ---------------------------------------------------------------------------

#import "NLLogDetailViewController.h"

// ---------------------------------------------------------------------------
// Custom Log Cell
// ---------------------------------------------------------------------------

@interface NLLogCell : UITableViewCell
@property(nonatomic, strong) UILabel *methodBadge;
@property(nonatomic, strong) UILabel *statusBadge;
@property(nonatomic, strong) UILabel *hostLabel;
@property(nonatomic, strong) UILabel *pathLabel;
@property(nonatomic, strong) UILabel *metaLabel;
@end

@implementation NLLogCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

    // ── Method Badge (e.g. GET, POST) ──
    _methodBadge = [[UILabel alloc] init];
    _methodBadge.font = [UIFont monospacedSystemFontOfSize:10
                                                    weight:UIFontWeightBold];
    _methodBadge.textColor = [UIColor whiteColor];
    _methodBadge.textAlignment = NSTextAlignmentCenter;
    _methodBadge.layer.cornerRadius = 4;
    _methodBadge.clipsToBounds = YES;
    _methodBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_methodBadge];

    // ── Status Badge ──
    _statusBadge = [[UILabel alloc] init];
    _statusBadge.font = [UIFont monospacedSystemFontOfSize:11
                                                    weight:UIFontWeightBold];
    _statusBadge.textAlignment = NSTextAlignmentCenter;
    _statusBadge.layer.cornerRadius = 4;
    _statusBadge.clipsToBounds = YES;
    _statusBadge.translatesAutoresizingMaskIntoConstraints = NO;
    [self.contentView addSubview:_statusBadge];

    // ── Host Label ──
    _hostLabel = [[UILabel alloc] init];
    _hostLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _hostLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _hostLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    [self.contentView addSubview:_hostLabel];

    // ── Path Label ──
    _pathLabel = [[UILabel alloc] init];
    _pathLabel.font = [UIFont monospacedSystemFontOfSize:12
                                                  weight:UIFontWeightRegular];
    _pathLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _pathLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
    if (@available(iOS 13.0, *)) {
      _pathLabel.textColor = [UIColor secondaryLabelColor];
    } else {
      _pathLabel.textColor = [UIColor darkGrayColor];
    }
    [self.contentView addSubview:_pathLabel];

    // ── Meta Label (time, app) ──
    _metaLabel = [[UILabel alloc] init];
    _metaLabel.font = [UIFont systemFontOfSize:11];
    _metaLabel.translatesAutoresizingMaskIntoConstraints = NO;
    if (@available(iOS 13.0, *)) {
      _metaLabel.textColor = [UIColor tertiaryLabelColor];
    } else {
      _metaLabel.textColor = [UIColor lightGrayColor];
    }
    [self.contentView addSubview:_metaLabel];

    // ── Auto Layout ──

    // Method badge: fixed width, left aligned
    [NSLayoutConstraint activateConstraints:@[
      [_methodBadge.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:16],
      [_methodBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                             constant:10],
      [_methodBadge.widthAnchor constraintGreaterThanOrEqualToConstant:40],
      [_methodBadge.heightAnchor constraintEqualToConstant:20],

      // Status badge: right side
      [_statusBadge.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-8],
      [_statusBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor
                                             constant:10],
      [_statusBadge.widthAnchor constraintGreaterThanOrEqualToConstant:36],
      [_statusBadge.heightAnchor constraintEqualToConstant:20],

      // Host label: to the right of method badge
      [_hostLabel.leadingAnchor
          constraintEqualToAnchor:_methodBadge.trailingAnchor
                         constant:8],
      [_hostLabel.centerYAnchor
          constraintEqualToAnchor:_methodBadge.centerYAnchor],
      [_hostLabel.trailingAnchor
          constraintLessThanOrEqualToAnchor:_statusBadge.leadingAnchor
                                   constant:-8],

      // Path label: full width below
      [_pathLabel.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:16],
      [_pathLabel.topAnchor constraintEqualToAnchor:_methodBadge.bottomAnchor
                                           constant:4],
      [_pathLabel.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-36],

      // Meta label: bottom
      [_metaLabel.leadingAnchor
          constraintEqualToAnchor:self.contentView.leadingAnchor
                         constant:16],
      [_metaLabel.topAnchor constraintEqualToAnchor:_pathLabel.bottomAnchor
                                           constant:2],
      [_metaLabel.trailingAnchor
          constraintEqualToAnchor:self.contentView.trailingAnchor
                         constant:-36],
      [_metaLabel.bottomAnchor
          constraintEqualToAnchor:self.contentView.bottomAnchor
                         constant:-8],
    ]];
  }
  return self;
}

- (void)configureWithEntry:(NLLogEntry *)entry {
  // ── Method badge color ──
  NSString *m = entry.method ?: @"?";
  self.methodBadge.text = [NSString stringWithFormat:@" %@ ", m];

  UIColor *methodColor;
  if ([m isEqualToString:@"GET"])
    methodColor = [UIColor systemGreenColor];
  else if ([m isEqualToString:@"POST"])
    methodColor = [UIColor systemBlueColor];
  else if ([m isEqualToString:@"PUT"])
    methodColor = [UIColor systemOrangeColor];
  else if ([m isEqualToString:@"DELETE"])
    methodColor = [UIColor systemRedColor];
  else if ([m isEqualToString:@"PATCH"])
    methodColor = [UIColor systemPurpleColor];
  else if ([m isEqualToString:@"DIAGNOSTIC"])
    methodColor = [UIColor systemTealColor];
  else
    methodColor = [UIColor systemGrayColor];
  self.methodBadge.backgroundColor = methodColor;

  // ── Status badge ──
  NSInteger s = entry.status;
  self.statusBadge.text =
      (s > 0) ? [NSString stringWithFormat:@" %ld ", (long)s] : @" — ";

  UIColor *statusBg, *statusFg;
  if (s >= 200 && s < 300) {
    statusBg = [[UIColor systemGreenColor] colorWithAlphaComponent:0.15];
    statusFg = [UIColor systemGreenColor];
  } else if (s >= 300 && s < 400) {
    statusBg = [[UIColor systemOrangeColor] colorWithAlphaComponent:0.15];
    statusFg = [UIColor systemOrangeColor];
  } else if (s >= 400) {
    statusBg = [[UIColor systemRedColor] colorWithAlphaComponent:0.15];
    statusFg = [UIColor systemRedColor];
  } else {
    if (@available(iOS 13.0, *)) {
      statusBg = [UIColor tertiarySystemFillColor];
      statusFg = [UIColor secondaryLabelColor];
    } else {
      statusBg = [[UIColor grayColor] colorWithAlphaComponent:0.15];
      statusFg = [UIColor grayColor];
    }
  }
  self.statusBadge.backgroundColor = statusBg;
  self.statusBadge.textColor = statusFg;

  // ── Host & Path ──
  self.hostLabel.text = [entry hostFromURL];
  self.pathLabel.text = [entry pathFromURL];

  // ── Meta ──
  NSDateFormatter *df = [[NSDateFormatter alloc] init];
  df.dateFormat = @"HH:mm:ss";
  NSDate *d = [NSDate dateWithTimeIntervalSince1970:entry.timestamp];

  NSString *durText = @"—";
  if ([entry respondsToSelector:@selector(durationText)]) {
    durText = [entry durationText];
  }
  self.metaLabel.text =
      [NSString stringWithFormat:@"%@  •  %@  •  %@", [df stringFromDate:d],
                                 entry.app ?: @"?", durText];
}

@end

// ---------------------------------------------------------------------------
// Log Viewer Controller
// ---------------------------------------------------------------------------

@interface NetLoggerLogViewerController
    : PSViewController <UITableViewDelegate, UITableViewDataSource,
                        UISearchResultsUpdating, UISearchBarDelegate>
@property(nonatomic, strong) UITableView *tableView;
@property(nonatomic, strong) NSMutableArray<NLLogEntry *> *allLogs;
@property(nonatomic, strong) NSMutableArray<NLLogEntry *> *filteredLogs;
@property(nonatomic, strong) UISearchController *searchController;
@property(nonatomic, strong) NSTimer *autoRefreshTimer;
@property(nonatomic, assign) BOOL isAutoRefreshEnabled;
@property(nonatomic, strong) UIBarButtonItem *autoRefreshBtn;
@end

@implementation NetLoggerLogViewerController

- (void)loadView {
  [super loadView];
  self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];

  if (@available(iOS 13.0, *)) {
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];
  }

  // ── Table View ──
  self.tableView = [[UITableView alloc] initWithFrame:self.view.bounds
                                                style:UITableViewStylePlain];
  self.tableView.autoresizingMask =
      UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.tableView.delegate = self;
  self.tableView.dataSource = self;
  self.tableView.estimatedRowHeight = 72;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  [self.tableView registerClass:[NLLogCell class]
         forCellReuseIdentifier:@"NLLogCell"];
  if (@available(iOS 13.0, *)) {
    self.tableView.backgroundColor = [UIColor systemBackgroundColor];
  }
  [self.view addSubview:self.tableView];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Network Logs";
  self.allLogs = [NSMutableArray array];
  self.filteredLogs = [NSMutableArray array];

  // ── Search Controller ──
  self.searchController =
      [[UISearchController alloc] initWithSearchResultsController:nil];
  self.searchController.searchResultsUpdater = self;
  self.searchController.obscuresBackgroundDuringPresentation = NO;
  self.searchController.searchBar.placeholder =
      @"Filter by URL, method, app...";
  self.searchController.searchBar.delegate = self;
  self.searchController.searchBar.scopeButtonTitles =
      @[ @"All", @"2xx", @"3xx", @"4xx+", @"Err" ];
  self.navigationItem.searchController = self.searchController;
  self.navigationItem.hidesSearchBarWhenScrolling = YES;
  self.definesPresentationContext = YES;

  // ── Nav Bar Buttons ──
  self.autoRefreshBtn =
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"timer"]
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(toggleAutoRefresh)];

  UIBarButtonItem *refreshBtn = [[UIBarButtonItem alloc]
      initWithImage:[UIImage systemImageNamed:@"arrow.clockwise"]
              style:UIBarButtonItemStylePlain
             target:self
             action:@selector(reloadLogs)];

  UIBarButtonItem *clearBtn =
      [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                       style:UIBarButtonItemStylePlain
                                      target:self
                                      action:@selector(clearLog)];
  clearBtn.tintColor = [UIColor systemRedColor];

  self.navigationItem.rightBarButtonItems =
      @[ clearBtn, self.autoRefreshBtn, refreshBtn ];

  // ── Pull-to-Refresh ──
  UIRefreshControl *rc = [[UIRefreshControl alloc] init];
  [rc addTarget:self
                action:@selector(pullRefresh:)
      forControlEvents:UIControlEventValueChanged];
  self.tableView.refreshControl = rc;

  [self reloadLogs];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (self.autoRefreshTimer) {
    [self.autoRefreshTimer invalidate];
    self.autoRefreshTimer = nil;
  }
  self.isAutoRefreshEnabled = NO;
  self.autoRefreshBtn.tintColor = nil;
}

- (void)toggleAutoRefresh {
  self.isAutoRefreshEnabled = !self.isAutoRefreshEnabled;
  if (self.isAutoRefreshEnabled) {
    self.autoRefreshBtn.tintColor = [UIColor systemGreenColor];
    self.autoRefreshTimer =
        [NSTimer scheduledTimerWithTimeInterval:3.0
                                         target:self
                                       selector:@selector(reloadLogs)
                                       userInfo:nil
                                        repeats:YES];
  } else {
    self.autoRefreshBtn.tintColor = nil;
    [self.autoRefreshTimer invalidate];
    self.autoRefreshTimer = nil;
  }
}

// viewWillAppear intentionally does NOT reload to preserve scroll position
// User can pull-to-refresh or tap the refresh button instead.

- (void)pullRefresh:(UIRefreshControl *)rc {
  [self reloadLogs];
  [rc endRefreshing];
}

// ---------------------------------------------------------------------------
#pragma mark - Data Loading
// ---------------------------------------------------------------------------

- (void)reloadLogs {
  [self.allLogs removeAllObjects];

  NSDictionary *prefs = [NSDictionary
      dictionaryWithContentsOfFile:@"/var/jb/var/mobile/Library/Preferences/"
                                   @"com.minh.netlogger.settings.plist"];
  NSArray *selectedApps = prefs[@"selectedApps"];

  for (NSString *bundleID in selectedApps) {
    if (!bundleID || bundleID.length == 0)
      continue;

    NSString *logPath = nil;

    // Preference bundle chạy trong Settings.app → NSHomeDirectory() trả đúng
    // thư mục mà tweak đã ghi log. LSApplicationProxy.dataContainerURL trả nil
    // cho system app nên không dùng được.
    if ([bundleID isEqualToString:@"com.apple.Preferences"]) {
      logPath =
          [NSHomeDirectory() stringByAppendingPathComponent:
                                 @"Library/Caches/com.minh.netlogger.logs.txt"];
    } else {
      LSApplicationProxy *proxy = [NSClassFromString(@"LSApplicationProxy")
          applicationProxyForIdentifier:bundleID];
      if (!proxy || !proxy.dataContainerURL)
        continue;
      NSString *cachesPath = [[proxy.dataContainerURL path]
          stringByAppendingPathComponent:@"Library/Caches"];
      logPath = [cachesPath
          stringByAppendingPathComponent:@"com.minh.netlogger.logs.txt"];
    }

    NSString *content = [NSString stringWithContentsOfFile:logPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:nil];
    if (!content || content.length == 0)
      continue;

    NSArray *lines =
        [content componentsSeparatedByCharactersInSet:[NSCharacterSet
                                                          newlineCharacterSet]];
    for (NSString *line in lines) {
      if (line.length == 0)
        continue;
      NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
      if (!data)
        continue;

      NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data
                                                           options:0
                                                             error:nil];
      if ([dict isKindOfClass:[NSDictionary class]]) {
        NLLogEntry *entry = [[NLLogEntry alloc] initWithDictionary:dict];
        [self.allLogs addObject:entry];
      }
    }
  }

  // Sort newest last
  [self.allLogs
      sortUsingComparator:^NSComparisonResult(NLLogEntry *a, NLLogEntry *b) {
        if (a.timestamp < b.timestamp)
          return NSOrderedAscending;
        if (a.timestamp > b.timestamp)
          return NSOrderedDescending;
        return NSOrderedSame;
      }];

  [self applyFilter];
}

- (void)applyFilter {
  NSString *query = self.searchController.searchBar.text;
  NSInteger scope = self.searchController.searchBar.selectedScopeButtonIndex;

  NSMutableArray *results = [NSMutableArray array];
  NSString *lower = [query lowercaseString];

  for (NLLogEntry *e in self.allLogs) {
    // Scope Check
    // 0=All, 1=2xx, 2=3xx, 3=4xx+, 4=Err
    BOOL scopeMatch = YES;
    if (scope == 1) {
      scopeMatch = (e.status >= 200 && e.status < 300);
    } else if (scope == 2) {
      scopeMatch = (e.status >= 300 && e.status < 400);
    } else if (scope == 3) {
      scopeMatch = (e.status >= 400);
    } else if (scope == 4) {
      scopeMatch = (e.status == 0);
    }

    if (!scopeMatch)
      continue;

    // Text Check
    BOOL textMatch = YES;
    if (query.length > 0) {
      textMatch = ([e.url.lowercaseString containsString:lower] ||
                   [e.method.lowercaseString containsString:lower] ||
                   [e.app.lowercaseString containsString:lower]);
    }

    if (textMatch) {
      [results addObject:e];
    }
  }
  self.filteredLogs = results;

  [self.tableView reloadData];

  // Update title with count
  self.title = [NSString
      stringWithFormat:@"Logs (%lu)", (unsigned long)self.filteredLogs.count];
}

- (void)searchBar:(UISearchBar *)searchBar
    selectedScopeButtonIndexDidChange:(NSInteger)selectedScope {
  [self applyFilter];
}

// ---------------------------------------------------------------------------
#pragma mark - UISearchResultsUpdating
// ---------------------------------------------------------------------------

- (void)updateSearchResultsForSearchController:
    (UISearchController *)searchController {
  [self applyFilter];
}

// ---------------------------------------------------------------------------
#pragma mark - Clear Logs
// ---------------------------------------------------------------------------

- (void)clearLog {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Clear Logs"
                       message:@"Delete all captured network logs?"
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert
      addAction:
          [UIAlertAction
              actionWithTitle:@"Clear"
                        style:UIAlertActionStyleDestructive
                      handler:^(UIAlertAction *_) {
                        NSDictionary *prefs = [NSDictionary
                            dictionaryWithContentsOfFile:
                                @"/var/jb/var/mobile/Library/Preferences/"
                                @"com.minh.netlogger.settings.plist"];
                        NSArray *selectedApps = prefs[@"selectedApps"];
                        for (NSString *bundleID in selectedApps) {
                          NSString *logPath = nil;
                          if ([bundleID
                                  isEqualToString:@"com.apple.Preferences"]) {
                            logPath = [NSHomeDirectory()
                                stringByAppendingPathComponent:
                                    @"Library/Caches/"
                                    @"com.minh.netlogger.logs.txt"];
                          } else {
                            LSApplicationProxy *proxy =
                                [NSClassFromString(@"LSApplicationProxy")
                                    applicationProxyForIdentifier:bundleID];
                            if (!proxy || !proxy.dataContainerURL)
                              continue;
                            NSString *cachesPath =
                                [[proxy.dataContainerURL path]
                                    stringByAppendingPathComponent:
                                        @"Library/Caches"];
                            logPath =
                                [cachesPath stringByAppendingPathComponent:
                                                @"com.minh.netlogger.logs.txt"];
                          }
                          [@"" writeToFile:logPath
                                atomically:YES
                                  encoding:NSUTF8StringEncoding
                                     error:nil];
                        }
                        [self reloadLogs];
                      }]];

  [self presentViewController:alert animated:YES completion:nil];
}

// ---------------------------------------------------------------------------
#pragma mark - Table View
// ---------------------------------------------------------------------------

- (NSInteger)tableView:(UITableView *)tableView
    numberOfRowsInSection:(NSInteger)section {
  if (self.filteredLogs.count == 0) {
    // ── Premium empty state ──
    UIView *emptyView = [[UIView alloc] initWithFrame:tableView.bounds];

    UIImageView *icon = [[UIImageView alloc]
        initWithImage:
            [UIImage systemImageNamed:@"antenna.radiowaves.left.and.right"]];
    icon.tintColor = [UIColor systemGray3Color];
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    [emptyView addSubview:icon];

    UILabel *titleLbl = [[UILabel alloc] init];
    titleLbl.text = @"No Network Logs";
    titleLbl.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
    if (@available(iOS 13.0, *))
      titleLbl.textColor = [UIColor secondaryLabelColor];
    titleLbl.textAlignment = NSTextAlignmentCenter;
    titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [emptyView addSubview:titleLbl];

    UILabel *subtitleLbl = [[UILabel alloc] init];
    subtitleLbl.text =
        @"Enable NetLogger and select apps\nto start capturing traffic.";
    subtitleLbl.font = [UIFont systemFontOfSize:14];
    subtitleLbl.numberOfLines = 0;
    if (@available(iOS 13.0, *))
      subtitleLbl.textColor = [UIColor tertiaryLabelColor];
    subtitleLbl.textAlignment = NSTextAlignmentCenter;
    subtitleLbl.translatesAutoresizingMaskIntoConstraints = NO;
    [emptyView addSubview:subtitleLbl];

    [NSLayoutConstraint activateConstraints:@[
      [icon.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
      [icon.centerYAnchor constraintEqualToAnchor:emptyView.centerYAnchor
                                         constant:-60],
      [icon.widthAnchor constraintEqualToConstant:50],
      [icon.heightAnchor constraintEqualToConstant:50],
      [titleLbl.topAnchor constraintEqualToAnchor:icon.bottomAnchor
                                         constant:16],
      [titleLbl.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
      [subtitleLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor
                                            constant:8],
      [subtitleLbl.centerXAnchor
          constraintEqualToAnchor:emptyView.centerXAnchor],
      [subtitleLbl.widthAnchor constraintLessThanOrEqualToConstant:280],
    ]];

    tableView.backgroundView = emptyView;
  } else {
    tableView.backgroundView = nil;
  }
  return self.filteredLogs.count;
}

- (UITableViewCell *)tableView:(UITableView *)tableView
         cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  NLLogCell *cell = [tableView dequeueReusableCellWithIdentifier:@"NLLogCell"
                                                    forIndexPath:indexPath];
  NLLogEntry *entry = self.filteredLogs[indexPath.row];
  [cell configureWithEntry:entry];
  return cell;
}

- (void)tableView:(UITableView *)tableView
    didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  NLLogEntry *entry = self.filteredLogs[indexPath.row];
  NLLogDetailViewController *vc = [[NLLogDetailViewController alloc] init];
  vc.logEntry = entry;
  [self.navigationController pushViewController:vc animated:YES];
}

- (BOOL)tableView:(UITableView *)tableView
    canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  return YES;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (editingStyle == UITableViewCellEditingStyleDelete) {
    NLLogEntry *entry = self.filteredLogs[indexPath.row];
    [self.allLogs removeObject:entry];
    [self.filteredLogs removeObject:entry];
    [tableView deleteRowsAtIndexPaths:@[ indexPath ]
                     withRowAnimation:UITableViewRowAnimationAutomatic];

    // Update Title
    self.title = [NSString
        stringWithFormat:@"Logs (%lu)", (unsigned long)self.filteredLogs.count];

    // NOTE: Swipe-to-delete memory-only for now unless we rewrite files. Wait
    // to see if user needs persistent delete.
  }
}

@end
// ---------------------------------------------------------------------------
#pragma mark - Icon Helper
// ---------------------------------------------------------------------------

static UIImage *iconWithSFSymbol(NSString *name, UIColor *color, CGFloat size) {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:size weight:UIImageSymbolWeightMedium];
    UIImage *img = [[UIImage systemImageNamed:name withConfiguration:config]
                    imageWithTintColor:[UIColor whiteColor]
                    renderingMode:UIImageRenderingModeAlwaysOriginal];
    
    CGFloat boxSize = size + 8;
    CGRect rect = CGRectMake(0, 0, boxSize, boxSize);
    UIGraphicsBeginImageContextWithOptions(rect.size, NO, 0);
    
    // Rounded rect background
    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:rect cornerRadius:boxSize * 0.22];
    [color setFill];
    [path fill];
    
    // Center the white symbol on top
    CGSize imgSize = [img size];
    CGFloat x = (boxSize - imgSize.width) / 2;
    CGFloat y = (boxSize - imgSize.height) / 2;
    [img drawAtPoint:CGPointMake(x, y)];
    
    UIImage *result = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return [result imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
}

// ---------------------------------------------------------------------------
#pragma mark - Premium Header View
// ---------------------------------------------------------------------------

@interface NLHeaderView : UIView
@end

@implementation NLHeaderView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        
        // Container with gradient
        UIView *container = [[UIView alloc] init];
        container.translatesAutoresizingMaskIntoConstraints = NO;
        container.layer.cornerRadius = 16;
        container.clipsToBounds = YES;
        [self addSubview:container];
        
        // Gradient layer
        CAGradientLayer *gradient = [CAGradientLayer layer];
        gradient.colors = @[
            (id)[UIColor colorWithRed:0.20 green:0.40 blue:0.90 alpha:1.0].CGColor,
            (id)[UIColor colorWithRed:0.45 green:0.25 blue:0.85 alpha:1.0].CGColor
        ];
        gradient.startPoint = CGPointMake(0, 0);
        gradient.endPoint = CGPointMake(1, 1);
        gradient.frame = CGRectMake(0, 0, UIScreen.mainScreen.bounds.size.width - 32, 120);
        [container.layer insertSublayer:gradient atIndex:0];
        
        // App icon
        UIImageView *iconView = [[UIImageView alloc] init];
        UIImageSymbolConfiguration *iconConfig = [UIImageSymbolConfiguration configurationWithPointSize:36 weight:UIImageSymbolWeightBold];
        iconView.image = [UIImage systemImageNamed:@"network" withConfiguration:iconConfig];
        iconView.tintColor = [UIColor whiteColor];
        iconView.contentMode = UIViewContentModeScaleAspectFit;
        iconView.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:iconView];
        
        // App name
        UILabel *titleLabel = [[UILabel alloc] init];
        titleLabel.text = @"NetLogger";
        titleLabel.font = [UIFont systemFontOfSize:26 weight:UIFontWeightBold];
        titleLabel.textColor = [UIColor whiteColor];
        titleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:titleLabel];
        
        // Subtitle
        UILabel *subtitleLabel = [[UILabel alloc] init];
        subtitleLabel.text = @"Universal Network Interceptor";
        subtitleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        subtitleLabel.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.75];
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:subtitleLabel];
        
        // Version badge
        UILabel *versionLabel = [[UILabel alloc] init];
        versionLabel.text = @" v0.0.1 ";
        versionLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightSemibold];
        versionLabel.textColor = [UIColor whiteColor];
        versionLabel.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.2];
        versionLabel.layer.cornerRadius = 8;
        versionLabel.clipsToBounds = YES;
        versionLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [container addSubview:versionLabel];
        
        [NSLayoutConstraint activateConstraints:@[
            [container.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
            [container.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
            [container.topAnchor constraintEqualToAnchor:self.topAnchor constant:8],
            [container.bottomAnchor constraintEqualToAnchor:self.bottomAnchor constant:-8],
            [container.heightAnchor constraintEqualToConstant:120],
            
            [iconView.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:20],
            [iconView.centerYAnchor constraintEqualToAnchor:container.centerYAnchor constant:-4],
            [iconView.widthAnchor constraintEqualToConstant:44],
            [iconView.heightAnchor constraintEqualToConstant:44],
            
            [titleLabel.leadingAnchor constraintEqualToAnchor:iconView.trailingAnchor constant:14],
            [titleLabel.topAnchor constraintEqualToAnchor:iconView.topAnchor constant:-2],
            
            [versionLabel.leadingAnchor constraintEqualToAnchor:titleLabel.trailingAnchor constant:8],
            [versionLabel.centerYAnchor constraintEqualToAnchor:titleLabel.centerYAnchor],
            
            [subtitleLabel.leadingAnchor constraintEqualToAnchor:titleLabel.leadingAnchor],
            [subtitleLabel.topAnchor constraintEqualToAnchor:titleLabel.bottomAnchor constant:4],
        ]];
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Update gradient frame on layout
    UIView *container = self.subviews.firstObject;
    for (CALayer *layer in container.layer.sublayers) {
        if ([layer isKindOfClass:[CAGradientLayer class]]) {
            layer.frame = container.bounds;
        }
    }
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Main Settings Controller
// ---------------------------------------------------------------------------

@interface NetLoggerPreferencesListController : PSListController
@end

@implementation NetLoggerPreferencesListController

- (NSArray *)specifiers {
  if (!_specifiers) {
    _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    [self addIconsToSpecifiers];
  }
  return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    // Set tint color
    self.view.tintColor = [UIColor colorWithRed:0.30 green:0.45 blue:0.95 alpha:1.0];
    self.navigationItem.largeTitleDisplayMode = UINavigationItemLargeTitleDisplayModeNever;
    
    // Add premium header
    NLHeaderView *header = [[NLHeaderView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 136)];
    UITableView *tv = [self valueForKey:@"_table"];
    if (!tv) {
        // Try finding the table view in subviews
        for (UIView *v in self.view.subviews) {
            if ([v isKindOfClass:[UITableView class]]) {
                tv = (UITableView *)v;
                break;
            }
        }
    }
    if (tv) {
        tv.tableHeaderView = header;
    }
}

- (void)addIconsToSpecifiers {
    CGFloat iconSize = 18;
    
    for (PSSpecifier *spec in _specifiers) {
        NSString *label = [spec propertyForKey:@"label"];
        if (!label) continue;
        
        UIImage *icon = nil;
        
        // General section
        if ([label isEqualToString:@"Enable NetLogger"]) {
            icon = iconWithSFSymbol(@"power", [UIColor systemGreenColor], iconSize);
        } else if ([label isEqualToString:@"Disable App Caching (No 304)"]) {
            icon = iconWithSFSymbol(@"arrow.triangle.2.circlepath", [UIColor systemOrangeColor], iconSize);
        } else if ([label isEqualToString:@"Enable Socket Capture (TCP/UDP)"]) {
            icon = iconWithSFSymbol(@"bolt.horizontal", [UIColor systemPurpleColor], iconSize);
        }
        // App Selection
        else if ([label isEqualToString:@"Select Apps to Monitor"]) {
            icon = iconWithSFSymbol(@"apps.iphone", [UIColor systemBlueColor], iconSize);
        }
        // Blacklist
        else if ([label isEqualToString:@"Blacklisted Domains"]) {
            icon = iconWithSFSymbol(@"shield.slash", [UIColor systemRedColor], iconSize);
        }
        // MitM
        else if ([label isEqualToString:@"MitM Response Rules"]) {
            icon = iconWithSFSymbol(@"wand.and.rays", [UIColor systemIndigoColor], iconSize);
        }
        // Logs
        else if ([label isEqualToString:@"Network Analytics"]) {
            icon = iconWithSFSymbol(@"chart.bar.xaxis", [UIColor colorWithRed:0.35 green:0.60 blue:0.95 alpha:1.0], iconSize);
        }
        else if ([label isEqualToString:@"View Network Logs"]) {
            icon = iconWithSFSymbol(@"list.bullet.rectangle", [UIColor systemTealColor], iconSize);
        }
        // About
        else if ([label isEqualToString:@"Donate"]) {
            icon = iconWithSFSymbol(@"heart.fill", [UIColor systemPinkColor], iconSize);
        } else if ([label isEqualToString:@"Version"]) {
            icon = iconWithSFSymbol(@"info.circle", [UIColor systemGray2Color], iconSize);
        } else if ([label isEqualToString:@"Author"]) {
            icon = iconWithSFSymbol(@"person.fill", [UIColor systemCyanColor], iconSize);
        }
        // Danger
        else if ([label isEqualToString:@"Restore Default Settings"]) {
            icon = iconWithSFSymbol(@"arrow.counterclockwise", [UIColor systemRedColor], iconSize);
        }
        
        if (icon) {
            [spec setProperty:icon forKey:@"iconImage"];
        }
    }
}

- (void)openGithub {
  NSURL *url = [NSURL
      URLWithString:@"https://github.com/pass-with-high-score/NetLogger"];
  if ([[UIApplication sharedApplication] canOpenURL:url]) {
    [[UIApplication sharedApplication] openURL:url
                                       options:@{}
                             completionHandler:nil];
  }
}

- (void)openDonate {
  NSURL *url = [NSURL URLWithString:@"https://buymeacoffee.com/nguyenquane"];
  if ([[UIApplication sharedApplication] canOpenURL:url]) {
    [[UIApplication sharedApplication] openURL:url
                                       options:@{}
                             completionHandler:nil];
  }
}

- (NSString *)getVersion:(id)specifier {
  return @"0.0.1";
}

- (NSString *)getAuthor:(id)specifier {
  return @"pass-with-high-score";
}

- (void)restoreSettings {
  UIAlertController *alert = [UIAlertController
      alertControllerWithTitle:@"Restore Settings"
                       message:@"Are you sure you want to restore default "
                               @"settings? All your configurations, selected "
                               @"apps, and MitM rules will be deleted."
                preferredStyle:UIAlertControllerStyleAlert];

  [alert addAction:[UIAlertAction actionWithTitle:@"Cancel"
                                            style:UIAlertActionStyleCancel
                                          handler:nil]];
  [alert
      addAction:[UIAlertAction
                    actionWithTitle:@"Restore"
                              style:UIAlertActionStyleDestructive
                            handler:^(UIAlertAction *action) {
                              CFArrayRef keys = CFPreferencesCopyKeyList(
                                  CFSTR("com.minh.netlogger"),
                                  kCFPreferencesCurrentUser,
                                  kCFPreferencesAnyHost);
                              if (keys) {
                                CFPreferencesSetMultiple(
                                    NULL, keys, CFSTR("com.minh.netlogger"),
                                    kCFPreferencesCurrentUser,
                                    kCFPreferencesAnyHost);
                                CFRelease(keys);
                              }
                              CFPreferencesAppSynchronize(
                                  CFSTR("com.minh.netlogger"));

                              [[NSFileManager defaultManager]
                                  removeItemAtPath:
                                      @"/var/jb/var/mobile/Library/Preferences/"
                                      @"com.minh.netlogger.settings.plist"
                                             error:nil];
                              [[NSFileManager defaultManager]
                                  removeItemAtPath:
                                      @"/var/mobile/Library/Preferences/"
                                      @"com.minh.netlogger.settings.plist"
                                             error:nil];

                              [self reloadSpecifiers];
                            }]];

  [self presentViewController:alert animated:YES completion:nil];
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

  CFPropertyListRef en =
      CFPreferencesCopyAppValue(CFSTR("enabled"), CFSTR("com.minh.netlogger"));
  if (en) {
    settings[@"enabled"] = (__bridge_transfer id)en;
  }

  CFPropertyListRef apps = CFPreferencesCopyAppValue(
      CFSTR("selectedApps"), CFSTR("com.minh.netlogger"));
  if (apps) {
    settings[@"selectedApps"] = (__bridge_transfer id)apps;
  }

  CFPropertyListRef blacklist = CFPreferencesCopyAppValue(
      CFSTR("blacklistedDomains"), CFSTR("com.minh.netlogger"));
  if (blacklist) {
    settings[@"blacklistedDomains"] = (__bridge_transfer id)blacklist;
  }

  CFPropertyListRef blRules = CFPreferencesCopyAppValue(
      CFSTR("blacklistRules"), CFSTR("com.minh.netlogger"));
  if (blRules) {
    settings[@"blacklistRules"] = (__bridge_transfer id)blRules;
  }

  CFPropertyListRef mitm = CFPreferencesCopyAppValue(
      CFSTR("mitmRules"), CFSTR("com.minh.netlogger"));
  if (mitm) {
    settings[@"mitmRules"] = (__bridge_transfer id)mitm;
  }

  CFPropertyListRef nocache = CFPreferencesCopyAppValue(
      CFSTR("noCachingEnabled"), CFSTR("com.minh.netlogger"));
  if (nocache) {
    settings[@"noCachingEnabled"] = (__bridge_transfer id)nocache;
  }

  CFPropertyListRef socketCapture = CFPreferencesCopyAppValue(
      CFSTR("socketCaptureEnabled"), CFSTR("com.minh.netlogger"));
  if (socketCapture) {
    settings[@"socketCaptureEnabled"] = (__bridge_transfer id)socketCapture;
  }

  NSString *path = @"/var/jb/var/mobile/Library/Preferences/"
                   @"com.minh.netlogger.settings.plist";
  [settings writeToFile:path atomically:YES];

  // Make it world-readable
  [[NSFileManager defaultManager]
      setAttributes:@{NSFilePosixPermissions : @(0644)}
       ofItemAtPath:path
              error:nil];
}

@end
