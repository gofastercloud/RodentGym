// Latency Monitor — see LatencyMonitor.h.

#import "LatencyMonitor.h"
#import "Multitouch.h"
#import "Bluetooth.h"
#import "UI.h"

#define SPAN        120.0   // seconds of history on screen
#define MAX_CLICKS  1024
#define SERIES_LEN  1024    // 4 Hz rate samples or 0.5 Hz signal samples, comfortably more than SPAN
#define MAX_STALLS  128
#define STAT_CLICKS 200     // latency statistics cover the most recent clicks

typedef struct { double t; float ms; unsigned char button; BOOL dropped; } RGClick;
typedef struct { double t; float v, jitter; } RGPoint;

#pragma mark - A time series for one device

@interface RGSeries : NSObject {
@public
    RGPoint pts[SERIES_LEN];
    int head, count;
    double stalls[MAX_STALLS];
    int stallHead, stallCount;
    long totalStalls, lost;
    RGFrameStats last;
    BOOL haveLast;
    double lastActive;
}
@property (copy) NSString *name;
@property (strong) NSColor *colour;
@end

@implementation RGSeries
- (void)add:(double)t value:(float)v jitter:(float)j {
    pts[head] = (RGPoint){t, v, j};
    head = (head + 1) % SERIES_LEN;
    if (count < SERIES_LEN) count++;
    lastActive = t;
}
- (RGPoint)at:(int)i { return pts[(head - count + i + SERIES_LEN) % SERIES_LEN]; }   // 0 = oldest
- (RGPoint)latest { return [self at:count - 1]; }
- (void)addStall:(double)t {
    stalls[stallHead] = t;
    stallHead = (stallHead + 1) % MAX_STALLS;
    if (stallCount < MAX_STALLS) stallCount++;
}
- (int)stallsSince:(double)t {
    int n = 0;
    for (int i = 0; i < stallCount; i++) if (stalls[i] >= t) n++;
    return n;
}
@end

static NSColor *colourForKind(NSDictionary *d) {
    if ([d[@"builtIn"] boolValue]) return NSColor.systemMintColor;
    return [d[@"kind"] isEqual:@"mouse"] ? NSColor.systemTealColor : NSColor.systemIndigoColor;
}
static NSColor *clickColour(int b) {
    return b == 2 ? NSColor.systemOrangeColor : b == 3 ? NSColor.systemPurpleColor : NSColor.systemBlueColor;
}

// The smallest "nice" axis maximum that leaves headroom above `v`.
static double niceMax(double v, const double *steps, int n) {
    for (int i = 0; i < n; i++) if (v * 1.15 <= steps[i]) return steps[i];
    return steps[n - 1];
}

@class RGLatencyView;

@interface RGLatencyMonitor () {
@public
    RGClick clicks[MAX_CLICKS];
    int clickHead, clickCount;
    long totalClicks, totalDrops;
    double lastDropTime;
    double frozen, pausedAt;
    BOOL paused;
}
@property (strong, readwrite) NSWindow *window;
@property (strong) RGLatencyView *view;
@property (strong) NSView *badge;
@property (strong) NSTextField *badgeLabel;
@property (strong) NSMutableDictionary<NSString *, RGSeries *> *rates, *signals;
@property (strong) NSMutableArray<NSDictionary *> *links;
@property (strong) NSTimer *sampler, *redraw;
- (double)now;
- (RGClick)clickAt:(int)i;
- (NSArray<NSNumber *> *)recentLatencies;
- (RGSeries *)activeRate;
- (RGSeries *)activeSignal;
@end

#pragma mark - Graph view

@interface RGLatencyView : NSView
@property (weak) RGLatencyMonitor *m;
- (NSRect)cardRect;
@end

@implementation RGLatencyView

- (BOOL)isFlipped { return YES; }

- (NSRect)cardRect {
    CGFloat top = self.safeAreaInsets.top + 16;
    return NSMakeRect(20, top, self.bounds.size.width - 40, MAX(380, self.bounds.size.height - top - 16 - 104 - 20));
}

