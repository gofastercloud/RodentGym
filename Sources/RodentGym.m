// RodentGym — see what your Magic Mouse and Magic Trackpad send, and what macOS delivers.
//
// For each multitouch device RodentGym shows the live finger contacts (private
// MultitouchSupport framework), the raw HID button reports (IOHIDManager) and the settings the
// driver is actually applying (read from the device's IORegistry entry). Separately it watches
// the click events macOS delivers to the login session (listen-only CGEventTap).
//
// A button press the hardware reports that never arrives as a click event is flagged as
// DROPPED and written, with memory state, to ~/Library/Logs/RodentGym.log.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDManager.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <ApplicationServices/ApplicationServices.h>
#import <os/lock.h>
#include <sys/sysctl.h>

#define APP_NAME    @"RodentGym"
#define APP_VERSION @"1.0"
#define LOG_PATH    [@"~/Library/Logs/RodentGym.log" stringByExpandingTildeInPath]

#pragma mark - MultitouchSupport (private framework)

typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame; double timestamp; int identifier, state, fingerID, handID;
    MTReadout normalized; float size; int zero1;
    float angle, majorAxis, minorAxis;
    MTReadout mm; int zero2[2]; float unk2;
} MTFinger;
typedef void *MTDeviceRef;
typedef int (*MTContactCallback)(MTDeviceRef, MTFinger *, int, double, int);
extern CFMutableArrayRef MTDeviceCreateList(void);
extern void MTRegisterContactFrameCallback(MTDeviceRef, MTContactCallback);
extern void MTUnregisterContactFrameCallback(MTDeviceRef, MTContactCallback);
extern void MTDeviceStart(MTDeviceRef, int);
extern void MTDeviceStop(MTDeviceRef);
extern int MTDeviceGetFamilyID(MTDeviceRef, int *);
extern bool MTDeviceIsBuiltIn(MTDeviceRef);
extern io_service_t MTDeviceGetService(MTDeviceRef);
extern int MTDeviceGetSensorSurfaceDimensions(MTDeviceRef, int *, int *);

#define MAX_TOUCHES 16
#define MAX_DEVICES 8

// Touch frames arrive on a MultitouchSupport thread; they are copied into fixed slots under a lock.
typedef struct { MTDeviceRef mt; int count; MTFinger touches[MAX_TOUCHES]; } RGSlot;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static RGSlot gSlots[MAX_DEVICES];
static int gSlotCount;

static int contactCallback(MTDeviceRef dev, MTFinger *f, int n, double ts, int frame) {
    if (n < 0) n = 0;
    if (n > MAX_TOUCHES) n = MAX_TOUCHES;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gSlotCount; i++) {
        if (gSlots[i].mt != dev) continue;
        if (n) memcpy(gSlots[i].touches, f, sizeof(MTFinger) * (size_t)n);
        gSlots[i].count = n;
        break;
    }
    os_unfair_lock_unlock(&gLock);
    return 0;
}

static int copyTouches(int slot, MTFinger *out) {
    os_unfair_lock_lock(&gLock);
    int n = (slot >= 0 && slot < gSlotCount) ? gSlots[slot].count : 0;
    if (n) memcpy(out, gSlots[slot].touches, sizeof(MTFinger) * (size_t)n);
    os_unfair_lock_unlock(&gLock);
    return n;
}

#pragma mark - Settings keys and small helpers

static NSString *const kKeepOnTop = @"KeepOnTop";
static NSString *const kShowBuiltIn = @"ShowBuiltInTrackpad";
static NSString *const kDropSound = @"PlaySoundOnDrop";
static NSString *const kLogAll = @"LogEveryClick";
static NSString *const kMatchMs = @"MatchWindowMs";
static NSString *const kFinishes = @"ColourFinishes";   // { "<ColorID>": "white" | "black" }

static NSString *const kButtonName[4] = {@"", @"Left", @"Right", @"Middle"};
static int otherButton(int b) { return b == 1 ? 2 : (b == 2 ? 1 : 0); }

static NSColor *gray(CGFloat w) { return [NSColor colorWithWhite:w alpha:1]; }
static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
#define ORANGE rgb(1.0, 0.55, 0.15)
#define GREEN  rgb(0.20, 0.68, 0.36)
#define RED    rgb(1.0, 0.38, 0.32)
#define AMBER  rgb(1.0, 0.72, 0.28)
#define BLUE   rgb(0.25, 0.55, 1.0)

static int intOf(id v, int def) { return [v respondsToSelector:@selector(intValue)] ? [v intValue] : def; }

static id regProp(io_registry_entry_t e, NSString *key, BOOL searchParents) {
    if (!e) return nil;
    CFTypeRef v = searchParents
        ? IORegistryEntrySearchCFProperty(e, kIOServicePlane, (__bridge CFStringRef)key, kCFAllocatorDefault,
                                          kIORegistryIterateRecursively | kIORegistryIterateParents)
        : IORegistryEntryCreateCFProperty(e, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    return CFBridgingRelease(v);
}

static id globalPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, kCFPreferencesAnyApplication));
}

// Accessory firmware is reported as BCD-style hex: 0x311 -> "3.1.1".
static NSString *firmwareString(int v) {
    if (v <= 0) return nil;
    NSString *hex = [NSString stringWithFormat:@"%x", v];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < hex.length; i++) [parts addObject:[hex substringWithRange:NSMakeRange(i, 1)]];
    return [parts componentsJoinedByString:@"."];
}

// Finds every registry entry carrying `key` (e.g. BatteryPercent, ColorID) and indexes the value
// by the owning device's serial number and product name.
static NSDictionary<NSString *, NSNumber *> *registryValuesWithKey(NSString *key) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSDictionary *match = @{@"IOPropertyExistsMatch": key};
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)match, &it) != KERN_SUCCESS) return out;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        NSNumber *v = regProp(s, key, NO);
        NSString *serial = regProp(s, @"SerialNumber", YES), *product = regProp(s, @"Product", YES);
        if ([v isKindOfClass:NSNumber.class]) {
            if ([serial isKindOfClass:NSString.class]) out[[@"serial:" stringByAppendingString:serial]] = v;
            if ([product isKindOfClass:NSString.class]) out[[@"product:" stringByAppendingString:product]] = v;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return out;
}

#pragma mark - Device model

typedef NS_ENUM(NSInteger, RGKind) { RGKindMouse, RGKindTrackpad, RGKindBuiltIn };
// How a surface is drawn: a light or dark top, and the colour of the aluminium edge.
typedef struct { BOOL darkTop; CGFloat rimR, rimG, rimB; } RGStyle;
static const RGStyle kLightStyle = {NO, 0.86, 0.86, 0.87};
static const RGStyle kDarkStyle = {YES, 0.42, 0.43, 0.45};

// Apple accessory colour codes, as reported in the IORegistry `ColorID` property. The same table
// is used in Continuity proximity-pairing adverts (see furiousMAC/continuity, airpods_color_vals),
// and macOS's CoreUtils carries the same ordered names. Verified: Magic Mouse 2 white = 0,
// Magic Trackpad 2 space grey = 5.
typedef struct { int code; __unsafe_unretained NSString *name; RGStyle style; } RGColour;
static const RGColour kColours[] = {
    {0,  @"White",      {NO,  0.86, 0.86, 0.87}},
    {1,  @"Black",      {YES, 0.80, 0.80, 0.82}},   // black surface on silver aluminium
    {2,  @"Red",        {NO,  0.78, 0.24, 0.26}},
    {3,  @"Blue",       {NO,  0.30, 0.46, 0.78}},
    {4,  @"Pink",       {NO,  0.93, 0.64, 0.68}},
    {5,  @"Grey / space grey", {YES, 0.42, 0.43, 0.45}},   // 2017 space grey Magic Trackpad 2 reports 5
    {6,  @"Silver",     {NO,  0.86, 0.86, 0.87}},
    {7,  @"Gold",       {NO,  0.89, 0.79, 0.62}},
    {8,  @"Rose Gold",  {NO,  0.91, 0.73, 0.69}},
    {9,  @"Space Grey", {YES, 0.42, 0.43, 0.45}},
    {10, @"Dark Blue",  {YES, 0.18, 0.25, 0.42}},
    {11, @"Light Blue", {NO,  0.64, 0.79, 0.91}},
    {12, @"Yellow",     {NO,  0.95, 0.83, 0.42}},
};

static const RGColour *colourForCode(int code) {
    for (size_t i = 0; i < sizeof kColours / sizeof kColours[0]; i++) if (kColours[i].code == code) return &kColours[i];
    return NULL;
}

static NSColor *blend(NSColor *c, NSColor *with, CGFloat amount) {
    return [[c colorUsingColorSpace:NSColorSpace.sRGBColorSpace] blendedColorWithFraction:amount ofColor:with] ?: c;
}

static NSString *modelName(int productID, RGKind kind) {
    if (kind == RGKindBuiltIn) return @"Built-in trackpad";
    switch (productID) {
        case 0x030d: return @"Magic Mouse (1st generation)";
        case 0x030e: return @"Magic Trackpad (1st generation)";
        case 0x0269: return @"Magic Mouse 2 (Lightning)";
        case 0x0265: return @"Magic Trackpad 2 (Lightning)";
    }
    return [NSString stringWithFormat:@"%@ (product 0x%04x)", kind == RGKindMouse ? @"Magic Mouse" : @"Magic Trackpad", productID];
}

