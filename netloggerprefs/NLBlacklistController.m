#import "NLBlacklistController.h"
#import "NLLocalization.h"

#define PREFS_PLIST @"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"

// ---------------------------------------------------------------------------
#pragma mark - Filter Type & Policy Helpers
// ---------------------------------------------------------------------------

// Filter types: 0=Domain(exact), 1=Domain Suffix, 2=Domain Keyword
static NSString *filterTypeName(NSInteger type) {
    switch (type) {
        case 0: return @"DOMAIN";
        case 1: return @"SUFFIX";
        case 2: return @"KEYWORD";
        default: return @"?";
    }
}

static UIColor *filterTypeColor(NSInteger type) {
    switch (type) {
        case 0: return [UIColor systemBlueColor];
        case 1: return [UIColor systemOrangeColor];
        case 2: return [UIColor systemPurpleColor];
        default: return [UIColor systemGrayColor];
    }
}

// Policies: 0=Direct, 1=Reject
static NSString *policyName(NSInteger policy) {
    switch (policy) {
        case 0: return @"DIRECT";
        case 1: return @"REJECT";
        default: return @"?";
    }
}

static UIColor *policyColor(NSInteger policy) {
    switch (policy) {
        case 0: return [UIColor systemGreenColor];
        case 1: return [UIColor systemRedColor];
        default: return [UIColor systemGrayColor];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Custom Rule Cell
// ---------------------------------------------------------------------------

@interface NLBlacklistRuleCell : UITableViewCell
@property (nonatomic, strong) UILabel *filterBadge;
@property (nonatomic, strong) UILabel *policyBadge;
@property (nonatomic, strong) UILabel *domainLabel;
@property (nonatomic, strong) UIView  *statusDot;
@end

@implementation NLBlacklistRuleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // Filter type badge
        _filterBadge = [[UILabel alloc] init];
        _filterBadge.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
        _filterBadge.textColor = [UIColor whiteColor];
        _filterBadge.textAlignment = NSTextAlignmentCenter;
        _filterBadge.layer.cornerRadius = 4;
        _filterBadge.clipsToBounds = YES;
        _filterBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_filterBadge];

        // Policy badge
        _policyBadge = [[UILabel alloc] init];
        _policyBadge.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
        _policyBadge.textColor = [UIColor whiteColor];
        _policyBadge.textAlignment = NSTextAlignmentCenter;
        _policyBadge.layer.cornerRadius = 4;
        _policyBadge.clipsToBounds = YES;
        _policyBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_policyBadge];

        // Status dot (enabled/disabled)
        _statusDot = [[UIView alloc] init];
        _statusDot.layer.cornerRadius = 4;
        _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_statusDot];

        // Domain label
        _domainLabel = [[UILabel alloc] init];
        _domainLabel.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightMedium];
        _domainLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _domainLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_domainLabel];

        [NSLayoutConstraint activateConstraints:@[
            // Filter badge — top left
            [_filterBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_filterBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_filterBadge.widthAnchor constraintGreaterThanOrEqualToConstant:56],
            [_filterBadge.heightAnchor constraintEqualToConstant:18],

            // Policy badge — right of filter
            [_policyBadge.leadingAnchor constraintEqualToAnchor:_filterBadge.trailingAnchor constant:6],
            [_policyBadge.centerYAnchor constraintEqualToAnchor:_filterBadge.centerYAnchor],
            [_policyBadge.widthAnchor constraintGreaterThanOrEqualToConstant:52],
            [_policyBadge.heightAnchor constraintEqualToConstant:18],

            // Status dot
            [_statusDot.leadingAnchor constraintEqualToAnchor:_policyBadge.trailingAnchor constant:6],
            [_statusDot.centerYAnchor constraintEqualToAnchor:_filterBadge.centerYAnchor],
            [_statusDot.widthAnchor constraintEqualToConstant:8],
            [_statusDot.heightAnchor constraintEqualToConstant:8],

            // Domain label — below badges
            [_domainLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_domainLabel.topAnchor constraintEqualToAnchor:_filterBadge.bottomAnchor constant:6],
            [_domainLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-36],
            [_domainLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)configureWithRule:(NSDictionary *)rule {
    NSInteger filterType = [rule[@"filter_type"] integerValue];
    NSInteger policy = [rule[@"policy"] integerValue];
    BOOL enabled = [rule[@"enabled"] boolValue];

    self.filterBadge.text = [NSString stringWithFormat:@" %@ ", filterTypeName(filterType)];
    self.filterBadge.backgroundColor = enabled ? filterTypeColor(filterType) : [UIColor systemGrayColor];

    self.policyBadge.text = [NSString stringWithFormat:@" %@ ", policyName(policy)];
    self.policyBadge.backgroundColor = enabled ? policyColor(policy) : [UIColor systemGray3Color];

    self.statusDot.backgroundColor = enabled ? [UIColor systemGreenColor] : [UIColor systemGray3Color];

    self.domainLabel.text = rule[@"domain"] ?: @"(no domain)";
    self.domainLabel.textColor = enabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Add/Edit Rule Controller
// ---------------------------------------------------------------------------

@interface NLBlacklistEditController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, assign) NSInteger ruleIndex;
@property (nonatomic, copy) void (^onSave)(NSDictionary *rule, NSInteger index);
@end

@implementation NLBlacklistEditController {
    UITableView *_tableView;
    UITextField *_domainField;
    UISwitch *_enabledSwitch;
    NSInteger _selectedFilterType;
    NSInteger _selectedPolicy;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.ruleIndex < 0
        ? NLLocalizedString(@"New Rule", @"New Rule")
        : NLLocalizedString(@"Edit Rule", @"Edit Rule");
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveRule)];

    if (!self.rule) {
        self.rule = [@{
            @"domain": @"",
            @"filter_type": @(1),  // Default: Domain Suffix
            @"policy": @(1),       // Default: Reject
            @"enabled": @YES
        } mutableCopy];
    }
    _selectedFilterType = [self.rule[@"filter_type"] integerValue];
    _selectedPolicy = [self.rule[@"policy"] integerValue];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
    [self.view addSubview:_tableView];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillShow:) name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(keyboardWillHide:) name:UIKeyboardWillHideNotification object:nil];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillShowNotification object:nil];
    [[NSNotificationCenter defaultCenter] removeObserver:self name:UIKeyboardWillHideNotification object:nil];
}

