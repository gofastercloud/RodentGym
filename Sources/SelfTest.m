// Hardware Self-Test — see SelfTest.h.

#import "SelfTest.h"
#import "Multitouch.h"
#import "UI.h"
#include <sys/sysctl.h>

#define MAXG 40
#define COUNTDOWN 3.0
#define IDLE_SECONDS 10.0

typedef NS_ENUM(NSInteger, RGTest) { RGTestCoverage, RGTestPhantom, RGTestHaptics };
typedef NS_ENUM(NSInteger, RGPhase) { RGPhaseReady, RGPhaseCountdown, RGPhaseRunning, RGPhaseAsking, RGPhaseDone };

static NSString *const kTestKeys[] = {@"coverage", @"phantom", @"haptics"};
static NSString *const kTestNames[] = {@"Surface Coverage", @"Phantom Touch", @"Haptics"};
static NSString *const kTestSymbols[] = {@"square.grid.3x3.topleft.filled", @"hand.raised.slash", @"waveform"};

static BOOL contact(int state) { return state >= RGTouchMake && state <= RGTouchBreak; }

static NSColor *statusColour(NSString *s) {
    if ([s isEqual:@"pass"]) return NSColor.systemGreenColor;
    if ([s isEqual:@"fail"]) return NSColor.systemRedColor;
    if ([s isEqual:@"warn"]) return NSColor.systemOrangeColor;
    return NSColor.secondaryLabelColor;
}
static NSString *statusName(NSString *s) {
    if ([s isEqual:@"pass"]) return @"Pass";
    if ([s isEqual:@"fail"]) return @"Fail";
    if ([s isEqual:@"warn"]) return @"Check";
    if ([s isEqual:@"na"]) return @"Not applicable";
    if ([s isEqual:@"running"]) return @"Running";
    return @"Not run";
}

@class RGSelfTestView;

@interface RGSelfTest () {
@public
    RGTest test;
    RGPhase phase;
    double phaseStart, lastContactTime;
    int nx, ny, maskCount, hitCount;
    BOOL mask[MAXG][MAXG], hit[MAXG][MAXG];
    struct { int id; float x, y; } prevTouch[MAX_TOUCHES];
    int prevTouchCount;
    RGFrameStats base;
    long phantomFrames;
    double pulseStart[3];
    int pulsesWithFinger;
    BOOL demo;
    MTFinger demoTouch;
}
@property (strong, readwrite) NSWindow *window;
@property (strong) RGSelfTestView *view;
@property (strong) NSPopUpButton *devicePopup;
@property (strong) NSSegmentedControl *testPicker;
@property (strong) NSStackView *panel;
@property (strong) NSTextField *titleLabel, *bodyLabel, *metricsLabel;
@property (strong) NSProgressIndicator *progress;
@property (strong) NSButton *primary, *secondary, *tertiary;
@property (strong) NSTimer *timer;
@property (copy) NSArray<NSDictionary *> *deviceList;
@property (copy) NSDictionary *current;
@property (strong) NSMutableArray<NSValue *> *phantomPoints;
@property (strong) NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, NSDictionary *> *> *results;
- (NSDictionary *)resultFor:(RGTest)t;
- (BOOL)hasHaptics;
- (int)kind;
- (void)selectTest:(RGTest)t;
@end

#pragma mark - View

@interface RGSelfTestView : NSView
@property (weak) RGSelfTest *st;
- (NSRect)surfaceCard;
- (NSRect)panelCard;
- (NSRect)strip;
@end

@implementation RGSelfTestView

- (BOOL)isFlipped { return YES; }

- (NSRect)surfaceCard {
    CGFloat top = self.safeAreaInsets.top + 16;
    return NSMakeRect(20, top, self.bounds.size.width - 40 - 16 - 340, MAX(300, self.bounds.size.height - top - 20 - 92 - 16));
}
- (NSRect)panelCard { NSRect s = self.surfaceCard; return NSMakeRect(NSMaxX(s) + 16, s.origin.y, 340, s.size.height); }
- (NSRect)strip { NSRect s = self.surfaceCard; return NSMakeRect(20, NSMaxY(s) + 16, self.bounds.size.width - 40, 92); }

// The surface at the sensor's real aspect ratio, centred under the card's title.
- (NSRect)surfaceIn:(NSRect)card {
    NSDictionary *d = self.st.current;
    double w = [d[@"widthMM"] doubleValue], h = [d[@"heightMM"] doubleValue];
    double aspect = (w > 0 && h > 0) ? w / h : (self.st.kind == 0 ? 0.57 : 1.41);
    NSRect area = NSInsetRect(NSMakeRect(card.origin.x, card.origin.y + 56, card.size.width, card.size.height - 56), 36, 24);
    NSSize sz = (area.size.width / area.size.height > aspect) ? NSMakeSize(area.size.height * aspect, area.size.height)
                                                              : NSMakeSize(area.size.width, area.size.width / aspect);
    return NSMakeRect(round(NSMidX(area) - sz.width / 2), round(NSMidY(area) - sz.height / 2), round(sz.width), round(sz.height));
}

