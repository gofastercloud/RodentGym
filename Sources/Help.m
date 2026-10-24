// Help — see Help.h.

#import "Help.h"
#import "UI.h"

static const CGFloat kBody = 14;

#pragma mark - Parsing Help.md

@interface RGHelpTopic : NSObject
@property (copy) NSString *title, *symbol, *summary;
@property (strong) NSMutableArray<NSString *> *lines;
@property (copy) NSString *searchText;
@end
@implementation RGHelpTopic
@end

static NSArray<RGHelpTopic *> *parseHelp(NSString *md) {
    NSMutableArray *topics = [NSMutableArray array];
    // Drop the format notes at the top
    NSRange comment = [md rangeOfString:@"-->"];
    if ([md hasPrefix:@"<!--"] && comment.location != NSNotFound) md = [md substringFromIndex:NSMaxRange(comment)];
    RGHelpTopic *t = nil;
    for (NSString *raw in [md componentsSeparatedByString:@"\n"]) {
        if ([raw hasPrefix:@"# "]) {
            NSArray *parts = [[raw substringFromIndex:2] componentsSeparatedByString:@"|"];
            t = [RGHelpTopic new];
            t.title = [parts[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
            t.symbol = parts.count > 1 ? [parts[1] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"book";
            t.summary = parts.count > 2 ? [parts[2] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet] : @"";
            t.lines = [NSMutableArray array];
            [topics addObject:t];
        } else if (t) {
            [t.lines addObject:raw];
        }
    }
    for (RGHelpTopic *topic in topics)
        topic.searchText = [[@[topic.title, topic.summary, [topic.lines componentsJoinedByString:@" "]] componentsJoinedByString:@" "] lowercaseString];
    return topics;
}

#pragma mark - Rendering

static NSMutableParagraphStyle *paragraph(CGFloat before, CGFloat after) {
    NSMutableParagraphStyle *p = [NSMutableParagraphStyle new];
    p.lineHeightMultiple = 1.18;
    p.paragraphSpacingBefore = before;
    p.paragraphSpacing = after;
    return p;
}

// **bold**, `code`, [text](url)
static NSAttributedString *inlineText(NSString *s, NSDictionary *base) {
    NSMutableAttributedString *out = [NSMutableAttributedString new];
    NSFont *font = base[NSFontAttributeName];
    NSFont *bold = [NSFont systemFontOfSize:font.pointSize weight:NSFontWeightSemibold];
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:@"\\*\\*(.+?)\\*\\*|`(.+?)`|\\[(.+?)\\]\\((.+?)\\)" options:0 error:nil];
    __block NSUInteger at = 0;
    [re enumerateMatchesInString:s options:0 range:NSMakeRange(0, s.length) usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f, BOOL *stop) {
        if (m.range.location > at) [out appendAttributedString:[[NSAttributedString alloc] initWithString:[s substringWithRange:NSMakeRange(at, m.range.location - at)] attributes:base]];
        NSMutableDictionary *a = [base mutableCopy];
        NSString *text;
        if ([m rangeAtIndex:1].location != NSNotFound) {
            text = [s substringWithRange:[m rangeAtIndex:1]];
            a[NSFontAttributeName] = bold;
        } else if ([m rangeAtIndex:2].location != NSNotFound) {
            text = [NSString stringWithFormat:@" %@ ", [s substringWithRange:[m rangeAtIndex:2]]];
            a[NSFontAttributeName] = [NSFont monospacedSystemFontOfSize:font.pointSize - 1.5 weight:NSFontWeightMedium];
            a[NSBackgroundColorAttributeName] = NSColor.quaternarySystemFillColor;
        } else {
            text = [s substringWithRange:[m rangeAtIndex:3]];
            NSURL *url = [NSURL URLWithString:[s substringWithRange:[m rangeAtIndex:4]]];
            if (url) a[NSLinkAttributeName] = url;
        }
        [out appendAttributedString:[[NSAttributedString alloc] initWithString:text attributes:a]];
        at = NSMaxRange(m.range);
    }];
    if (at < s.length) [out appendAttributedString:[[NSAttributedString alloc] initWithString:[s substringFromIndex:at] attributes:base]];
    return out;
}

static NSAttributedString *renderTopic(RGHelpTopic *t) {
    NSMutableAttributedString *doc = [NSMutableAttributedString new];
    NSString *nl = @"\n";

    // Heading: the topic's symbol, title and one-line summary
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:30 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.controlAccentColor]];
    NSImage *icon = [RGSymbol(t.symbol, t.title) imageWithSymbolConfiguration:cfg];
    if (icon) {
        NSTextAttachment *att = [NSTextAttachment new];
        att.image = icon;
        att.bounds = NSMakeRect(0, 0, icon.size.width, icon.size.height);
        NSMutableAttributedString *iconLine = [[NSAttributedString attributedStringWithAttachment:att] mutableCopy];
        [iconLine addAttribute:NSParagraphStyleAttributeName value:paragraph(0, 10) range:NSMakeRange(0, iconLine.length)];
        [doc appendAttributedString:iconLine];
        [doc appendAttributedString:[[NSAttributedString alloc] initWithString:nl]];
    }
    [doc appendAttributedString:[[NSAttributedString alloc] initWithString:[t.title stringByAppendingString:nl] attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:28 weight:NSFontWeightBold], NSForegroundColorAttributeName: NSColor.labelColor,
        NSParagraphStyleAttributeName: paragraph(0, 4)}]];
    if (t.summary.length)
        [doc appendAttributedString:[[NSAttributedString alloc] initWithString:[t.summary stringByAppendingString:nl] attributes:@{
            NSFontAttributeName: [NSFont systemFontOfSize:16], NSForegroundColorAttributeName: NSColor.secondaryLabelColor,
            NSParagraphStyleAttributeName: paragraph(0, 22)}]];

    NSDictionary *body = @{NSFontAttributeName: [NSFont systemFontOfSize:kBody], NSForegroundColorAttributeName: NSColor.labelColor,
                           NSParagraphStyleAttributeName: paragraph(0, 12)};

    // Two-column rows share a first-column width, measured across the topic
    CGFloat termWidth = 0;
    for (NSString *l in t.lines) {
        if (![l hasPrefix:@"| "]) continue;
        NSArray *cells = [[l substringFromIndex:2] componentsSeparatedByString:@" | "];
        NSAttributedString *term = inlineText([cells[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], body);
        termWidth = MAX(termWidth, term.size.width);
    }
    termWidth = ceil(termWidth) + 20;

    NSMutableArray<NSString *> *para = [NSMutableArray array];
    void (^flush)(void) = ^{
        if (!para.count) return;
        [doc appendAttributedString:inlineText([para componentsJoinedByString:@" "], body)];
        [doc appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:body]];
        [para removeAllObjects];
    };
    NSArray *lines = t.lines;
    for (NSUInteger i = 0; i < lines.count; i++) {
        NSString *l = [lines[i] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if (!l.length) { flush(); continue; }
        if ([l hasPrefix:@"## "]) {
            flush();
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:[[l substringFromIndex:3] stringByAppendingString:nl] attributes:@{
                NSFontAttributeName: [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], NSForegroundColorAttributeName: NSColor.labelColor,
                NSParagraphStyleAttributeName: paragraph(14, 6)}]];
        } else if ([l hasPrefix:@"- "]) {
            flush();
            NSMutableParagraphStyle *p = paragraph(0, 8);
            p.headIndent = 20;
            p.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:20 options:@{}]];
            NSMutableDictionary *a = [body mutableCopy];
            a[NSParagraphStyleAttributeName] = p;
            NSMutableDictionary *dot = [a mutableCopy];
            dot[NSForegroundColorAttributeName] = NSColor.tertiaryLabelColor;
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:@"•\t" attributes:dot]];
            [doc appendAttributedString:inlineText([l substringFromIndex:2], a)];
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:a]];
        } else if ([l hasPrefix:@"| "]) {
            flush();
            NSArray *cells = [[l substringFromIndex:2] componentsSeparatedByString:@" | "];
            NSMutableParagraphStyle *p = paragraph(0, 7);
            p.headIndent = termWidth;
            p.tabStops = @[[[NSTextTab alloc] initWithTextAlignment:NSTextAlignmentLeft location:termWidth options:@{}]];
            NSMutableDictionary *a = [body mutableCopy];
            a[NSParagraphStyleAttributeName] = p;
            NSMutableDictionary *termAttrs = [a mutableCopy];
            termAttrs[NSFontAttributeName] = [NSFont systemFontOfSize:kBody weight:NSFontWeightSemibold];
            [doc appendAttributedString:inlineText([cells[0] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet], termAttrs)];
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:@"\t" attributes:a]];
            NSString *rest = cells.count > 1 ? [[cells subarrayWithRange:NSMakeRange(1, cells.count - 1)] componentsJoinedByString:@" | "] : @"";
            [doc appendAttributedString:inlineText(rest, a)];
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:a]];
        } else if ([l hasPrefix:@"> "]) {
            flush();
            // A callout: tinted panel with an accent bar down its leading edge
            NSTextBlock *block = [NSTextBlock new];
            block.backgroundColor = [NSColor.controlAccentColor colorWithAlphaComponent:0.08];
            [block setValue:100 type:NSTextBlockPercentageValueType forDimension:NSTextBlockWidth];
            [block setWidth:14 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding];
            [block setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMinYEdge];
            [block setWidth:12 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockPadding edge:NSMaxYEdge];
            [block setWidth:3 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockBorder edge:NSMinXEdge];
            [block setBorderColor:NSColor.controlAccentColor forEdge:NSMinXEdge];
            [block setWidth:6 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMinYEdge];
            [block setWidth:16 type:NSTextBlockAbsoluteValueType forLayer:NSTextBlockMargin edge:NSMaxYEdge];
            NSMutableParagraphStyle *p = paragraph(0, 0);
            p.textBlocks = @[block];
            NSMutableDictionary *a = [body mutableCopy];
            a[NSParagraphStyleAttributeName] = p;
            a[NSFontAttributeName] = [NSFont systemFontOfSize:kBody - 0.5];
            [doc appendAttributedString:inlineText([l substringFromIndex:2], a)];
            [doc appendAttributedString:[[NSAttributedString alloc] initWithString:nl attributes:a]];
        } else {
            [para addObject:l];
        }
    }
    flush();
    return doc;
}

