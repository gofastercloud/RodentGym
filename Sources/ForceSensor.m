// Force Sensor — see ForceSensor.h.
//
// The trace is plotted on a 0–3 scale: 0–1 touching before the click, 1–2 clicked (stage 1),
// 2–3 Force Click (stage 2). NSEvent reports pressure 0–1 within the current stage.

#import "ForceSensor.h"
#import "UI.h"

#define SAMPLES 600   // 10 seconds at 60 Hz

typedef struct { float value; unsigned char button; BOOL force; } RGSample;

@class RGForceView;

@interface RGForceSensor () {
@public
    RGSample samples[SAMPLES];
    int head;                 // next slot to write
    long ticks;               // samples written since the window opened (drives the scrolling grid)
    float value;              // current reading on the 0–3 scale
    int button;               // 0 none, 1 left, 2 right
    NSInteger stage;
    BOOL pressHasForce, paused, demo;
    float pressPeak, sessionPeak;
    long clicks[3], forceClicks[3];
    float peakSum[3];
    long peakCount[3];
}
@property (strong, readwrite) NSWindow *window;
@property (strong) RGForceView *graph;
@property (strong) NSView *badge;
@property (strong) NSTextField *badgeLabel;
@property (strong) NSTimer *timer;
- (void)press:(int)b event:(NSEvent *)e;
- (void)releaseButton;
- (void)pressure:(NSEvent *)e;
- (NSString *)settingsSummary;
- (BOOL)hasForceTrackpad;
@end

static NSString *stageName(float v) { return v >= 2 ? @"Force Click" : v >= 1 ? @"Click" : v > 0 ? @"Touch" : @"Idle"; }
static NSColor *buttonColour(int b) { return b == 2 ? NSColor.systemOrangeColor : NSColor.systemBlueColor; }

#pragma mark - Graph view

@interface RGForceView : NSView
@property (weak) RGForceSensor *sensor;
- (NSRect)graphRect;
@end

@implementation RGForceView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)acceptsFirstMouse:(NSEvent *)e { return NO; }
- (NSMenu *)menuForEvent:(NSEvent *)e { return nil; }   // right click is measured here, not a menu

- (void)mouseDown:(NSEvent *)e {
    [self.sensor press:(e.modifierFlags & NSEventModifierFlagControl) ? 2 : 1 event:e];
}
- (void)rightMouseDown:(NSEvent *)e { [self.sensor press:2 event:e]; }
- (void)mouseUp:(NSEvent *)e { [self.sensor releaseButton]; }
- (void)rightMouseUp:(NSEvent *)e { [self.sensor releaseButton]; }
- (void)pressureChangeWithEvent:(NSEvent *)e { [self.sensor pressure:e]; }

- (NSRect)graphRect {
    CGFloat top = self.safeAreaInsets.top + 16;
    return NSMakeRect(20, top, self.bounds.size.width - 40, MAX(240, self.bounds.size.height - top - 150));
}