- (void)keyboardWillShow:(NSNotification *)notification {
    NSDictionary *info = [notification userInfo];
    CGSize kbSize = [[info objectForKey:UIKeyboardFrameEndUserInfoKey] CGRectValue].size;
    UIEdgeInsets contentInsets = UIEdgeInsetsMake(0.0, 0.0, kbSize.height, 0.0);
    _tableView.contentInset = contentInsets;
    _tableView.scrollIndicatorInsets = contentInsets;
}

- (void)keyboardWillHide:(NSNotification *)notification {
    _tableView.contentInset = UIEdgeInsetsZero;
    _tableView.scrollIndicatorInsets = UIEdgeInsetsZero;
}

// Section layout:
// 0 = Filter Type (3 rows: Domain, Domain Suffix, Domain Keyword)
// 1 = Domain Pattern (1 text field)
// 2 = Policy (2 rows: Direct, Reject)
// 3 = State (enabled toggle)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 3;  // 3 filter types
    if (s == 1) return 1;  // domain text field
    if (s == 2) return 2;  // 2 policies
    return 1;              // enabled toggle
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return NLLocalizedString(@"Filter Type", @"Filter Type");
        case 1: return NLLocalizedString(@"Domain Pattern", @"Domain Pattern");
        case 2: return NLLocalizedString(@"Policy", @"Policy");
        case 3: return NLLocalizedString(@"State", @"State");
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return NLLocalizedString(@"Select how the domain pattern should be matched against request hosts.", @"Select how the domain pattern should be matched against request hosts.");
    if (s == 1) {
        switch (_selectedFilterType) {
            case 0: return NLLocalizedString(@"Exact match: only requests to this exact domain will be affected.", @"Exact match: only requests to this exact domain will be affected.");
            case 1: return NLLocalizedString(@"Suffix match: any host ending with this pattern will be affected (e.g. '.google.com' matches 'ads.google.com').", @"Suffix match: any host ending with this pattern will be affected.");
            case 2: return NLLocalizedString(@"Keyword match: any host containing this keyword will be affected.", @"Keyword match: any host containing this keyword will be affected.");
        }
    }
    if (s == 2) return NLLocalizedString(@"Direct: allow traffic but hide from logs. Reject: block the request entirely.", @"Direct: allow traffic but hide from logs. Reject: block the request entirely.");
    return nil;
}

