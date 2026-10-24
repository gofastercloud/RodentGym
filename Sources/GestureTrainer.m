// Gesture Trainer — see GestureTrainer.h.
//
// Window: an NSSplitViewController with a source-list sidebar (the checklist, rendered as a Liquid
// Glass sidebar on macOS 26+) and a practice pad. A glass banner floats over the pad to name each
// gesture as it's recognised.

#import "GestureTrainer.h"
#import "Multitouch.h"
#import "UI.h"

#pragma mark - Model

@interface RGGestureItem : NSObject
@property (copy) NSString *key, *title, *how, *action;
@property BOOL enabled, done, system;
@end
@implementation RGGestureItem
@end

@interface RGGestureGroup : NSObject
@property (copy) NSString *name, *kind;
@property int slot;
@property (copy) NSDictionary *prefs;
@property (strong) NSArray<RGGestureItem *> *items;
@end
@implementation RGGestureGroup
- (BOOL)isMouse { return [self.kind isEqualToString:@"mouse"]; }
- (NSUInteger)enabledCount { NSUInteger n = 0; for (RGGestureItem *i in self.items) if (i.enabled) n++; return n; }
- (NSUInteger)doneCount { NSUInteger n = 0; for (RGGestureItem *i in self.items) if (i.enabled && i.done) n++; return n; }
@end

// One continuous touch on a device, from first finger down to last finger up.
typedef struct {
    BOOL active;
    int maxFingers;
    double start, lastSeen;
    float sx, sy, sSpread, ex, ey, eSpread, firstX;
} RGSession;

static id readPref(NSString *key, NSString *domain) {
    CFStringRef app = domain ? (__bridge CFStringRef)domain : kCFPreferencesAnyApplication;
    CFPreferencesAppSynchronize(app);
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, app));
}
static BOOL prefOn(NSString *key, NSString *domain, BOOL fallback) { id v = readPref(key, domain); return v ? [v boolValue] : fallback; }
static int pv(NSDictionary *d, NSString *k, int fallback) { id v = d[k]; return [v respondsToSelector:@selector(intValue)] ? [v intValue] : fallback; }

static RGGestureItem *gesture(NSString *key, NSString *title, NSString *how, NSString *action, BOOL enabled, BOOL system) {
    RGGestureItem *i = [RGGestureItem new];
    i.key = key;
    i.title = title;
    i.enabled = enabled && how != nil;
    i.how = i.enabled ? how : @"Off in System Settings";
    i.action = action;
    i.system = system;
    return i;
}