#pragma mark - Window

// A topic row. The selected one sits on a soft accent-tinted capsule, drawn here rather than by the
// table so it looks the same everywhere, including rendered screenshots.
@interface RGHelpCell : NSTableCellView
@property (nonatomic) BOOL selected;
@end
@implementation RGHelpCell
- (void)setSelected:(BOOL)selected {
    _selected = selected;
    self.textField.font = [NSFont systemFontOfSize:NSFont.systemFontSize weight:selected ? NSFontWeightSemibold : NSFontWeightRegular];
    self.needsDisplay = YES;
}
- (void)drawRect:(NSRect)dirty {
    if (!self.selected) return;
    [[NSColor.controlAccentColor colorWithAlphaComponent:0.16] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(self.bounds, -4, 1) xRadius:8 yRadius:8] fill];
}
@end

@interface RGHelp ()
@property (strong, readwrite) NSWindow *window;
@property (copy) NSArray<RGHelpTopic *> *topics, *shown;
@property (strong) NSTableView *list;
@property (strong) NSTextView *text;
@property (strong) NSSearchToolbarItem *search;
@end

static NSString *const kSearchItem = @"search";

@implementation RGHelp

- (void)load {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Help" withExtension:@"md"];
    NSString *md = url ? [NSString stringWithContentsOfURL:url encoding:NSUTF8StringEncoding error:nil] : nil;
    self.topics = parseHelp(md ?: @"# Help is missing | exclamationmark.triangle | Help.md isn't in the app bundle\n\nRebuild RodentGym with build.sh.");
    self.shown = self.topics;
}