- (void)drawRect:(NSRect)dirty {
    RGForceSensor *s = self.sensor;
    if (!s) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSRect card = self.graphRect;
    RGDrawCard(card, 18);
    NSRect plot = NSMakeRect(card.origin.x + 104, card.origin.y + 22, card.size.width - 128, card.size.height - 60);
    CGFloat (^yFor)(float) = ^CGFloat(float v) { return NSMaxY(plot) - MIN(3, MAX(0, v)) / 3.0 * plot.size.height; };

    // Bands: Force Click shaded, with labelled thresholds
    NSRect forceBand = NSMakeRect(plot.origin.x, yFor(3), plot.size.width, yFor(2) - yFor(3));
    [[NSColor.systemPinkColor colorWithAlphaComponent:0.06] setFill];
    NSRectFillUsingOperation(forceBand, NSCompositingOperationSourceOver);
    NSFont *axis = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    NSArray *bands = @[@[@0.5, @"Touch"], @[@1.5, @"Click"], @[@2.5, @"Force Click"]];
    for (NSArray *b in bands)
        RGDrawText(b[1], NSMakeRect(card.origin.x + 16, yFor([b[0] floatValue]) - 8, 84, 16), axis, NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    for (int level = 1; level <= 2; level++) {
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(plot.origin.x, yFor(level) + 0.5)];
        [line lineToPoint:NSMakePoint(NSMaxX(plot), yFor(level) + 0.5)];
        CGFloat dash[] = {5, 4};
        [line setLineDash:dash count:2 phase:0];
        [NSColor.separatorColor setStroke];
        [line stroke];
    }
    [NSColor.separatorColor setStroke];
    [NSBezierPath strokeLineFromPoint:NSMakePoint(plot.origin.x, NSMaxY(plot) + 0.5) toPoint:NSMakePoint(NSMaxX(plot), NSMaxY(plot) + 0.5)];

    // Scrolling one-second grid
    [[NSColor.separatorColor colorWithAlphaComponent:0.15] setStroke];
    for (int i = 0; i < SAMPLES; i++) {
        long sampleIndex = s->ticks - (SAMPLES - 1 - i);
        if (sampleIndex > 0 && sampleIndex % 60 == 0) {
            CGFloat x = round(plot.origin.x + plot.size.width * i / (SAMPLES - 1)) + 0.5;
            [NSBezierPath strokeLineFromPoint:NSMakePoint(x, plot.origin.y) toPoint:NSMakePoint(x, NSMaxY(plot))];
        }
    }
    RGDrawText(@"10 s", NSMakeRect(plot.origin.x, NSMaxY(plot) + 6, 60, 14), [NSFont systemFontOfSize:10], NSColor.tertiaryLabelColor, NSTextAlignmentLeft);
    RGDrawText(@"now", NSMakeRect(NSMaxX(plot) - 60, NSMaxY(plot) + 6, 60, 14), [NSFont systemFontOfSize:10], NSColor.tertiaryLabelColor, NSTextAlignmentRight);

    // The trace, in runs of the same button and force state
    [NSGraphicsContext saveGraphicsState];
    [[NSBezierPath bezierPathWithRect:plot] addClip];
    int i = 0;
    while (i < SAMPLES) {
        RGSample first = s->samples[(s->head + i) % SAMPLES];
        int j = i;
        NSBezierPath *path = [NSBezierPath bezierPath];
        while (j < SAMPLES) {
            RGSample smp = s->samples[(s->head + j) % SAMPLES];
            if (smp.button != first.button || smp.force != first.force) break;
            NSPoint p = NSMakePoint(plot.origin.x + plot.size.width * j / (SAMPLES - 1), yFor(smp.value));
            if (j == i) {
                // A press rises from the baseline in its own colour
                if (first.button && i > 0) {
                    [path moveToPoint:NSMakePoint(p.x, yFor(0))];
                    [path lineToPoint:p];
                } else {
                    [path moveToPoint:p];
                }
            } else {
                [path lineToPoint:p];
            }
            j++;
        }
        if (j < SAMPLES && first.button) {   // and falls back to it when released
            RGSample next = s->samples[(s->head + j) % SAMPLES];
            [path lineToPoint:NSMakePoint(plot.origin.x + plot.size.width * j / (SAMPLES - 1), yFor(next.value))];
        }
        if (first.button) {
            NSColor *c = buttonColour(first.button);
            NSBezierPath *fill = [path copy];
            [fill lineToPoint:NSMakePoint(fill.currentPoint.x, NSMaxY(plot))];
            [fill lineToPoint:NSMakePoint(plot.origin.x + plot.size.width * i / (SAMPLES - 1), NSMaxY(plot))];
            [fill closePath];
            [[c colorWithAlphaComponent:first.force ? 0.14 : 0.06] setFill];
            [fill fill];
            path.lineWidth = 2.5;
            if (!first.force) { CGFloat dash[] = {5, 4}; [path setLineDash:dash count:2 phase:0]; }
            [c setStroke];
        } else {
            path.lineWidth = 1.5;
            [NSColor.tertiaryLabelColor setStroke];
        }
        path.lineJoinStyle = NSLineJoinStyleRound;
        path.lineCapStyle = NSLineCapStyleRound;
        [path stroke];
        i = j;
    }
    [NSGraphicsContext restoreGraphicsState];

    // Legend
    CGFloat lx = plot.origin.x + 70, ly = NSMaxY(plot) + 5;
    NSArray *legend = @[@[NSColor.systemBlueColor, @"Left click"], @[NSColor.systemOrangeColor, @"Right click"], @[NSColor.tertiaryLabelColor, @"Dashed: no force data"]];
    for (NSArray *item in legend) {
        [(NSColor *)item[0] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(lx, ly + 4, 14, 6) xRadius:3 yRadius:3] fill];
        RGDrawText(item[1], NSMakeRect(lx + 20, ly, 160, 14), [NSFont systemFontOfSize:10.5], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        lx += 30 + [item[1] sizeWithAttributes:@{NSFontAttributeName: [NSFont systemFontOfSize:10.5]}].width + 14;
    }

    [self drawStats:NSMakeRect(20, NSMaxY(card) + 16, self.bounds.size.width - 40, 104)];
}