- (void)drawRect:(NSRect)dirty {
    RGLatencyMonitor *m = self.m;
    if (!m) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSRect card = self.cardRect;
    RGDrawCard(card, 18);

    double now = m.now;
    CGFloat x0 = card.origin.x + 64, x1 = NSMaxX(card) - 22;
    CGFloat top = card.origin.y + 44, bottom = NSMaxY(card) - 52, gap = 46;
    CGFloat avail = bottom - top - 2 * gap;
    NSRect lat = NSMakeRect(x0, top, x1 - x0, round(avail * 0.42));
    NSRect rate = NSMakeRect(x0, NSMaxY(lat) + gap, x1 - x0, round(avail * 0.31));
    NSRect sig = NSMakeRect(x0, NSMaxY(rate) + gap, x1 - x0, bottom - (NSMaxY(rate) + gap));
    NSArray<NSValue *> *lanes = @[[NSValue valueWithRect:lat], [NSValue valueWithRect:rate], [NSValue valueWithRect:sig]];
    CGFloat (^xFor)(double) = ^CGFloat(double t) { return x1 - (now - t) / SPAN * (x1 - x0); };
    double since = now - SPAN;

    // Scrolling 10-second grid
    [[NSColor.separatorColor colorWithAlphaComponent:0.18] setStroke];
    for (double t = floor(now / 10) * 10; t > since; t -= 10) {
        CGFloat x = round(xFor(t)) + 0.5;
        for (NSValue *v in lanes)
            [NSBezierPath strokeLineFromPoint:NSMakePoint(x, v.rectValue.origin.y) toPoint:NSMakePoint(x, NSMaxY(v.rectValue))];
    }

    NSFont *title = [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], *small = [NSFont systemFontOfSize:10.5];
    NSFont *tick = [NSFont monospacedDigitSystemFontOfSize:10 weight:NSFontWeightRegular];
    // Each lane is titled above its top edge: "Click latency  milliseconds"
    void (^laneHeader)(NSRect, NSString *, NSString *) = ^(NSRect r, NSString *t, NSString *sub) {
        CGFloat tw = [t sizeWithAttributes:@{NSFontAttributeName: title}].width;
        RGDrawText(t, NSMakeRect(card.origin.x + 18, r.origin.y - 26, tw + 4, 17), title, NSColor.labelColor, NSTextAlignmentLeft);
        RGDrawText(sub, NSMakeRect(card.origin.x + 18 + tw + 8, r.origin.y - 24.5, 420, 14), small, NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    };
    void (^axis)(NSRect, double, double, NSArray<NSNumber *> *, NSString *) = ^(NSRect r, double lo, double hi, NSArray<NSNumber *> *ticks, NSString *fmt) {
        for (NSNumber *v in ticks) {
            CGFloat y = round(NSMaxY(r) - (v.doubleValue - lo) / (hi - lo) * r.size.height) + 0.5;
            [[NSColor.separatorColor colorWithAlphaComponent:v.doubleValue == lo ? 0.7 : 0.3] setStroke];
            [NSBezierPath strokeLineFromPoint:NSMakePoint(r.origin.x, y) toPoint:NSMakePoint(NSMaxX(r), y)];
            RGDrawText([NSString stringWithFormat:fmt, v.doubleValue], NSMakeRect(r.origin.x - 46, y - 7, 40, 13), tick,
                       NSColor.tertiaryLabelColor, NSTextAlignmentRight);
        }
    };

    // 1. Click latency
    NSMutableArray<NSNumber *> *visible = [NSMutableArray array];
    for (int i = 0; i < m->clickCount; i++) {
        RGClick c = [m clickAt:i];
        if (c.t >= since && !c.dropped) [visible addObject:@(c.ms)];
    }
    static const double latSteps[] = {10, 20, 50, 100, 200, 500, 1000};
    double latMax = niceMax(MAX(8, [[visible valueForKeyPath:@"@max.doubleValue"] doubleValue]), latSteps, 7);
    laneHeader(lat, @"Click latency", @"milliseconds from button report to delivered click");
    axis(lat, 0, latMax, @[@0, @(latMax / 2), @(latMax)], latMax < 20 ? @"%.0f" : @"%.0f");
    CGFloat (^yLat)(double) = ^CGFloat(double ms) { return NSMaxY(lat) - MIN(latMax, ms) / latMax * lat.size.height; };
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;
    for (int i = 0; i < m->clickCount; i++) {
        RGClick c = [m clickAt:i];
        if (c.t < since) continue;
        CGFloat x = xFor(c.t);
        if (c.dropped) {
            [[NSColor.systemRedColor colorWithAlphaComponent:0.45] setStroke];
            for (NSValue *v in lanes)
                [NSBezierPath strokeLineFromPoint:NSMakePoint(round(x) + 0.5, v.rectValue.origin.y) toPoint:NSMakePoint(round(x) + 0.5, NSMaxY(v.rectValue))];
            NSBezierPath *cross = [NSBezierPath bezierPath];
            CGFloat cy = lat.origin.y + 7, r = 5;
            [cross moveToPoint:NSMakePoint(x - r, cy - r)]; [cross lineToPoint:NSMakePoint(x + r, cy + r)];
            [cross moveToPoint:NSMakePoint(x - r, cy + r)]; [cross lineToPoint:NSMakePoint(x + r, cy - r)];
            cross.lineWidth = 2.2;
            cross.lineCapStyle = NSLineCapStyleRound;
            [NSColor.systemRedColor setStroke];
            [cross stroke];
            continue;
        }
        CGFloat y = yLat(c.ms), r = 3.6;
        NSColor *col = clickColour(c.button);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 5, [col colorWithAlphaComponent:0.55].CGColor);
        [col setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(x - r, y - r, 2 * r, 2 * r)] fill];
        CGContextRestoreGState(ctx);
        if (c.ms > latMax) {   // off the scale: an arrow at the top edge
            RGDrawText(@"▲", NSMakeRect(x - 5, lat.origin.y - 2, 10, 10), [NSFont systemFontOfSize:7], col, NSTextAlignmentCenter);
        }
    }
    if (visible.count >= 3) {
        NSArray *sorted = [visible sortedArrayUsingSelector:@selector(compare:)];
        double med = [sorted[sorted.count / 2] doubleValue];
        NSBezierPath *ml = [NSBezierPath bezierPath];
        [ml moveToPoint:NSMakePoint(x0, round(yLat(med)) + 0.5)];
        [ml lineToPoint:NSMakePoint(x1, round(yLat(med)) + 0.5)];
        CGFloat dash[] = {3, 4};
        [ml setLineDash:dash count:2 phase:0];
        [[NSColor.labelColor colorWithAlphaComponent:0.35] setStroke];
        [ml stroke];
        RGDrawText([NSString stringWithFormat:@"median %.1f", med], NSMakeRect(x1 - 120, yLat(med) - 15, 116, 13), tick,
                   NSColor.secondaryLabelColor, NSTextAlignmentRight);
    }
    if (m->clickCount == 0)
        RGDrawText(@"Click with a mouse or trackpad to measure latency", NSMakeRect(x0, NSMidY(lat) - 8, x1 - x0, 16),
                   [NSFont systemFontOfSize:12], NSColor.tertiaryLabelColor, NSTextAlignmentCenter);

    // 2. Touch report rate
    double maxHz = 0;
    for (RGSeries *s in m.rates.allValues)
        for (int i = 0; i < s->count; i++) { RGPoint p = [s at:i]; if (p.t >= since) maxHz = MAX(maxHz, p.v); }
    static const double hzSteps[] = {60, 90, 120, 150, 180, 240, 360, 480};
    double hzMax = niceMax(MAX(50, maxHz), hzSteps, 8);
    laneHeader(rate, @"Touch report rate", @"frames per second while touching · ▲ stall");
    axis(rate, 0, hzMax, @[@0, @(hzMax / 2), @(hzMax)], @"%.0f");
    CGFloat (^yHz)(double) = ^CGFloat(double hz) { return NSMaxY(rate) - MIN(hzMax, hz) / hzMax * rate.size.height; };
    BOOL anyRate = NO;
    for (RGSeries *s in m.rates.allValues) {
        NSBezierPath *path = [NSBezierPath bezierPath];
        double prevT = -1;
        for (int i = 0; i < s->count; i++) {
            RGPoint p = [s at:i];
            if (p.t < since - 1) { prevT = -1; continue; }
            NSPoint pt = NSMakePoint(MAX(x0, xFor(p.t)), yHz(p.v));
            if (prevT < 0 || p.t - prevT > 0.8) [path moveToPoint:pt];
            else [path lineToPoint:pt];
            prevT = p.t;
            anyRate = YES;
        }
        path.lineWidth = 2;
        path.lineJoinStyle = NSLineJoinStyleRound;
        path.lineCapStyle = NSLineCapStyleRound;
        [s.colour setStroke];
        [path stroke];
        for (int i = 0; i < s->stallCount; i++) {   // stalls: red marks on the baseline
            double t = s->stalls[i];
            if (t < since) continue;
            CGFloat x = xFor(t), by = NSMaxY(rate);
            NSBezierPath *tri = [NSBezierPath bezierPath];
            [tri moveToPoint:NSMakePoint(x, by - 7)];
            [tri lineToPoint:NSMakePoint(x - 4, by)];
            [tri lineToPoint:NSMakePoint(x + 4, by)];
            [tri closePath];
            [NSColor.systemRedColor setFill];
            [tri fill];
        }
    }
    if (!anyRate)
        RGDrawText(@"Touch a Magic Mouse or trackpad to see how often it reports", NSMakeRect(x0, NSMidY(rate) - 8, x1 - x0, 16),
                   [NSFont systemFontOfSize:12], NSColor.tertiaryLabelColor, NSTextAlignmentCenter);

    // 3. Bluetooth signal
    laneHeader(sig, @"Bluetooth signal", @"dBm · higher is stronger");
    NSString *btOff = m.bluetoothStatus ? m.bluetoothStatus() : nil;
    BOOL anySignal = NO;
    for (RGSeries *s in m.signals.allValues) if (s->count && [s latest].t >= since) anySignal = YES;
    if (btOff && !anySignal) {
        RGDrawText(btOff, NSMakeRect(x0, NSMidY(sig) - 8, x1 - x0, 16), [NSFont systemFontOfSize:12], NSColor.tertiaryLabelColor, NSTextAlignmentCenter);
    } else {
        double lo = -100, hi = -30;
        CGFloat (^yDb)(double) = ^CGFloat(double db) { return NSMaxY(sig) - (MAX(lo, MIN(hi, db)) - lo) / (hi - lo) * sig.size.height; };
        [[NSColor.systemRedColor colorWithAlphaComponent:0.05] setFill];
        NSRectFillUsingOperation(NSMakeRect(x0, yDb(-80), x1 - x0, NSMaxY(sig) - yDb(-80)), NSCompositingOperationSourceOver);
        [[NSColor.systemOrangeColor colorWithAlphaComponent:0.025] setFill];
        NSRectFillUsingOperation(NSMakeRect(x0, yDb(-70), x1 - x0, yDb(-80) - yDb(-70)), NSCompositingOperationSourceOver);
        axis(sig, lo, hi, @[@-90, @-70, @-50], @"%.0f");
        RGDrawText(@"Poor", NSMakeRect(x1 - 64, yDb(-80) + 3, 60, 12), [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium],
                   [NSColor.systemRedColor colorWithAlphaComponent:0.7], NSTextAlignmentRight);
        for (RGSeries *s in m.signals.allValues) {
            NSBezierPath *path = [NSBezierPath bezierPath];
            double prevT = -1;
            for (int i = 0; i < s->count; i++) {
                RGPoint p = [s at:i];
                if (p.t < since - 3) { prevT = -1; continue; }
                NSPoint pt = NSMakePoint(MAX(x0, xFor(p.t)), yDb(p.v));
                if (prevT < 0 || p.t - prevT > 6) [path moveToPoint:pt];
                else [path lineToPoint:pt];
                prevT = p.t;
            }
            path.lineWidth = 2;
            path.lineJoinStyle = NSLineJoinStyleRound;
            [s.colour setStroke];
            [path stroke];
        }
        if (!anySignal)
            RGDrawText(@"No connected Bluetooth device is reporting signal strength", NSMakeRect(x0, NSMidY(sig) - 8, x1 - x0, 16),
                       [NSFont systemFontOfSize:12], NSColor.tertiaryLabelColor, NSTextAlignmentCenter);
    }

    // Connects and disconnects, marked across every lane; labels step up when they would overlap
    CGFloat labelEnd = -1, labelY = NSMaxY(sig) - 14;
    for (NSDictionary *l in m.links) {
        double t = [l[@"t"] doubleValue];
        if (t < since) continue;
        CGFloat x = round(xFor(t)) + 0.5;
        BOOL up = [l[@"connected"] boolValue];
        NSBezierPath *line = [NSBezierPath bezierPath];
        [line moveToPoint:NSMakePoint(x, lat.origin.y)];
        [line lineToPoint:NSMakePoint(x, NSMaxY(sig))];
        CGFloat dash[] = {2, 3};
        [line setLineDash:dash count:2 phase:0];
        [(up ? NSColor.systemGreenColor : NSColor.secondaryLabelColor) setStroke];
        [line stroke];
        NSString *label = [NSString stringWithFormat:@"%@ %@", l[@"name"], up ? @"connected" : @"disconnected"];
        NSFont *lf = [NSFont systemFontOfSize:9.5 weight:NSFontWeightMedium];
        CGFloat w = [label sizeWithAttributes:@{NSFontAttributeName: lf}].width + 4;
        labelY = (x + 4 < labelEnd) ? labelY - 13 : NSMaxY(sig) - 14;
        BOOL flip = x + 4 + w > x1;   // near "now": put the label on the left of the line
        NSRect lr = NSMakeRect(flip ? x - 4 - w : x + 4, labelY, w, 12);
        [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.7] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSInsetRect(lr, -2, 0) xRadius:3 yRadius:3] fill];
        RGDrawText(label, lr, lf, up ? NSColor.systemGreenColor : NSColor.secondaryLabelColor, flip ? NSTextAlignmentRight : NSTextAlignmentLeft);
        labelEnd = NSMaxX(lr) + 4;
    }

    // Time axis and legend
    CGFloat ty = NSMaxY(sig) + 5;
    RGDrawText(@"−2 min", NSMakeRect(x0, ty, 60, 13), small, NSColor.tertiaryLabelColor, NSTextAlignmentLeft);
    RGDrawText(@"−1 min", NSMakeRect((x0 + x1) / 2 - 30, ty, 60, 13), small, NSColor.tertiaryLabelColor, NSTextAlignmentCenter);
    RGDrawText(@"now", NSMakeRect(x1 - 60, ty, 60, 13), small, NSColor.tertiaryLabelColor, NSTextAlignmentRight);

    NSMutableArray *legend = [NSMutableArray arrayWithArray:@[@[NSColor.systemBlueColor, @"Left click", @0], @[NSColor.systemOrangeColor, @"Right click", @0],
                                                             @[NSColor.systemRedColor, @"Dropped click", @1]]];
    NSMutableSet *named = [NSMutableSet set];
    for (NSDictionary<NSString *, RGSeries *> *group in @[m.rates, m.signals])
        for (RGSeries *s in [group.allValues sortedArrayUsingComparator:^NSComparisonResult(RGSeries *a, RGSeries *b) { return [a.name compare:b.name]; }])
            if (s.name && ![named containsObject:s.name]) { [named addObject:s.name]; [legend addObject:@[s.colour, s.name, @2]]; }
    CGFloat lx = card.origin.x + 16, ly = NSMaxY(card) - 26;
    NSFont *lf = [NSFont systemFontOfSize:10.5];
    for (NSArray *item in legend) {
        NSColor *c = item[0];
        int style = [item[2] intValue];
        if (style == 0) { [c setFill]; [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(lx, ly + 3, 8, 8)] fill]; }
        else if (style == 1) RGDrawText(@"✕", NSMakeRect(lx - 1, ly - 1, 12, 14), [NSFont systemFontOfSize:10 weight:NSFontWeightBold], c, NSTextAlignmentLeft);
        else { [c setFill]; [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(lx, ly + 5, 12, 4) xRadius:2 yRadius:2] fill]; }
        CGFloat w = [item[1] sizeWithAttributes:@{NSFontAttributeName: lf}].width;
        RGDrawText(item[1], NSMakeRect(lx + 16, ly, w + 4, 14), lf, NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        lx += 16 + w + 16;
    }

    [self drawTiles:NSMakeRect(20, NSMaxY(card) + 16, self.bounds.size.width - 40, 104) now:now];
}