// Builds the checklist for one device from the settings its driver is applying, plus the Dock's
// gesture switches and the global page-swipe settings.
static NSArray<RGGestureItem *> *gesturesFor(RGGestureGroup *g) {
    NSDictionary *p = g.prefs;
    NSMutableArray *a = [NSMutableArray array];
    BOOL dockMissionControl = prefOn(@"showMissionControlGestureEnabled", @"com.apple.dock", YES);
    BOOL dockExpose = prefOn(@"showAppExposeGestureEnabled", @"com.apple.dock", NO);
    BOOL dockApps = prefOn(@"showLaunchpadGestureEnabled", @"com.apple.dock", YES);
    BOOL dockDesktop = prefOn(@"showDesktopGestureEnabled", @"com.apple.dock", YES);

    if (g.isMouse) {
        NSString *mode = p[@"MouseButtonMode"];
        NSString *secondary = [mode isEqual:@"TwoButton"] ? @"Click the right side" : [mode isEqual:@"TwoButtonSwapped"] ? @"Click the left side" : nil;
        int twoSwipe = pv(p, @"MouseTwoFingerHorizSwipeGesture", 2);
        NSString *pages = twoSwipe == 1 ? @"Swipe left or right with two fingers"
                        : prefOn(@"AppleEnableMouseSwipeNavigateWithScrolls", nil, YES) ? @"Swipe left or right with one finger" : nil;
        [a addObject:gesture(@"click", @"Click", @"Press the primary side", nil, YES, NO)];
        [a addObject:gesture(@"secondary", @"Secondary click", secondary, nil, YES, NO)];
        [a addObject:gesture(@"double", @"Double-click", @"Click twice quickly", nil, YES, NO)];
        [a addObject:gesture(@"scroll", @"Scroll", @"Slide one finger up or down", nil, pv(p, @"MouseVerticalScroll", 1), NO)];
        [a addObject:gesture(@"smartzoom", @"Smart zoom", @"Double-tap with one finger", nil, pv(p, @"MouseOneFingerDoubleTapGesture", 0), NO)];
        [a addObject:gesture(@"pages", @"Swipe between pages", pages, nil, YES, NO)];
        [a addObject:gesture(@"fullscreen", @"Swipe between full-screen apps", @"Swipe left or right with two fingers",
                             @"switches full-screen app", twoSwipe == 2, YES)];
        [a addObject:gesture(@"mission", @"Mission Control", @"Double-tap with two fingers", @"opens Mission Control",
                             pv(p, @"MouseTwoFingerDoubleTapGesture", 3) == 3 && dockMissionControl, YES)];
        return a;
    }

    BOOL forceClick = prefOn(@"com.apple.trackpad.forceClick", nil, YES);
    int threeH = pv(p, @"TrackpadThreeFingerHorizSwipeGesture", 1), fourH = pv(p, @"TrackpadFourFingerHorizSwipeGesture", 2);
    int threeV = pv(p, @"TrackpadThreeFingerVertSwipeGesture", 2), fourV = pv(p, @"TrackpadFourFingerVertSwipeGesture", 2);
    BOOL pinchSystem = pv(p, @"TrackpadFiveFingerPinchGesture", 2) == 2 || pv(p, @"TrackpadFourFingerPinchGesture", 2) == 2;
    int corner = pv(p, @"TrackpadCornerSecondaryClick", 0);
    NSString *secondary = corner == 2 ? @"Click in the bottom-right corner" : corner == 1 ? @"Click in the bottom-left corner"
                        : pv(p, @"TrackpadRightClick", 1) ? @"Click or tap with two fingers" : nil;
    NSString *pages = threeH == 1 ? @"Swipe left or right with three fingers"
                    : prefOn(@"AppleEnableSwipeNavigateWithScrolls", nil, YES) ? @"Swipe left or right with two fingers" : nil;
    NSString *fsFingers = threeH == 2 ? @"three" : fourH == 2 ? @"four" : nil;
    NSString *mcFingers = threeV == 2 ? @"three" : fourV == 2 ? @"four" : nil;

    [a addObject:gesture(@"click", @"Click", @"Press down until it clicks", nil, YES, NO)];
    [a addObject:gesture(@"tap", @"Tap to click", @"Tap lightly with one finger", nil, pv(p, @"Clicking", 0), NO)];
    [a addObject:gesture(@"secondary", @"Secondary click", secondary, nil, YES, NO)];
    [a addObject:gesture(@"double", @"Double-click", @"Click twice quickly", nil, YES, NO)];
    [a addObject:gesture(@"triple", @"Triple-click", @"Click three times quickly", nil, YES, NO)];
    [a addObject:gesture(@"force", @"Force Click", @"Click, then press harder", nil, forceClick, NO)];
    if (!forceClick)
        [a addObject:gesture(@"lookup", @"Look up", @"Tap with three fingers", nil, pv(p, @"TrackpadThreeFingerTapGesture", 0) == 2, NO)];
    [a addObject:gesture(@"scroll", @"Scroll", @"Slide two fingers up or down", nil, pv(p, @"TrackpadScroll", 1), NO)];
    [a addObject:gesture(@"pinch", @"Zoom in or out", @"Pinch two fingers together or apart", nil, pv(p, @"TrackpadPinch", 1), NO)];
    [a addObject:gesture(@"rotate", @"Rotate", @"Twist two fingers", nil, pv(p, @"TrackpadRotate", 1), NO)];
    [a addObject:gesture(@"smartzoom", @"Smart zoom", @"Double-tap with two fingers", nil, pv(p, @"TrackpadTwoFingerDoubleTapGesture", 1), NO)];
    [a addObject:gesture(@"pages", @"Swipe between pages", pages, nil, YES, NO)];
    [a addObject:gesture(@"drag3", @"Three-finger drag", @"Drag with three fingers", nil, pv(p, @"TrackpadThreeFingerDrag", 0), NO)];
    [a addObject:gesture(@"fullscreen", @"Swipe between full-screen apps",
                         fsFingers ? [NSString stringWithFormat:@"Swipe left or right with %@ fingers", fsFingers] : nil,
                         @"switches full-screen app", YES, YES)];
    [a addObject:gesture(@"mission", @"Mission Control",
                         mcFingers ? [NSString stringWithFormat:@"Swipe up with %@ fingers", mcFingers] : nil,
                         @"opens Mission Control", dockMissionControl, YES)];
    [a addObject:gesture(@"expose", @"App Exposé",
                         mcFingers ? [NSString stringWithFormat:@"Swipe down with %@ fingers", mcFingers] : nil,
                         @"shows App Exposé", dockExpose, YES)];
    [a addObject:gesture(@"apps", @"Apps", @"Pinch with your thumb and three fingers", @"opens Apps", pinchSystem && dockApps, YES)];
    [a addObject:gesture(@"desktop", @"Show desktop", @"Spread your thumb and three fingers", @"shows the desktop", pinchSystem && dockDesktop, YES)];
    [a addObject:gesture(@"notifications", @"Notification Centre", @"Swipe left from the right edge with two fingers",
                         @"opens Notification Centre", pv(p, @"TrackpadTwoFingerFromRightEdgeSwipeGesture", 3) == 3, YES)];
    return a;
}

static void measure(const MTFinger *t, int n, float *cx, float *cy, float *spread) {
    float x = 0, y = 0, s = 0;
    for (int i = 0; i < n; i++) { x += t[i].normalized.pos.x; y += t[i].normalized.pos.y; }
    x /= n;
    y /= n;
    for (int i = 0; i < n; i++) s += hypotf(t[i].normalized.pos.x - x, t[i].normalized.pos.y - y);
    *cx = x;
    *cy = y;
    *spread = s / n;
}

#pragma mark - Trainer

@class RGPadView;

@interface RGGestureTrainer () <NSTableViewDataSource, NSTableViewDelegate, NSToolbarDelegate> {
@public
    RGSession sessions[8];
    double lastTouch[8];
    double lastMouseTwoTap, lastPressure, lastDown, lastScrollReport, lastSwipeEvent;
    NSInteger pressureStage;
    float pressureValue;
    CGFloat magnification, rotation;
    BOOL magnifying, rotating, demo;
    CGFloat scrollX, scrollY;
    MTFinger demoTouches[5];
    int demoCount;
    int refreshTicks;
}
@property (strong, readwrite) NSWindow *window;
@property (strong) NSArray<RGGestureGroup *> *groups;
@property (strong) NSArray *rows;   // RGGestureGroup (section header) or RGGestureItem
@property (strong) NSTableView *table;
@property (strong) RGPadView *pad;
@property (strong) NSView *banner;
@property (strong) NSImageView *bannerIcon;
@property (strong) NSTextField *bannerTitle, *bannerDetail;
@property (strong) NSMutableArray<NSString *> *history;
@property (strong) NSTimer *timer;
@property (strong) NSDateFormatter *timeFormat;
- (RGGestureGroup *)recentGroup;
- (int)touchesForGroup:(RGGestureGroup *)g into:(MTFinger *)out;
- (void)recognise:(NSString *)key group:(RGGestureGroup *)g title:(NSString *)title detail:(NSString *)detail;
@end

#pragma mark Practice pad

@interface RGPadView : NSView
@property (weak) RGGestureTrainer *trainer;
@end

@implementation RGPadView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return NO; }
- (NSMenu *)menuForEvent:(NSEvent *)e { return nil; }   // secondary click is something to practise here