- (UIImage *)circleImageWithColor:(UIColor *)color {
    CGSize size = CGSizeMake(12, 12);
    UIGraphicsBeginImageContextWithOptions(size, NO, 0);
    [color setFill];
    UIBezierPath *path = [UIBezierPath bezierPathWithOvalInRect:CGRectMake(0, 0, size.width, size.height)];
    [path fill];
    UIImage *img = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return img;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    // ── Section 0: Filter Type ──
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

        NSArray *titles = @[
            NLLocalizedString(@"Domain", @"Domain"),
            NLLocalizedString(@"Domain Suffix", @"Domain Suffix"),
            NLLocalizedString(@"Domain Keyword", @"Domain Keyword")
        ];
        NSArray *subtitles = @[
            NLLocalizedString(@"Exact host match", @"Exact host match"),
            NLLocalizedString(@"Match hosts ending with pattern", @"Match hosts ending with pattern"),
            NLLocalizedString(@"Match hosts containing keyword", @"Match hosts containing keyword")
        ];

        cell.textLabel.text = titles[indexPath.row];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.text = subtitles[indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.imageView.image = [self circleImageWithColor:filterTypeColor(indexPath.row)];
        cell.accessoryType = (indexPath.row == _selectedFilterType) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = filterTypeColor(_selectedFilterType);
        return cell;
    }

    // ── Section 1: Domain Pattern ──
    if (indexPath.section == 1) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.selectionStyle = UITableViewCellSelectionStyleNone;

        UILabel *lbl = [[UILabel alloc] init];
        lbl.text = NLLocalizedString(@"Domain / Keyword", @"Domain / Keyword");
        lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
        lbl.textColor = [UIColor secondaryLabelColor];
        lbl.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:lbl];

        _domainField = [[UITextField alloc] init];
        NSArray *placeholders = @[@"ads.example.com", @"google-analytics.com", @"analytics"];
        _domainField.placeholder = placeholders[_selectedFilterType];
        _domainField.text = self.rule[@"domain"];
        _domainField.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
        _domainField.autocorrectionType = UITextAutocorrectionTypeNo;
        _domainField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        _domainField.keyboardType = UIKeyboardTypeURL;
        _domainField.clearButtonMode = UITextFieldViewModeWhileEditing;
        _domainField.translatesAutoresizingMaskIntoConstraints = NO;
        [cell.contentView addSubview:_domainField];

        [NSLayoutConstraint activateConstraints:@[
            [lbl.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [lbl.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],
            [_domainField.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
            [_domainField.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
            [_domainField.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:4],
            [_domainField.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
            [_domainField.heightAnchor constraintEqualToConstant:30],
        ]];

        return cell;
    }

    // ── Section 2: Policy ──
    if (indexPath.section == 2) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

        NSArray *titles = @[
            NLLocalizedString(@"Direct", @"Direct"),
            NLLocalizedString(@"Reject", @"Reject")
        ];
        NSArray *subtitles = @[
            NLLocalizedString(@"Allow traffic, hide from logs", @"Allow traffic, hide from logs"),
            NLLocalizedString(@"Block request entirely", @"Block request entirely")
        ];

        cell.textLabel.text = titles[indexPath.row];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.text = subtitles[indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];
        cell.imageView.image = [self circleImageWithColor:policyColor(indexPath.row)];
        cell.accessoryType = (indexPath.row == _selectedPolicy) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = policyColor(_selectedPolicy);
        return cell;
    }

    // ── Section 3: Enabled toggle ──
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = NLLocalizedString(@"Enabled", @"Enabled");
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    _enabledSwitch = [[UISwitch alloc] init];
    _enabledSwitch.on = [self.rule[@"enabled"] boolValue];
    _enabledSwitch.onTintColor = policyColor(_selectedPolicy);
    cell.accessoryView = _enabledSwitch;
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        _selectedFilterType = indexPath.row;
        [tv reloadData];
    } else if (indexPath.section == 2) {
        _selectedPolicy = indexPath.row;
        [tv reloadData];
    }
}