@interface RGDevice : NSObject {
@public
    MTDeviceRef mt;
    io_service_t service;
    int slot, family, vendorID, productID, battery, colorID;
    RGKind kind;
    double widthMM, heightMM;
    BOOL hidDown[4];
    long sent[4], dropped[4], remapped;
}
@property (copy) NSString *name, *model, *firmware, *identifier, *transport;
@property (copy) NSDictionary *prefs;   // MultitouchPreferences the driver is applying
@end

@implementation RGDevice

// Mouse: 0 off, 1 right side, 2 left side.  Trackpad: 0 off, 1 two-finger, 2 bottom-right, 3 bottom-left.
- (int)secondaryZone {
    if (kind == RGKindMouse) {
        NSString *m = self.prefs[@"MouseButtonMode"];
        if ([m isEqual:@"TwoButton"]) return 1;
        if ([m isEqual:@"TwoButtonSwapped"]) return 2;
        return 0;
    }
    int corner = intOf(self.prefs[@"TrackpadCornerSecondaryClick"], 0);
    if (corner == 2) return 2;
    if (corner == 1) return 3;
    return intOf(self.prefs[@"TrackpadRightClick"], 1) ? 1 : 0;
}

- (float)division { return intOf(self.prefs[@"MouseButtonDivision"], 55) / 100.0f; }

- (NSString *)secondaryDescription {
    int z = self.secondaryZone;
    if (kind == RGKindMouse)
        return z == 1 ? @"Right side (right-handed)" : z == 2 ? @"Left side (left-handed)" : @"Off — whole surface clicks left";
    return z == 1 ? @"Click or tap with two fingers" : z == 2 ? @"Bottom-right corner" : z == 3 ? @"Bottom-left corner" : @"Off";
}

- (NSArray<NSString *> *)settingsLines {
    NSMutableArray *a = [NSMutableArray arrayWithObject:[@"Secondary click: " stringByAppendingString:self.secondaryDescription]];
    id dir = globalPref(@"com.apple.swipescrolldirection");
    NSString *scroll = (dir == nil || [dir boolValue]) ? @"natural" : @"standard";
    if (kind == RGKindMouse) {
        NSString *split = self.secondaryZone ? [NSString stringWithFormat:@"Split at %d%%", (int)lroundf(self.division * 100)] : @"No split";
        [a addObject:[NSString stringWithFormat:@"%@ · Smart zoom %@", split,
                      intOf(self.prefs[@"MouseOneFingerDoubleTapGesture"], 0) ? @"on" : @"off"]];
        [a addObject:[NSString stringWithFormat:@"Scrolling %@ · tracking speed %.1f", scroll,
                      [globalPref(@"com.apple.mouse.scaling") doubleValue]]];
    } else {
        static NSString *const pressure[] = {@"light", @"medium", @"firm"};
        int p = MAX(0, MIN(2, intOf(self.prefs[@"FirstClickThreshold"], 1)));
        [a addObject:[NSString stringWithFormat:@"Tap to click %@ · pressure %@ · Force Click %@",
                      intOf(self.prefs[@"Clicking"], 0) ? @"on" : @"off", pressure[p],
                      [globalPref(@"com.apple.trackpad.forceClick") boolValue] ? @"on" : @"off"]];
        [a addObject:[NSString stringWithFormat:@"Scrolling %@ · tracking speed %.1f", scroll,
                      [globalPref(@"com.apple.trackpad.scaling") doubleValue]]];
    }
    return a;
}

- (NSString *)key { return self.identifier ?: self.name; }
@end

#pragma mark - Drawing helpers

static void text(NSString *s, CGFloat x, CGFloat y, NSFont *f, NSColor *c) {
    [s drawAtPoint:NSMakePoint(x, y) withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c}];
}

static void rtext(NSString *s, CGFloat right, CGFloat y, NSFont *f, NSColor *c) {
    NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c};
    [s drawAtPoint:NSMakePoint(right - [s sizeWithAttributes:a].width, y) withAttributes:a];
}

static void textIn(NSString *s, NSRect r, NSFont *f, NSColor *c) {
    NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    [s drawInRect:r withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSParagraphStyleAttributeName: ps}];
}

static void centred(NSString *s, NSRect r, NSFont *f, NSColor *c) {
    NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c};
    NSSize z = [s sizeWithAttributes:a];
    [s drawAtPoint:NSMakePoint(NSMidX(r) - z.width / 2, NSMidY(r) - z.height / 2) withAttributes:a];
}

// Draws text rotated to read bottom-to-top, centred on `centre`.
static void verticalLabel(NSString *s, NSPoint centre, NSFont *f, NSColor *c) {
    NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c, NSKernAttributeName: @1.2};
    NSSize z = [s sizeWithAttributes:a];
    [NSGraphicsContext saveGraphicsState];
    NSAffineTransform *t = [NSAffineTransform transform];
    [t translateXBy:centre.x yBy:centre.y];
    [t rotateByDegrees:NSGraphicsContext.currentContext.isFlipped ? -90 : 90];
    [t concat];
    [s drawAtPoint:NSMakePoint(-z.width / 2, -z.height / 2) withAttributes:a];
    [NSGraphicsContext restoreGraphicsState];
}

static void lamp(NSRect r, NSString *label, BOOL on) {
    NSBezierPath *p = [NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8];
    [(on ? GREEN : gray(0.2)) setFill];
    [p fill];
    [gray(on ? 0.9 : 0.32) setStroke];
    p.lineWidth = 1;
    [p stroke];
    centred(label, r, [NSFont systemFontOfSize:12.5 weight:NSFontWeightSemibold], on ? NSColor.whiteColor : gray(0.6));
}

static void panel(NSRect r) {
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:r xRadius:12 yRadius:12];
    [gray(0.135) setFill];
    [bg fill];
    [gray(0.22) setStroke];
    bg.lineWidth = 1;
    [bg stroke];
}

#pragma mark - Device surfaces

// Top-down outline: the mouse shell has elliptical ends; the trackpad is a rounded glass slab.
static NSBezierPath *surfacePath(RGKind kind, NSRect r) {
    if (kind == RGKindMouse)
        return [NSBezierPath bezierPathWithRoundedRect:r xRadius:r.size.width * 0.5 yRadius:r.size.height * 0.2];
    CGFloat rad = MIN(r.size.width, r.size.height) * 0.07;
    return [NSBezierPath bezierPathWithRoundedRect:r xRadius:rad yRadius:rad];
}

// Renders a device surface lit from the upper left: shadow, aluminium edge, shell or glass, sheen.
// Works in flipped and unflipped contexts (the window view is flipped, the app icon is not).
static void drawSurface(RGKind kind, NSRect r, RGStyle style) {
    BOOL black = style.darkTop;
    NSColor *rimColour = rgb(style.rimR, style.rimG, style.rimB);
    BOOL flipped = NSGraphicsContext.currentContext.isFlipped;
    CGFloat down = flipped ? 1 : -1;   // sign of "towards the bottom of the screen"
    NSBezierPath *base = surfacePath(kind, NSInsetRect(r, -3, -3));

    [NSGraphicsContext saveGraphicsState];
    NSShadow *shadow = [NSShadow new];
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.6];
    shadow.shadowBlurRadius = MAX(6, r.size.width * 0.08);
    shadow.shadowOffset = NSMakeSize(0, -r.size.width * 0.025);
    [shadow set];
    [rimColour setFill];
    [base fill];
    [NSGraphicsContext restoreGraphicsState];

    // Aluminium edge in the device's colour, lit from above
    NSGradient *rim = [[NSGradient alloc] initWithStartingColor:blend(rimColour, NSColor.whiteColor, 0.45)
                                                    endingColor:blend(rimColour, NSColor.blackColor, 0.4)];
    [rim drawInBezierPath:base angle:90 * down];

    NSBezierPath *top = surfacePath(kind, r);
    NSGradient *body = black
        ? [[NSGradient alloc] initWithColorsAndLocations:gray(0.25), 0.0, gray(0.13), 0.55, gray(0.06), 1.0, nil]
        : [[NSGradient alloc] initWithColorsAndLocations:gray(1.0), 0.0, gray(0.955), 0.55, gray(0.83), 1.0, nil];
    if (kind == RGKindMouse) [body drawInBezierPath:top relativeCenterPosition:NSMakePoint(-0.3, -0.45 * down)];
    else [body drawInBezierPath:top angle:60 * down];

    [NSGraphicsContext saveGraphicsState];
    [top addClip];
    CGFloat sw = r.size.width * (kind == RGKindMouse ? 0.95 : 0.8);
    CGFloat sh = r.size.height * (kind == RGKindMouse ? 0.55 : 0.8);
    CGFloat sy = flipped ? r.origin.y - sh * 0.35 : NSMaxY(r) - sh * 0.65;
    CGFloat peak = black ? 0.09 : 0.6;   // eased falloff so the highlight has no visible edge
    NSGradient *sheen = [[NSGradient alloc] initWithColorsAndLocations:
        [NSColor colorWithWhite:1 alpha:peak], 0.0, [NSColor colorWithWhite:1 alpha:peak * 0.45], 0.4,
        [NSColor colorWithWhite:1 alpha:peak * 0.12], 0.75, [NSColor colorWithWhite:1 alpha:0], 1.0, nil];
    [sheen drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(r.origin.x - sw * 0.2, sy, sw, sh)]
     relativeCenterPosition:NSZeroPoint];
    NSBezierPath *edge = surfacePath(kind, NSInsetRect(r, 0.75, 0.75));
    edge.lineWidth = 1.5;
    [[NSColor colorWithWhite:black ? 1 : 0 alpha:black ? 0.10 : 0.12] setStroke];
    [edge stroke];
    [NSGraphicsContext restoreGraphicsState];
}