- (void)mouseDown:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    RGGestureGroup *g = t.recentGroup;
    double now = CFAbsoluteTimeGetCurrent(), interval = now - t->lastDown;
    t->lastDown = now;
    if (e.modifierFlags & NSEventModifierFlagControl) {
        [t recognise:@"secondary" group:g title:@"Secondary click" detail:@"Control-click"];
        return;
    }
    if (e.clickCount == 2) {
        [t recognise:@"double" group:g title:@"Double-click"
              detail:[NSString stringWithFormat:@"%.0f ms apart · macOS allows up to %.0f ms", interval * 1000, NSEvent.doubleClickInterval * 1000]];
        return;
    }
    if (e.clickCount >= 3) { [t recognise:@"triple" group:g title:@"Triple-click" detail:nil]; return; }
    if (g.isMouse) { [t recognise:@"click" group:g title:@"Click" detail:nil]; return; }
    // On a Force Touch trackpad a physical click reports pressure; a tap doesn't.
    double down = now;
    __weak RGGestureTrainer *weak = t;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        RGGestureTrainer *s = weak;
        if (!s) return;
        BOOL pressed = s->lastPressure >= down - 0.15;
        [s recognise:pressed ? @"click" : @"tap" group:g title:pressed ? @"Click" : @"Tap to click" detail:nil];
    });
}

- (void)rightMouseDown:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    RGGestureGroup *g = t.recentGroup;
    MTFinger f[MAX_TOUCHES];
    int n = g ? [t touchesForGroup:g into:f] : 0;
    NSString *how = g.isMouse ? @"Right side of the mouse" : n >= 2 ? @"Two fingers" : n == 1 ? @"Corner click" : nil;
    [t recognise:@"secondary" group:g title:@"Secondary click" detail:how];
}

- (void)otherMouseDown:(NSEvent *)e {
    [self.trainer recognise:nil group:self.trainer.recentGroup title:@"Middle click" detail:@"Not part of macOS's gestures"];
}

- (void)pressureChangeWithEvent:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    if (e.stage >= 1) t->lastPressure = CFAbsoluteTimeGetCurrent();
    if (e.stage == 2 && t->pressureStage < 2) [t recognise:@"force" group:t.recentGroup title:@"Force Click" detail:nil];
    t->pressureStage = e.stage;
    t->pressureValue = e.pressure;
}

- (void)magnifyWithEvent:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    if (e.phase == NSEventPhaseBegan) { t->magnification = 0; t->magnifying = YES; }
    t->magnification += e.magnification;
    if (e.phase == NSEventPhaseEnded || e.phase == NSEventPhaseCancelled) {
        t->magnifying = NO;
        CGFloat scale = MAX(0.05, 1 + t->magnification);
        [t recognise:@"pinch" group:t.recentGroup title:scale >= 1 ? @"Zoom in" : @"Zoom out"
              detail:[NSString stringWithFormat:@"Pinched to ×%.2f", scale]];
    }
}

- (void)rotateWithEvent:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    if (e.phase == NSEventPhaseBegan) { t->rotation = 0; t->rotating = YES; }
    t->rotation += e.rotation;
    if (e.phase == NSEventPhaseEnded || e.phase == NSEventPhaseCancelled) {
        t->rotating = NO;
        if (fabs(t->rotation) >= 8)
            [t recognise:@"rotate" group:t.recentGroup title:@"Rotate"
                  detail:[NSString stringWithFormat:@"%.0f° %@", fabs(t->rotation), t->rotation > 0 ? @"anticlockwise" : @"clockwise"]];
    }
}

- (void)smartMagnifyWithEvent:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    RGGestureGroup *g = t.recentGroup;
    [t recognise:@"smartzoom" group:g title:@"Smart zoom" detail:g.isMouse ? @"One-finger double-tap" : @"Two-finger double-tap"];
}

- (void)swipeWithEvent:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    t->lastSwipeEvent = CFAbsoluteTimeGetCurrent();
    NSString *dir = e.deltaX > 0 ? @"left" : e.deltaX < 0 ? @"right" : e.deltaY > 0 ? @"up" : @"down";
    [t recognise:@"pages" group:t.recentGroup title:@"Swipe between pages" detail:[@"Swiped " stringByAppendingString:dir]];
}

- (void)scrollWheel:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    if (e.momentumPhase != NSEventPhaseNone) return;
    if (e.phase == NSEventPhaseBegan) { t->scrollX = 0; t->scrollY = 0; }
    t->scrollX += e.scrollingDeltaX;
    t->scrollY += e.scrollingDeltaY;
    BOOL finished = e.phase == NSEventPhaseEnded || e.phase == NSEventPhaseCancelled || e.phase == NSEventPhaseNone;
    double now = CFAbsoluteTimeGetCurrent();
    if (!finished || now - t->lastScrollReport < 0.6) return;
    CGFloat ax = fabs(t->scrollX), ay = fabs(t->scrollY);
    if (MAX(ax, ay) < (e.hasPreciseScrollingDeltas ? 40 : 3)) return;
    t->lastScrollReport = now;
    RGGestureGroup *g = t.recentGroup;
    if (ax > ay * 1.5 && ax > 80 && now - t->lastSwipeEvent > 0.5)
        [t recognise:@"pages" group:g title:@"Horizontal swipe"
              detail:@"Swipes between pages in apps that support it"];
    else
        [t recognise:@"scroll" group:g title:@"Scroll"
              detail:[NSString stringWithFormat:@"%@ scroll, %.0f points", ax > ay ? @"Sideways" : @"Vertical", MAX(ax, ay)]];
    t->scrollX = t->scrollY = 0;
}

- (void)mouseDragged:(NSEvent *)e {
    RGGestureTrainer *t = self.trainer;
    RGGestureGroup *g = t.recentGroup;
    MTFinger f[MAX_TOUCHES];
    if (g && !g.isMouse && [t touchesForGroup:g into:f] == 3 && pv(g.prefs, @"TrackpadThreeFingerDrag", 0)) {
        for (RGGestureItem *i in g.items) if ([i.key isEqualToString:@"drag3"] && i.done) return;
        [t recognise:@"drag3" group:g title:@"Three-finger drag" detail:nil];
    }
}