- (void)buildWindow {
    [self load];
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 940, 680)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"RodentGym Help";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentMinSize = NSMakeSize(680, 420);

    // Sidebar: the topics
    self.list = [NSTableView new];
    self.list.style = NSTableViewStyleSourceList;
    self.list.headerView = nil;
    self.list.rowHeight = 30;
    self.list.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;   // RGHelpCell draws the selection
    self.list.dataSource = self;
    self.list.delegate = self;
    self.list.accessibilityLabel = @"Help topics";
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"topic"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.list addTableColumn:col];
    self.list.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    NSScrollView *listScroll = [NSScrollView new];
    listScroll.documentView = self.list;
    listScroll.drawsBackground = NO;
    listScroll.hasVerticalScroller = YES;
    NSViewController *sidebarVC = [NSViewController new];
    sidebarVC.view = listScroll;

    // Detail: the topic's text (TextKit 1, for callout panels)
    NSScrollView *textScroll = [NSScrollView new];
    textScroll.hasVerticalScroller = YES;
    textScroll.drawsBackground = YES;
    textScroll.backgroundColor = NSColor.textBackgroundColor;
    self.text = [NSTextView textViewUsingTextLayoutManager:NO];
    self.text.frame = NSMakeRect(0, 0, 680, 600);
    self.text.minSize = NSMakeSize(0, 0);
    self.text.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    self.text.editable = NO;
    self.text.selectable = YES;
    self.text.drawsBackground = YES;
    self.text.backgroundColor = NSColor.textBackgroundColor;
    self.text.textContainerInset = NSMakeSize(44, 36);
    self.text.autoresizingMask = NSViewWidthSizable;
    self.text.verticallyResizable = YES;
    self.text.textContainer.widthTracksTextView = YES;
    self.text.linkTextAttributes = @{NSForegroundColorAttributeName: NSColor.linkColor, NSCursorAttributeName: NSCursor.pointingHandCursor};
    textScroll.documentView = self.text;
    NSViewController *detailVC = [NSViewController new];
    detailVC.view = textScroll;

    NSSplitViewController *split = [NSSplitViewController new];
    NSSplitViewItem *side = [NSSplitViewItem sidebarWithViewController:sidebarVC];
    side.minimumThickness = 210;
    side.maximumThickness = 300;
    side.canCollapse = NO;
    [split addSplitViewItem:side];
    NSSplitViewItem *detail = [NSSplitViewItem splitViewItemWithViewController:detailVC];
    detail.minimumThickness = 420;
    [split addSplitViewItem:detail];
    self.window.contentViewController = split;
    [self.window setContentSize:NSMakeSize(940, 680)];

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"HelpToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymHelpWindow"];

    [self.list reloadData];
    [self.list selectRowIndexes:[NSIndexSet indexSetWithIndex:0] byExtendingSelection:NO];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarSidebarTrackingSeparatorItemIdentifier, NSToolbarFlexibleSpaceItemIdentifier, kSearchItem];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    if (![ident isEqualToString:kSearchItem]) return nil;
    self.search = [[NSSearchToolbarItem alloc] initWithItemIdentifier:kSearchItem];
    self.search.searchField.placeholderString = @"Search Help";
    self.search.searchField.delegate = self;
    self.search.searchField.target = self;
    self.search.searchField.action = @selector(searchChanged:);
    return self.search;
}