#pragma mark - App icon (drawn in code; build.sh renders it to AppIcon.icns)

static NSImage *appIcon(CGFloat size) {
    return [NSImage imageWithSize:NSMakeSize(size, size) flipped:NO drawingHandler:^BOOL(NSRect r) {
        CGFloat s = r.size.width;
        NSRect tile = NSInsetRect(r, s * 0.098, s * 0.098);
        NSBezierPath *sq = [NSBezierPath bezierPathWithRoundedRect:tile xRadius:tile.size.width * 0.225 yRadius:tile.size.width * 0.225];
        [NSGraphicsContext saveGraphicsState];
        NSShadow *sh = [NSShadow new];
        sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
        sh.shadowBlurRadius = s * 0.02;
        sh.shadowOffset = NSMakeSize(0, -s * 0.01);
        [sh set];
        [rgb(0.07, 0.09, 0.14) setFill];
        [sq fill];
        [NSGraphicsContext restoreGraphicsState];
        [[[NSGradient alloc] initWithStartingColor:rgb(0.17, 0.23, 0.36) endingColor:rgb(0.04, 0.06, 0.11)] drawInBezierPath:sq angle:-90];

        NSRect mouse = NSMakeRect(NSMidX(tile) - s * 0.15, NSMidY(tile) - s * 0.27, s * 0.30, s * 0.52);
        NSPoint touch = NSMakePoint(mouse.origin.x + mouse.size.width * 0.74, mouse.origin.y + mouse.size.height * 0.74);
        [NSGraphicsContext saveGraphicsState];
        [sq addClip];
        for (int i = 2; i >= 0; i--) {
            CGFloat rad = s * (0.13 + i * 0.085);
            NSBezierPath *ring = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(touch.x - rad, touch.y - rad, rad * 2, rad * 2)];
            ring.lineWidth = s * 0.014;
            [[NSColor colorWithSRGBRed:1 green:0.58 blue:0.2 alpha:0.42 - i * 0.12] setStroke];
            [ring stroke];
        }
        [NSGraphicsContext restoreGraphicsState];
        drawSurface(RGKindMouse, mouse, kLightStyle);
        CGFloat dot = s * 0.045;
        [[NSColor colorWithSRGBRed:1 green:0.55 blue:0.15 alpha:0.35] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(touch.x - dot * 1.8, touch.y - dot * 1.8, dot * 3.6, dot * 3.6)] fill];
        [ORANGE setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(touch.x - dot, touch.y - dot, dot * 2, dot * 2)] fill];
        return YES;
    }];
}

static BOOL writeIconPNG(NSString *path, int px) {
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:px pixelsHigh:px
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    rep.size = NSMakeSize(px, px);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = [NSGraphicsContext graphicsContextWithBitmapImageRep:rep];
    [appIcon(px) drawInRect:NSMakeRect(0, 0, px, px)];
    [NSGraphicsContext restoreGraphicsState];
    return [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
}

#pragma mark - Controller interface

#define CARD_W    300.0
#define CARD_H    426.0
#define MARGIN    16.0
#define TOOLBAR_H 46.0
#define DELIVER_H 70.0
#define STATUS_H  24.0
#define LOG_H     152.0

@class RGView;

@interface RGController : NSObject <NSApplicationDelegate> {
@public
    double hidPending[4], evtPending[4];
    __strong RGDevice *hidPendingDevice[4], *evtToucher[4];
    __strong NSString *hidPendingName[4];
    BOOL evtDown[4], anonHidDown[4];
    long delivered[4], remappedTotal;
    double lastDrop;
    NSString *lastDropText, *statusLine;
    NSMutableArray<NSString *> *lines;
    CFMachPortRef tap;
    IOHIDManagerRef hid;
    BOOL tapOK, hidOK;
    CFMutableArrayRef mtList;
    IONotificationPortRef notifyPort;
    io_iterator_t addIter, removeIter;
    int statusTicks;
}
@property (strong) NSWindow *window, *settingsWindow, *helpWindow;
@property (strong) RGView *view;
@property (strong) NSTextField *matchLabel;
@property (strong) NSArray<RGDevice *> *devices;
@property (strong) NSMutableDictionary *hidCache;
@property (strong) NSMutableDictionary<NSString *, NSString *> *lastSecondary;
@property (strong) NSFileHandle *logFile;
@property (strong) NSDateFormatter *shortFmt, *longFmt;
@property (copy) NSString *snapshotPath;
@property BOOL demo;
- (NSArray<RGDevice *> *)visibleDevices;
- (RGStyle)styleFor:(RGDevice *)d;
- (NSString *)colourTextFor:(RGDevice *)d;
- (double)matchWindow;
- (void)hidButton:(int)b down:(BOOL)down device:(IOHIDDeviceRef)h;
- (void)event:(int)b down:(BOOL)down;
- (void)rescanDevices:(id)sender;
@end

static void hidCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(el) != kHIDPage_Button) return;
    uint32_t usage = IOHIDElementGetUsage(el);
    if (usage < 1 || usage > 3) return;
    [(__bridge RGController *)ctx hidButton:(int)usage down:IOHIDValueGetIntegerValue(value) != 0 device:IOHIDElementGetDevice(el)];
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ctx) {
    RGController *c = (__bridge RGController *)ctx;
    switch (type) {
        case kCGEventTapDisabledByTimeout:
        case kCGEventTapDisabledByUserInput: CGEventTapEnable(c->tap, true); break;
        case kCGEventLeftMouseDown:  [c event:1 down:YES]; break;
        case kCGEventLeftMouseUp:    [c event:1 down:NO];  break;
        case kCGEventRightMouseDown: [c event:2 down:YES]; break;
        case kCGEventRightMouseUp:   [c event:2 down:NO];  break;
        case kCGEventOtherMouseDown: [c event:3 down:YES]; break;
        case kCGEventOtherMouseUp:   [c event:3 down:NO];  break;
        default: break;
    }
    return ev;
}

static void devicesChangedCallback(void *refcon, io_iterator_t it) {
    io_object_t o;
    while ((o = IOIteratorNext(it))) IOObjectRelease(o);
    RGController *c = (__bridge RGController *)refcon;
    [NSObject cancelPreviousPerformRequestsWithTarget:c selector:@selector(rescanDevices:) object:nil];
    [c performSelector:@selector(rescanDevices:) withObject:nil afterDelay:1.5];
}

#pragma mark - Main view

@interface RGView : NSView
@property (weak) RGController *c;
@end

@implementation RGView

- (BOOL)isFlipped { return YES; }

- (void)drawRect:(NSRect)dirty {
    RGController *c = self.c;
    if (!c) return;
    [gray(0.09) setFill];
    NSRectFill(self.bounds);
    NSArray<RGDevice *> *devs = c.visibleDevices;
    CGFloat w = self.bounds.size.width - 2 * MARGIN;
    if (devs.count == 0)
        centred(@"No Magic Mouse or Magic Trackpad found", NSMakeRect(MARGIN, TOOLBAR_H, w, CARD_H),
                [NSFont systemFontOfSize:14], gray(0.5));
    for (NSUInteger i = 0; i < devs.count; i++)
        [self drawCard:devs[i] in:NSMakeRect(MARGIN + i * (CARD_W + MARGIN), TOOLBAR_H, CARD_W, CARD_H)];
    CGFloat y = TOOLBAR_H + CARD_H + MARGIN;
    [self drawDelivered:NSMakeRect(MARGIN, y, w, DELIVER_H)];
    y += DELIVER_H + 5;
    textIn(c->statusLine ?: @"", NSMakeRect(MARGIN + 2, y, w, 15), [NSFont systemFontOfSize:10.5], gray(0.55));
    [self drawLog:NSMakeRect(MARGIN, y + STATUS_H - 5, w, LOG_H)];
}