- (void)saveRule {
    NSString *domain = [_domainField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] ?: @"";

    if (domain.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:NLLocalizedString(@"Missing Fields", @"Missing Fields")
            message:NLLocalizedString(@"Domain pattern is required.", @"Domain pattern is required.")
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSDictionary *saved = @{
        @"domain": domain,
        @"filter_type": @(_selectedFilterType),
        @"policy": @(_selectedPolicy),
        @"enabled": @(_enabledSwitch.on)
    };

    if (self.onSave) self.onSave(saved, self.ruleIndex);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Blacklist Rules List Controller
// ---------------------------------------------------------------------------

@implementation NLBlacklistController {
    UITableView *_tableView;
    NSMutableArray *_rules;
}

- (void)loadView {
    [super loadView];
    self.view = [[UIView alloc] initWithFrame:UIScreen.mainScreen.bounds];
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.estimatedRowHeight = 60;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    [_tableView registerClass:[NLBlacklistRuleCell class] forCellReuseIdentifier:@"RuleCell"];
    [self.view addSubview:_tableView];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = NLLocalizedString(@"Blacklisted Domains", @"Blacklisted Domains");

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addRule)];

    [self loadRules];
}

// ---------------------------------------------------------------------------
#pragma mark - Data: Load / Save / Migrate
// ---------------------------------------------------------------------------

- (void)loadRules {
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));

    // Try new format first
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("blacklistRules"), CFSTR("com.minh.netlogger"));
    if (ref) {
        NSArray *saved = (__bridge_transfer NSArray *)ref;
        if ([saved isKindOfClass:[NSArray class]]) {
            _rules = [saved mutableCopy] ?: [NSMutableArray array];
            return;
        }
    }

    // Migrate old CSV format
    CFPropertyListRef oldRef = CFPreferencesCopyAppValue(CFSTR("blacklistedDomains"), CFSTR("com.minh.netlogger"));
    if (oldRef) {
        NSString *oldCSV = (__bridge_transfer NSString *)oldRef;
        if ([oldCSV isKindOfClass:[NSString class]] && oldCSV.length > 0) {
            _rules = [NSMutableArray array];
            NSArray *parts = [oldCSV componentsSeparatedByString:@","];
            for (NSString *p in parts) {
                NSString *trimmed = [p stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                if (trimmed.length > 0) {
                    [_rules addObject:@{
                        @"domain": trimmed,
                        @"filter_type": @(1),  // Domain Suffix (closest to old behavior)
                        @"policy": @(0),       // Direct (old behavior was log-filter only)
                        @"enabled": @YES
                    }];
                }
            }
            // Save migrated data in new format
            [self saveRules];
            return;
        }
    }

    _rules = [NSMutableArray array];
}

- (void)saveRules {
    CFPreferencesSetAppValue(CFSTR("blacklistRules"), (__bridge CFArrayRef)_rules, CFSTR("com.minh.netlogger"));
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));

    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PLIST] ?: [NSMutableDictionary dictionary];
    dict[@"blacklistRules"] = _rules;
    [dict writeToFile:PREFS_PLIST atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:PREFS_PLIST error:nil];

    [_tableView reloadData];
}

// ---------------------------------------------------------------------------
#pragma mark - Actions
// ---------------------------------------------------------------------------

- (void)addRule {
    NLBlacklistEditController *vc = [[NLBlacklistEditController alloc] init];
    vc.ruleIndex = -1;
    __weak typeof(self) weakSelf = self;
    vc.onSave = ^(NSDictionary *rule, NSInteger index) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_rules addObject:rule];
        [strongSelf saveRules];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