- (void)drawTiles:(NSRect)r now:(double)now {
    RGLatencyMonitor *m = self.m;
    NSArray<NSNumber *> *lat = [[m recentLatencies] sortedArrayUsingSelector:@selector(compare:)];
    NSString *latV = @"–", *latS = @"No clicks measured yet";
    if (lat.count) {
        double med = [lat[lat.count / 2] doubleValue], p95 = [lat[MIN(lat.count - 1, (NSUInteger)(lat.count * 0.95))] doubleValue];
        latV = [NSString stringWithFormat:@"%.1f ms", med];
        latS = [NSString stringWithFormat:@"Median · 95%% under %.1f ms · worst %.1f ms", p95, [lat.lastObject doubleValue]];
    }
    NSString *dropV = [NSString stringWithFormat:@"%ld", m->totalDrops];
    NSString *dropS = m->totalDrops ? [NSString stringWithFormat:@"Of %ld clicks · last at %@", m->totalClicks,
                                        [NSDateFormatter localizedStringFromDate:[NSDate dateWithTimeIntervalSinceReferenceDate:m->lastDropTime]
                                                                       dateStyle:NSDateFormatterNoStyle timeStyle:NSDateFormatterMediumStyle]]
                                    : [NSString stringWithFormat:@"Of %ld clicks", m->totalClicks];
    RGSeries *rs = [m activeRate];
    NSString *rateV = @"–", *rateS = @"Touch a device to measure";
    if (rs && rs->count) {
        RGPoint p = [rs latest];
        rateV = [NSString stringWithFormat:@"%.0f Hz", p.v];
        int st = [rs stallsSince:now - SPAN];
        rateS = [NSString stringWithFormat:@"%@ · jitter ±%.1f ms · %d stall%@", rs.name, p.jitter, st, st == 1 ? @"" : @"s"];
    }
    RGSeries *ss = [m activeSignal];
    NSString *btOff = m.bluetoothStatus ? m.bluetoothStatus() : nil;
    NSString *sigV = @"Off", *sigS = btOff ?: @"Waiting for a reading";
    NSColor *sigC = NSColor.labelColor;
    if (ss && ss->count && now - [ss latest].t < 10) {
        int v = (int)lroundf([ss latest].v);
        sigV = [NSString stringWithFormat:@"%d dBm", v];
        NSString *q = [RGBluetoothMonitor qualityFor:v];
        sigS = [NSString stringWithFormat:@"%@ · %@", ss.name, q];
        sigC = v < -80 ? NSColor.systemRedColor : v < -70 ? NSColor.systemOrangeColor : NSColor.labelColor;
    } else if (!btOff) {
        sigV = @"–";
    }
    NSArray *tiles = @[@[@"CLICK LATENCY", latV, latS, NSColor.labelColor],
                       @[@"DROPPED CLICKS", dropV, dropS, m->totalDrops ? NSColor.systemRedColor : NSColor.labelColor],
                       @[@"TOUCH REPORT RATE", rateV, rateS, NSColor.labelColor],
                       @[@"BLUETOOTH SIGNAL", sigV, sigS, sigC]];
    CGFloat w = (r.size.width - 3 * 12) / 4;
    for (NSUInteger i = 0; i < tiles.count; i++) {
        NSRect t = NSMakeRect(r.origin.x + i * (w + 12), r.origin.y, w, r.size.height);
        RGDrawCard(t, 16);
        RGDrawText(tiles[i][0], NSMakeRect(t.origin.x + 14, t.origin.y + 14, w - 28, 14),
                   [NSFont systemFontOfSize:10 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        RGDrawText(tiles[i][1], NSMakeRect(t.origin.x + 14, t.origin.y + 32, w - 28, 30),
                   [NSFont monospacedDigitSystemFontOfSize:22 weight:NSFontWeightSemibold], tiles[i][3], NSTextAlignmentLeft);
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        [(NSString *)tiles[i][2] drawWithRect:NSMakeRect(t.origin.x + 14, t.origin.y + 66, w - 28, 32)
                                      options:NSStringDrawingUsesLineFragmentOrigin | NSStringDrawingTruncatesLastVisibleLine
                                   attributes:@{NSFontAttributeName: [NSFont systemFontOfSize:11], NSParagraphStyleAttributeName: ps,
                                                NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    }
}

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Latency graphs"; }
- (NSString *)accessibilityValue { return self.m.summary; }
@end

#pragma mark - Monitor

static NSString *const kSettingsItem = @"settings", *const kPauseItem = @"pause", *const kClearItem = @"clear";

@implementation RGLatencyMonitor

- (instancetype)init {
    if ((self = [super init])) {
        _rates = [NSMutableDictionary dictionary];
        _signals = [NSMutableDictionary dictionary];
        _links = [NSMutableArray array];
    }
    return self;
}

- (double)now {
    if (frozen > 0) return frozen;
    return paused ? pausedAt : CFAbsoluteTimeGetCurrent();
}

- (RGClick)clickAt:(int)i { return clicks[(clickHead - clickCount + i + MAX_CLICKS) % MAX_CLICKS]; }

- (void)addClick:(RGClick)c {
    clicks[clickHead] = c;
    clickHead = (clickHead + 1) % MAX_CLICKS;
    if (clickCount < MAX_CLICKS) clickCount++;
}

- (NSArray<NSNumber *> *)recentLatencies {
    NSMutableArray *a = [NSMutableArray array];
    for (int i = clickCount - 1; i >= 0 && a.count < STAT_CLICKS; i--) {
        RGClick c = [self clickAt:i];
        if (!c.dropped) [a addObject:@(c.ms)];
    }
    return a;
}

- (RGSeries *)mostRecent:(NSDictionary<NSString *, RGSeries *> *)group {
    RGSeries *best = nil;
    for (RGSeries *s in group.allValues) if (s->count && (!best || s->lastActive > best->lastActive)) best = s;
    return best;
}
- (RGSeries *)activeRate { return [self mostRecent:self.rates]; }
- (RGSeries *)activeSignal { return [self mostRecent:self.signals]; }

- (RGSeries *)series:(NSMutableDictionary *)group key:(NSString *)key name:(NSString *)name colour:(NSColor *)colour {
    RGSeries *s = group[key];
    if (!s) { s = [RGSeries new]; group[key] = s; }
    s.name = name;
    if (colour) s.colour = colour;
    if (!s.colour) s.colour = NSColor.systemTealColor;
    return s;
}

#pragma mark Recording

- (void)start {
    if (self.sampler) return;
    self.sampler = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(sample) userInfo:nil repeats:YES];
    self.sampler.tolerance = 0.03;
    [NSRunLoop.mainRunLoop addTimer:self.sampler forMode:NSRunLoopCommonModes];
}

// Turns the running frame totals into a report rate and jitter for each quarter second of touching.
- (void)sample {
    double t = CFAbsoluteTimeGetCurrent();
    for (NSDictionary *d in (self.devices ? self.devices() : @[])) {
        NSString *key = d[@"key"];
        if (!key) continue;
        RGSeries *s = [self series:self.rates key:key name:d[@"name"] colour:colourForKind(d)];
        RGFrameStats now;
        RGGetFrameStats([d[@"slot"] intValue], &now);
        if (!s->haveLast || now.frames < s->last.frames || now.intervals < s->last.intervals) {
            s->last = now;
            s->haveLast = YES;
            continue;
        }
        long di = now.intervals - s->last.intervals, ds = now.stalls - s->last.stalls;
        if (di >= 3) {
            double sum = now.sum - s->last.sum, sq = now.sumSq - s->last.sumSq, mean = sum / di;
            if (mean > 0) [s add:t value:(float)(1 / mean) jitter:(float)(sqrt(MAX(0, sq / di - mean * mean)) * 1000)];
        }
        for (long k = 0; k < MIN(ds, 16); k++) [s addStall:t];
        s->totalStalls += ds;
        s->lost += now.lost - s->last.lost;
        s->last = now;
    }
}

- (void)recordClick:(int)button latency:(double)ms device:(NSString *)name {
    if (ms < 0 || ms > 5000) return;
    totalClicks++;
    [self addClick:(RGClick){CFAbsoluteTimeGetCurrent(), (float)ms, (unsigned char)button, NO}];
    self.badgeLabel.stringValue = [NSString stringWithFormat:@"Last click %.1f ms", ms];
    self.badgeLabel.textColor = clickColour(button);
}

- (void)recordDrop:(int)button device:(NSString *)name {
    totalClicks++;
    totalDrops++;
    lastDropTime = CFAbsoluteTimeGetCurrent();
    [self addClick:(RGClick){lastDropTime, 0, (unsigned char)button, YES}];
    self.badgeLabel.stringValue = @"Click dropped";
    self.badgeLabel.textColor = NSColor.systemRedColor;
}

- (void)recordSignal:(int)rssi device:(NSString *)key name:(NSString *)name {
    NSColor *c = self.rates[key].colour;
    [[self series:self.signals key:key name:name colour:c] add:CFAbsoluteTimeGetCurrent() value:rssi jitter:0];
}

- (void)recordLink:(BOOL)connected device:(NSString *)name {
    [self.links addObject:@{@"t": @(CFAbsoluteTimeGetCurrent()), @"name": name ?: @"Device", @"connected": @(connected)}];
    if (self.links.count > 100) [self.links removeObjectAtIndex:0];
}

- (NSString *)summary {
    NSMutableArray *out = [NSMutableArray array];
    NSArray<NSNumber *> *lat = [[self recentLatencies] sortedArrayUsingSelector:@selector(compare:)];
    if (lat.count)
        [out addObject:[NSString stringWithFormat:@"Click latency: median %.1f ms, 95th percentile %.1f ms, worst %.1f ms (last %lu clicks).",
                        [lat[lat.count / 2] doubleValue], [lat[MIN(lat.count - 1, (NSUInteger)(lat.count * 0.95))] doubleValue],
                        [lat.lastObject doubleValue], (unsigned long)lat.count]];
    else
        [out addObject:@"Click latency: no clicks measured yet."];
    [out addObject:[NSString stringWithFormat:@"Dropped clicks: %ld of %ld.", totalDrops, totalClicks]];
    for (RGSeries *s in self.rates.allValues) {
        if (!s->count) continue;
        RGPoint p = [s latest];
        [out addObject:[NSString stringWithFormat:@"Touch report rate, %@: %.0f Hz, jitter ±%.1f ms, %ld stalls, %ld lost contacts.",
                        s.name, p.v, p.jitter, s->totalStalls, s->lost]];
    }
    NSString *btOff = self.bluetoothStatus ? self.bluetoothStatus() : nil;
    BOOL anySignal = NO;
    for (RGSeries *s in self.signals.allValues) {
        if (!s->count) continue;
        int v = (int)lroundf([s latest].v);
        [out addObject:[NSString stringWithFormat:@"Bluetooth signal, %@: %d dBm (%@).", s.name, v, [RGBluetoothMonitor qualityFor:v]]];
        anySignal = YES;
    }
    if (!anySignal) [out addObject:[NSString stringWithFormat:@"Bluetooth signal: %@", btOff ?: @"no readings."]];
    return [out componentsJoinedByString:@"\n"];
}

#pragma mark Window

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1040, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Latency Monitor";
    self.window.subtitle = @"Click latency, touch report rate and Bluetooth signal over the last 2 minutes";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentMinSize = NSMakeSize(900, 640);
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"LatencyMonitorToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    self.view = [[RGLatencyView alloc] initWithFrame:NSMakeRect(0, 0, 1040, 760)];
    self.view.m = self;
    self.window.contentView = self.view;
    [self buildBadge];
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymLatencyMonitor"];
}

// The latest measurement on Liquid Glass, floating in the bottom-right corner of the graph card.
- (void)buildBadge {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 210, 34)];
    NSImageView *icon = [NSImageView imageViewWithImage:RGSymbol(@"stopwatch", @"Latency") ?: [NSImage new]];
    icon.frame = NSMakeRect(12, 8, 18, 18);
    icon.contentTintColor = NSColor.secondaryLabelColor;
    self.badgeLabel = RGLabel(@"Waiting for a click", [NSFont monospacedDigitSystemFontOfSize:12.5 weight:NSFontWeightSemibold],
                              NSColor.secondaryLabelColor);
    self.badgeLabel.frame = NSMakeRect(36, 8, 168, 18);
    [content addSubview:icon];
    [content addSubview:self.badgeLabel];
    self.badge = RGGlassView(content, 17);
    [self.view addSubview:self.badge];
}