- (void)searchChanged:(NSSearchField *)field {
    NSString *q = [field.stringValue stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet].lowercaseString;
    RGHelpTopic *selected = self.list.selectedRow >= 0 && self.list.selectedRow < (NSInteger)self.shown.count ? self.shown[(NSUInteger)self.list.selectedRow] : nil;
    if (!q.length) {
        self.shown = self.topics;
    } else {
        NSArray *words = [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        self.shown = [self.topics filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(RGHelpTopic *t, NSDictionary *b) {
            for (NSString *w in words) if (w.length && ![t.searchText containsString:w]) return NO;
            return YES;
        }]];
    }
    [self.list reloadData];
    NSUInteger keep = selected ? [self.shown indexOfObject:selected] : NSNotFound;
    if (self.shown.count) [self.list selectRowIndexes:[NSIndexSet indexSetWithIndex:keep != NSNotFound ? keep : 0] byExtendingSelection:NO];
    else [self.text.textStorage setAttributedString:[[NSAttributedString alloc] initWithString:@"No topics match your search." attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:kBody], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}]];
    if (q.length) [self highlight:q];
}

// Marks search words in the visible topic.
- (void)highlight:(NSString *)q {
    NSString *s = self.text.string.lowercaseString;
    for (NSString *w in [q componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]) {
        if (w.length < 2) continue;
        NSRange r = NSMakeRange(0, s.length), found;
        while ((found = [s rangeOfString:w options:0 range:r]).location != NSNotFound) {
            [self.text.layoutManager addTemporaryAttribute:NSBackgroundColorAttributeName value:[NSColor.findHighlightColor colorWithAlphaComponent:0.6] forCharacterRange:found];
            r = NSMakeRange(NSMaxRange(found), s.length - NSMaxRange(found));
        }
    }
}