- (void)drawRect:(NSRect)dirty {
    RGGestureTrainer *t = self.trainer;
    if (!t) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSRect b = self.bounds;
    CGFloat top = self.safeAreaInsets.top;

    // Live touches on the device you used last
    RGGestureGroup *g = t.recentGroup;
    CGFloat aspect = g.isMouse ? 0.57 : 1.41;
    CGFloat h = MIN(250, b.size.height * 0.4), w = MIN(b.size.width - 80, h * aspect);
    h = w / aspect;
    NSRect surface = NSMakeRect(NSMidX(b) - w / 2, top + 120 + (b.size.height - top - 120 - 190 - h) / 2, w, h);
    CGFloat radius = g.isMouse ? w / 2 : 18;
    NSBezierPath *outline = [NSBezierPath bezierPathWithRoundedRect:surface xRadius:radius yRadius:g.isMouse ? h * 0.2 : radius];
    [NSColor.quaternarySystemFillColor setFill];
    [outline fill];
    [NSColor.separatorColor setStroke];
    outline.lineWidth = 1;
    [outline stroke];

    MTFinger f[MAX_TOUCHES];
    int n = g ? [t touchesForGroup:g into:f] : 0;
    for (int i = 0; i < n; i++) {
        CGFloat x = surface.origin.x + f[i].normalized.pos.x * w, y = surface.origin.y + (1 - f[i].normalized.pos.y) * h;
        CGFloat r = 10 + MIN(f[i].size, 2.5f) * 4;
        NSColor *c = n >= 3 ? NSColor.systemPurpleColor : n == 2 ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        [[c colorWithAlphaComponent:0.22] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - r - 7, y - r - 7, 2 * (r + 7), 2 * (r + 7))] fill];
        [c setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - r, y - r, 2 * r, 2 * r)] fill];
    }
    NSString *caption = g ? [NSString stringWithFormat:@"%@ · %d finger%@", g.name, n, n == 1 ? @"" : @"s"] : @"No multitouch device";
    RGDrawText(caption, NSMakeRect(b.origin.x, NSMaxY(surface) + 12, b.size.width, 18),
               [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor, NSTextAlignmentCenter);

    // Live pinch, rotate and pressure feedback
    NSPoint c = NSMakePoint(NSMidX(surface), NSMidY(surface));
    if (t->magnifying) {
        CGFloat r = 40 * MAX(0.2, 1 + t->magnification);
        NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(c.x - r, c.y - r, 2 * r, 2 * r)];
        ring.lineWidth = 3;
        [NSColor.controlAccentColor setStroke];
        [ring stroke];
    }
    if (t->rotating) {
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:c radius:52 startAngle:-90 endAngle:-90 - t->rotation clockwise:t->rotation > 0];
        arc.lineWidth = 4;
        arc.lineCapStyle = NSLineCapStyleRound;
        [NSColor.systemTealColor setStroke];
        [arc stroke];
    }
    if (CFAbsoluteTimeGetCurrent() - t->lastPressure < 0.3 && t->pressureValue > 0) {
        NSRect bar = NSMakeRect(NSMidX(b) - 100, NSMaxY(surface) + 38, 200, 8);
        [NSColor.tertiarySystemFillColor setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4] fill];
        bar.size.width *= MIN(1, t->pressureValue);
        [(t->pressureStage >= 2 ? NSColor.systemPinkColor : NSColor.controlAccentColor) setFill];
        [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:4 yRadius:4] fill];
    }

    // Recent gestures
    CGFloat y = b.size.height - 150;
    RGDrawText(@"RECENT", NSMakeRect(32, y, 200, 14), [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold],
               NSColor.tertiaryLabelColor, NSTextAlignmentLeft);
    NSFont *row = [NSFont systemFontOfSize:12];
    for (NSUInteger i = 0; i < MIN(5, t.history.count); i++)
        RGDrawText(t.history[i], NSMakeRect(32, y + 18 + i * 19, b.size.width - 64, 17), row,
                   i == 0 ? NSColor.labelColor : NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    if (t.history.count == 0)
        RGDrawText(@"Try any gesture from the checklist with the pointer over this area.", NSMakeRect(32, y + 18, b.size.width - 64, 17),
                   row, NSColor.secondaryLabelColor, NSTextAlignmentLeft);
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Gesture practice area"; }
- (NSString *)accessibilityValue {
    return self.trainer.history.firstObject ?: @"No gestures yet";
}
@end

#pragma mark Trainer implementation

static NSString *const kResetItem = @"reset", *const kTrackpadItem = @"trackpad", *const kMouseItem = @"mouse";

@implementation RGGestureTrainer

- (instancetype)init {
    if ((self = [super init])) {
        _history = [NSMutableArray array];
        _timeFormat = [NSDateFormatter new];
        _timeFormat.dateFormat = @"HH:mm:ss";
    }
    return self;
}

- (void)buildWindow {
    // Sidebar: the checklist as a source list
    self.table = [NSTableView new];
    self.table.style = NSTableViewStyleSourceList;
    self.table.headerView = nil;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.selectionHighlightStyle = NSTableViewSelectionHighlightStyleNone;
    self.table.intercellSpacing = NSMakeSize(0, 2);
    NSTableColumn *col = [[NSTableColumn alloc] initWithIdentifier:@"gesture"];
    col.resizingMask = NSTableColumnAutoresizingMask;
    [self.table addTableColumn:col];
    self.table.columnAutoresizingStyle = NSTableViewFirstColumnOnlyAutoresizingStyle;
    self.table.accessibilityLabel = @"Gesture checklist";
    NSScrollView *scroll = [NSScrollView new];
    scroll.documentView = self.table;
    scroll.hasVerticalScroller = YES;
    scroll.drawsBackground = NO;
    NSViewController *sideVC = [NSViewController new];
    sideVC.view = scroll;

    // Detail: the practice pad with a glass banner floating above it
    NSView *detail = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 700, 680)];
    self.pad = [[RGPadView alloc] initWithFrame:detail.bounds];
    self.pad.trainer = self;
    self.pad.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [detail addSubview:self.pad];
    [self buildBannerIn:detail];
    NSViewController *detailVC = [NSViewController new];
    detailVC.view = detail;

    NSSplitViewController *split = [NSSplitViewController new];
    NSSplitViewItem *sidebar = [NSSplitViewItem sidebarWithViewController:sideVC];
    sidebar.minimumThickness = 270;
    sidebar.maximumThickness = 360;
    NSSplitViewItem *content = [NSSplitViewItem splitViewItemWithViewController:detailVC];
    content.minimumThickness = 520;
    [split addSplitViewItem:sidebar];
    [split addSplitViewItem:content];

    self.window = [NSWindow windowWithContentViewController:split];
    self.window.styleMask |= NSWindowStyleMaskFullSizeContentView | NSWindowStyleMaskResizable;
    self.window.title = @"Gesture Trainer";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"GestureTrainerToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    [self.window setContentSize:NSMakeSize(1020, 700)];
    self.window.contentMinSize = NSMakeSize(820, 560);
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymGestureTrainer"];
}