- (void)layoutBadge {
    NSRect card = self.view.cardRect;
    self.badge.frame = NSMakeRect(NSMaxX(card) - 210 - 14, NSMaxY(card) - 34 - 10, 210, 34);
}

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
        item.toolTip = @"Freeze the graphs (recording continues)";
        item.action = @selector(togglePause:);
    } else if ([ident isEqualToString:kClearItem]) {
        item.label = @"Clear";
        item.image = RGSymbol(@"trash", @"Clear");
        item.toolTip = @"Clear the graphs and the counts";
        item.action = @selector(clear:);
    } else {
        item.label = @"Settings";
        item.image = RGSymbol(@"gearshape", @"Settings");
        item.toolTip = @"Open Settings, where Bluetooth signal monitoring is turned on";
        item.action = @selector(openSettings:);
    }
    return item;
}

- (void)togglePause:(id)sender {
    paused = !paused;
    pausedAt = CFAbsoluteTimeGetCurrent();
    for (NSToolbarItem *i in self.window.toolbar.items)
        if ([i.itemIdentifier isEqualToString:kPauseItem]) {
            i.image = RGSymbol(paused ? @"play.fill" : @"pause.fill", paused ? @"Resume" : @"Pause");
            i.label = paused ? @"Resume" : @"Pause";
        }
    self.view.needsDisplay = YES;
}