- (void)drawRect:(NSRect)dirty {
    RGSelfTest *st = self.st;
    if (!st) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSRect card = self.surfaceCard;
    RGDrawCard(card, 18);
    RGDrawCard(self.panelCard, 18);
    NSDictionary *d = st.current;
    if (!d) {
        RGDrawText(@"No Magic Mouse or trackpad connected", NSMakeRect(card.origin.x, NSMidY(card) - 10, card.size.width, 20),
                   [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor, NSTextAlignmentCenter);
        [self drawStrip];
        return;
    }
    RGDrawText(d[@"name"], NSMakeRect(card.origin.x + 20, card.origin.y + 16, card.size.width - 40, 20),
               [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    NSMutableArray *sub = [NSMutableArray arrayWithObject:d[@"model"] ?: @""];
    if (d[@"firmware"]) [sub addObject:[@"firmware " stringByAppendingString:d[@"firmware"]]];
    RGDrawText([sub componentsJoinedByString:@" · "], NSMakeRect(card.origin.x + 20, card.origin.y + 37, card.size.width - 40, 16),
               [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);

    NSRect s = [self surfaceIn:card];
    int kind = st.kind;
    RGDrawSurface(kind, s, [d[@"darkTop"] boolValue]);
    BOOL dark = [d[@"darkTop"] boolValue];
    [NSGraphicsContext saveGraphicsState];
    [RGSurfacePath(kind, s) addClip];
    if (st->test == RGTestCoverage) [self drawCoverage:s dark:dark];
    else if (st->test == RGTestPhantom) [self drawPhantom:s];
    else [self drawHaptics:s];
    [self drawTouches:s];
    [NSGraphicsContext restoreGraphicsState];
    [self drawOverlay:s];
    [self drawStrip];
}

- (NSRect)cellRect:(int)i :(int)j in:(NSRect)s {
    RGSelfTest *st = self.st;
    CGFloat cw = s.size.width / st->nx, ch = s.size.height / st->ny;
    return NSMakeRect(s.origin.x + i * cw, s.origin.y + j * ch, cw, ch);
}

- (void)drawCoverage:(NSRect)s dark:(BOOL)dark {
    RGSelfTest *st = self.st;
    BOOL done = st->phase == RGPhaseDone;
    BOOL active = st->phase == RGPhaseRunning || done;
    for (int i = 0; i < st->nx; i++)
        for (int j = 0; j < st->ny; j++) {
            if (!st->mask[i][j]) continue;
            NSRect c = NSInsetRect([self cellRect:i :j in:s], 0.75, 0.75);
            if (st->hit[i][j]) [[NSColor.systemGreenColor colorWithAlphaComponent:dark ? 0.5 : 0.42] setFill];
            else if (done) [[NSColor.systemRedColor colorWithAlphaComponent:0.38] setFill];
            else if (active) [[NSColor colorWithWhite:dark ? 1 : 0 alpha:0.045] setFill];
            else continue;
            [[NSBezierPath bezierPathWithRoundedRect:c xRadius:2 yRadius:2] fill];
        }
}

- (void)drawPhantom:(NSRect)s {
    RGSelfTest *st = self.st;
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    for (NSValue *v in st.phantomPoints) {
        NSPoint p = v.pointValue;
        NSPoint c = NSMakePoint(s.origin.x + p.x * s.size.width, s.origin.y + (1 - p.y) * s.size.height);
        CGFloat r = 9;
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 14, [NSColor.systemRedColor colorWithAlphaComponent:0.8].CGColor);
        [[NSColor.systemRedColor colorWithAlphaComponent:0.85] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)] fill];
        CGContextRestoreGState(ctx);
    }
}

- (void)drawHaptics:(NSRect)s {
    RGSelfTest *st = self.st;
    double now = CFAbsoluteTimeGetCurrent();
    NSPoint c = NSMakePoint(NSMidX(s), NSMidY(s));
    CGFloat reach = MIN(s.size.width, s.size.height) * 0.48;
    for (int k = 0; k < 3; k++) {
        double age = now - st->pulseStart[k];
        if (st->pulseStart[k] <= 0 || age < 0 || age > 0.7) continue;
        double t = age / 0.7, e = 1 - pow(1 - t, 3);
        for (int ring = 0; ring < 2; ring++) {
            double rr = reach * (0.15 + 0.85 * MAX(0, e - ring * 0.18));
            NSBezierPath *p = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - rr, c.y - rr, 2 * rr, 2 * rr)];
            p.lineWidth = 3 - ring;
            [[NSColor.systemPurpleColor colorWithAlphaComponent:0.75 * (1 - t)] setStroke];
            [p stroke];
        }
    }
}

- (void)drawTouches:(NSRect)s {
    RGSelfTest *st = self.st;
    MTFinger t[MAX_TOUCHES];
    int n = 0;
    if (st->demo) { t[0] = st->demoTouch; n = 1; }
    else n = RGCopyTouches([st.current[@"slot"] intValue], t);
    CGFloat r = MAX(7, MIN(s.size.width, s.size.height) * 0.04);
    for (int i = 0; i < n; i++) {
        if (!contact(t[i].state) && !st->demo) continue;
        NSPoint c = NSMakePoint(s.origin.x + t[i].normalized.pos.x * s.size.width, s.origin.y + (1 - t[i].normalized.pos.y) * s.size.height);
        NSColor *col = st->test == RGTestPhantom && st->phase == RGPhaseRunning ? NSColor.systemRedColor : NSColor.systemBlueColor;
        [[col colorWithAlphaComponent:0.25] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r * 1.6, c.y - r * 1.6, r * 3.2, r * 3.2)] fill];
        [col setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r * 0.7, c.y - r * 0.7, r * 1.4, r * 1.4)] fill];
    }
}