- (void)buildBannerIn:(NSView *)detail {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 480, 66)];
    self.bannerIcon = [NSImageView imageViewWithImage:RGSymbol(@"hand.wave", @"Gesture") ?: [NSImage new]];
    self.bannerIcon.frame = NSMakeRect(20, 17, 32, 32);
    self.bannerIcon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:24 weight:NSFontWeightMedium];
    self.bannerIcon.contentTintColor = NSColor.labelColor;
    self.bannerTitle = RGLabel(@"Ready when you are", [NSFont systemFontOfSize:17 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.bannerTitle.frame = NSMakeRect(64, 34, 400, 22);
    self.bannerTitle.lineBreakMode = NSLineBreakByTruncatingTail;
    self.bannerDetail = RGLabel(@"Try a gesture from the checklist", [NSFont systemFontOfSize:12], NSColor.secondaryLabelColor);
    self.bannerDetail.frame = NSMakeRect(64, 13, 400, 18);
    self.bannerDetail.lineBreakMode = NSLineBreakByTruncatingTail;
    [content addSubview:self.bannerIcon];
    [content addSubview:self.bannerTitle];
    [content addSubview:self.bannerDetail];
    self.banner = RGGlassView(content, 33);
    self.banner.autoresizingMask = NSViewMinXMargin | NSViewMaxXMargin | NSViewMinYMargin;
    self.banner.frame = NSMakeRect((detail.bounds.size.width - 480) / 2, detail.bounds.size.height - 66 - 70, 480, 66);
    self.banner.accessibilityElement = YES;
    self.banner.accessibilityRole = NSAccessibilityStaticTextRole;
    [detail addSubview:self.banner];
}

#pragma mark Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[NSToolbarToggleSidebarItemIdentifier, NSToolbarSidebarTrackingSeparatorItemIdentifier,
             NSToolbarFlexibleSpaceItemIdentifier, kMouseItem, kTrackpadItem, NSToolbarSpaceItemIdentifier, kResetItem];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.target = self;
    item.bordered = YES;
    if ([ident isEqualToString:kResetItem]) {
        item.label = @"Reset Checklist";
        item.image = RGSymbol(@"arrow.counterclockwise", @"Reset checklist");
        item.toolTip = @"Clear every tick and start again";
        item.action = @selector(resetChecklist:);
    } else if ([ident isEqualToString:kTrackpadItem]) {
        item.label = @"Trackpad Settings";
        item.image = RGSymbol(@"rectangle.and.hand.point.up.left", @"Trackpad settings");
        item.toolTip = @"Open Trackpad settings to switch gestures on or off";
        item.action = @selector(openTrackpadSettings:);
    } else if ([ident isEqualToString:kMouseItem]) {
        item.label = @"Mouse Settings";
        item.image = RGSymbol(@"magicmouse", @"Mouse settings") ?: RGSymbol(@"computermouse", @"Mouse settings");
        item.toolTip = @"Open Mouse settings to switch gestures on or off";
        item.action = @selector(openMouseSettings:);
    }
    return item;
}

- (void)openTrackpadSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Trackpad-Settings.extension"]];
}
- (void)openMouseSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Mouse-Settings.extension"]];
}

- (void)resetChecklist:(id)sender {
    for (RGGestureGroup *g in self.groups) for (RGGestureItem *i in g.items) i.done = NO;
    [self.history removeAllObjects];
    [self setBannerTitle:@"Checklist reset" detail:@"Every gesture is back to do" symbol:@"arrow.counterclockwise" tint:nil];
    [self reloadChecklist];
}

#pragma mark Lifecycle

- (void)show {
    if (!self.window) [self buildWindow];
    [self refreshGroups];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.pad];
    if (!self.timer) {
        self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}

- (void)windowWillClose:(NSNotification *)n {
    [self.timer invalidate];
    self.timer = nil;
}

// Rebuilds the checklist from current settings, keeping ticks for gestures that are still on.
- (void)refreshGroups {
    NSArray<NSDictionary *> *infos = demo ? nil : (self.devices ? self.devices() : @[]);
    if (demo) return;
    NSMutableArray<RGGestureGroup *> *groups = [NSMutableArray array];
    for (NSDictionary *info in infos) {
        RGGestureGroup *g = [RGGestureGroup new];
        g.name = info[@"name"];
        g.kind = info[@"kind"];
        g.slot = [info[@"slot"] intValue];
        g.prefs = [info[@"prefs"] isKindOfClass:NSDictionary.class] ? info[@"prefs"] : @{};
        g.items = gesturesFor(g);
        for (RGGestureGroup *old in self.groups)
            if ([old.name isEqualToString:g.name])
                for (RGGestureItem *oi in old.items)
                    for (RGGestureItem *ni in g.items)
                        if ([oi.key isEqualToString:ni.key] && oi.done && ni.enabled) ni.done = YES;
        [groups addObject:g];
    }
    [groups sortUsingComparator:^NSComparisonResult(RGGestureGroup *a, RGGestureGroup *b) { return [@(a.isMouse) compare:@(b.isMouse)]; }];
    if (groups.count != self.groups.count) memset(sessions, 0, sizeof sessions);
    self.groups = groups;
    [self reloadChecklist];
}