- (void)clear:(id)sender {
    clickCount = clickHead = 0;
    totalClicks = totalDrops = 0;
    lastDropTime = 0;
    for (RGSeries *s in self.rates.allValues) { s->count = s->head = s->stallCount = s->stallHead = 0; s->totalStalls = s->lost = 0; }
    [self.signals removeAllObjects];
    [self.links removeAllObjects];
    self.badgeLabel.stringValue = @"Waiting for a click";
    self.badgeLabel.textColor = NSColor.secondaryLabelColor;
    self.view.needsDisplay = YES;
}

- (void)openSettings:(id)sender { if (self.openSettings) self.openSettings(); }

- (void)show {
    if (!self.window) [self buildWindow];
    [self.window makeKeyAndOrderFront:nil];
    [self layoutBadge];
    if (!self.redraw) {
        self.redraw = [NSTimer timerWithTimeInterval:1.0 / 15 target:self selector:@selector(redrawTick) userInfo:nil repeats:YES];
        self.redraw.tolerance = 0.01;
        [NSRunLoop.mainRunLoop addTimer:self.redraw forMode:NSRunLoopCommonModes];
    }
}

- (void)redrawTick { if (!paused) self.view.needsDisplay = YES; }
- (void)windowDidResize:(NSNotification *)n { [self layoutBadge]; }
- (void)windowWillClose:(NSNotification *)n { [self.redraw invalidate]; self.redraw = nil; }