// Big centred state text over the surface: the countdown, "Hands off", or the result.
- (void)drawOverlay:(NSRect)s {
    RGSelfTest *st = self.st;
    NSString *big = nil;
    NSColor *colour = NSColor.labelColor;
    double now = CFAbsoluteTimeGetCurrent();
    if (st->test == RGTestPhantom) {
        if (st->phase == RGPhaseCountdown) big = [NSString stringWithFormat:@"%d", (int)ceil(COUNTDOWN - (now - st->phaseStart))];
        else if (st->phase == RGPhaseRunning) { big = @"Hands off"; colour = NSColor.secondaryLabelColor; }
    }
    if (st->test == RGTestHaptics && !st.hasHaptics) { big = @"No haptic engine"; colour = NSColor.secondaryLabelColor; }
    if (!big) return;
    NSFont *f = [NSFont systemFontOfSize:big.length <= 2 ? 64 : 26 weight:NSFontWeightBold];
    NSDictionary *a = @{NSFontAttributeName: f};
    NSSize sz = [big sizeWithAttributes:a];
    NSRect pill = NSMakeRect(NSMidX(s) - sz.width / 2 - 26, NSMidY(s) - sz.height / 2 - 12, sz.width + 52, sz.height + 24);
    [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.78] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:pill xRadius:pill.size.height / 2 yRadius:pill.size.height / 2] fill];
    RGDrawText(big, NSMakeRect(pill.origin.x, NSMidY(pill) - sz.height / 2, pill.size.width, sz.height + 2), f, colour, NSTextAlignmentCenter);
}

- (void)drawStrip {
    RGSelfTest *st = self.st;
    NSRect r = self.strip;
    CGFloat w = (r.size.width - 2 * 12) / 3;
    for (int i = 0; i < 3; i++) {
        NSRect t = NSMakeRect(r.origin.x + i * (w + 12), r.origin.y, w, r.size.height);
        RGDrawCard(t, 16);
        if (st->test == i) {
            NSBezierPath *sel = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(t, 1, 1) xRadius:15 yRadius:15];
            sel.lineWidth = 2;
            [NSColor.controlAccentColor setStroke];
            [sel stroke];
        }
        NSDictionary *res = [st resultFor:(RGTest)i];
        NSString *status = res[@"status"] ?: @"none";
        NSImage *icon = [RGSymbol(kTestSymbols[i], kTestNames[i]) imageWithSymbolConfiguration:
                         [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium]];
        [icon drawInRect:NSMakeRect(t.origin.x + 16, t.origin.y + 16, icon.size.width, icon.size.height) fromRect:NSZeroRect
               operation:NSCompositingOperationSourceOver fraction:0.7 respectFlipped:YES hints:nil];
        RGDrawText(kTestNames[i], NSMakeRect(t.origin.x + 42, t.origin.y + 15, w - 150, 18),
                   [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
        RGDrawPill(NSMakeRect(NSMaxX(t) - 16 - 104, t.origin.y + 14, 104, 22), statusName(status), statusColour(status));
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        NSString *detail = res[@"summary"] ?: @"Not run yet";
        [detail drawWithRect:NSMakeRect(t.origin.x + 16, t.origin.y + 46, w - 32, 34)
                     options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                  attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSParagraphStyleAttributeName: ps,
                               NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    }
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect r = self.strip;
    if (!NSPointInRect(p, r)) return;
    CGFloat w = (r.size.width - 2 * 12) / 3;
    int i = (int)((p.x - r.origin.x) / (w + 12));
    if (i >= 0 && i < 3) [self.st selectTest:(RGTest)i];
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Self-test surface"; }
- (NSString *)accessibilityValue {
    RGSelfTest *st = self.st;
    NSMutableArray *a = [NSMutableArray array];
    for (int i = 0; i < 3; i++) {
        NSDictionary *res = [st resultFor:(RGTest)i];
        [a addObject:[NSString stringWithFormat:@"%@: %@", kTestNames[i], statusName(res[@"status"] ?: @"none")]];
    }
    return [a componentsJoinedByString:@". "];
}
@end

#pragma mark - Controller

static NSString *const kDeviceItem = @"device", *const kTestItem = @"test", *const kReportItem = @"report";

@implementation RGSelfTest

- (instancetype)init {
    if ((self = [super init])) {
        _results = [NSMutableDictionary dictionary];
        _phantomPoints = [NSMutableArray array];
    }
    return self;
}

- (int)kind {
    if ([self.current[@"builtIn"] boolValue]) return 2;
    return [self.current[@"kind"] isEqual:@"mouse"] ? 0 : 1;
}

// Force Touch trackpads have a haptic engine; the Magic Mouse and the first Magic Trackpad don't.
- (BOOL)hasHaptics {
    if (!self.current || self.kind == 0) return NO;
    return [self.current[@"productID"] intValue] != 0x030e;
}

- (NSString *)deviceKey { return self.current[@"key"] ?: @"none"; }

- (NSDictionary *)resultFor:(RGTest)t {
    if (t == RGTestHaptics && self.current && !self.hasHaptics)
        return @{@"status": @"na", @"summary": @"This device has no haptic engine.", @"detail": @"Not applicable: this device has no haptic engine."};
    if (t == test && (phase == RGPhaseRunning || phase == RGPhaseCountdown || phase == RGPhaseAsking))
        return @{@"status": @"running", @"summary": @"In progress"};
    return self.results[self.deviceKey][kTestKeys[t]];
}

- (void)setResult:(RGTest)t status:(NSString *)status summary:(NSString *)summary detail:(NSString *)detail {
    NSMutableDictionary *r = self.results[self.deviceKey];
    if (!r) { r = [NSMutableDictionary dictionary]; self.results[self.deviceKey] = r; }
    r[kTestKeys[t]] = @{@"status": status, @"summary": summary, @"detail": detail};
    if (self.log && !demo)
        self.log([NSString stringWithFormat:@"%@ Self-test, %@: %@ %@ — %@", [status isEqual:@"pass"] ? @"✓" : [status isEqual:@"fail"] ? @"✗" : @"·",
                  self.current[@"name"], kTestNames[t].lowercaseString, statusName(status).lowercaseString, summary]);
    NSAccessibilityPostNotificationWithUserInfo(self.view, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: [NSString stringWithFormat:@"%@: %@. %@", kTestNames[t], statusName(status), summary],
          NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)});
}

#pragma mark Window

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1060, 720)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Hardware Self-Test";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentMinSize = NSMakeSize(940, 640);

    self.devicePopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 200, 28) pullsDown:NO];
    self.devicePopup.target = self;
    self.devicePopup.action = @selector(deviceChanged:);
    self.devicePopup.accessibilityLabel = @"Device to test";
    NSMutableArray *images = [NSMutableArray array];
    for (int i = 0; i < 3; i++) [images addObject:RGSymbol(kTestSymbols[i], kTestNames[i]) ?: [NSImage new]];
    self.testPicker = [NSSegmentedControl segmentedControlWithLabels:@[kTestNames[0], kTestNames[1], kTestNames[2]]
                                                        trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(testChanged:)];
    for (int i = 0; i < 3; i++) [self.testPicker setImage:images[i] forSegment:i];
    self.testPicker.selectedSegment = 0;
    self.testPicker.accessibilityLabel = @"Test";

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"SelfTestToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    if (@available(macOS 13.0, *)) toolbar.centeredItemIdentifiers = [NSSet setWithObject:kTestItem];
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;

    self.view = [[RGSelfTestView alloc] initWithFrame:NSMakeRect(0, 0, 1060, 720)];
    self.view.st = self;
    self.window.contentView = self.view;
    [self buildPanel];
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymSelfTest"];
}

