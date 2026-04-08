#import "NLMitmRulesController.h"

#define PREFS_PLIST @"/var/jb/var/mobile/Library/Preferences/com.minh.netlogger.settings.plist"

// ---------------------------------------------------------------------------
#pragma mark - Rule Type Helpers
// ---------------------------------------------------------------------------

static NSString *ruleTypeName(NSInteger type) {
    switch (type) {
        case 0: return @"RES BODY";
        case 1: return @"REQ BODY";
        case 2: return @"REQ HEAD";
        case 3: return @"RES HEAD";
        case 4: return @"REQ URL";
        default: return @"?";
    }
}

static UIColor *ruleTypeColor(NSInteger type) {
    switch (type) {
        case 0: return [UIColor systemGreenColor];   // Response Body
        case 1: return [UIColor systemBlueColor];    // Request Body
        case 2: return [UIColor systemOrangeColor];  // Request Header
        case 3: return [UIColor systemPurpleColor];  // Response Header
        case 4: return [UIColor systemTealColor];    // URL Rewrite
        default: return [UIColor systemGrayColor];
    }
}

// ---------------------------------------------------------------------------
#pragma mark - Custom Rule Cell
// ---------------------------------------------------------------------------

@interface NLMitmRuleCell : UITableViewCell
@property (nonatomic, strong) UILabel *typeBadge;
@property (nonatomic, strong) UILabel *patternLabel;
@property (nonatomic, strong) UILabel *detailLabel;
@property (nonatomic, strong) UIView  *statusDot;
@end

@implementation NLMitmRuleCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
    if (self) {
        self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

        // Type badge
        _typeBadge = [[UILabel alloc] init];
        _typeBadge.font = [UIFont monospacedSystemFontOfSize:9 weight:UIFontWeightBold];
        _typeBadge.textColor = [UIColor whiteColor];
        _typeBadge.textAlignment = NSTextAlignmentCenter;
        _typeBadge.layer.cornerRadius = 4;
        _typeBadge.clipsToBounds = YES;
        _typeBadge.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_typeBadge];

        // Status dot (enabled/disabled)
        _statusDot = [[UIView alloc] init];
        _statusDot.layer.cornerRadius = 4;
        _statusDot.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_statusDot];

        // URL pattern
        _patternLabel = [[UILabel alloc] init];
        _patternLabel.font = [UIFont monospacedSystemFontOfSize:13 weight:UIFontWeightMedium];
        _patternLabel.lineBreakMode = NSLineBreakByTruncatingMiddle;
        _patternLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_patternLabel];

        // key → value
        _detailLabel = [[UILabel alloc] init];
        _detailLabel.font = [UIFont monospacedSystemFontOfSize:11 weight:UIFontWeightRegular];
        _detailLabel.textColor = [UIColor secondaryLabelColor];
        _detailLabel.lineBreakMode = NSLineBreakByTruncatingTail;
        _detailLabel.translatesAutoresizingMaskIntoConstraints = NO;
        [self.contentView addSubview:_detailLabel];

        [NSLayoutConstraint activateConstraints:@[
            // Type badge
            [_typeBadge.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_typeBadge.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:10],
            [_typeBadge.widthAnchor constraintGreaterThanOrEqualToConstant:60],
            [_typeBadge.heightAnchor constraintEqualToConstant:18],

            // Status dot — right of badge
            [_statusDot.leadingAnchor constraintEqualToAnchor:_typeBadge.trailingAnchor constant:6],
            [_statusDot.centerYAnchor constraintEqualToAnchor:_typeBadge.centerYAnchor],
            [_statusDot.widthAnchor constraintEqualToConstant:8],
            [_statusDot.heightAnchor constraintEqualToConstant:8],

            // Pattern label — right of status dot
            [_patternLabel.leadingAnchor constraintEqualToAnchor:_statusDot.trailingAnchor constant:6],
            [_patternLabel.centerYAnchor constraintEqualToAnchor:_typeBadge.centerYAnchor],
            [_patternLabel.trailingAnchor constraintLessThanOrEqualToAnchor:self.contentView.trailingAnchor constant:-36],

            // Detail below
            [_detailLabel.leadingAnchor constraintEqualToAnchor:self.contentView.leadingAnchor constant:16],
            [_detailLabel.topAnchor constraintEqualToAnchor:_typeBadge.bottomAnchor constant:4],
            [_detailLabel.trailingAnchor constraintEqualToAnchor:self.contentView.trailingAnchor constant:-36],
            [_detailLabel.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor constant:-10],
        ]];
    }
    return self;
}