- (void)reloadChecklist {
    NSMutableArray *rows = [NSMutableArray array];
    NSUInteger done = 0, total = 0;
    for (RGGestureGroup *g in self.groups) {
        [rows addObject:g];
        NSArray *sorted = [g.items sortedArrayUsingComparator:^NSComparisonResult(RGGestureItem *a, RGGestureItem *b) {
            return [@(!a.enabled) compare:@(!b.enabled)];   // gestures that are on first
        }];
        [rows addObjectsFromArray:sorted];
        done += g.doneCount;
        total += g.enabledCount;
    }
    self.rows = rows;
    [self.table reloadData];
    self.window.subtitle = total ? [NSString stringWithFormat:@"%lu of %lu gestures done", (unsigned long)done, (unsigned long)total] : @"";
}

- (RGGestureGroup *)recentGroup {
    RGGestureGroup *best = nil;
    double bestTime = 0, now = CFAbsoluteTimeGetCurrent();
    for (NSUInteger i = 0; i < self.groups.count && i < 8; i++)
        if (lastTouch[i] > bestTime && now - lastTouch[i] < 2.0) { bestTime = lastTouch[i]; best = self.groups[i]; }
    if (best) return best;
    for (RGGestureGroup *g in self.groups) if (!g.isMouse) return g;
    return self.groups.firstObject;
}

- (int)touchesForGroup:(RGGestureGroup *)g into:(MTFinger *)out {
    if (demo) {
        if (g != self.groups.firstObject) return 0;
        memcpy(out, demoTouches, sizeof(MTFinger) * (size_t)demoCount);
        return demoCount;
    }
    return RGCopyTouches(g.slot, out);
}

#pragma mark Recognising system gestures from raw touches

- (void)tick {
    double now = CFAbsoluteTimeGetCurrent();
    if (++refreshTicks % 120 == 0) [self refreshGroups];
    if (!demo && self.window.isVisible && !self.window.isMiniaturized) {
        for (NSUInteger i = 0; i < self.groups.count && i < 8; i++) {
            RGGestureGroup *g = self.groups[i];
            MTFinger f[MAX_TOUCHES];
            int n = RGCopyTouches(g.slot, f);
            RGSession *s = &sessions[i];
            if (n > 0) {
                float cx, cy, spread;
                measure(f, n, &cx, &cy, &spread);
                lastTouch[i] = now;
                if (!s->active) {
                    *s = (RGSession){.active = YES, .maxFingers = n, .start = now, .sx = cx, .sy = cy, .sSpread = spread,
                                     .ex = cx, .ey = cy, .eSpread = spread, .firstX = cx};
                } else if (n > s->maxFingers) {
                    s->maxFingers = n;   // all fingers are down now: measure the gesture from here
                    s->sx = s->ex = cx; s->sy = s->ey = cy; s->sSpread = s->eSpread = spread;
                } else if (n == s->maxFingers) {
                    s->ex = cx; s->ey = cy; s->eSpread = spread;
                }
                s->lastSeen = now;
            } else if (s->active) {
                s->active = NO;
                [self classify:*s group:g now:now];
            }
        }
    }
    self.pad.needsDisplay = YES;
}

- (void)classify:(RGSession)s group:(RGGestureGroup *)g now:(double)now {
    float dx = s.ex - s.sx, dy = s.ey - s.sy, dist = hypotf(dx, dy);
    float ratio = s.sSpread > 0.01f ? s.eSpread / s.sSpread : 1;
    double duration = s.lastSeen - s.start;
    int f = s.maxFingers;
    NSDictionary *p = g.prefs;

    if (g.isMouse) {
        if (f >= 2 && fabsf(dx) > 0.2f && fabsf(dx) > fabsf(dy)) {
            BOOL fullScreen = pv(p, @"MouseTwoFingerHorizSwipeGesture", 2) == 2;
            [self recognise:fullScreen ? @"fullscreen" : @"pages" group:g title:@"Two-finger swipe"
                     detail:[@"Swiped " stringByAppendingString:dx > 0 ? @"right" : @"left"]];
        } else if (f == 2 && duration < 0.3 && dist < 0.06f) {
            if (now - lastMouseTwoTap < 0.55) {
                lastMouseTwoTap = 0;
                [self recognise:@"mission" group:g title:@"Two-finger double-tap" detail:nil];
            } else {
                lastMouseTwoTap = now;
            }
        }
        return;
    }

    if (f >= 4 && (ratio < 0.72f || ratio > 1.38f)) {
        BOOL squeeze = ratio < 1;
        [self recognise:squeeze ? @"apps" : @"desktop" group:g
                  title:squeeze ? @"Squeeze with thumb and fingers" : @"Spread thumb and fingers"
                 detail:[NSString stringWithFormat:@"%d fingers, %.0f%% %@", f, fabsf(1 - ratio) * 100, squeeze ? @"closer" : @"wider"]];
        return;
    }
    if (f == 3 && pv(p, @"TrackpadThreeFingerDrag", 0) && dist > 0.05f) return;   // reported by the pad as a drag
    if (f >= 3 && dist > 0.12f) {
        BOOL vertical = fabsf(dy) > fabsf(dx);
        int horizontal = f == 3 ? pv(p, @"TrackpadThreeFingerHorizSwipeGesture", 1) : pv(p, @"TrackpadFourFingerHorizSwipeGesture", 2);
        int upDown = f == 3 ? pv(p, @"TrackpadThreeFingerVertSwipeGesture", 2) : pv(p, @"TrackpadFourFingerVertSwipeGesture", 2);
        NSString *direction = vertical ? (dy > 0 ? @"up" : @"down") : (dx > 0 ? @"right" : @"left");
        NSString *key = vertical ? (upDown == 2 ? (dy > 0 ? @"mission" : @"expose") : nil)
                                 : (horizontal == 2 ? @"fullscreen" : horizontal == 1 ? @"pages" : nil);
        if ([key isEqualToString:@"pages"] && now - lastSwipeEvent < 0.6) return;   // the pad already saw it
        [self recognise:key group:g title:[NSString stringWithFormat:@"%@-finger swipe %@", f == 3 ? @"Three" : f == 4 ? @"Four" : @"Five", direction]
                 detail:nil];
        return;
    }
    if (f == 3 && duration < 0.3 && dist < 0.03f) {
        [self recognise:@"lookup" group:g title:@"Three-finger tap" detail:nil];
        return;
    }
    if (f == 2 && s.firstX > 0.9f && dx < -0.08f)
        [self recognise:@"notifications" group:g title:@"Swipe in from the right edge" detail:@"Two fingers"];
}