- (void)buildPanel {
    self.titleLabel = RGLabel(@"", [NSFont systemFontOfSize:19 weight:NSFontWeightBold], NSColor.labelColor);
    self.bodyLabel = [NSTextField wrappingLabelWithString:@""];
    self.bodyLabel.font = [NSFont systemFontOfSize:13];
    self.bodyLabel.textColor = NSColor.secondaryLabelColor;
    self.bodyLabel.preferredMaxLayoutWidth = 292;
    [self.bodyLabel.widthAnchor constraintEqualToConstant:292].active = YES;
    self.metricsLabel = [NSTextField wrappingLabelWithString:@""];
    self.metricsLabel.font = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightMedium];
    self.metricsLabel.textColor = NSColor.labelColor;
    self.metricsLabel.preferredMaxLayoutWidth = 292;
    [self.metricsLabel.widthAnchor constraintEqualToConstant:292].active = YES;
    self.progress = [NSProgressIndicator new];
    self.progress.style = NSProgressIndicatorStyleBar;
    self.progress.indeterminate = NO;
    self.progress.minValue = 0;
    self.progress.maxValue = 1;
    [self.progress.widthAnchor constraintEqualToConstant:292].active = YES;
    self.primary = [NSButton buttonWithTitle:@"Start" target:self action:@selector(primaryAction:)];
    self.primary.keyEquivalent = @"\r";
    self.primary.controlSize = NSControlSizeLarge;
    self.secondary = [NSButton buttonWithTitle:@"" target:self action:@selector(secondaryAction:)];
    self.secondary.controlSize = NSControlSizeLarge;
    self.tertiary = [NSButton buttonWithTitle:@"" target:self action:@selector(tertiaryAction:)];
    self.tertiary.controlSize = NSControlSizeLarge;
    NSStackView *buttons = [NSStackView stackViewWithViews:@[self.primary, self.secondary, self.tertiary]];
    buttons.spacing = 8;
    self.panel = [NSStackView new];
    self.panel.orientation = NSUserInterfaceLayoutOrientationVertical;
    self.panel.alignment = NSLayoutAttributeLeading;
    self.panel.spacing = 14;
    for (NSView *v in @[self.titleLabel, self.bodyLabel, self.progress, self.metricsLabel, buttons])
        [self.panel addView:v inGravity:NSStackViewGravityTop];
    NSTextField *footnote = [NSTextField wrappingLabelWithString:
        @"When you're done, Copy Report in the toolbar puts every result, with the device's model, firmware and serial number, on the clipboard for an Apple support case."];
    footnote.font = [NSFont systemFontOfSize:11];
    footnote.textColor = NSColor.tertiaryLabelColor;
    footnote.preferredMaxLayoutWidth = 292;
    [footnote.widthAnchor constraintEqualToConstant:292].active = YES;
    [self.panel addView:footnote inGravity:NSStackViewGravityBottom];
    [self.panel setCustomSpacing:8 afterView:self.titleLabel];
    [self.panel setCustomSpacing:22 afterView:self.metricsLabel];
    [self.view addSubview:self.panel];
}

- (void)layoutPanel {
    self.panel.frame = NSInsetRect(self.view.panelCard, 24, 24);
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kDeviceItem, NSToolbarFlexibleSpaceItemIdentifier, kTestItem, NSToolbarFlexibleSpaceItemIdentifier, kReportItem];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    if ([ident isEqualToString:kDeviceItem]) {
        item.label = @"Device";
        item.view = self.devicePopup;
    } else if ([ident isEqualToString:kTestItem]) {
        item.label = @"Test";
        item.view = self.testPicker;
    } else {
        item.label = @"Copy Report";
        item.image = RGSymbol(@"doc.on.clipboard", @"Copy report");
        item.toolTip = @"Copy the results as text, for example for an Apple support case";
        item.target = self;
        item.action = @selector(copyReport:);
        item.bordered = YES;
    }
    return item;
}

#pragma mark Devices and test selection