- (void)configureWithRule:(NSDictionary *)rule {
    NSInteger type = [rule[@"rule_type"] integerValue];
    BOOL enabled = [rule[@"enabled"] boolValue];

    self.typeBadge.text = [NSString stringWithFormat:@" %@ ", ruleTypeName(type)];
    self.typeBadge.backgroundColor = enabled ? ruleTypeColor(type) : [UIColor systemGrayColor];

    self.statusDot.backgroundColor = enabled ? [UIColor systemGreenColor] : [UIColor systemGray3Color];

    self.patternLabel.text = rule[@"url_pattern"] ?: @"(no pattern)";
    self.patternLabel.textColor = enabled ? [UIColor labelColor] : [UIColor tertiaryLabelColor];

    NSString *key = rule[@"key_path"] ?: @"?";
    NSString *val = rule[@"new_value"] ?: @"?";
    self.detailLabel.text = [NSString stringWithFormat:@"%@ = %@", key, val];
    self.detailLabel.textColor = enabled ? [UIColor secondaryLabelColor] : [UIColor tertiaryLabelColor];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - Add/Edit Rule Controller
// ---------------------------------------------------------------------------

@interface NLMitmEditController : UIViewController <UITableViewDelegate, UITableViewDataSource>
@property (nonatomic, strong) NSMutableDictionary *rule;
@property (nonatomic, assign) NSInteger ruleIndex;
@property (nonatomic, copy) void (^onSave)(NSDictionary *rule, NSInteger index);
@end

@implementation NLMitmEditController {
    UITableView *_tableView;
    UITextField *_urlField;
    UITextField *_keyField;
    UITextField *_valueField;
    UISwitch *_enabledSwitch;
    NSInteger _selectedType;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = self.ruleIndex < 0 ? @"New Rule" : @"Edit Rule";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemSave target:self action:@selector(saveRule)];

    if (!self.rule) {
        self.rule = [@{
            @"rule_type": @0,
            @"url_pattern": @"",
            @"key_path": @"",
            @"new_value": @"true",
            @"enabled": @YES
        } mutableCopy];
    }
    _selectedType = [self.rule[@"rule_type"] integerValue];

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
    UIEdgeInsets contentInsets = UIEdgeInsetsZero;
    _tableView.contentInset = contentInsets;
    _tableView.scrollIndicatorInsets = contentInsets;
}

// --------------- Section layout ---------------
// 0 = Rule Type (5 selectable rows)
// 1 = Match (URL pattern)
// 2 = Modify (key + value)
// 3 = State (enabled toggle)

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tv { return 4; }

- (NSInteger)tableView:(UITableView *)tv numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 5; // 5 rule types
    if (s == 1) return 1; // URL pattern
    if (s == 2) return 2; // key + value
    return 1;             // enabled toggle
}

- (NSString *)tableView:(UITableView *)tv titleForHeaderInSection:(NSInteger)s {
    switch (s) {
        case 0: return @"Rule Type";
        case 1: return @"URL Match";
        case 2: return [self modifySectionTitle];
        case 3: return @"State";
        default: return nil;
    }
}

- (NSString *)tableView:(UITableView *)tv titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"Select what part of the request/response to modify.";
    if (s == 1) return @"Rule activates when request URL contains this string.";
    if (s == 2) {
        switch (_selectedType) {
            case 0: case 1: return @"Supports nested key paths (e.g. data.user.is_vip).\nValue types: true, false, null, numbers, or strings.";
            case 2: case 3: return @"Set or override an HTTP header field.";
            case 4: return @"Find a substring in the URL and replace it.";
        }
    }
    return nil;
}

- (NSString *)modifySectionTitle {
    switch (_selectedType) {
        case 0: return @"Response Body (JSON)";
        case 1: return @"Request Body (JSON)";
        case 2: return @"Request Header";
        case 3: return @"Response Header";
        case 4: return @"URL Rewrite";
        default: return @"Modify";
    }
}

- (NSString *)keyPlaceholder {
    switch (_selectedType) {
        case 0: case 1: return @"data.user.is_vip";
        case 2: case 3: return @"X-Custom-Header";
        case 4: return @"item=bronze";
        default: return @"";
    }
}

- (NSString *)valuePlaceholder {
    switch (_selectedType) {
        case 0: case 1: return @"true";
        case 2: case 3: return @"custom_value";
        case 4: return @"item=legend";
        default: return @"";
    }
}

- (NSString *)keyLabel {
    switch (_selectedType) {
        case 0: case 1: return @"Key Path";
        case 2: case 3: return @"Header Name";
        case 4: return @"Find";
        default: return @"Key";
    }
}