// ---------------------------------------------------------------------------
#pragma mark - Table View
// ---------------------------------------------------------------------------

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 1; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (_rules.count == 0) {
        // ── Empty state ──
        UIView *emptyView = [[UIView alloc] initWithFrame:tv.bounds];

        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"shield.slash"]];
        icon.tintColor = [UIColor systemGray3Color];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyView addSubview:icon];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.text = NLLocalizedString(@"No Rules", @"No Rules");
        titleLbl.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        titleLbl.textColor = [UIColor secondaryLabelColor];
        titleLbl.textAlignment = NSTextAlignmentCenter;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyView addSubview:titleLbl];

        UILabel *subtitleLbl = [[UILabel alloc] init];
        subtitleLbl.text = NLLocalizedString(@"Tap + to add a domain rule.\nDirect = hide from logs, Reject = block.", @"Tap + to add a domain rule.\nDirect = hide from logs, Reject = block.");
        subtitleLbl.font = [UIFont systemFontOfSize:14];
        subtitleLbl.numberOfLines = 0;
        subtitleLbl.textColor = [UIColor tertiaryLabelColor];
        subtitleLbl.textAlignment = NSTextAlignmentCenter;
        subtitleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyView addSubview:subtitleLbl];

        [NSLayoutConstraint activateConstraints:@[
            [icon.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
            [icon.centerYAnchor constraintEqualToAnchor:emptyView.centerYAnchor constant:-60],
            [icon.widthAnchor constraintEqualToConstant:44],
            [icon.heightAnchor constraintEqualToConstant:44],
            [titleLbl.topAnchor constraintEqualToAnchor:icon.bottomAnchor constant:16],
            [titleLbl.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
            [subtitleLbl.topAnchor constraintEqualToAnchor:titleLbl.bottomAnchor constant:8],
            [subtitleLbl.centerXAnchor constraintEqualToAnchor:emptyView.centerXAnchor],
            [subtitleLbl.widthAnchor constraintLessThanOrEqualToConstant:280],
        ]];

        tv.backgroundView = emptyView;
        return 0;
    }

    tv.backgroundView = nil;
    return _rules.count;
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    return _rules.count > 0 ? [NSString stringWithFormat:@"%@ (%lu)", NLLocalizedString(@"Rules", @"Rules"), (unsigned long)_rules.count] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLBlacklistRuleCell *cell = [tv dequeueReusableCellWithIdentifier:@"RuleCell" forIndexPath:indexPath];
    [cell configureWithRule:_rules[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];
    if (_rules.count == 0) return;

    NLBlacklistEditController *vc = [[NLBlacklistEditController alloc] init];
    vc.rule = [_rules[indexPath.row] mutableCopy];
    vc.ruleIndex = indexPath.row;
    __weak typeof(self) weakSelf = self;
    vc.onSave = ^(NSDictionary *rule, NSInteger index) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        [strongSelf->_rules replaceObjectAtIndex:index withObject:rule];
        [strongSelf saveRules];
    };
    [self.navigationController pushViewController:vc animated:YES];
}

// ---------------------------------------------------------------------------
#pragma mark - Swipe Actions
// ---------------------------------------------------------------------------

- (BOOL)tableView:(UITableView *)tv canEditRowAtIndexPath:(NSIndexPath *)indexPath {
    return _rules.count > 0;
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    // Delete
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:NLLocalizedString(@"Delete", @"Delete") handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        [self->_rules removeObjectAtIndex:indexPath.row];
        [self saveRules];
        completion(YES);
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    // Duplicate
    UIContextualAction *dupAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:NLLocalizedString(@"Duplicate", @"Duplicate") handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        NSMutableDictionary *copy = [self->_rules[indexPath.row] mutableCopy];
        copy[@"enabled"] = @NO;
        [self->_rules insertObject:copy atIndex:indexPath.row + 1];
        [self saveRules];
        completion(YES);
    }];
    dupAction.backgroundColor = [UIColor systemIndigoColor];
    dupAction.image = [UIImage systemImageNamed:@"doc.on.doc"];

    return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction, dupAction]];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)tv leadingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)indexPath {
    NSDictionary *rule = _rules[indexPath.row];
    BOOL isEnabled = [rule[@"enabled"] boolValue];

    NSString *title = isEnabled ? NLLocalizedString(@"Disable", @"Disable") : NLLocalizedString(@"Enable", @"Enable");
    UIContextualAction *toggleAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:title handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        NSMutableDictionary *updated = [self->_rules[indexPath.row] mutableCopy];
        updated[@"enabled"] = @(!isEnabled);
        [self->_rules replaceObjectAtIndex:indexPath.row withObject:updated];
        [self saveRules];
        completion(YES);
    }];
    toggleAction.backgroundColor = isEnabled ? [UIColor systemGrayColor] : [UIColor systemGreenColor];
    toggleAction.image = [UIImage systemImageNamed:isEnabled ? @"pause.circle" : @"play.circle"];

    UISwipeActionsConfiguration *config = [UISwipeActionsConfiguration configurationWithActions:@[toggleAction]];
    config.performsFirstActionWithFullSwipe = YES;
    return config;
}

@end