- (void)reloadDevices {
    NSArray *list = demo ? self.deviceList : (self.devices ? self.devices() : @[]);
    NSString *keep = self.current[@"key"];
    self.deviceList = list;
    [self.devicePopup removeAllItems];
    for (NSDictionary *d in list) [self.devicePopup addItemWithTitle:d[@"name"]];
    NSDictionary *pick = list.firstObject;
    for (NSDictionary *d in list) if ([d[@"key"] isEqual:keep]) pick = d;
    BOOL changed = ![pick[@"key"] isEqual:keep];
    self.current = pick;
    if (pick) [self.devicePopup selectItemAtIndex:(NSInteger)[list indexOfObject:pick]];
    if (changed) [self resetTest];
}

- (void)deviceChanged:(NSPopUpButton *)p {
    NSInteger i = p.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)self.deviceList.count) return;
    self.current = self.deviceList[(NSUInteger)i];
    [self resetTest];
}

- (void)testChanged:(NSSegmentedControl *)s { [self selectTest:(RGTest)s.selectedSegment]; }

- (void)selectTest:(RGTest)t {
    test = t;
    self.testPicker.selectedSegment = t;
    [self resetTest];
}

- (void)resetTest {
    phase = RGPhaseReady;
    [self.phantomPoints removeAllObjects];
    memset(pulseStart, 0, sizeof pulseStart);
    [self buildGrid];
    [self updatePanel];
}

// One cell per ~4.5 mm, and only cells whose centre lies on the device's surface count.
- (void)buildGrid {
    double w = [self.current[@"widthMM"] doubleValue], h = [self.current[@"heightMM"] doubleValue];
    if (w <= 0 || h <= 0) { w = self.kind == 0 ? 50 : 150; h = self.kind == 0 ? 88 : 105; }
    nx = MAX(8, MIN(MAXG, (int)lround(w / 4.5)));
    ny = MAX(8, MIN(MAXG, (int)lround(h / 4.5)));
    memset(mask, 0, sizeof mask);
    memset(hit, 0, sizeof hit);
    maskCount = hitCount = 0;
    NSBezierPath *shape = RGSurfacePath(self.kind, NSMakeRect(0, 0, 1000, 1000));
    CGFloat inset = self.kind == 0 ? 0.05 : 0.0;   // the mouse's shell curves away at its edges
    for (int i = 0; i < nx; i++)
        for (int j = 0; j < ny; j++) {
            double cx = (i + 0.5) / nx, cy = (j + 0.5) / ny;
            NSPoint p = NSMakePoint(500 + (cx - 0.5) * 1000 * (1 + inset * 2), 500 + (cy - 0.5) * 1000 * (1 + inset * 2));
            if ([shape containsPoint:p]) { mask[i][j] = YES; maskCount++; }
        }
}

#pragma mark Panel text and buttons

- (void)setButtons:(NSString *)a :(NSString *)b :(NSString *)c {
    self.primary.title = a ?: @"";
    self.primary.hidden = !a;
    self.secondary.title = b ?: @"";
    self.secondary.hidden = !b;
    self.tertiary.title = c ?: @"";
    self.tertiary.hidden = !c;
}

- (double)coverage { return maskCount ? (double)hitCount / maskCount : 0; }
- (double)coverageTarget { return self.kind == 0 ? 0.85 : 0.95; }

- (void)updatePanel {
    NSString *name = self.current[@"name"] ?: @"the device";
    NSDictionary *res = self.results[self.deviceKey][kTestKeys[test]];
    self.titleLabel.stringValue = kTestNames[test];
    self.progress.hidden = YES;
    self.metricsLabel.stringValue = @"";
    if (!self.current) {
        self.bodyLabel.stringValue = @"Connect a Magic Mouse or trackpad to test it.";
        [self setButtons:nil :nil :nil];
        return;
    }
    if (test == RGTestCoverage) {
        if (phase == RGPhaseReady) {
            self.bodyLabel.stringValue = [NSString stringWithFormat:
                @"Wipe one finger slowly over the whole surface of %@, row by row, until it's all green. Areas that never light up aren't responding.\n\nUse one finger so macOS doesn't treat it as a gesture.", name];
            [self setButtons:res ? @"Test Again" : @"Start" :nil :nil];
        } else if (phase == RGPhaseRunning) {
            self.bodyLabel.stringValue = [NSString stringWithFormat:@"Keep wiping. The test finishes by itself once %.0f%% of the surface has responded and you lift your finger, or press Finish.",
                                          self.coverageTarget * 100];
            self.progress.hidden = NO;
            self.progress.doubleValue = self.coverage;
            [self setButtons:@"Finish" :@"Cancel" :nil];
        } else {
            self.bodyLabel.stringValue = res[@"detail"] ?: @"";
            [self setButtons:@"Test Again" :nil :nil];
        }
        if (phase != RGPhaseReady) {
            RGFrameStats now = [self stats];
            self.metricsLabel.stringValue = [NSString stringWithFormat:@"Covered   %3.0f%%  (target %.0f%%)\nStrokes   %ld\nLost      %ld",
                self.coverage * 100, self.coverageTarget * 100, now.strokes - base.strokes, now.lost - base.lost];
        }
    } else if (test == RGTestPhantom) {
        if (phase == RGPhaseReady) {
            self.bodyLabel.stringValue = [NSString stringWithFormat:
                @"Checks that %@ reports nothing when nobody is touching it.\n\nPress Start, then take your hands away and keep it still for %.0f seconds. Put a mouse on a clean, dry, non-metallic surface.",
                name, IDLE_SECONDS];
            [self setButtons:res ? @"Test Again" : @"Start" :nil :nil];
        } else if (phase == RGPhaseCountdown) {
            self.bodyLabel.stringValue = @"Take your hands away now.";
            [self setButtons:nil :@"Cancel" :nil];
        } else if (phase == RGPhaseRunning) {
            self.bodyLabel.stringValue = @"Listening for contacts. Don't touch the device.";
            self.progress.hidden = NO;
            self.progress.doubleValue = MIN(1, (CFAbsoluteTimeGetCurrent() - phaseStart) / IDLE_SECONDS);
            self.metricsLabel.stringValue = [NSString stringWithFormat:@"Contact frames  %ld\nPlaces          %lu", phantomFrames, (unsigned long)self.phantomPoints.count];
            [self setButtons:nil :@"Cancel" :nil];
        } else {
            self.bodyLabel.stringValue = res[@"detail"] ?: @"";
            [self setButtons:@"Test Again" :nil :nil];
        }
    } else {
        if (!self.hasHaptics) {
            self.bodyLabel.stringValue = self.kind == 0
                ? @"The Magic Mouse has no haptic engine, so there's nothing to test here. Its click is mechanical."
                : @"The first-generation Magic Trackpad clicks mechanically and has no haptic engine.";
            [self setButtons:nil :nil :nil];
        } else if (phase == RGPhaseReady) {
            self.bodyLabel.stringValue = [NSString stringWithFormat:
                @"A Force Touch trackpad's click is made by its haptic engine. This plays three taps through it.\n\nRest one finger lightly on %@ without clicking, then press Return to play.", name];
            [self setButtons:res ? @"Play Again" : @"Play" :nil :nil];
        } else if (phase == RGPhaseRunning) {
            self.bodyLabel.stringValue = @"Keep your finger resting on the trackpad…";
            [self setButtons:nil :nil :nil];
        } else if (phase == RGPhaseAsking) {
            self.bodyLabel.stringValue = pulsesWithFinger == 0
                ? @"Did you feel three distinct taps?\n\nRodentGym didn't see a finger on this trackpad while they played, so if you felt nothing, rest a finger on it and play again."
                : @"Did you feel three distinct taps?";
            [self setButtons:@"Yes, I Felt Them" :@"No" :@"Play Again"];
        } else {
            self.bodyLabel.stringValue = res[@"detail"] ?: @"";
            [self setButtons:@"Play Again" :nil :nil];
        }
    }
}