- (void)drawCard:(RGDevice *)d in:(NSRect)card {
    RGController *c = self.c;
    panel(card);
    CGFloat x = card.origin.x + 14, y = card.origin.y, iw = card.size.width - 28;
    textIn(c.demo ? (d->kind == RGKindMouse ? @"Magic Mouse" : @"Magic Trackpad") : d.name,
           NSMakeRect(x, y + 11, iw, 19), [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], gray(0.93));
    NSString *sub = (c.demo || !d.identifier.length) ? d.model : [NSString stringWithFormat:@"%@ · %@", d.model, d.identifier];
    textIn(sub, NSMakeRect(x, y + 30, iw, 15), [NSFont systemFontOfSize:11], gray(0.55));

    // Surface, drawn at the sensor's real aspect ratio
    NSRect area = NSMakeRect(x + 8, y + 58, iw - 16, 194);
    double aspect = (d->widthMM > 0 && d->heightMM > 0) ? d->widthMM / d->heightMM : (d->kind == RGKindMouse ? 0.57 : 1.41);
    NSSize sz = (area.size.width / area.size.height > aspect) ? NSMakeSize(area.size.height * aspect, area.size.height)
                                                              : NSMakeSize(area.size.width, area.size.width / aspect);
    NSRect s = NSMakeRect(round(NSMidX(area) - sz.width / 2), round(NSMidY(area) - sz.height / 2), round(sz.width), round(sz.height));
    RGStyle style = [c styleFor:d];
    drawSurface(d->kind, s, style);
    [self drawZones:d surface:s dark:style.darkTop];
    [self drawTouches:d surface:s];

    // What the hardware reports
    CGFloat ly = y + 264, lw = (iw - 52 - 8) / 2;
    text(@"Sends", x, ly + 8, [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], gray(0.6));
    lamp(NSMakeRect(x + 52, ly, lw, 30), @"Left", d->hidDown[1]);
    lamp(NSMakeRect(x + 52 + lw + 8, ly, lw, 30), @"Right", d->hidDown[2]);

    // Hardware details and the settings the driver is applying
    NSMutableArray *hw = [NSMutableArray array];
    if (d.firmware) [hw addObject:[@"Firmware " stringByAppendingString:d.firmware]];
    if (d.transport) [hw addObject:d.transport];
    if (d->battery >= 0) [hw addObject:[NSString stringWithFormat:@"Battery %d%%", d->battery]];
    NSMutableArray *info = [NSMutableArray arrayWithObject:hw.count ? [hw componentsJoinedByString:@" · "] : @"No hardware details reported"];
    [info addObject:[c colourTextFor:d]];
    [info addObjectsFromArray:d.settingsLines];
    CGFloat ty = ly + 42;
    NSFont *f = [NSFont systemFontOfSize:11];
    for (NSString *l in info) {
        BOOL warn = [l hasPrefix:@"Secondary click: Off"];
        textIn(l, NSMakeRect(x, ty, iw, 15), f, warn ? AMBER : gray(0.72));
        ty += 15.5;
    }
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    text([NSString stringWithFormat:@"Sent  L %ld  R %ld", d->sent[1], d->sent[2]], x, ty + 3, mono, gray(0.82));
    long drops = d->dropped[1] + d->dropped[2] + d->dropped[3];
    rtext([NSString stringWithFormat:@"Dropped  L %ld  R %ld", d->dropped[1], d->dropped[2]], x + iw, ty + 3,
          drops ? [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold] : mono, drops ? RED : gray(0.82));
}

- (void)drawZones:(RGDevice *)d surface:(NSRect)s dark:(BOOL)dark {
    NSColor *ink = dark ? gray(0.62) : gray(0.42);
    NSColor *accent = rgb(0.92, 0.5, 0.1);
    NSFont *f = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    NSColor *zoneFill = [ORANGE colorWithAlphaComponent:0.16];
    int z = d.secondaryZone;
    [NSGraphicsContext saveGraphicsState];
    [surfacePath(d->kind, s) addClip];
    if (d->kind == RGKindMouse) {
        if (z == 0) {
            centred(@"Secondary click off", NSMakeRect(s.origin.x, s.origin.y + s.size.height * 0.62, s.size.width, 14), f, accent);
        } else {
            float div = d.division;
            CGFloat splitX = round(s.origin.x + s.size.width * (z == 1 ? div : 1 - div)) + 0.5;
            NSRect zone = z == 1 ? NSMakeRect(splitX, s.origin.y, NSMaxX(s) - splitX, s.size.height)
                                 : NSMakeRect(s.origin.x, s.origin.y, splitX - s.origin.x, s.size.height);
            NSRect primary = z == 1 ? NSMakeRect(s.origin.x, s.origin.y, splitX - s.origin.x, s.size.height)
                                    : NSMakeRect(splitX, s.origin.y, NSMaxX(s) - splitX, s.size.height);
            [zoneFill setFill];
            NSRectFillUsingOperation(zone, NSCompositingOperationSourceOver);
            NSBezierPath *line = [NSBezierPath bezierPath];
            [line moveToPoint:NSMakePoint(splitX, s.origin.y)];
            [line lineToPoint:NSMakePoint(splitX, NSMaxY(s))];
            CGFloat dash[] = {4, 3};
            [line setLineDash:dash count:2 phase:0];
            line.lineWidth = 1.2;
            [[ORANGE colorWithAlphaComponent:0.8] setStroke];
            [line stroke];
            // Labels run along each zone so they fit however narrow the zone is
            CGFloat ly = s.origin.y + s.size.height * 0.58;
            verticalLabel(@"PRIMARY", NSMakePoint(NSMidX(primary), ly), f, ink);
            verticalLabel(@"SECONDARY", NSMakePoint(NSMidX(zone), ly), f, accent);
        }
    } else if (z >= 2) {
        // Apple doesn't publish the corner size; a quarter by a bit over a quarter is a close visual guide.
        CGFloat zw = s.size.width * 0.25, zh = s.size.height * 0.28;
        NSRect zone = NSMakeRect(z == 2 ? NSMaxX(s) - zw : s.origin.x, NSMaxY(s) - zh, zw, zh);
        [zoneFill setFill];
        NSRectFillUsingOperation(zone, NSCompositingOperationSourceOver);
        centred(@"Secondary", zone, f, accent);
    } else {
        centred(z == 1 ? @"Secondary click: two fingers" : @"Secondary click off",
                NSMakeRect(s.origin.x, NSMaxY(s) - 22, s.size.width, 14), f, z ? ink : accent);
    }
    [NSGraphicsContext restoreGraphicsState];
}

- (void)drawTouches:(RGDevice *)d surface:(NSRect)s {
    MTFinger t[MAX_TOUCHES];
    int n = copyTouches(d->slot, t);
    int z = d.secondaryZone;
    float div = d.division;
    for (int i = 0; i < n; i++) {
        float tx = t[i].normalized.pos.x, ty = t[i].normalized.pos.y;
        CGFloat px = s.origin.x + tx * s.size.width, py = s.origin.y + (1 - ty) * s.size.height;
        BOOL secondary;
        if (d->kind == RGKindMouse) secondary = (z == 1 && tx >= div) || (z == 2 && tx <= 1 - div);
        else if (z == 1) secondary = n >= 2;
        else if (z >= 2) secondary = ty <= 0.28 && (z == 2 ? tx >= 0.75 : tx <= 0.25);
        else secondary = NO;
        NSColor *col = secondary ? ORANGE : BLUE;
        CGFloat r = 7 + MIN(t[i].size, 2.5f) * 4.5;
        [[col colorWithAlphaComponent:0.25] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px - r - 6, py - r - 6, 2 * (r + 6), 2 * (r + 6))] fill];
        [[col colorWithAlphaComponent:0.92] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px - r, py - r, 2 * r, 2 * r)] fill];
    }
}

- (void)drawDelivered:(NSRect)r {
    RGController *c = self.c;
    panel(r);
    CGFloat x = r.origin.x + 14, y = r.origin.y;
    text(@"macOS delivers", x, y + 14, [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], gray(0.92));
    text(@"click events reaching apps", x, y + 33, [NSFont systemFontOfSize:10.5], gray(0.5));
    NSRect left = NSMakeRect(x + 168, y + 18, 100, 34), right = NSMakeRect(x + 276, y + 18, 100, 34);
    lamp(left, @"Left", c->evtDown[1]);
    lamp(right, @"Right", c->evtDown[2]);
    if (!c->tapOK && !c.snapshotPath)
        centred(@"Unavailable: see Help", NSUnionRect(left, right), [NSFont systemFontOfSize:11 weight:NSFontWeightMedium], RED);
    CGFloat cx = x + 392, cw = NSMaxX(r) - 14 - cx;
    double now = CFAbsoluteTimeGetCurrent();
    if (c->lastDrop > 0 && now - c->lastDrop < 3) {
        NSRect b = NSMakeRect(cx, y + 14, cw, 42);
        [RED setFill];
        [[NSBezierPath bezierPathWithRoundedRect:b xRadius:8 yRadius:8] fill];
        centred([c->lastDropText ?: @"Click dropped" uppercaseString], b, [NSFont systemFontOfSize:12 weight:NSFontWeightBold], NSColor.whiteColor);
        return;
    }
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    text([NSString stringWithFormat:@"Delivered  L %ld  R %ld", c->delivered[1], c->delivered[2]], cx, y + 17, mono, gray(0.82));
    text([NSString stringWithFormat:@"Remapped %ld · window %d ms", c->remappedTotal, (int)lround(c.matchWindow * 1000)],
         cx, y + 36, mono, c->remappedTotal ? AMBER : gray(0.55));
}

- (void)drawLog:(NSRect)r {
    RGController *c = self.c;
    [gray(0.12) setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:8 yRadius:8] fill];
    NSFont *f = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    NSInteger maxLines = (NSInteger)((r.size.height - 12) / 13.5);
    NSInteger start = MAX(0, (NSInteger)c->lines.count - maxLines);
    for (NSInteger i = start; i < (NSInteger)c->lines.count; i++) {
        NSString *l = c->lines[i];
        NSColor *col = [l containsString:@"✗"] ? RED : [l containsString:@"≠"] ? AMBER : [l containsString:@"✓"] ? gray(0.8) : gray(0.5);
        textIn(l, NSMakeRect(r.origin.x + 10, r.origin.y + 7 + (i - start) * 13.5, r.size.width - 20, 14), f, col);
    }
}
@end