#pragma mark Topic list

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.shown.count; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)col row:(NSInteger)row {
    RGHelpCell *cell = [tv makeViewWithIdentifier:@"topicCell" owner:self];
    if (!cell) {
        cell = [RGHelpCell new];
        cell.identifier = @"topicCell";
        NSImageView *iv = [NSImageView new];
        NSTextField *tf = [NSTextField labelWithString:@""];
        tf.lineBreakMode = NSLineBreakByTruncatingTail;
        iv.translatesAutoresizingMaskIntoConstraints = NO;
        tf.translatesAutoresizingMaskIntoConstraints = NO;
        [cell addSubview:iv];
        [cell addSubview:tf];
        cell.imageView = iv;
        cell.textField = tf;
        [NSLayoutConstraint activateConstraints:@[
            [iv.leadingAnchor constraintEqualToAnchor:cell.leadingAnchor constant:4],
            [iv.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor],
            [iv.widthAnchor constraintEqualToConstant:20],
            [tf.leadingAnchor constraintEqualToAnchor:iv.trailingAnchor constant:8],
            [tf.trailingAnchor constraintEqualToAnchor:cell.trailingAnchor constant:-4],
            [tf.centerYAnchor constraintEqualToAnchor:cell.centerYAnchor]]];
    }
    RGHelpTopic *t = self.shown[(NSUInteger)row];
    cell.imageView.image = RGSymbol(t.symbol, t.title);
    cell.imageView.contentTintColor = NSColor.controlAccentColor;
    cell.textField.stringValue = t.title;
    cell.textField.textColor = NSColor.labelColor;
    cell.selected = row == tv.selectedRow;
    return cell;
}

- (void)tableViewSelectionDidChange:(NSNotification *)n {
    NSInteger row = self.list.selectedRow;
    for (NSInteger r = 0; r < self.list.numberOfRows; r++) {
        RGHelpCell *c = [self.list viewAtColumn:0 row:r makeIfNecessary:NO];
        if ([c isKindOfClass:RGHelpCell.class]) c.selected = r == row;
    }
    if (row < 0 || row >= (NSInteger)self.shown.count) return;
    [self.text.textStorage setAttributedString:renderTopic(self.shown[(NSUInteger)row])];
    [self.text scrollPoint:NSZeroPoint];
    NSString *q = self.search.searchField.stringValue.lowercaseString;
    if (q.length) [self highlight:q];
}

#pragma mark Showing

- (void)show {
    BOOL first = !self.window;
    if (first) [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    if (first) {   // rows are only made once the sidebar has its size
        [self.window.contentView layoutSubtreeIfNeeded];
        NSInteger row = MAX(0, self.list.selectedRow);
        [self.list reloadData];
        [self.list selectRowIndexes:[NSIndexSet indexSetWithIndex:(NSUInteger)row] byExtendingSelection:NO];
    }
}

- (void)showTopic:(NSString *)title {
    [self show];
    self.search.searchField.stringValue = @"";
    [self searchChanged:self.search.searchField];
    for (NSUInteger i = 0; i < self.shown.count; i++)
        if ([self.shown[i].title hasPrefix:title]) {
            [self.list selectRowIndexes:[NSIndexSet indexSetWithIndex:i] byExtendingSelection:NO];
            [self.list scrollRowToVisible:(NSInteger)i];
        }
}

@end