#pragma mark Actions

- (RGFrameStats)stats {
    RGFrameStats s;
    if (demo) { memset(&s, 0, sizeof s); s.strokes = 23; return s; }
    RGGetFrameStats([self.current[@"slot"] intValue], &s);
    return s;
}

- (void)primaryAction:(id)sender {
    if (!self.current) return;
    if (test == RGTestCoverage) {
        if (phase == RGPhaseRunning) [self finishCoverage];
        else { [self buildGrid]; base = [self stats]; prevTouchCount = 0; lastContactTime = 0; phase = RGPhaseRunning; }
    } else if (test == RGTestPhantom) {
        [self.phantomPoints removeAllObjects];
        phantomFrames = 0;
        phase = RGPhaseCountdown;
        phaseStart = CFAbsoluteTimeGetCurrent();
    } else if (self.hasHaptics) {
        if (phase == RGPhaseAsking) {
            [self setResult:RGTestHaptics status:@"pass" summary:@"All three taps felt." detail:@"Pass. You felt all three haptic patterns, so the haptic engine is working."];
            phase = RGPhaseDone;
        } else {
            [self playHaptics];
        }
    }
    [self updatePanel];
    self.view.needsDisplay = YES;
}

- (void)secondaryAction:(id)sender {
    if (test == RGTestHaptics && phase == RGPhaseAsking) {
        [self setResult:RGTestHaptics status:@"fail" summary:@"Taps not felt."
                 detail:@"Fail. You didn't feel the haptic taps. Check that Force Click and haptic feedback is on in Trackpad settings, then try again. "
                        @"If the trackpad also doesn't click when you press it, its haptic engine or its power may have failed: contact Apple."];
        phase = RGPhaseDone;
    } else {
        phase = RGPhaseReady;   // Cancel
    }
    [self updatePanel];
    self.view.needsDisplay = YES;
}

- (void)tertiaryAction:(id)sender { [self playHaptics]; [self updatePanel]; }

- (void)playHaptics {
    phase = RGPhaseRunning;
    pulsesWithFinger = 0;
    memset(pulseStart, 0, sizeof pulseStart);
    NSHapticFeedbackPattern patterns[] = {NSHapticFeedbackPatternGeneric, NSHapticFeedbackPatternAlignment, NSHapticFeedbackPatternLevelChange};
    for (int k = 0; k < 3; k++) {
        NSHapticFeedbackPattern pattern = patterns[k];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((0.5 + k * 0.75) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self->phase != RGPhaseRunning || self->test != RGTestHaptics) return;
            [NSHapticFeedbackManager.defaultPerformer performFeedbackPattern:pattern performanceTime:NSHapticFeedbackPerformanceTimeNow];
            self->pulseStart[k] = CFAbsoluteTimeGetCurrent();
            MTFinger t[MAX_TOUCHES];
            int n = RGCopyTouches([self.current[@"slot"] intValue], t);
            for (int i = 0; i < n; i++) if (contact(t[i].state)) { self->pulsesWithFinger++; break; }
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->phase != RGPhaseRunning || self->test != RGTestHaptics) return;
        self->phase = RGPhaseAsking;
        [self updatePanel];
    });
}