#pragma mark - Controller

@implementation RGController

+ (void)initialize {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kKeepOnTop: @YES, kShowBuiltIn: @NO, kDropSound: @YES, kLogAll: @YES, kMatchMs: @400, kFinishes: @{}}];
}

- (double)matchWindow { return MAX(100, [NSUserDefaults.standardUserDefaults integerForKey:kMatchMs]) / 1000.0; }

- (NSArray<RGDevice *> *)visibleDevices {
    BOOL showBuiltIn = [NSUserDefaults.standardUserDefaults boolForKey:kShowBuiltIn];
    NSMutableArray *a = [NSMutableArray array];
    for (RGDevice *d in self.devices) if (d->kind != RGKindBuiltIn || showBuiltIn) [a addObject:d];
    return a;
}

- (NSString *)finishNameFor:(RGDevice *)d {
    if (d->colorID < 0) return nil;
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kFinishes][[@(d->colorID) stringValue]];
}

// The colour code decides the drawing unless the user has overridden it in Settings.
- (RGStyle)styleFor:(RGDevice *)d {
    NSString *override = [self finishNameFor:d];
    if ([override isEqualToString:@"black"]) return kDarkStyle;
    if ([override isEqualToString:@"white"]) return kLightStyle;
    const RGColour *c = colourForCode(d->colorID);
    return c ? c->style : kLightStyle;
}

- (NSString *)colourTextFor:(RGDevice *)d {
    if (d->colorID < 0) return @"Colour: not reported by the device";
    NSString *override = [self finishNameFor:d];
    if (override) return [NSString stringWithFormat:@"Colour: %@ (set in Settings; code %d)",
                          [override isEqualToString:@"black"] ? @"black / space grey" : @"white / silver", d->colorID];
    const RGColour *c = colourForCode(d->colorID);
    return c ? [NSString stringWithFormat:@"Colour: %@ (code %d)", c->name, d->colorID]
             : [NSString stringWithFormat:@"Colour code %d · unknown, set it in Settings", d->colorID];
}

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    lines = [NSMutableArray array];
    self.hidCache = [NSMutableDictionary dictionary];
    self.lastSecondary = [NSMutableDictionary dictionary];
    self.shortFmt = [NSDateFormatter new];
    self.shortFmt.dateFormat = @"HH:mm:ss";
    self.longFmt = [NSDateFormatter new];
    self.longFmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    NSApp.applicationIconImage = appIcon(512);
    if (!self.snapshotPath) [self openLogFile];
    [self buildMenu];
    [self buildWindow];
    [self rescanDevices:nil];
    [self updateStatus];

    if (self.snapshotPath) {
        if (self.demo) [self injectDemoState];
        [self performSelector:@selector(writeSnapshot) withObject:nil afterDelay:1.0];
        return;
    }
    [self setupHID];
    [self setupTap];
    [self watchDevices];
    [self updateStatus];
    NSTimer *draw = [NSTimer timerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    NSTimer *status = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:draw forMode:NSRunLoopCommonModes];
    [NSRunLoop.mainRunLoop addTimer:status forMode:NSRunLoopCommonModes];
    [self log:[NSString stringWithFormat:@"· %@ %@ started: button reports %@, click events %@ | %@", APP_NAME, APP_VERSION,
               hidOK ? @"ok" : @"unavailable", tapOK ? @"ok" : @"unavailable", statusLine]];
    [self activate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }

- (void)activate {
    if (@available(macOS 14, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
}

- (void)openLogFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:LOG_PATH]) [fm createFileAtPath:LOG_PATH contents:nil attributes:nil];
    self.logFile = [NSFileHandle fileHandleForWritingAtPath:LOG_PATH];
    [self.logFile seekToEndOfFile];
}

- (void)log:(NSString *)msg {
    NSDate *now = [NSDate date];
    [lines addObject:[NSString stringWithFormat:@"%@ %@", [self.shortFmt stringFromDate:now], msg]];
    if (lines.count > 500) [lines removeObjectsInRange:NSMakeRange(0, lines.count - 500)];
    NSString *fileLine = [NSString stringWithFormat:@"%@  %@\n", [self.longFmt stringFromDate:now], msg];
    [self.logFile writeData:[fileLine dataUsingEncoding:NSUTF8StringEncoding]];
    self.view.needsDisplay = YES;
}

#pragma mark Menus and windows

- (NSMenu *)addMenu:(NSString *)title to:(NSMenu *)bar {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    item.submenu = m;
    [bar addItem:item];
    return m;
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];
    NSEventModifierFlags cmdShift = NSEventModifierFlagCommand | NSEventModifierFlagShift;

    NSMenu *app = [self addMenu:APP_NAME to:bar];
    [app addItemWithTitle:@"About RodentGym" action:@selector(showAbout:) keyEquivalent:@""];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Settings…" action:@selector(showSettings:) keyEquivalent:@","];
    [app addItem:NSMenuItem.separatorItem];
    [app addItemWithTitle:@"Hide RodentGym" action:@selector(hide:) keyEquivalent:@"h"];
    [app addItemWithTitle:@"Quit RodentGym" action:@selector(terminate:) keyEquivalent:@"q"];

    NSMenu *edit = [self addMenu:@"Edit" to:bar];
    [edit addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [edit addItemWithTitle:@"Select All" action:@selector(selectAll:) keyEquivalent:@"a"];

    NSMenu *dev = [self addMenu:@"Devices" to:bar];
    [dev addItemWithTitle:@"Open Mouse Settings" action:@selector(openMouseSettings:) keyEquivalent:@"m"].keyEquivalentModifierMask = cmdShift;
    [dev addItemWithTitle:@"Open Trackpad Settings" action:@selector(openTrackpadSettings:) keyEquivalent:@"t"].keyEquivalentModifierMask = cmdShift;
    [dev addItem:NSMenuItem.separatorItem];
    [dev addItemWithTitle:@"Rescan Devices" action:@selector(rescanDevices:) keyEquivalent:@"r"].keyEquivalentModifierMask = cmdShift;
    [dev addItemWithTitle:@"Reset Counters" action:@selector(resetCounters:) keyEquivalent:@"k"];
    [dev addItemWithTitle:@"Open Log File" action:@selector(openLog:) keyEquivalent:@"l"];

    NSMenu *win = [self addMenu:@"Window" to:bar];
    [win addItemWithTitle:@"Minimise" action:@selector(performMiniaturize:) keyEquivalent:@"m"];
    [win addItemWithTitle:@"Close" action:@selector(performClose:) keyEquivalent:@"w"];
    NSApp.windowsMenu = win;

    NSMenu *help = [self addMenu:@"Help" to:bar];
    [help addItemWithTitle:@"RodentGym Help" action:@selector(showHelp:) keyEquivalent:@"?"];
    NSApp.helpMenu = help;
    NSApp.mainMenu = bar;
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 648, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = APP_NAME;
    self.window.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.window.releasedWhenClosed = NO;
    self.view = [[RGView alloc] initWithFrame:frame];
    self.view.c = self;
    self.window.contentView = self.view;
    [self applyWindowLevel];
    if (self.snapshotPath) {
        [self.window setFrameOrigin:NSMakePoint(-10000, -10000)];
    } else {
        [self.window center];
        [self.window setFrameAutosaveName:@"RodentGymMain"];
        [self.window makeKeyAndOrderFront:nil];
    }
}

- (void)applyWindowLevel {
    NSWindowLevel level = [NSUserDefaults.standardUserDefaults boolForKey:kKeepOnTop] ? NSFloatingWindowLevel : NSNormalWindowLevel;
    for (NSWindow *w in NSApp.windows) w.level = level;   // keep About, Settings and Help above the main window too
    self.window.level = level;
}

- (void)relayout {
    NSUInteger n = MAX(1, self.visibleDevices.count);
    CGFloat w = MAX(648, n * CARD_W + (n + 1) * MARGIN);
    CGFloat h = TOOLBAR_H + CARD_H + MARGIN + DELIVER_H + STATUS_H + LOG_H + MARGIN;
    NSRect old = self.window.frame;
    NSRect frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [self.window setFrame:frame display:YES];
    self.view.frame = NSMakeRect(0, 0, w, h);
    [self buildToolbar];
    self.view.needsDisplay = YES;
}

- (void)buildToolbar {
    for (NSView *v in [self.view.subviews copy]) [v removeFromSuperview];
    CGFloat x = MARGIN;
    NSArray *specs = @[@[@"Mouse Settings…", @"openMouseSettings:"], @[@"Trackpad Settings…", @"openTrackpadSettings:"],
                       @[@"Reset Counters", @"resetCounters:"], @[@"RodentGym Settings…", @"showSettings:"]];
    for (NSArray *spec in specs) {
        NSButton *b = [NSButton buttonWithTitle:spec[0] target:self action:NSSelectorFromString(spec[1])];
        b.bezelStyle = NSBezelStylePush;
        b.controlSize = NSControlSizeSmall;
        b.font = [NSFont systemFontOfSize:11];
        [b sizeToFit];
        b.frame = NSMakeRect(x, 12, b.frame.size.width, 24);
        x += b.frame.size.width + 4;
        [self.view addSubview:b];
    }
    NSButton *help = [[NSButton alloc] initWithFrame:NSMakeRect(self.view.bounds.size.width - MARGIN - 23, 12, 23, 23)];
    help.bezelStyle = NSBezelStyleHelpButton;
    help.title = @"";
    help.target = self;
    help.action = @selector(showHelp:);
    [self.view addSubview:help];
}