#pragma mark Results

- (void)recognise:(NSString *)key group:(RGGestureGroup *)g title:(NSString *)title detail:(NSString *)detail {
    RGGestureItem *item = nil;
    if (key) for (RGGestureItem *i in g.items) if ([i.key isEqualToString:key]) item = i;
    BOOL fresh = item.enabled && !item.done;
    if (item.enabled) item.done = YES;

    NSString *outcome;
    if (!item) outcome = @"Not assigned to anything in System Settings";
    else if (!item.enabled) outcome = @"Switched off in System Settings, so macOS ignores it";
    else if (item.system) outcome = [@"macOS " stringByAppendingString:item.action];
    NSMutableArray *parts = [NSMutableArray array];
    if (detail.length) [parts addObject:detail];
    if (outcome) [parts addObject:outcome];
    NSString *line = [parts componentsJoinedByString:@" · "];

    NSString *symbol = !item.enabled ? @"exclamationmark.circle" : fresh ? @"checkmark.circle.fill" : @"hand.wave";
    NSColor *tint = !item.enabled ? [NSColor.systemOrangeColor colorWithAlphaComponent:0.25]
                  : fresh ? [NSColor.systemGreenColor colorWithAlphaComponent:0.25] : nil;
    BOOL allDone = fresh;
    for (RGGestureGroup *gg in self.groups) if (gg.doneCount < gg.enabledCount) allDone = NO;
    if (allDone) { title = @"Every gesture done"; line = @"Your mouse and trackpad passed the workout"; symbol = @"trophy.fill"; }
    [self setBannerTitle:title detail:line.length ? line : (g.name ?: @"") symbol:symbol tint:tint];

    [self.history insertObject:[NSString stringWithFormat:@"%@   %@%@%@", [self.timeFormat stringFromDate:[NSDate date]], title,
                                g.name ? [@" · " stringByAppendingString:g.name] : @"", detail.length ? [@" · " stringByAppendingString:detail] : @""]
                       atIndex:0];
    if (self.history.count > 50) [self.history removeLastObject];
    if (self.log) self.log([NSString stringWithFormat:@"· Gesture: %@ on %@%@", title, g.name ?: @"unknown device",
                            line.length ? [@" — " stringByAppendingString:line] : @""]);
    [self reloadChecklist];
}

- (void)setBannerTitle:(NSString *)title detail:(NSString *)detail symbol:(NSString *)symbol tint:(NSColor *)tint {
    self.bannerTitle.stringValue = title;
    self.bannerDetail.stringValue = detail ?: @"";
    self.bannerIcon.image = RGSymbol(symbol, title);
    self.bannerIcon.contentTintColor = [symbol isEqualToString:@"checkmark.circle.fill"] || [symbol isEqualToString:@"trophy.fill"]
        ? NSColor.systemGreenColor : [symbol hasPrefix:@"exclamationmark"] ? NSColor.systemOrangeColor : NSColor.labelColor;
    RGSetGlassTint(self.banner, tint);
    self.banner.accessibilityLabel = [NSString stringWithFormat:@"%@. %@", title, detail ?: @""];
    NSAccessibilityPostNotificationWithUserInfo(self.banner, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: title, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityMedium)});
    if (!RGReduceMotion()) {
        self.banner.alphaValue = 0.4;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
            ctx.duration = 0.25;
            self.banner.animator.alphaValue = 1;
        }];
    }
}

#pragma mark Checklist table

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tv { return (NSInteger)self.rows.count; }

- (BOOL)tableView:(NSTableView *)tv isGroupRow:(NSInteger)row { return [self.rows[(NSUInteger)row] isKindOfClass:RGGestureGroup.class]; }

- (CGFloat)tableView:(NSTableView *)tv heightOfRow:(NSInteger)row {
    return [self.rows[(NSUInteger)row] isKindOfClass:RGGestureGroup.class] ? 30 : 44;
}

- (BOOL)tableView:(NSTableView *)tv shouldSelectRow:(NSInteger)row { return NO; }