- (void)finishCoverage {
    double c = self.coverage, target = self.coverageTarget;
    RGFrameStats now = [self stats];
    long strokes = now.strokes - base.strokes, lost = now.lost - base.lost;
    BOOL lossy = lost >= 3 && lost * 10 >= strokes;
    NSString *lostText = [NSString stringWithFormat:@"The sensor lost track of %ld of %ld strokes partway across the surface, which can mean an intermittent sensor or a dirty surface.", lost, strokes];
    if (c >= target && !lossy) {
        [self setResult:RGTestCoverage status:@"pass" summary:[NSString stringWithFormat:@"%.0f%% of the surface responded.", c * 100]
                 detail:[NSString stringWithFormat:@"Pass. %.0f%% of the surface responded and no strokes were lost.%@", c * 100,
                         c < 0.999 ? @" Any red cells are areas you didn't reach." : @""]];
    } else if (c >= target) {
        [self setResult:RGTestCoverage status:@"warn" summary:[NSString stringWithFormat:@"%.0f%% covered, %ld strokes lost.", c * 100, lost]
                 detail:[NSString stringWithFormat:@"Check. %.0f%% of the surface responded, but %@", c * 100, lostText]];
    } else {
        [self setResult:RGTestCoverage status:@"warn" summary:[NSString stringWithFormat:@"Only %.0f%% of the surface responded.", c * 100]
                 detail:[NSString stringWithFormat:@"Incomplete. Only %.0f%% of the surface responded. Wipe the red areas again: if a patch never lights up however you wipe it, that part of the sensor isn't working.%@",
                         c * 100, lossy ? [@" " stringByAppendingString:lostText] : @""]];
    }
    phase = RGPhaseDone;
}

- (void)finishPhantom {
    RGFrameStats now = [self stats];
    phantomFrames = MAX(phantomFrames, now.contactFrames - base.contactFrames);
    if (phantomFrames == 0 && self.phantomPoints.count == 0) {
        [self setResult:RGTestPhantom status:@"pass" summary:[NSString stringWithFormat:@"No contacts in %.0f seconds.", IDLE_SECONDS]
                 detail:[NSString stringWithFormat:@"Pass. The device reported nothing in %.0f seconds with no one touching it.", IDLE_SECONDS]];
    } else {
        NSUInteger places = MAX(1, self.phantomPoints.count);
        [self setResult:RGTestPhantom status:@"fail"
                summary:[NSString stringWithFormat:@"%ld contact frames in %lu place%@ while idle.", phantomFrames, (unsigned long)places, places == 1 ? @"" : @"s"]
                 detail:[NSString stringWithFormat:@"Fail. The device reported contact in %lu place%@ (%ld frames) while no one was touching it. "
                         @"Make sure nothing was touching it, then clean and dry the surface, move it away from metal and chargers, and test again. "
                         @"If contacts keep appearing in the same place, the sensor is probably faulty.",
                         (unsigned long)places, places == 1 ? @"" : @"s", phantomFrames]];
    }
    phase = RGPhaseDone;
}

- (void)copyReport:(id)sender {
    NSMutableString *r = [NSMutableString string];
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"";
    char model[64] = {0};
    size_t len = sizeof model;
    sysctlbyname("hw.model", model, &len, NULL, 0);
    [r appendFormat:@"RodentGym %@ hardware self-test, %@\n", version,
        [NSDateFormatter localizedStringFromDate:[NSDate date] dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle]];
    [r appendFormat:@"Mac %s, %@\n", model, NSProcessInfo.processInfo.operatingSystemVersionString];
    for (NSDictionary *d in self.deviceList) {
        NSMutableArray *hw = [NSMutableArray arrayWithObject:d[@"model"] ?: @""];
        if (d[@"firmware"]) [hw addObject:[@"firmware " stringByAppendingString:d[@"firmware"]]];
        if (d[@"transport"]) [hw addObject:d[@"transport"]];
        if (d[@"serial"]) [hw addObject:[@"serial " stringByAppendingString:d[@"serial"]]];
        [r appendFormat:@"\n%@ — %@\n", d[@"name"], [hw componentsJoinedByString:@", "]];
        NSDictionary *saved = self.current;
        self.current = d;
        for (int t = 0; t < 3; t++) {
            NSDictionary *res = [self resultFor:(RGTest)t];
            [r appendFormat:@"  %@: %@\n", kTestNames[t], res ? res[@"detail"] : @"not run"];
        }
        self.current = saved;
    }
    NSString *lat = self.latencySummary ? self.latencySummary() : nil;
    if (lat.length) [r appendFormat:@"\n%@\n", lat];
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:r forType:NSPasteboardTypeString];
    self.window.subtitle = @"Report copied to the clipboard";
    [self performSelector:@selector(clearSubtitle) withObject:nil afterDelay:3];
}

- (void)clearSubtitle { self.window.subtitle = @""; }

#pragma mark Sampling

- (void)tick {
    if (demo) return;
    double now = CFAbsoluteTimeGetCurrent();
    if (test == RGTestCoverage && phase == RGPhaseRunning) [self sampleCoverage:now];
    if (test == RGTestPhantom) {
        if (phase == RGPhaseCountdown && now - phaseStart >= COUNTDOWN) {
            phase = RGPhaseRunning;
            phaseStart = now;
            base = [self stats];
        } else if (phase == RGPhaseRunning) {
            [self samplePhantom];
            if (now - phaseStart >= IDLE_SECONDS) [self finishPhantom];
        }
    }
    if (phase != RGPhaseReady && phase != RGPhaseDone) [self updatePanel];
    self.view.needsDisplay = YES;
}