- (void)openMouseSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Mouse-Settings.extension"]];
}

- (void)openTrackpadSettings:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Trackpad-Settings.extension"]];
}

- (void)openLog:(id)sender { [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:LOG_PATH]]; }
- (void)revealLog:(id)sender { [NSWorkspace.sharedWorkspace activateFileViewerSelectingURLs:@[[NSURL fileURLWithPath:LOG_PATH]]]; }

- (void)resetCounters:(id)sender {
    for (RGDevice *d in self.devices) {
        memset(d->sent, 0, sizeof(d->sent));
        memset(d->dropped, 0, sizeof(d->dropped));
        d->remapped = 0;
    }
    memset(delivered, 0, sizeof(delivered));
    remappedTotal = 0;
    lastDrop = 0;
    [self log:@"· Counters reset"];
}

- (void)showAbout:(id)sender {
    NSString *credits = @"See what your Magic Mouse and Magic Trackpad report, and what macOS actually delivers. "
                        @"Dropped and remapped clicks are flagged and logged.\n\n"
                        @"Touch data comes from Apple's private MultitouchSupport framework, so a future macOS update may break it.";
    NSAttributedString *c = [[NSAttributedString alloc] initWithString:credits attributes:@{
        NSFontAttributeName: [NSFont systemFontOfSize:11], NSForegroundColorAttributeName: NSColor.secondaryLabelColor}];
    [NSApp orderFrontStandardAboutPanelWithOptions:@{
        NSAboutPanelOptionApplicationName: APP_NAME, NSAboutPanelOptionApplicationVersion: APP_VERSION,
        NSAboutPanelOptionVersion: @"", NSAboutPanelOptionCredits: c,
        NSAboutPanelOptionApplicationIcon: appIcon(256), @"Copyright": @"© 2026 gofastercloud · MIT License"}];
    [self applyWindowLevel];
    [self activate];
}

- (void)showHelp:(id)sender {
    if (!self.helpWindow) {
        self.helpWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 660, 760)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable
            backing:NSBackingStoreBuffered defer:NO];
        self.helpWindow.title = @"RodentGym Help";
        self.helpWindow.releasedWhenClosed = NO;
        self.helpWindow.contentMinSize = NSMakeSize(420, 300);
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 660, 760)];
        scroll.hasVerticalScroller = YES;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
        tv.editable = NO;
        tv.textContainerInset = NSMakeSize(26, 22);
        tv.autoresizingMask = NSViewWidthSizable;
        tv.backgroundColor = NSColor.textBackgroundColor;
        [tv.textStorage setAttributedString:[self helpText]];
        scroll.documentView = tv;
        self.helpWindow.contentView = scroll;
        [self.helpWindow center];
    }
    [self.helpWindow makeKeyAndOrderFront:nil];
    [self applyWindowLevel];
    [self activate];
}

// Loads Help.html and recolours it with semantic colours so it reads well in light and dark mode.
- (NSAttributedString *)helpText {
    NSURL *url = [NSBundle.mainBundle URLForResource:@"Help" withExtension:@"html"];
    NSData *html = url ? [NSData dataWithContentsOfURL:url] : nil;
    NSMutableAttributedString *s = html
        ? [[NSMutableAttributedString alloc] initWithHTML:html options:@{NSCharacterEncodingDocumentOption: @(NSUTF8StringEncoding)} documentAttributes:nil]
        : nil;
    if (!s) return [[NSAttributedString alloc] initWithString:@"Help.html is missing from the app bundle. Rebuild with build.sh."
                                                   attributes:@{NSForegroundColorAttributeName: NSColor.labelColor}];
    [s enumerateAttributesInRange:NSMakeRange(0, s.length) options:0 usingBlock:^(NSDictionary *attrs, NSRange range, BOOL *stop) {
        if (attrs[NSLinkAttributeName]) return;
        NSColor *c = [attrs[NSForegroundColorAttributeName] colorUsingColorSpace:NSColorSpace.sRGBColorSpace];
        CGFloat r = c ? c.redComponent : 0, g = c ? c.greenComponent : 0, b = c ? c.blueComponent : 0;
        BOOL grey = fabs(r - g) < 0.05 && fabs(g - b) < 0.05;
        if (!c || (grey && r < 0.25)) [s addAttribute:NSForegroundColorAttributeName value:NSColor.labelColor range:range];
        else if (grey) [s addAttribute:NSForegroundColorAttributeName value:NSColor.secondaryLabelColor range:range];
    }];
    return s;
}

#pragma mark Settings window

- (NSTextField *)heading:(NSString *)s {
    NSTextField *t = [NSTextField labelWithString:s];
    t.font = [NSFont boldSystemFontOfSize:13];
    return t;
}

- (NSTextField *)note:(NSString *)s {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.font = [NSFont systemFontOfSize:11];
    t.textColor = NSColor.secondaryLabelColor;
    [t.widthAnchor constraintEqualToConstant:410].active = YES;
    return t;
}

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(toggleSetting:)];
    b.identifier = key;
    b.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

- (void)toggleSetting:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:b.identifier];
    if ([b.identifier isEqualToString:kKeepOnTop]) [self applyWindowLevel];
    if ([b.identifier isEqualToString:kShowBuiltIn]) [self relayout];
}

- (void)updateMatchLabel {
    self.matchLabel.stringValue = [NSString stringWithFormat:@"Drop detection window: %ld ms",
                                   (long)[NSUserDefaults.standardUserDefaults integerForKey:kMatchMs]];
}

- (void)matchChanged:(NSSlider *)s {
    [NSUserDefaults.standardUserDefaults setInteger:lround(s.doubleValue) forKey:kMatchMs];
    [self updateMatchLabel];
    self.view.needsDisplay = YES;
}

- (void)colourChanged:(NSPopUpButton *)p {
    NSMutableDictionary *m = [[NSUserDefaults.standardUserDefaults dictionaryForKey:kFinishes] mutableCopy] ?: [NSMutableDictionary dictionary];
    NSString *choice = p.indexOfSelectedItem == 1 ? @"white" : p.indexOfSelectedItem == 2 ? @"black" : nil;
    if (choice) m[p.identifier] = choice;
    else [m removeObjectForKey:p.identifier];
    [NSUserDefaults.standardUserDefaults setObject:m forKey:kFinishes];
    self.view.needsDisplay = YES;
}

- (void)showSettings:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSStackView *stack = [NSStackView stackViewWithViews:@[]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 9;
    stack.edgeInsets = NSEdgeInsetsMake(20, 24, 22, 24);

    [stack addArrangedSubview:[self heading:@"Window"]];
    [stack addArrangedSubview:[self checkbox:@"Keep RodentGym on top of other windows" key:kKeepOnTop]];
    [stack addArrangedSubview:[self checkbox:@"Show the built-in trackpad" key:kShowBuiltIn]];

    [stack addArrangedSubview:[self heading:@"Detection"]];
    [stack addArrangedSubview:[self checkbox:@"Play a sound when a click is dropped" key:kDropSound]];
    [stack addArrangedSubview:[self checkbox:@"Log every click, not just problems" key:kLogAll]];
    self.matchLabel = [NSTextField labelWithString:@""];
    [self updateMatchLabel];
    [stack addArrangedSubview:self.matchLabel];
    NSSlider *slider = [NSSlider sliderWithValue:[ud integerForKey:kMatchMs] minValue:150 maxValue:1000
                                          target:self action:@selector(matchChanged:)];
    slider.numberOfTickMarks = 18;
    slider.allowsTickMarkValuesOnly = YES;
    [slider.widthAnchor constraintEqualToConstant:410].active = YES;
    [stack addArrangedSubview:slider];
    [stack addArrangedSubview:[self note:@"How long RodentGym waits for macOS to deliver a click the hardware reported before calling it dropped. Raise it if you see false drops while the Mac is very busy."]];

    [stack addArrangedSubview:[self heading:@"Device colours"]];
    [stack addArrangedSubview:[self note:@"Each accessory reports a colour code, and RodentGym decodes it automatically. If a device is drawn in the wrong finish, override it here. The choice applies to every device with that code."]];
    NSMutableDictionary<NSNumber *, NSMutableArray *> *codes = [NSMutableDictionary dictionary];
    for (RGDevice *d in self.devices) {
        if (d->colorID < 0) continue;
        if (!codes[@(d->colorID)]) codes[@(d->colorID)] = [NSMutableArray array];
        [codes[@(d->colorID)] addObject:d.name];
    }
    NSDictionary *finishes = [ud dictionaryForKey:kFinishes];
    for (NSNumber *code in [codes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSTextField *label = [NSTextField labelWithString:[NSString stringWithFormat:@"Code %@ — %@", code,
                                                           [codes[code] componentsJoinedByString:@", "]]];
        label.lineBreakMode = NSLineBreakByTruncatingTail;
        [label.widthAnchor constraintEqualToConstant:230].active = YES;
        NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        const RGColour *known = colourForCode(code.intValue);
        [p addItemsWithTitles:@[known ? [NSString stringWithFormat:@"Automatic (%@)", known->name] : @"Automatic (unknown)",
                                @"White / silver", @"Black / space grey"]];
        p.identifier = code.stringValue;
        NSString *cur = finishes[code.stringValue];
        [p selectItemAtIndex:[cur isEqualToString:@"white"] ? 1 : [cur isEqualToString:@"black"] ? 2 : 0];
        p.target = self;
        p.action = @selector(colourChanged:);
        NSStackView *row = [NSStackView stackViewWithViews:@[label, p]];
        row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
        [stack addArrangedSubview:row];
    }
    if (codes.count == 0) [stack addArrangedSubview:[self note:@"No connected device reports a colour code."]];

    [stack addArrangedSubview:[self heading:@"Log"]];
    [stack addArrangedSubview:[self note:[@"Clicks and problems are written to " stringByAppendingString:[LOG_PATH stringByAbbreviatingWithTildeInPath]]]];
    [stack addArrangedSubview:[NSButton buttonWithTitle:@"Show Log in Finder" target:self action:@selector(revealLog:)]];

    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 460, 500)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.title = @"RodentGym Settings";
        self.settingsWindow.releasedWhenClosed = NO;
        [self.settingsWindow center];
    }
    self.settingsWindow.contentView = stack;
    [self.settingsWindow setContentSize:stack.fittingSize];
    [self.settingsWindow makeKeyAndOrderFront:nil];
    [self applyWindowLevel];
    [self activate];
}