#pragma mark Demo

- (void)loadDemo {
    frozen = CFAbsoluteTimeGetCurrent();
    double t0 = frozen - SPAN;
    srand48(7);
    NSDictionary *mouse = @{@"kind": @"mouse", @"name": @"Magic Mouse"}, *pad = @{@"kind": @"trackpad", @"name": @"Magic Trackpad"};
    RGSeries *mr = [self series:self.rates key:@"mouse" name:@"Magic Mouse" colour:colourForKind(mouse)];
    RGSeries *tr = [self series:self.rates key:@"pad" name:@"Magic Trackpad" colour:colourForKind(pad)];
    // Clicks: a few milliseconds normally; slower and less even while the Mac is busy, with one dropped
    for (double t = t0 + 2; t < frozen - 1; t += 1.3 + drand48() * 1.6) {
        BOOL busy = t > frozen - 75 && t < frozen - 48;
        double ms = busy ? 14 + drand48() * 38 : 3.2 + drand48() * 3.5 + (drand48() < 0.06 ? 6 : 0);
        int b = drand48() < 0.3 ? 2 : 1;
        if (busy && fabs(t - (frozen - 61)) < 0.9) {
            [self addClick:(RGClick){t, 0, 2, YES}];
            totalDrops++;
            lastDropTime = t;
        } else {
            [self addClick:(RGClick){t, (float)ms, (unsigned char)b, NO}];
        }
        totalClicks++;
    }
    // Touch report rate in bursts of use: steady at 90 Hz, ragged with stalls while the Mac is busy
    for (double t = t0; t < frozen; t += 0.25) {
        double phase = fmod(t - t0, 30);
        BOOL busy = t > frozen - 75 && t < frozen - 48;
        if (phase < 11) [mr add:t value:(float)(busy ? 62 + drand48() * 24 : 89.2 + drand48() * 1.6) jitter:(float)(busy ? 3.5 + drand48() * 4 : 0.6 + drand48() * 0.4)];
        else if (phase > 15 && phase < 24) [tr add:t value:(float)(busy ? 70 + drand48() * 18 : 89.5 + drand48() * 1.2) jitter:(float)(busy ? 2.5 + drand48() * 3 : 0.5 + drand48() * 0.3)];
        if (busy && phase < 11 && drand48() < 0.08) { [mr addStall:t]; mr->totalStalls++; }
    }
    mr->lastActive = frozen - 1;
    // Bluetooth signal for the mouse, with a short disconnect
    RGSeries *ms = [self series:self.signals key:@"mouse" name:@"Magic Mouse" colour:mr.colour];
    for (double t = t0; t < frozen; t += 2) {
        if (t > frozen - 36 && t < frozen - 31) continue;
        double base = (t > frozen - 44 && t < frozen - 36) ? -76 : -54;
        [ms add:t value:(float)(base + drand48() * 5 - 2.5) jitter:0];
    }
    [self.links addObject:@{@"t": @(frozen - 36), @"name": @"Magic Mouse", @"connected": @NO}];
    [self.links addObject:@{@"t": @(frozen - 31), @"name": @"Magic Mouse", @"connected": @YES}];
}

- (void)showDemo {
    self.bluetoothStatus = ^NSString * { return nil; };
    [self show];
    [self loadDemo];
    self.badgeLabel.stringValue = @"Last click 4.8 ms";
    self.badgeLabel.textColor = NSColor.systemBlueColor;
    self.view.needsDisplay = YES;
}

- (BOOL)writeDemoSnapshotTo:(NSString *)path {
    [self showDemo];
    [self.window orderOut:nil];
    NSView *v = self.view;
    NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
    [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}
@end