// Marks every cell within about half a cell of each contact, joining the dots between frames so a
// quick wipe doesn't leave gaps.
- (void)sampleCoverage:(double)now {
    MTFinger t[MAX_TOUCHES];
    int n = RGCopyTouches([self.current[@"slot"] intValue], t);
    int count = 0;
    typeof(prevTouch[0]) next[MAX_TOUCHES];
    for (int i = 0; i < n; i++) {
        if (!contact(t[i].state)) continue;
        float x = t[i].normalized.pos.x, y = 1 - t[i].normalized.pos.y;
        float px = x, py = y;
        for (int k = 0; k < prevTouchCount; k++) if (prevTouch[k].id == t[i].identifier) { px = prevTouch[k].x; py = prevTouch[k].y; }
        float dx = (x - px) * nx, dy = (y - py) * ny;
        int steps = MAX(1, (int)ceilf(sqrtf(dx * dx + dy * dy) * 2));
        for (int s = 0; s <= steps; s++) {
            float u = (float)s / steps;
            [self markX:px + (x - px) * u y:py + (y - py) * u];
        }
        next[count++] = (typeof(prevTouch[0])){t[i].identifier, x, y};
        lastContactTime = now;
    }
    memcpy(prevTouch, next, sizeof(prevTouch[0]) * (size_t)count);
    prevTouchCount = count;
    if (self.coverage >= self.coverageTarget && count == 0 && lastContactTime > 0 && now - lastContactTime > 1.0) {
        [self finishCoverage];
        [self updatePanel];
    }
}

- (void)markX:(float)x y:(float)y {
    float gx = x * nx, gy = y * ny;
    for (int i = MAX(0, (int)gx - 1); i <= MIN(nx - 1, (int)gx + 1); i++)
        for (int j = MAX(0, (int)gy - 1); j <= MIN(ny - 1, (int)gy + 1); j++) {
            float cx = i + 0.5f - gx, cy = j + 0.5f - gy;
            if (cx * cx + cy * cy <= 0.6f && mask[i][j] && !hit[i][j]) { hit[i][j] = YES; hitCount++; }
        }
}

- (void)samplePhantom {
    MTFinger t[MAX_TOUCHES];
    int n = RGCopyTouches([self.current[@"slot"] intValue], t);
    for (int i = 0; i < n; i++) {
        if (!contact(t[i].state)) continue;
        NSPoint p = NSMakePoint(t[i].normalized.pos.x, t[i].normalized.pos.y);
        BOOL known = NO;
        for (NSValue *v in self.phantomPoints) if (hypot(v.pointValue.x - p.x, v.pointValue.y - p.y) < 0.05) known = YES;
        if (!known && self.phantomPoints.count < 50) [self.phantomPoints addObject:[NSValue valueWithPoint:p]];
    }
    RGFrameStats now = [self stats];
    phantomFrames = now.contactFrames - base.contactFrames;
}

#pragma mark Lifecycle

- (void)show {
    if (!self.window) [self buildWindow];
    [self reloadDevices];
    [self.window makeKeyAndOrderFront:nil];
    [self layoutPanel];
    [self updatePanel];
    if (!self.timer && !demo) {
        self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}

- (void)windowDidResize:(NSNotification *)n { [self layoutPanel]; }
- (void)windowDidBecomeKey:(NSNotification *)n { if (!demo && phase == RGPhaseReady) [self reloadDevices]; }
- (void)windowWillClose:(NSNotification *)n {
    [self.timer invalidate];
    self.timer = nil;
    if (phase != RGPhaseDone) phase = RGPhaseReady;
}

#pragma mark Demo

- (void)showDemo {
    demo = YES;
    self.deviceList = @[@{@"name": @"Magic Trackpad", @"key": @"demo-pad", @"kind": @"trackpad", @"builtIn": @NO, @"slot": @-1,
                          @"model": @"Magic Trackpad 2 (Lightning)", @"firmware": @"8.7.1", @"transport": @"USB",
                          @"productID": @0x0265, @"darkTop": @YES, @"widthMM": @160, @"heightMM": @115}];
    [self show];
    [self buildGrid];
    // Serpentine wipe, about three-quarters done
    int total = maskCount, goal = (int)(total * 0.74), done = 0;
    for (int j = 0; j < ny && done < goal; j++)
        for (int k = 0; k < nx && done < goal; k++) {
            int i = (j % 2) ? nx - 1 - k : k;
            if (mask[i][j] && !hit[i][j]) { hit[i][j] = YES; hitCount++; done++; }
        }
    int lastRow = 0;
    for (int j = 0; j < ny; j++) for (int i = 0; i < nx; i++) if (hit[i][j]) lastRow = j;
    int lastCol = (lastRow % 2) ? 0 : nx - 1;
    for (int i = 0; i < nx; i++) if (hit[i][lastRow]) lastCol = (lastRow % 2) ? (lastCol == 0 || i < lastCol ? i : lastCol) : i;
    memset(&demoTouch, 0, sizeof demoTouch);
    demoTouch.state = RGTouchTouching;
    demoTouch.normalized.pos = (MTPoint){(lastCol + 0.5f) / nx, 1 - (lastRow + 0.5f) / ny};
    self.results[@"demo-pad"] = [@{
        kTestKeys[RGTestPhantom]: @{@"status": @"pass", @"summary": @"No contacts in 10 seconds.", @"detail": @""},
        kTestKeys[RGTestHaptics]: @{@"status": @"pass", @"summary": @"All three taps felt.", @"detail": @""}} mutableCopy];
    phase = RGPhaseRunning;
    [self updatePanel];
    self.progress.doubleValue = self.coverage;
    self.metricsLabel.stringValue = [NSString stringWithFormat:@"Covered   %3.0f%%  (target 95%%)\nStrokes   23\nLost      0", self.coverage * 100];
    self.view.needsDisplay = YES;
}

- (BOOL)writeDemoSnapshotTo:(NSString *)path {
    [self showDemo];
    [self.window orderOut:nil];
    [self.view layoutSubtreeIfNeeded];
    [self layoutPanel];
    NSView *v = self.view;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end