- (NSString *)valueLabel {
    switch (_selectedType) {
        case 0: case 1: return @"New Value";
        case 2: case 3: return @"Header Value";
        case 4: return @"Replace With";
        default: return @"Value";
    }
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {

    // ── Section 0: Rule Type (checkmark selection) ──
    if (indexPath.section == 0) {
        UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];

        NSArray *titles = @[@"Response Body", @"Request Body", @"Request Header", @"Response Header", @"URL Rewrite"];
        NSArray *subtitles = @[
            @"Modify JSON values in response",
            @"Modify JSON values in request",
            @"Set or override request headers",
            @"Set or override response headers",
            @"Search & replace in request URL"
        ];

        cell.textLabel.text = titles[indexPath.row];
        cell.textLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        cell.detailTextLabel.text = subtitles[indexPath.row];
        cell.detailTextLabel.font = [UIFont systemFontOfSize:12];
        cell.detailTextLabel.textColor = [UIColor secondaryLabelColor];

        // Color dot
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 10, 10)];
        dot.backgroundColor = ruleTypeColor(indexPath.row);
        dot.layer.cornerRadius = 5;
        cell.imageView.image = [self circleImageWithColor:ruleTypeColor(indexPath.row)];

        cell.accessoryType = (indexPath.row == _selectedType) ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        cell.tintColor = ruleTypeColor(_selectedType);
        return cell;
    }

    // ── Section 1: URL Pattern ──
    if (indexPath.section == 1) {
        return [self textFieldCellWithLabel:@"URL Contains"
                               placeholder:@"/api/v1/user"
                                      text:self.rule[@"url_pattern"]
                                    assign:^(UITextField *f) { self->_urlField = f; }];
    }

    // ── Section 2: Key + Value ──
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            return [self textFieldCellWithLabel:[self keyLabel]
                                   placeholder:[self keyPlaceholder]
                                          text:self.rule[@"key_path"]
                                        assign:^(UITextField *f) { self->_keyField = f; }];
        } else {
            return [self textFieldCellWithLabel:[self valueLabel]
                                   placeholder:[self valuePlaceholder]
                                          text:self.rule[@"new_value"]
                                        assign:^(UITextField *f) { self->_valueField = f; }];
        }
    }

    // ── Section 3: Enabled toggle ──
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.textLabel.text = @"Enabled";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    _enabledSwitch = [[UISwitch alloc] init];
    _enabledSwitch.on = [self.rule[@"enabled"] boolValue];
    _enabledSwitch.onTintColor = ruleTypeColor(_selectedType);
    cell.accessoryView = _enabledSwitch;
    return cell;
}

- (UITableViewCell *)textFieldCellWithLabel:(NSString *)label
                                placeholder:(NSString *)placeholder
                                       text:(NSString *)text
                                     assign:(void(^)(UITextField *))assign {
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;

    UILabel *lbl = [[UILabel alloc] init];
    lbl.text = label;
    lbl.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    lbl.textColor = [UIColor secondaryLabelColor];
    lbl.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:lbl];

    UITextField *field = [[UITextField alloc] init];
    field.placeholder = placeholder;
    field.text = text;
    field.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    field.clearButtonMode = UITextFieldViewModeWhileEditing;
    field.translatesAutoresizingMaskIntoConstraints = NO;
    [cell.contentView addSubview:field];

    [NSLayoutConstraint activateConstraints:@[
        [lbl.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [lbl.topAnchor constraintEqualToAnchor:cell.contentView.topAnchor constant:8],

        [field.leadingAnchor constraintEqualToAnchor:cell.contentView.leadingAnchor constant:16],
        [field.trailingAnchor constraintEqualToAnchor:cell.contentView.trailingAnchor constant:-16],
        [field.topAnchor constraintEqualToAnchor:lbl.bottomAnchor constant:4],
        [field.bottomAnchor constraintEqualToAnchor:cell.contentView.bottomAnchor constant:-8],
        [field.heightAnchor constraintEqualToConstant:30],
    ]];

    if (assign) assign(field);
    return cell;
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

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section == 0) {
        _selectedType = indexPath.row;
        // Reload all sections so labels/placeholders update
        [tv reloadData];
    }
}