- (NSView *)tableView:(NSTableView *)tv viewForTableColumn:(NSTableColumn *)column row:(NSInteger)row {
    id obj = self.rows[(NSUInteger)row];
    if ([obj isKindOfClass:RGGestureGroup.class]) {
        RGGestureGroup *g = obj;
        NSTableCellView *cell = [tv makeViewWithIdentifier:@"group" owner:self];
        if (!cell) {
            cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 280, 30)];
            cell.identifier = @"group";
            NSTextField *t = RGLabel(@"", [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor);
            t.frame = NSMakeRect(4, 6, 270, 16);
            t.autoresizingMask = NSViewWidthSizable;
            cell.textField = t;
            [cell addSubview:t];
        }
        cell.textField.stringValue = [NSString stringWithFormat:@"%@  ·  %lu of %lu", g.name.uppercaseString,
                                      (unsigned long)g.doneCount, (unsigned long)g.enabledCount];
        return cell;
    }
    RGGestureItem *item = obj;
    NSTableCellView *cell = [tv makeViewWithIdentifier:@"item" owner:self];
    NSTextField *sub;
    if (!cell) {
        cell = [[NSTableCellView alloc] initWithFrame:NSMakeRect(0, 0, 280, 44)];
        cell.identifier = @"item";
        NSImageView *icon = [NSImageView new];
        icon.frame = NSMakeRect(6, 12, 20, 20);
        icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightMedium];
        NSTextField *title = RGLabel(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightMedium], NSColor.labelColor);
        title.frame = NSMakeRect(34, 22, 236, 17);
        title.autoresizingMask = NSViewWidthSizable;
        title.lineBreakMode = NSLineBreakByTruncatingTail;
        sub = RGLabel(@"", [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor);
        sub.frame = NSMakeRect(34, 5, 236, 15);
        sub.autoresizingMask = NSViewWidthSizable;
        sub.lineBreakMode = NSLineBreakByTruncatingTail;
        sub.identifier = @"subtitle";
        cell.imageView = icon;
        cell.textField = title;
        [cell addSubview:icon];
        [cell addSubview:title];
        [cell addSubview:sub];
    }
    for (NSView *v in cell.subviews) if ([v.identifier isEqualToString:@"subtitle"]) sub = (NSTextField *)v;
    NSString *symbol = !item.enabled ? @"minus.circle" : item.done ? @"checkmark.circle.fill" : @"circle";
    cell.imageView.image = RGSymbol(symbol, item.done ? @"Done" : item.enabled ? @"To do" : @"Off");
    cell.imageView.contentTintColor = !item.enabled ? NSColor.tertiaryLabelColor : item.done ? NSColor.systemGreenColor : NSColor.secondaryLabelColor;
    cell.textField.stringValue = item.title;
    cell.textField.textColor = item.enabled ? NSColor.labelColor : NSColor.tertiaryLabelColor;
    sub.stringValue = item.enabled && item.system ? [NSString stringWithFormat:@"%@ · macOS %@", item.how, item.action] : item.how;
    sub.textColor = item.enabled ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
    cell.toolTip = sub.stringValue;
    cell.accessibilityLabel = [NSString stringWithFormat:@"%@, %@. %@", item.title, item.done ? @"done" : item.enabled ? @"to do" : @"off", sub.stringValue];
    return cell;
}

#pragma mark Demo (README screenshot)

- (void)loadDemo {
    demo = YES;
    RGGestureGroup *tp = [RGGestureGroup new];
    tp.name = @"Magic Trackpad";
    tp.kind = @"trackpad";
    tp.prefs = @{@"Clicking": @1, @"TrackpadRightClick": @1, @"TrackpadScroll": @1, @"TrackpadPinch": @1, @"TrackpadRotate": @1,
                 @"TrackpadTwoFingerDoubleTapGesture": @1, @"TrackpadThreeFingerHorizSwipeGesture": @1,
                 @"TrackpadFourFingerHorizSwipeGesture": @2, @"TrackpadThreeFingerVertSwipeGesture": @2,
                 @"TrackpadFourFingerVertSwipeGesture": @2, @"TrackpadFiveFingerPinchGesture": @2,
                 @"TrackpadFourFingerPinchGesture": @2, @"TrackpadTwoFingerFromRightEdgeSwipeGesture": @3};
    tp.items = gesturesFor(tp);
    RGGestureGroup *mouse = [RGGestureGroup new];
    mouse.name = @"Magic Mouse";
    mouse.kind = @"mouse";
    mouse.prefs = @{@"MouseButtonMode": @"TwoButton", @"MouseVerticalScroll": @1, @"MouseTwoFingerHorizSwipeGesture": @2,
                    @"MouseTwoFingerDoubleTapGesture": @3};
    mouse.items = gesturesFor(mouse);
    NSSet *done = [NSSet setWithArray:@[@"click", @"tap", @"secondary", @"double", @"scroll", @"pinch", @"rotate", @"pages", @"mission", @"apps"]];
    for (RGGestureItem *i in tp.items) if (i.enabled && [done containsObject:i.key]) i.done = YES;
    for (RGGestureItem *i in mouse.items) if (i.enabled && [@[@"click", @"secondary"] containsObject:i.key]) i.done = YES;
    self.groups = @[tp, mouse];
    float pts[4][2] = {{0.40f, 0.62f}, {0.50f, 0.66f}, {0.60f, 0.62f}, {0.47f, 0.36f}};
    demoCount = 4;
    memset(demoTouches, 0, sizeof demoTouches);
    for (int i = 0; i < 4; i++) { demoTouches[i].normalized.pos = (MTPoint){pts[i][0], pts[i][1]}; demoTouches[i].size = 1.2f; }
    lastTouch[0] = CFAbsoluteTimeGetCurrent() + 3600;
    [self.history addObjectsFromArray:@[@"09:42:31   Squeeze with thumb and fingers · Magic Trackpad · 4 fingers, 41% closer",
                                        @"09:42:24   Three-finger swipe up · Magic Trackpad",
                                        @"09:42:18   Rotate · Magic Trackpad · 47° clockwise",
                                        @"09:42:12   Zoom out · Magic Trackpad · Pinched to ×0.62",
                                        @"09:42:05   Double-click · Magic Trackpad · 212 ms apart · macOS allows up to 500 ms"]];
}

- (void)showDemo {
    if (!self.window) [self buildWindow];
    [self loadDemo];
    [self reloadChecklist];
    [self setBannerTitle:@"Squeeze with thumb and fingers" detail:@"4 fingers, 41% closer · macOS opens Apps"
                  symbol:@"checkmark.circle.fill" tint:[NSColor.systemGreenColor colorWithAlphaComponent:0.25]];
    [self.window makeKeyAndOrderFront:nil];
}

- (BOOL)writeDemoSnapshotTo:(NSString *)path {
    [self showDemo];
    NSView *v = self.window.contentView;
    [v layoutSubtreeIfNeeded];
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end