#pragma mark Devices

- (void)describe:(RGDevice *)d {
    MTDeviceGetFamilyID(d->mt, &d->family);
    BOOL builtIn = MTDeviceIsBuiltIn(d->mt);
    int w = 0, h = 0;
    MTDeviceGetSensorSurfaceDimensions(d->mt, &w, &h);   // hundredths of a millimetre
    d->widthMM = w / 100.0;
    d->heightMM = h / 100.0;
    d->service = MTDeviceGetService(d->mt);
    d->battery = -1;
    d->colorID = -1;
    NSString *product = regProp(d->service, @"Product", YES);
    d.name = [product isKindOfClass:NSString.class] ? product : @"Multitouch device";
    d->vendorID = intOf(regProp(d->service, @"VendorID", YES), 0);
    d->productID = intOf(regProp(d->service, @"ProductID", YES), 0);
    NSString *serial = regProp(d->service, @"SerialNumber", YES);
    d.identifier = [serial isKindOfClass:NSString.class] && serial.length ? serial : nil;
    NSString *transport = regProp(d->service, @"Transport", YES);
    d.transport = builtIn ? @"Built in" : [transport isKindOfClass:NSString.class] ? transport : nil;
    d.firmware = builtIn ? nil : firmwareString(intOf(regProp(d->service, @"VersionNumber", YES), 0));
    NSDictionary *prefs = regProp(d->service, @"MultitouchPreferences", NO);
    d.prefs = [prefs isKindOfClass:NSDictionary.class] ? prefs : @{};
    d->kind = builtIn ? RGKindBuiltIn : (d->family == 112 || d.prefs[@"MouseButtonMode"]) ? RGKindMouse : RGKindTrackpad;
    d.model = modelName(d->productID, d->kind);
}

- (void)rescanDevices:(id)sender {
    if (!self.snapshotPath)
        for (RGDevice *d in self.devices) {
            MTUnregisterContactFrameCallback(d->mt, contactCallback);
            MTDeviceStop(d->mt);
        }
    os_unfair_lock_lock(&gLock);
    gSlotCount = 0;
    os_unfair_lock_unlock(&gLock);
    if (mtList) CFRelease(mtList);
    [self.hidCache removeAllObjects];
    for (int b = 0; b < 4; b++) { hidPendingDevice[b] = nil; evtToucher[b] = nil; }

    mtList = MTDeviceCreateList();
    CFIndex count = mtList ? MIN(CFArrayGetCount(mtList), MAX_DEVICES) : 0;
    os_unfair_lock_lock(&gLock);
    for (CFIndex i = 0; i < count; i++) {
        gSlots[i].mt = (MTDeviceRef)CFArrayGetValueAtIndex(mtList, i);
        gSlots[i].count = 0;
    }
    gSlotCount = (int)count;
    os_unfair_lock_unlock(&gLock);

    NSMutableArray<RGDevice *> *found = [NSMutableArray array];
    for (CFIndex i = 0; i < count; i++) {
        RGDevice *d = [RGDevice new];
        d->mt = gSlots[i].mt;
        d->slot = (int)i;
        [self describe:d];
        [found addObject:d];
        if (!self.snapshotPath) {
            MTRegisterContactFrameCallback(d->mt, contactCallback);
            MTDeviceStart(d->mt, 0);
        }
    }
    [found sortUsingComparator:^NSComparisonResult(RGDevice *a, RGDevice *b) { return [@(a->kind) compare:@(b->kind)]; }];
    self.devices = found;
    for (RGDevice *d in found) self.lastSecondary[d.key] = d.secondaryDescription;
    [self refreshBatteryAndColour];
    [self relayout];

    NSMutableArray *names = [NSMutableArray array];
    for (RGDevice *d in found)
        [names addObject:[NSString stringWithFormat:@"%@ (%@%@)", d.name, d.model, d.firmware ? [@", firmware " stringByAppendingString:d.firmware] : @""]];
    if (!self.snapshotPath)
        [self log:[@"· Devices: " stringByAppendingString:names.count ? [names componentsJoinedByString:@"; "] : @"none"]];
}

- (void)refreshBatteryAndColour {
    NSDictionary *batt = registryValuesWithKey(@"BatteryPercent"), *col = registryValuesWithKey(@"ColorID");
    for (RGDevice *d in self.devices) {
        NSString *bySerial = d.identifier ? [@"serial:" stringByAppendingString:d.identifier] : @"";
        NSString *byName = [@"product:" stringByAppendingString:d.name];
        NSNumber *b = batt[bySerial] ?: batt[byName], *c = col[bySerial] ?: col[byName];
        d->battery = b ? b.intValue : -1;
        d->colorID = c ? c.intValue : -1;
    }
}

// Re-reads the settings each driver is applying and logs any change to secondary click.
- (void)refreshPrefs {
    for (RGDevice *d in self.devices) {
        NSDictionary *p = regProp(d->service, @"MultitouchPreferences", NO);
        if (![p isKindOfClass:NSDictionary.class]) continue;
        d.prefs = p;
        NSString *now = d.secondaryDescription, *before = self.lastSecondary[d.key];
        if (before && ![before isEqualToString:now])
            [self log:[NSString stringWithFormat:@"≠ %@: secondary click changed from \"%@\" to \"%@\"", d.name, before, now]];
        self.lastSecondary[d.key] = now;
    }
}

- (void)watchDevices {
    notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort), kCFRunLoopCommonModes);
    io_object_t o;
    IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                     devicesChangedCallback, (__bridge void *)self, &addIter);
    while ((o = IOIteratorNext(addIter))) IOObjectRelease(o);   // arm the notification
    IOServiceAddMatchingNotification(notifyPort, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"),
                                     devicesChangedCallback, (__bridge void *)self, &removeIter);
    while ((o = IOIteratorNext(removeIter))) IOObjectRelease(o);
}

#pragma mark Button reports and click events

- (void)setupHID {
    hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    NSArray *matches = @[@{@kIOHIDVendorIDKey: @0x004c},
                         @{@kIOHIDVendorIDKey: @0x05ac, @kIOHIDProductIDKey: @0x0265},
                         @{@kIOHIDVendorIDKey: @0x05ac, @kIOHIDProductIDKey: @0x030e},
                         @{@kIOHIDDeviceUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDDeviceUsageKey: @(kHIDUsage_GD_Mouse)}];
    IOHIDManagerSetDeviceMatchingMultiple(hid, (__bridge CFArrayRef)matches);
    IOHIDManagerRegisterInputValueCallback(hid, hidCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerOpen(hid, kIOHIDOptionsTypeNone);   // keyboards fail without Input Monitoring; pointing devices still open
    CFSetRef set = IOHIDManagerCopyDevices(hid);
    hidOK = set && CFSetGetCount(set) > 0;
    if (set) CFRelease(set);
}

- (void)setupTap {
    CGEventMask mask = CGEventMaskBit(kCGEventLeftMouseDown) | CGEventMaskBit(kCGEventLeftMouseUp) |
                       CGEventMaskBit(kCGEventRightMouseDown) | CGEventMaskBit(kCGEventRightMouseUp) |
                       CGEventMaskBit(kCGEventOtherMouseDown) | CGEventMaskBit(kCGEventOtherMouseUp);
    tap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly, mask, tapCallback, (__bridge void *)self);
    if (!tap) {
        CGRequestListenEventAccess();
        [self log:@"✗ Can't watch click events. Allow RodentGym under Privacy & Security → Input Monitoring, then reopen it."];
        return;
    }
    CFRunLoopSourceRef src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), src, kCFRunLoopCommonModes);
    CFRelease(src);
    CGEventTapEnable(tap, true);
    tapOK = YES;
}