- (void)saveRule {
    NSString *urlPattern = _urlField.text ?: @"";
    NSString *keyPath = _keyField.text ?: @"";
    NSString *newValue = _valueField.text ?: @"";

    if (urlPattern.length == 0 || keyPath.length == 0) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"Missing Fields"
            message:@"URL pattern and key/find field are required." preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }

    NSDictionary *saved = @{
        @"rule_type": @(_selectedType),
        @"url_pattern": urlPattern,
        @"key_path": keyPath,
        @"new_value": newValue,
        @"enabled": @(_enabledSwitch.on)
    };

    if (self.onSave) self.onSave(saved, self.ruleIndex);
    [self.navigationController popViewControllerAnimated:YES];
}

@end

// ---------------------------------------------------------------------------
#pragma mark - MitM Rules List Controller
// ---------------------------------------------------------------------------

@implementation NLMitmRulesController {
    UITableView *_tableView;
    NSMutableArray *_rules;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"MitM Rules";
    self.view.backgroundColor = [UIColor systemGroupedBackgroundColor];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addRule)];

    _tableView = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleInsetGrouped];
    _tableView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _tableView.delegate = self;
    _tableView.dataSource = self;
    _tableView.estimatedRowHeight = 60;
    _tableView.rowHeight = UITableViewAutomaticDimension;
    [_tableView registerClass:[NLMitmRuleCell class] forCellReuseIdentifier:@"RuleCell"];
    [self.view addSubview:_tableView];

    [self loadRules];
}

- (void)loadRules {
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));
    CFPropertyListRef ref = CFPreferencesCopyAppValue(CFSTR("mitmRules"), CFSTR("com.minh.netlogger"));
    NSArray *saved = ref ? (__bridge_transfer NSArray *)ref : @[];
    _rules = [saved mutableCopy] ?: [NSMutableArray array];
}

- (void)saveRules {
    CFPreferencesSetAppValue(CFSTR("mitmRules"), (__bridge CFArrayRef)_rules, CFSTR("com.minh.netlogger"));
    CFPreferencesAppSynchronize(CFSTR("com.minh.netlogger"));

    NSMutableDictionary *dict = [NSMutableDictionary dictionaryWithContentsOfFile:PREFS_PLIST] ?: [NSMutableDictionary dictionary];
    dict[@"mitmRules"] = _rules;
    [dict writeToFile:PREFS_PLIST atomically:YES];
    [[NSFileManager defaultManager] setAttributes:@{NSFilePosixPermissions: @(0644)} ofItemAtPath:PREFS_PLIST error:nil];

    [_tableView reloadData];
}

- (void)addRule {
    NLMitmEditController *vc = [[NLMitmEditController alloc] init];
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

        UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"wand.and.rays"]];
        icon.tintColor = [UIColor systemGray3Color];
        icon.contentMode = UIViewContentModeScaleAspectFit;
        icon.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyView addSubview:icon];

        UILabel *titleLbl = [[UILabel alloc] init];
        titleLbl.text = @"No Rules";
        titleLbl.font = [UIFont systemFontOfSize:20 weight:UIFontWeightSemibold];
        titleLbl.textColor = [UIColor secondaryLabelColor];
        titleLbl.textAlignment = NSTextAlignmentCenter;
        titleLbl.translatesAutoresizingMaskIntoConstraints = NO;
        [emptyView addSubview:titleLbl];

        UILabel *subtitleLbl = [[UILabel alloc] init];
        subtitleLbl.text = @"Tap + to create a rule that modifies\nrequests or responses in real-time.";
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
    return _rules.count > 0 ? [NSString stringWithFormat:@"Rules (%lu)", (unsigned long)_rules.count] : nil;
}

- (UITableViewCell *)tableView:(UITableView *)tv cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    NLMitmRuleCell *cell = [tv dequeueReusableCellWithIdentifier:@"RuleCell" forIndexPath:indexPath];
    [cell configureWithRule:_rules[indexPath.row]];
    return cell;
}

- (void)tableView:(UITableView *)tv didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tv deselectRowAtIndexPath:indexPath animated:YES];
    if (_rules.count == 0) return;

    NLMitmEditController *vc = [[NLMitmEditController alloc] init];
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
    UIContextualAction *deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:@"Delete" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        [self->_rules removeObjectAtIndex:indexPath.row];
        [self saveRules];
        completion(YES);
    }];
    deleteAction.image = [UIImage systemImageNamed:@"trash"];

    // Duplicate
    UIContextualAction *dupAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal title:@"Duplicate" handler:^(UIContextualAction *action, UIView *sourceView, void (^completion)(BOOL)) {
        NSMutableDictionary *copy = [self->_rules[indexPath.row] mutableCopy];
        copy[@"enabled"] = @NO; // duplicates start disabled
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

    NSString *title = isEnabled ? @"Disable" : @"Enable";
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