- (void)drawStats:(NSRect)r {
    RGForceSensor *s = self.sensor;
    CGFloat w = (r.size.width - 3 * 12) / 4;
    NSString *avgL = s->peakCount[1] ? [NSString stringWithFormat:@"%.0f%%", s->peakSum[1] / s->peakCount[1] / 3 * 100] : @"–";
    NSString *avgR = s->peakCount[2] ? [NSString stringWithFormat:@"%.0f%%", s->peakSum[2] / s->peakCount[2] / 3 * 100] : @"–";
    NSArray *tiles = @[
        @[@"PEAK", [NSString stringWithFormat:@"%.0f%%", s->sessionPeak / 3 * 100], stageName(s->sessionPeak)],
        @[@"CLICKS", [NSString stringWithFormat:@"%ld · %ld", s->clicks[1], s->clicks[2]], @"Left · right"],
        @[@"FORCE CLICKS", [NSString stringWithFormat:@"%ld · %ld", s->forceClicks[1], s->forceClicks[2]],
          [NSString stringWithFormat:@"Average peak %@ · %@", avgL, avgR]],
        @[@"TRACKPAD", s.hasForceTrackpad ? @"Force Touch" : @"Not found", s.settingsSummary]];
    for (NSUInteger i = 0; i < tiles.count; i++) {
        NSRect t = NSMakeRect(r.origin.x + i * (w + 12), r.origin.y, w, r.size.height);
        RGDrawCard(t, 16);
        RGDrawText(tiles[i][0], NSMakeRect(t.origin.x + 14, t.origin.y + 14, w - 28, 14),
                   [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        RGDrawText(tiles[i][1], NSMakeRect(t.origin.x + 14, t.origin.y + 32, w - 28, 30),
                   [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
        RGDrawText(tiles[i][2], NSMakeRect(t.origin.x + 14, t.origin.y + 68, w - 28, 28),
                   [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    }
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Click pressure graph"; }
- (NSString *)accessibilityValue {
    RGForceSensor *s = self.sensor;
    return [NSString stringWithFormat:@"%@ at %.0f percent. %ld left and %ld right clicks, %ld Force Clicks.",
            stageName(s->value), s->value / 3 * 100, s->clicks[1], s->clicks[2], s->forceClicks[1] + s->forceClicks[2]];
}
@end

#pragma mark - Sensor

static NSString *const kPauseItem = @"pause", *const kClearItem = @"clear", *const kSettingsItem = @"trackpad";

@implementation RGForceSensor

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 900, 640)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Force Sensor";
    self.window.subtitle = @"Press on a Force Touch trackpad with the pointer over the graph";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentMinSize = NSMakeSize(760, 520);
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"ForceSensorToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    self.graph = [[RGForceView alloc] initWithFrame:NSMakeRect(0, 0, 900, 640)];
    self.graph.sensor = self;
    self.window.contentView = self.graph;
    [self buildBadge];
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymForceSensor"];
}

// A live readout floating on Liquid Glass over the top-right of the graph.
- (void)buildBadge {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 250, 40)];
    NSImageView *icon = [NSImageView imageViewWithImage:RGSymbol(@"hand.point.up.left.fill", @"Pressure") ?: [NSImage new]];
    icon.frame = NSMakeRect(14, 10, 20, 20);
    icon.contentTintColor = NSColor.secondaryLabelColor;
    self.badgeLabel = RGLabel(@"Idle", [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.badgeLabel.frame = NSMakeRect(40, 11, 200, 18);
    [content addSubview:icon];
    [content addSubview:self.badgeLabel];
    self.badge = RGGlassView(content, 20);
    self.badge.autoresizingMask = NSViewMinXMargin | NSViewMaxYMargin;
    [self.graph addSubview:self.badge];
}

- (void)layoutBadge {
    NSRect g = self.graph.graphRect;
    self.badge.frame = NSMakeRect(NSMaxX(g) - 250 - 14, g.origin.y + 14, 250, 40);
}

#pragma mark Toolbar

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kSettingsItem, NSToolbarFlexibleSpaceItemIdentifier, kPauseItem, kClearItem];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.target = self;
    item.bordered = YES;
    if ([ident isEqualToString:kPauseItem]) {
        item.label = @"Pause";
        item.image = RGSymbol(@"pause.fill", @"Pause");
        item.toolTip = @"Pause or resume the graph";
        item.action = @selector(togglePause:);
    } else if ([ident isEqualToString:kClearItem]) {
        item.label = @"Clear";
        item.image = RGSymbol(@"trash", @"Clear");
        item.toolTip = @"Clear the graph and the counts";
        item.action = @selector(clear:);
    } else {
        item.label = @"Trackpad Settings";
        item.image = RGSymbol(@"rectangle.and.hand.point.up.left", @"Trackpad settings");
        item.toolTip = @"Open Trackpad settings to change click pressure or Force Click";
        item.action = @selector(openTrackpadSettings:);
    }
    return item;
}

- (void)togglePause:(NSToolbarItem *)sender {
    paused = !paused;
    for (NSToolbarItem *i in self.window.toolbar.items)
        if ([i.itemIdentifier isEqualToString:kPauseItem]) {
            i.image = RGSymbol(paused ? @"play.fill" : @"pause.fill", paused ? @"Resume" : @"Pause");
            i.label = paused ? @"Resume" : @"Pause";
        }
    self.graph.needsDisplay = YES;
}

- (void)clear:(id)sender {
    memset(samples, 0, sizeof samples);
    memset(clicks, 0, sizeof clicks);
    memset(forceClicks, 0, sizeof forceClicks);
    memset(peakSum, 0, sizeof peakSum);
    memset(peakCount, 0, sizeof peakCount);
    sessionPeak = 0;
    self.graph.needsDisplay = YES;
}

- (void)openTrackpadSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Trackpad-Settings.extension"]];
}

#pragma mark Lifecycle

- (void)show {
    if (!self.window) [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.graph];
    [self layoutBadge];
    if (!self.timer) {
        self.timer = [NSTimer timerWithTimeInterval:1.0 / 60 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
}

- (void)windowWillClose:(NSNotification *)n {
    [self.timer invalidate];
    self.timer = nil;
}

- (void)windowDidResize:(NSNotification *)n { [self layoutBadge]; }

- (void)windowDidResignKey:(NSNotification *)n { if (button) [self releaseButton]; }

#pragma mark Input

- (void)press:(int)b event:(NSEvent *)e {
    button = b;
    clicks[b]++;
    pressHasForce = NO;
    stage = 1;
    value = 1;   // a click with no pressure data sits at the click threshold
    pressPeak = value;
}

- (void)pressure:(NSEvent *)e {
    NSInteger previous = stage;
    stage = e.stage;
    float p = MIN(1, MAX(0, e.pressure));
    value = stage == 0 ? p * 0.95f : stage == 1 ? 1 + p : 2 + p;
    if (!button && stage >= 1) button = 1;   // pressure can arrive a moment before the mouse-down event
    if (button) pressHasForce = YES;
    if (stage == 2 && previous < 2 && button) forceClicks[button]++;
    pressPeak = MAX(pressPeak, value);
}

- (void)releaseButton {
    if (button && pressHasForce) {
        peakSum[button] += pressPeak;
        peakCount[button]++;
    }
    button = 0;
    stage = 0;
    value = 0;
    pressPeak = 0;
}

- (void)tick {
    if (paused || demo) return;
    samples[head] = (RGSample){value, (unsigned char)button, button ? pressHasForce : YES};
    head = (head + 1) % SAMPLES;
    ticks++;
    sessionPeak = MAX(sessionPeak, value);
    self.badgeLabel.stringValue = button
        ? [NSString stringWithFormat:@"%@ · %@ · %.0f%%", button == 2 ? @"Right" : @"Left", stageName(value), value / 3 * 100]
        : @"Idle · press to measure";
    self.badgeLabel.textColor = button ? buttonColour(button) : NSColor.secondaryLabelColor;
    self.graph.needsDisplay = YES;
}

#pragma mark Settings

- (NSDictionary *)trackpadPrefs {
    for (NSDictionary *d in (self.devices ? self.devices() : @[]))
        if ([d[@"kind"] isEqualToString:@"trackpad"]) return d[@"prefs"];
    return nil;
}

- (BOOL)hasForceTrackpad { return demo || self.trackpadPrefs != nil; }

- (NSString *)settingsSummary {
    NSDictionary *p = demo ? @{@"FirstClickThreshold": @1} : self.trackpadPrefs;
    if (!p) return @"Connect a Force Touch trackpad";
    static NSString *const pressure[] = {@"light", @"medium", @"firm"};
    id v = p[@"FirstClickThreshold"];
    int level = MAX(0, MIN(2, [v respondsToSelector:@selector(intValue)] ? [v intValue] : 1));
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    id force = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("com.apple.trackpad.forceClick"), kCFPreferencesAnyApplication));
    return [NSString stringWithFormat:@"%@ pressure · Force Click %@", pressure[level].capitalizedString, (force == nil || [force boolValue]) ? @"on" : @"off"];
}

#pragma mark Demo

- (void)loadDemo {
    demo = YES;
    memset(samples, 0, sizeof samples);
    head = 0;
    ticks = 600;
    // Three left presses (one a Force Click), a right click with pressure, and a Magic Mouse click with none
    struct { int start, len, button; float peak; BOOL force; } presses[] = {
        {40, 70, 1, 1.75f, YES}, {150, 120, 1, 2.7f, YES}, {320, 80, 2, 1.6f, YES}, {440, 60, 1, 1.0f, NO}, {520, 60, 2, 2.35f, YES}};
    for (size_t k = 0; k < sizeof presses / sizeof presses[0]; k++)
        for (int t = 0; t < presses[k].len; t++) {
            float x = (float)t / presses[k].len;
            float shape = presses[k].force ? sinf(x * (float)M_PI) : 1;
            float v = presses[k].force ? MAX(0.3f, presses[k].peak * powf(shape, 0.6f)) : presses[k].peak;
            samples[presses[k].start + t] = (RGSample){v, (unsigned char)presses[k].button, presses[k].force};
        }
    for (int i = 0; i < SAMPLES; i++) if (!samples[i].button) samples[i].force = YES;
    clicks[1] = 3; clicks[2] = 2; forceClicks[1] = 1; forceClicks[2] = 1;
    peakSum[1] = 1.75f + 2.7f; peakCount[1] = 2; peakSum[2] = 1.6f + 2.35f; peakCount[2] = 2;
    sessionPeak = 2.7f;
}

- (void)showDemo {
    [self show];
    [self loadDemo];
    self.badgeLabel.stringValue = @"Right · Force Click · 78%";
    self.badgeLabel.textColor = NSColor.systemOrangeColor;
    self.graph.needsDisplay = YES;
}

- (BOOL)writeDemoSnapshotTo:(NSString *)path {
    [self showDemo];
    [self.window orderOut:nil];
    NSView *v = self.graph;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end