- (RGDevice *)deviceForHID:(IOHIDDeviceRef)h name:(NSString **)nameOut {
    NSString *product = (__bridge NSString *)IOHIDDeviceGetProperty(h, CFSTR(kIOHIDProductKey));
    if (![product isKindOfClass:NSString.class]) product = @"Unknown device";
    *nameOut = product;
    NSValue *key = [NSValue valueWithPointer:h];
    id cached = self.hidCache[key];
    if (cached) return cached == NSNull.null ? nil : cached;
    NSString *serial = (__bridge NSString *)IOHIDDeviceGetProperty(h, CFSTR(kIOHIDSerialNumberKey));
    RGDevice *match = nil;
    for (RGDevice *d in self.devices)
        if (([serial isKindOfClass:NSString.class] && [d.identifier isEqualToString:serial]) || [d.name isEqualToString:product]) { match = d; break; }
    self.hidCache[key] = match ?: NSNull.null;
    return match;
}

- (RGDevice *)touchedDevice {
    MTFinger t[MAX_TOUCHES];
    for (RGDevice *d in self.devices) if (copyTouches(d->slot, t) > 0) return d;
    return nil;
}

- (BOOL)logAll { return [NSUserDefaults.standardUserDefaults boolForKey:kLogAll]; }

- (void)hidButton:(int)b down:(BOOL)down device:(IOHIDDeviceRef)h {
    NSString *name = nil;
    RGDevice *d = [self deviceForHID:h name:&name];
    BOOL *state = d ? d->hidDown : anonHidDown;
    if (!down) { state[b] = NO; self.view.needsDisplay = YES; return; }
    if (state[b]) return;   // the same press reported by a second HID interface
    state[b] = YES;
    if (d) d->sent[b]++;
    double now = CFAbsoluteTimeGetCurrent(), win = self.matchWindow;
    int o = otherButton(b);
    if (evtPending[b] > 0 && now - evtPending[b] < win) { evtPending[b] = 0; [self matched:b name:name]; }
    else if (o && evtPending[o] > 0 && now - evtPending[o] < win) { evtPending[o] = 0; [self sent:b delivered:o device:d name:name]; }
    else { hidPending[b] = now; hidPendingDevice[b] = d; hidPendingName[b] = name; }
    self.view.needsDisplay = YES;
}

- (void)event:(int)b down:(BOOL)down {
    if (!down) { evtDown[b] = NO; self.view.needsDisplay = YES; return; }
    evtDown[b] = YES;
    delivered[b]++;
    int o = otherButton(b);
    if (hidPending[b] > 0) { hidPending[b] = 0; [self matched:b name:hidPendingName[b]]; }
    else if (o && hidPending[o] > 0) { hidPending[o] = 0; [self sent:o delivered:b device:hidPendingDevice[o] name:hidPendingName[o]]; }
    else { evtPending[b] = CFAbsoluteTimeGetCurrent(); evtToucher[b] = [self touchedDevice]; }
    self.view.needsDisplay = YES;
}

- (void)matched:(int)b name:(NSString *)name {
    if (self.logAll) [self log:[NSString stringWithFormat:@"✓ %@ click: %@", kButtonName[b], name ?: @"unknown device"]];
}

- (void)sent:(int)from delivered:(int)to device:(RGDevice *)d name:(NSString *)name {
    if (d && d->kind != RGKindMouse && from == 1 && to == 2) {   // a trackpad's secondary click: expected
        if (self.logAll) [self log:[NSString stringWithFormat:@"✓ Right click: %@ (%@)", name, d.secondaryDescription.lowercaseString]];
        return;
    }
    if (d) d->remapped++;
    remappedTotal++;
    [self log:[NSString stringWithFormat:@"≠ %@ sent %@, macOS delivered %@", name ?: @"unknown device", kButtonName[from], kButtonName[to]]];
}

- (void)tick {
    double now = CFAbsoluteTimeGetCurrent(), win = self.matchWindow;
    for (int b = 1; b <= 3; b++) {
        if (hidPending[b] > 0 && now - hidPending[b] > win) {
            hidPending[b] = 0;
            RGDevice *d = hidPendingDevice[b];
            if (d) d->dropped[b]++;
            lastDrop = now;
            lastDropText = [NSString stringWithFormat:@"%@ click dropped", kButtonName[b]];
            if ([NSUserDefaults.standardUserDefaults boolForKey:kDropSound]) [[NSSound soundNamed:@"Basso"] play];
            [self log:[NSString stringWithFormat:@"✗ DROPPED %@ click: %@ sent it, macOS delivered nothing | %@%@",
                       kButtonName[b].lowercaseString, hidPendingName[b] ?: @"unknown device",
                       d ? [NSString stringWithFormat:@"secondary click: %@ | ", d.secondaryDescription] : @"", statusLine]];
        }
        if (evtPending[b] > 0 && now - evtPending[b] > win) {
            evtPending[b] = 0;
            RGDevice *t = evtToucher[b];
            evtToucher[b] = nil;
            if (self.logAll)
                [self log:t ? [NSString stringWithFormat:@"✓ %@ click: %@ (no button report; matched by touch)", kButtonName[b], t.name]
                            : [NSString stringWithFormat:@"· %@ click with no button report (another device, or synthetic)", kButtonName[b]]];
        }
    }
    self.view.needsDisplay = YES;
}

- (void)updateStatus {
    struct xsw_usage sw = {0};
    size_t len = sizeof(sw);
    sysctlbyname("vm.swapusage", &sw, &len, NULL, 0);
    int level = 0, pressure = 0;
    len = sizeof(level);
    sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0);
    len = sizeof(pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &len, NULL, 0);
    NSString *p = pressure >= 4 ? @"CRITICAL" : pressure >= 2 ? @"warning" : @"normal";
    statusLine = [NSString stringWithFormat:@"Memory free %d%% · pressure %@ · swap used %.1f GB · button reports %@ · click events %@",
                  level, p, sw.xsu_used / 1073741824.0, hidOK ? @"ok" : @"off", tapOK ? @"ok" : @"off"];
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    [self refreshPrefs];
    if (++statusTicks % 30 == 0) [self refreshBatteryAndColour];
}

#pragma mark Snapshot mode (used to produce the README screenshot)

- (void)injectDemoState {
    for (RGDevice *d in self.devices) {
        MTFinger f[2];
        memset(f, 0, sizeof f);
        int n;
        if (d->kind == RGKindMouse) {
            NSMutableDictionary *p = [d.prefs mutableCopy];
            p[@"MouseButtonMode"] = @"TwoButton";
            d.prefs = p;
            f[0].normalized.pos = (MTPoint){0.76f, 0.78f};
            f[0].size = 1.3f;
            n = 1;
            d->hidDown[2] = YES;
            d->sent[1] = 128; d->sent[2] = 23; d->dropped[2] = 1;
        } else {
            f[0].normalized.pos = (MTPoint){0.40f, 0.52f};
            f[1].normalized.pos = (MTPoint){0.55f, 0.56f};
            f[0].size = f[1].size = 1.0f;
            n = 2;
            d->sent[1] = 64; d->sent[2] = 0;
        }
        os_unfair_lock_lock(&gLock);
        memcpy(gSlots[d->slot].touches, f, sizeof(MTFinger) * (size_t)n);
        gSlots[d->slot].count = n;
        os_unfair_lock_unlock(&gLock);
    }
    evtDown[2] = YES;
    delivered[1] = 192; delivered[2] = 31;
    hidOK = tapOK = YES;
    statusLine = @"Memory free 58% · pressure normal · swap used 0.0 GB · button reports ok · click events ok";
    [lines addObjectsFromArray:@[
        @"09:41:02 · RodentGym 1.0 started: button reports ok, click events ok",
        @"09:41:02 · Devices: Magic Mouse (Magic Mouse 2 (Lightning), firmware 3.1.1); Magic Trackpad (Magic Trackpad 2 (Lightning), firmware 8.7.1)",
        @"09:41:09 ✓ Left click: Magic Mouse",
        @"09:41:11 ✓ Right click: Magic Trackpad (click or tap with two fingers)",
        @"09:41:15 ≠ Magic Mouse: secondary click changed from \"Off — whole surface clicks left\" to \"Right side (right-handed)\"",
        @"09:41:18 ✓ Right click: Magic Mouse",
        @"09:42:40 ✗ DROPPED right click: Magic Mouse sent it, macOS delivered nothing | secondary click: Right side (right-handed) | Memory free 21% · pressure warning",
        @"09:42:44 ✓ Right click: Magic Mouse"]];
    self.view.needsDisplay = YES;
}

- (void)writeSnapshot {
    NSBitmapImageRep *rep = [self.view bitmapImageRepForCachingDisplayInRect:self.view.bounds];
    [self.view cacheDisplayInRect:self.view.bounds toBitmapImageRep:rep];
    [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:self.snapshotPath atomically:YES];
    [NSApp terminate:nil];
}
@end

#pragma mark - Entry point

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        NSArray<NSString *> *args = NSProcessInfo.processInfo.arguments;
        NSUInteger i = [args indexOfObject:@"--render-icon"];
        if (i != NSNotFound && i + 1 < args.count) return writeIconPNG(args[i + 1], 1024) ? 0 : 1;

        RGController *controller = [RGController new];
        i = [args indexOfObject:@"--snapshot"];
        if (i != NSNotFound && i + 1 < args.count) {
            controller.snapshotPath = args[i + 1];
            controller.demo = [args containsObject:@"--demo"];
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        } else {
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        app.delegate = controller;
        [app run];
    }
    return 0;
}
