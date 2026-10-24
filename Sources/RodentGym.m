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
#import "Multitouch.h"
#import "UI.h"
#import "CheeseStack.h"
#import "GestureTrainer.h"

#define APP_NAME    @"RodentGym"
#define APP_VERSION ((NSString *)[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.1.0")
#define LOG_PATH    [@"~/Library/Logs/RodentGym.log" stringByExpandingTildeInPath]

#pragma mark - MultitouchSupport (private framework)

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

int RGCopyTouches(int slot, MTFinger *out) {
    os_unfair_lock_lock(&gLock);
    int n = (slot >= 0 && slot < gSlotCount) ? gSlots[slot].count : 0;
    if (n) memcpy(out, gSlots[slot].touches, sizeof(MTFinger) * (size_t)n);
    os_unfair_lock_unlock(&gLock);
    return n;
}

#pragma mark - Settings keys and helpers

static NSString *const kKeepOnTop = @"KeepOnTop";
static NSString *const kShowBuiltIn = @"ShowBuiltInTrackpad";
static NSString *const kDropSound = @"PlaySoundOnDrop";
static NSString *const kLogAll = @"LogEveryClick";
static NSString *const kMatchMs = @"MatchWindowMs";
static NSString *const kFinishes = @"ColourFinishes";   // { "<ColorID>": "white" | "black" } overrides

static NSString *const kButtonName[4] = {@"", @"Left", @"Right", @"Middle"};
static int otherButton(int b) { return b == 1 ? 2 : (b == 2 ? 1 : 0); }

static NSColor *rgb(CGFloat r, CGFloat g, CGFloat b) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:1]; }
static NSColor *grey(CGFloat w) { return [NSColor colorWithWhite:w alpha:1]; }
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

// Finds every registry entry carrying `key` (e.g. BatteryPercent, ColorID), indexed by the owning
// device's serial number and product name.
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

// Apple accessory colour codes, as reported in the IORegistry `ColorID` property. The same table is
// used in Continuity proximity-pairing adverts (furiousMAC/continuity, airpods_color_vals) and macOS's
// CoreUtils carries the same ordered names. Verified: Magic Mouse 2 white = 0, Magic Trackpad 2 space
// grey = 5, space grey Apple silicon MacBook built-in trackpad = 9.
typedef struct { int code; __unsafe_unretained NSString *name; RGStyle style; } RGColour;
static const RGColour kColours[] = {
    {0,  @"White",             {NO,  0.86, 0.86, 0.87}},
    {1,  @"Black",             {YES, 0.80, 0.80, 0.82}},   // black surface on silver aluminium
    {2,  @"Red",               {NO,  0.78, 0.24, 0.26}},
    {3,  @"Blue",              {NO,  0.30, 0.46, 0.78}},
    {4,  @"Pink",              {NO,  0.93, 0.64, 0.68}},
    {5,  @"Grey / space grey", {YES, 0.42, 0.43, 0.45}},   // 2017 space grey Magic Trackpad 2 reports 5
    {6,  @"Silver",            {NO,  0.86, 0.86, 0.87}},
    {7,  @"Gold",              {NO,  0.89, 0.79, 0.62}},
    {8,  @"Rose Gold",         {NO,  0.91, 0.73, 0.69}},
    {9,  @"Space Grey",        {YES, 0.42, 0.43, 0.45}},
    {10, @"Dark Blue",         {YES, 0.18, 0.25, 0.42}},
    {11, @"Light Blue",        {NO,  0.64, 0.79, 0.91}},
    {12, @"Yellow",            {NO,  0.95, 0.83, 0.42}},
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

#pragma mark - Drawing

static void text(NSString *s, CGFloat x, CGFloat y, NSFont *f, NSColor *c) {
    [s drawAtPoint:NSMakePoint(x, y) withAttributes:@{NSFontAttributeName: f, NSForegroundColorAttributeName: c}];
}

static void rtext(NSString *s, CGFloat right, CGFloat y, NSFont *f, NSColor *c) {
    NSDictionary *a = @{NSFontAttributeName: f, NSForegroundColorAttributeName: c};
    [s drawAtPoint:NSMakePoint(right - [s sizeWithAttributes:a].width, y) withAttributes:a];
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
    shadow.shadowColor = [NSColor colorWithWhite:0 alpha:0.35];
    shadow.shadowBlurRadius = MAX(6, r.size.width * 0.08);
    shadow.shadowOffset = NSMakeSize(0, -r.size.width * 0.025);
    [shadow set];
    [rimColour setFill];
    [base fill];
    [NSGraphicsContext restoreGraphicsState];

    NSGradient *rim = [[NSGradient alloc] initWithStartingColor:blend(rimColour, NSColor.whiteColor, 0.45)
                                                    endingColor:blend(rimColour, NSColor.blackColor, 0.4)];
    [rim drawInBezierPath:base angle:90 * down];

    NSBezierPath *top = surfacePath(kind, r);
    NSGradient *body = black
        ? [[NSGradient alloc] initWithColorsAndLocations:grey(0.25), 0.0, grey(0.13), 0.55, grey(0.06), 1.0, nil]
        : [[NSGradient alloc] initWithColorsAndLocations:grey(1.0), 0.0, grey(0.955), 0.55, grey(0.83), 1.0, nil];
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
        [rgb(1.0, 0.55, 0.15) setFill];
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
#define CARD_H    424.0
#define MARGIN    20.0
#define DELIVER_H 72.0
#define LOG_H     150.0

@class RGView;

@interface RGController : NSObject <NSApplicationDelegate, NSToolbarDelegate> {
@public
    double hidPending[4], evtPending[4];
    __strong RGDevice *hidPendingDevice[4], *evtToucher[4];
    __strong NSString *hidPendingName[4];
    BOOL evtDown[4], anonHidDown[4];
    long delivered[4], remappedTotal, totalDrops;
    double lastDrop;
    NSString *statusLine;
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
@property (strong) NSView *toast;
@property (strong) NSTextField *toastLabel;
@property (strong) RGCheeseStack *game;
@property (strong) RGGestureTrainer *trainer;
@property (strong) NSTextField *matchLabel;
@property (strong) NSArray<RGDevice *> *devices;
@property (strong) NSMutableDictionary *hidCache;
@property (strong) NSMutableDictionary<NSString *, NSString *> *lastSecondary;
@property (strong) NSFileHandle *logFile;
@property (strong) NSDateFormatter *shortFmt, *longFmt;
@property (copy) NSString *snapshotPath;
@property BOOL demo, live;
- (NSArray<RGDevice *> *)visibleDevices;
- (RGStyle)styleFor:(RGDevice *)d;
- (NSString *)colourTextFor:(RGDevice *)d;
- (double)matchWindow;
- (CGFloat)topInset;
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

- (NSRect)cardRect:(NSUInteger)i {
    return NSMakeRect(MARGIN + i * (CARD_W + MARGIN), self.c.topInset + 12, CARD_W, CARD_H);
}
- (NSRect)deliveredRect {
    return NSMakeRect(MARGIN, self.c.topInset + 12 + CARD_H + MARGIN, self.bounds.size.width - 2 * MARGIN, DELIVER_H);
}
- (NSRect)logRect {
    NSRect d = self.deliveredRect;
    return NSMakeRect(MARGIN, NSMaxY(d) + MARGIN, d.size.width, LOG_H);
}

- (void)drawRect:(NSRect)dirty {
    RGController *c = self.c;
    if (!c) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSArray<RGDevice *> *devs = c.visibleDevices;
    if (devs.count == 0)
        RGDrawText(@"No Magic Mouse or Magic Trackpad found", NSInsetRect([self cardRect:0], 0, CARD_H / 2 - 10),
                   [NSFont systemFontOfSize:14], NSColor.secondaryLabelColor, NSTextAlignmentCenter);
    for (NSUInteger i = 0; i < devs.count; i++) [self drawCard:devs[i] in:[self cardRect:i]];
    [self drawDelivered:self.deliveredRect];
    [self drawLog:self.logRect];
}

- (void)drawCard:(RGDevice *)d in:(NSRect)card {
    RGController *c = self.c;
    RGDrawCard(card, 16);
    CGFloat x = card.origin.x + 16, y = card.origin.y, iw = card.size.width - 32;
    NSString *title = c.demo ? (d->kind == RGKindMouse ? @"Magic Mouse" : @"Magic Trackpad") : d.name;
    RGDrawText(title, NSMakeRect(x, y + 14, iw, 20), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    NSString *sub = (c.demo || !d.identifier.length) ? d.model : [NSString stringWithFormat:@"%@ · %@", d.model, d.identifier];
    RGDrawText(sub, NSMakeRect(x, y + 35, iw, 16), [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);

    // Surface, drawn at the sensor's real aspect ratio
    NSRect area = NSMakeRect(x + 6, y + 62, iw - 12, 190);
    double aspect = (d->widthMM > 0 && d->heightMM > 0) ? d->widthMM / d->heightMM : (d->kind == RGKindMouse ? 0.57 : 1.41);
    NSSize sz = (area.size.width / area.size.height > aspect) ? NSMakeSize(area.size.height * aspect, area.size.height)
                                                              : NSMakeSize(area.size.width, area.size.width / aspect);
    NSRect s = NSMakeRect(round(NSMidX(area) - sz.width / 2), round(NSMidY(area) - sz.height / 2), round(sz.width), round(sz.height));
    RGStyle style = [c styleFor:d];
    drawSurface(d->kind, s, style);
    [self drawZones:d surface:s dark:style.darkTop];
    [self drawTouches:d surface:s];

    // What the hardware reports
    CGFloat ly = y + 266, lw = (iw - 56 - 8) / 2;
    text(@"Sends", x, ly + 7, [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    RGDrawLight(NSMakeRect(x + 56, ly, lw, 30), @"Left", d->hidDown[1], NSColor.systemGreenColor);
    RGDrawLight(NSMakeRect(x + 56 + lw + 8, ly, lw, 30), @"Right", d->hidDown[2], NSColor.systemGreenColor);

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
        RGDrawText(l, NSMakeRect(x, ty, iw, 15), warn ? [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold] : f,
                   warn ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        ty += 15.5;
    }
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    text([NSString stringWithFormat:@"Sent  L %ld  R %ld", d->sent[1], d->sent[2]], x, ty + 3, mono, NSColor.labelColor);
    long drops = d->dropped[1] + d->dropped[2] + d->dropped[3];
    rtext([NSString stringWithFormat:@"Dropped  L %ld  R %ld", d->dropped[1], d->dropped[2]], x + iw, ty + 3,
          drops ? [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold] : mono, drops ? NSColor.systemRedColor : NSColor.labelColor);
}

- (void)drawZones:(RGDevice *)d surface:(NSRect)s dark:(BOOL)dark {
    NSColor *ink = dark ? grey(0.62) : grey(0.42);
    NSColor *accent = rgb(0.92, 0.5, 0.1);
    NSFont *f = [NSFont systemFontOfSize:9.5 weight:NSFontWeightSemibold];
    NSColor *zoneFill = [rgb(1.0, 0.55, 0.15) colorWithAlphaComponent:0.16];
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
            [[accent colorWithAlphaComponent:0.8] setStroke];
            [line stroke];
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
    int n = RGCopyTouches(d->slot, t);
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
        NSColor *col = secondary ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        CGFloat r = 7 + MIN(t[i].size, 2.5f) * 4.5;
        [[col colorWithAlphaComponent:0.25] setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px - r - 6, py - r - 6, 2 * (r + 6), 2 * (r + 6))] fill];
        [col setFill];
        [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(px - r, py - r, 2 * r, 2 * r)] fill];
    }
}

- (void)drawDelivered:(NSRect)r {
    RGController *c = self.c;
    RGDrawCard(r, 16);
    CGFloat x = r.origin.x + 16, y = r.origin.y;
    RGDrawText(@"macOS delivers", NSMakeRect(x, y + 16, 160, 20), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
               NSColor.labelColor, NSTextAlignmentLeft);
    RGDrawText(@"Click events reaching apps", NSMakeRect(x, y + 38, 170, 16), [NSFont systemFontOfSize:11],
               NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    NSRect left = NSMakeRect(x + 178, y + 20, 100, 32), right = NSMakeRect(x + 286, y + 20, 100, 32);
    RGDrawLight(left, @"Left", c->evtDown[1], NSColor.systemGreenColor);
    RGDrawLight(right, @"Right", c->evtDown[2], NSColor.systemGreenColor);
    if (!c->tapOK && c.live)
        RGDrawText(@"Unavailable: see Help", NSMakeRect(left.origin.x, y + 56, 210, 14), [NSFont systemFontOfSize:10 weight:NSFontWeightMedium],
                   NSColor.systemRedColor, NSTextAlignmentCenter);
    CGFloat cx = x + 404;
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    text([NSString stringWithFormat:@"Delivered  L %ld  R %ld", c->delivered[1], c->delivered[2]], cx, y + 19, mono, NSColor.labelColor);
    text([NSString stringWithFormat:@"Remapped %ld · window %d ms", c->remappedTotal, (int)lround(c.matchWindow * 1000)],
         cx, y + 39, mono, c->remappedTotal ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor);
}

- (void)drawLog:(NSRect)r {
    RGController *c = self.c;
    RGDrawCard(r, 16);
    NSFont *f = [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular];
    NSInteger maxLines = (NSInteger)((r.size.height - 18) / 13.5);
    NSInteger start = MAX(0, (NSInteger)c->lines.count - maxLines);
    for (NSInteger i = start; i < (NSInteger)c->lines.count; i++) {
        NSString *l = c->lines[i];
        NSColor *col = [l containsString:@"✗"] ? NSColor.systemRedColor : [l containsString:@"≠"] ? NSColor.systemOrangeColor
                     : [l containsString:@"✓"] ? NSColor.labelColor : NSColor.secondaryLabelColor;
        RGDrawText(l, NSMakeRect(r.origin.x + 14, r.origin.y + 10 + (i - start) * 13.5, r.size.width - 28, 14), f, col, NSTextAlignmentLeft);
    }
}

#pragma mark Accessibility

- (BOOL)isAccessibilityElement { return NO; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"RodentGym dashboard"; }

- (NSAccessibilityElement *)element:(NSString *)label frame:(NSRect)r {
    NSRect screen = [self.window convertRectToScreen:[self convertRect:r toView:nil]];
    NSAccessibilityElement *e = [NSAccessibilityElement accessibilityElementWithRole:NSAccessibilityGroupRole frame:screen label:label parent:self];
    return e;
}

- (NSArray *)accessibilityChildren {
    RGController *c = self.c;
    NSMutableArray *a = [NSMutableArray arrayWithArray:[super accessibilityChildren] ?: @[]];
    NSArray<RGDevice *> *devs = c.visibleDevices;
    for (NSUInteger i = 0; i < devs.count; i++) {
        RGDevice *d = devs[i];
        NSString *label = [NSString stringWithFormat:@"%@, %@. Sending %@. %@. %@. Sent %ld left and %ld right clicks, dropped %ld.",
                           d.name, d.model,
                           d->hidDown[1] ? @"left" : d->hidDown[2] ? @"right" : @"nothing",
                           [d.settingsLines componentsJoinedByString:@". "], [c colourTextFor:d],
                           d->sent[1], d->sent[2], d->dropped[1] + d->dropped[2]];
        [a addObject:[self element:label frame:[self cardRect:i]]];
    }
    [a addObject:[self element:[NSString stringWithFormat:@"macOS delivers: %@. %ld left and %ld right clicks delivered, %ld remapped.",
                                c->evtDown[1] ? @"left down" : c->evtDown[2] ? @"right down" : @"no button down",
                                c->delivered[1], c->delivered[2], c->remappedTotal] frame:self.deliveredRect]];
    [a addObject:[self element:[@"Latest log entry: " stringByAppendingString:c->lines.lastObject ?: @"none"] frame:self.logRect]];
    return a;
}
@end

#pragma mark - Controller

static NSString *const kTBMouse = @"mouseSettings", *const kTBTrackpad = @"trackpadSettings", *const kTBGame = @"cheeseStack",
                *const kTBTrainer = @"gestureTrainer", *const kTBReset = @"resetCounters";

@implementation RGController

+ (void)initialize {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kKeepOnTop: @NO, kShowBuiltIn: @NO, kDropSound: @YES, kLogAll: @YES, kMatchMs: @400, kFinishes: @{}}];
}

- (double)matchWindow { return MAX(100, [NSUserDefaults.standardUserDefaults integerForKey:kMatchMs]) / 1000.0; }

- (NSArray<RGDevice *> *)visibleDevices {
    BOOL showBuiltIn = [NSUserDefaults.standardUserDefaults boolForKey:kShowBuiltIn];
    NSMutableArray *a = [NSMutableArray array];
    for (RGDevice *d in self.devices) if (d->kind != RGKindBuiltIn || showBuiltIn) [a addObject:d];
    return a;
}

- (NSString *)finishOverrideFor:(RGDevice *)d {
    if (d->colorID < 0) return nil;
    return [NSUserDefaults.standardUserDefaults dictionaryForKey:kFinishes][[@(d->colorID) stringValue]];
}

// The colour code decides the drawing unless the user has overridden it in Settings.
- (RGStyle)styleFor:(RGDevice *)d {
    NSString *override = [self finishOverrideFor:d];
    if ([override isEqualToString:@"black"]) return kDarkStyle;
    if ([override isEqualToString:@"white"]) return kLightStyle;
    const RGColour *c = colourForCode(d->colorID);
    return c ? c->style : kLightStyle;
}

- (NSString *)colourTextFor:(RGDevice *)d {
    if (d->colorID < 0) return @"Colour: not reported by the device";
    NSString *override = [self finishOverrideFor:d];
    if (override) return [NSString stringWithFormat:@"Colour: %@ (set in Settings; code %d)",
                          [override isEqualToString:@"black"] ? @"black / space grey" : @"white / silver", d->colorID];
    const RGColour *c = colourForCode(d->colorID);
    return c ? [NSString stringWithFormat:@"Colour: %@ (code %d)", c->name, d->colorID]
             : [NSString stringWithFormat:@"Colour code %d · unknown, set it in Settings", d->colorID];
}

// Height of the toolbar area the content must stay clear of (the window uses full-size content).
- (CGFloat)topInset {
    if (!self.window) return 0;
    NSRect content = [self.window contentRectForFrameRect:self.window.frame];
    return MAX(0, content.size.height - self.window.contentLayoutRect.size.height);
}

#pragma mark Lifecycle

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    lines = [NSMutableArray array];
    self.live = !self.snapshotPath && !self.demo;
    self.hidCache = [NSMutableDictionary dictionary];
    self.lastSecondary = [NSMutableDictionary dictionary];
    self.shortFmt = [NSDateFormatter new];
    self.shortFmt.dateFormat = @"HH:mm:ss";
    self.longFmt = [NSDateFormatter new];
    self.longFmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    if (self.live) [self openLogFile];
    [self buildMenu];
    [self buildWindow];
    [self rescanDevices:nil];
    [self updateStatus];

    if (self.snapshotPath) {
        if (self.demo) [self injectDemoState];
        [self performSelector:@selector(writeSnapshot) withObject:nil afterDelay:1.0];
        return;
    }
    if (self.demo) {
        [self injectDemoState];
        NSArray *args = NSProcessInfo.processInfo.arguments;
        if ([args containsObject:@"--demo-trainer"]) { self.trainer = [RGGestureTrainer new]; [self.trainer showDemo]; }
        if ([args containsObject:@"--demo-game"]) { [self showGame:nil]; [self.game showDemo]; }
    } else {
        [self setupHID];
        [self setupTap];
        [self watchDevices];
        [self updateStatus];
        [self log:[NSString stringWithFormat:@"· %@ %@ started: button reports %@, click events %@ | %@", APP_NAME, APP_VERSION,
                   hidOK ? @"ok" : @"unavailable", tapOK ? @"ok" : @"unavailable", statusLine]];
        NSArray *args = NSProcessInfo.processInfo.arguments;   // open the Gym straight away, e.g. from a shortcut
        if ([args containsObject:@"--show-trainer"]) [self showTrainer:nil];
        if ([args containsObject:@"--show-game"]) [self showGame:self];
    }
    NSTimer *draw = [NSTimer timerWithTimeInterval:1.0 / 30 target:self selector:@selector(tick) userInfo:nil repeats:YES];
    NSTimer *status = [NSTimer timerWithTimeInterval:1.0 target:self selector:@selector(updateStatus) userInfo:nil repeats:YES];
    [NSRunLoop.mainRunLoop addTimer:draw forMode:NSRunLoopCommonModes];
    if (self.live) [NSRunLoop.mainRunLoop addTimer:status forMode:NSRunLoopCommonModes];
    [self activate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)app { return YES; }
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication *)app { return YES; }

- (void)activate {
    if (@available(macOS 14, *)) [NSApp activate];
    else [NSApp activateIgnoringOtherApps:YES];
}

- (void)openLogFile {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:LOG_PATH]) [fm createFileAtPath:LOG_PATH contents:nil attributes:@{NSFilePosixPermissions: @0600}];
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

#pragma mark Menus

- (NSMenu *)addMenu:(NSString *)title to:(NSMenu *)bar {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:nil keyEquivalent:@""];
    NSMenu *m = [[NSMenu alloc] initWithTitle:title];
    item.submenu = m;
    [bar addItem:item];
    return m;
}

- (NSMenuItem *)add:(NSMenu *)menu title:(NSString *)title action:(SEL)action key:(NSString *)key
          modifiers:(NSEventModifierFlags)mods symbol:(NSString *)symbol {
    NSMenuItem *i = [menu addItemWithTitle:title action:action keyEquivalent:key];
    if (mods) i.keyEquivalentModifierMask = mods;
    if (symbol) i.image = RGSymbol(symbol, title);
    return i;
}

- (void)buildMenu {
    NSMenu *bar = [NSMenu new];
    NSEventModifierFlags cmd = NSEventModifierFlagCommand, cmdShift = cmd | NSEventModifierFlagShift;

    NSMenu *app = [self addMenu:APP_NAME to:bar];
    [self add:app title:@"About RodentGym" action:@selector(showAbout:) key:@"" modifiers:0 symbol:@"info.circle"];
    [app addItem:NSMenuItem.separatorItem];
    [self add:app title:@"Settings…" action:@selector(showSettings:) key:@"," modifiers:0 symbol:@"gearshape"];
    [app addItem:NSMenuItem.separatorItem];
    NSMenuItem *services = [app addItemWithTitle:@"Services" action:nil keyEquivalent:@""];
    services.submenu = [[NSMenu alloc] initWithTitle:@"Services"];
    NSApp.servicesMenu = services.submenu;
    [app addItem:NSMenuItem.separatorItem];
    [self add:app title:@"Hide RodentGym" action:@selector(hide:) key:@"h" modifiers:0 symbol:nil];
    [self add:app title:@"Hide Others" action:@selector(hideOtherApplications:) key:@"h" modifiers:cmd | NSEventModifierFlagOption symbol:nil];
    [self add:app title:@"Show All" action:@selector(unhideAllApplications:) key:@"" modifiers:0 symbol:nil];
    [app addItem:NSMenuItem.separatorItem];
    [self add:app title:@"Quit RodentGym" action:@selector(terminate:) key:@"q" modifiers:0 symbol:nil];

    NSMenu *file = [self addMenu:@"File" to:bar];
    [self add:file title:@"Close" action:@selector(performClose:) key:@"w" modifiers:0 symbol:@"xmark"];

    NSMenu *edit = [self addMenu:@"Edit" to:bar];
    [self add:edit title:@"Copy" action:@selector(copy:) key:@"c" modifiers:0 symbol:@"doc.on.doc"];
    [self add:edit title:@"Select All" action:@selector(selectAll:) key:@"a" modifiers:0 symbol:nil];

    NSMenu *dev = [self addMenu:@"Devices" to:bar];
    [self add:dev title:@"Open Mouse Settings" action:@selector(openMouseSettings:) key:@"m" modifiers:cmdShift symbol:@"computermouse"];
    [self add:dev title:@"Open Trackpad Settings" action:@selector(openTrackpadSettings:) key:@"t" modifiers:cmdShift
       symbol:@"rectangle.and.hand.point.up.left"];
    [dev addItem:NSMenuItem.separatorItem];
    [self add:dev title:@"Rescan Devices" action:@selector(rescanDevices:) key:@"r" modifiers:cmdShift symbol:@"arrow.triangle.2.circlepath"];
    [self add:dev title:@"Reset Counters" action:@selector(resetCounters:) key:@"k" modifiers:0 symbol:@"arrow.counterclockwise"];
    [dev addItem:NSMenuItem.separatorItem];
    [self add:dev title:@"Open Log File" action:@selector(openLog:) key:@"l" modifiers:0 symbol:@"doc.text"];

    NSMenu *gym = [self addMenu:@"Gym" to:bar];
    [self add:gym title:@"Cheese Stack" action:@selector(showGame:) key:@"g" modifiers:0 symbol:@"gamecontroller"];
    [self add:gym title:@"Gesture Trainer" action:@selector(showTrainer:) key:@"t" modifiers:0 symbol:@"hand.draw"];

    NSMenu *win = [self addMenu:@"Window" to:bar];
    [self add:win title:@"Minimise" action:@selector(performMiniaturize:) key:@"m" modifiers:0 symbol:nil];
    [self add:win title:@"Zoom" action:@selector(performZoom:) key:@"" modifiers:0 symbol:nil];
    [win addItem:NSMenuItem.separatorItem];
    [self add:win title:@"Bring All to Front" action:@selector(arrangeInFront:) key:@"" modifiers:0 symbol:nil];
    NSApp.windowsMenu = win;

    NSMenu *help = [self addMenu:@"Help" to:bar];
    [self add:help title:@"RodentGym Help" action:@selector(showHelp:) key:@"?" modifiers:0 symbol:@"questionmark.circle"];
    NSApp.helpMenu = help;
    NSApp.mainMenu = bar;
}

#pragma mark Window, toolbar and toast

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 660, 760);
    self.window = [[NSWindow alloc] initWithContentRect:frame
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = APP_NAME;
    self.window.releasedWhenClosed = NO;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"RodentGymToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    if (!self.snapshotPath) self.window.toolbar = toolbar;   // offscreen renders have no chrome to show
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;
    self.view = [[RGView alloc] initWithFrame:frame];
    self.view.c = self;
    self.window.contentView = self.view;
    [self buildToast];
    [self applyWindowLevel];
    if (self.snapshotPath) {
        [self.window setFrameOrigin:NSMakePoint(-10000, -10000)];
    } else {
        [self.window center];
        [self.window setFrameAutosaveName:@"RodentGymMain"];
        [self.window makeKeyAndOrderFront:nil];
    }
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kTBMouse, kTBTrackpad, NSToolbarFlexibleSpaceItemIdentifier, kTBGame, kTBTrainer, NSToolbarSpaceItemIdentifier, kTBReset];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar {
    return [[self toolbarDefaultItemIdentifiers:toolbar] arrayByAddingObject:NSToolbarSpaceItemIdentifier];
}

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSArray<NSString *> *spec = @{
        kTBMouse:    @[@"Mouse Settings", @"computermouse", @"Open Mouse settings", @"openMouseSettings:"],
        kTBTrackpad: @[@"Trackpad Settings", @"rectangle.and.hand.point.up.left", @"Open Trackpad settings", @"openTrackpadSettings:"],
        kTBGame:     @[@"Cheese Stack", @"gamecontroller", @"Play Cheese Stack, a click workout", @"showGame:"],
        kTBTrainer:  @[@"Gesture Trainer", @"hand.draw", @"Practise every gesture you have switched on", @"showTrainer:"],
        kTBReset:    @[@"Reset Counters", @"arrow.counterclockwise", @"Reset the click counters", @"resetCounters:"]}[ident];
    if (!spec) return nil;
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    item.label = spec[0];
    item.paletteLabel = spec[0];
    item.image = RGSymbol(spec[1], spec[0]);
    item.toolTip = spec[2];
    item.target = self;
    item.action = NSSelectorFromString(spec[3]);
    item.bordered = YES;
    return item;
}

// A Liquid Glass toast that floats under the toolbar when a click is dropped.
- (void)buildToast {
    NSView *content = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 320, 44)];
    NSImageView *icon = [NSImageView imageViewWithImage:RGSymbol(@"exclamationmark.triangle.fill", @"Warning") ?: [NSImage new]];
    icon.frame = NSMakeRect(16, 11, 22, 22);
    icon.contentTintColor = NSColor.systemRedColor;
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:16 weight:NSFontWeightSemibold];
    self.toastLabel = RGLabel(@"", [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold], NSColor.labelColor);
    self.toastLabel.frame = NSMakeRect(46, 13, 260, 18);
    [content addSubview:icon];
    [content addSubview:self.toastLabel];
    self.toast = RGGlassView(content, 22);
    RGSetGlassTint(self.toast, [NSColor.systemRedColor colorWithAlphaComponent:0.22]);
    self.toast.alphaValue = 0;
    self.toast.hidden = YES;
    self.toast.accessibilityElement = YES;
    self.toast.accessibilityRole = NSAccessibilityStaticTextRole;   // attached to the window only while showing
}

- (void)positionToast {
    NSRect b = self.view.bounds;
    self.toast.frame = NSMakeRect(round((b.size.width - 320) / 2), self.topInset + 8, 320, 44);
}

- (void)showToast:(NSString *)message {
    self.toastLabel.stringValue = message;
    self.toast.accessibilityLabel = message;
    if (!self.toast.superview) [self.view addSubview:self.toast];
    [self positionToast];
    self.toast.hidden = NO;
    NSAccessibilityPostNotificationWithUserInfo(self.toast, NSAccessibilityAnnouncementRequestedNotification,
        @{NSAccessibilityAnnouncementKey: message, NSAccessibilityPriorityKey: @(NSAccessibilityPriorityHigh)});
    if (RGReduceMotion()) self.toast.alphaValue = 1;
    else [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.2; self.toast.animator.alphaValue = 1; }];
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(hideToast) object:nil];
    [self performSelector:@selector(hideToast) withObject:nil afterDelay:3.0];
}

- (void)hideToast {
    if (RGReduceMotion()) { self.toast.alphaValue = 0; self.toast.hidden = YES; [self.toast removeFromSuperview]; return; }
    [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) { ctx.duration = 0.35; self.toast.animator.alphaValue = 0; }
                        completionHandler:^{ self.toast.hidden = YES; [self.toast removeFromSuperview]; }];
}

- (void)applyWindowLevel {
    NSWindowLevel level = [NSUserDefaults.standardUserDefaults boolForKey:kKeepOnTop] ? NSFloatingWindowLevel : NSNormalWindowLevel;
    for (NSWindow *w in NSApp.windows) w.level = level;   // keep About, Settings, Help and the Gym above the main window too
    self.window.level = level;
}

- (void)relayout {
    NSUInteger n = MAX(1, self.visibleDevices.count);
    CGFloat w = MAX(660, n * CARD_W + (n + 1) * MARGIN);
    CGFloat h = self.topInset + 12 + CARD_H + MARGIN + DELIVER_H + MARGIN + LOG_H + MARGIN;
    NSRect old = self.window.frame;
    NSRect frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [self.window setFrame:frame display:YES];
    // The toolbar height is only final once the window has its size; recompute once.
    CGFloat h2 = self.topInset + 12 + CARD_H + MARGIN + DELIVER_H + MARGIN + LOG_H + MARGIN;
    if (fabs(h2 - h) > 0.5) {
        frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h2)];
        frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
        [self.window setFrame:frame display:YES];
    }
    [self positionToast];
    self.view.needsDisplay = YES;
}

#pragma mark Actions

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

- (void)showGame:(id)sender {
    if (!self.game) {
        self.game = [RGCheeseStack new];
        __weak RGController *weakSelf = self;
        self.game.droppedClicks = ^long { RGController *s = weakSelf; return s ? s->totalDrops : 0; };
        self.game.inputWarning = ^NSString * {
            for (RGDevice *d in weakSelf.devices)
                if (d->kind == RGKindMouse && d.secondaryZone == 0)
                    return [NSString stringWithFormat:@"Secondary click is off on %@, so right-clicks arrive as left. Turn it on in Mouse Settings (⇧⌘M).", d.name];
            return nil;
        };
    }
    if (sender) [self.game show];
    [self applyWindowLevel];
    [self activate];
}

- (void)showTrainer:(id)sender {
    if (!self.trainer) {
        self.trainer = [RGGestureTrainer new];
        __weak RGController *weakSelf = self;
        self.trainer.devices = ^NSArray<NSDictionary *> * {
            NSMutableArray *a = [NSMutableArray array];
            for (RGDevice *d in weakSelf.visibleDevices)
                [a addObject:@{@"name": d.name, @"kind": d->kind == RGKindMouse ? @"mouse" : @"trackpad",
                               @"slot": @(d->slot), @"prefs": d.prefs ?: @{}}];
            return a;
        };
        self.trainer.log = ^(NSString *line) { [weakSelf log:line]; };
    }
    [self.trainer show];
    [self applyWindowLevel];
    [self activate];
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
        self.helpWindow.tabbingMode = NSWindowTabbingModeDisallowed;
        self.helpWindow.contentMinSize = NSMakeSize(420, 300);
        NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(0, 0, 660, 760)];
        scroll.hasVerticalScroller = YES;
        scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        NSTextView *tv = [[NSTextView alloc] initWithFrame:scroll.bounds];
        tv.editable = NO;
        tv.textContainerInset = NSMakeSize(28, 24);
        tv.autoresizingMask = NSViewWidthSizable;
        tv.backgroundColor = NSColor.textBackgroundColor;
        [tv.textStorage setAttributedString:[self helpText]];
        scroll.documentView = tv;
        self.helpWindow.contentView = scroll;
        [self.helpWindow center];
        [self.helpWindow setFrameAutosaveName:@"RodentGymHelp"];
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
        BOOL greyText = fabs(r - g) < 0.05 && fabs(g - b) < 0.05;
        if (!c || (greyText && r < 0.25)) [s addAttribute:NSForegroundColorAttributeName value:NSColor.labelColor range:range];
        else if (greyText) [s addAttribute:NSForegroundColorAttributeName value:NSColor.secondaryLabelColor range:range];
    }];
    return s;
}

#pragma mark Settings window

- (NSButton *)checkbox:(NSString *)title key:(NSString *)key {
    NSButton *b = [NSButton checkboxWithTitle:title target:self action:@selector(toggleSetting:)];
    b.identifier = key;
    b.state = [NSUserDefaults.standardUserDefaults boolForKey:key] ? NSControlStateValueOn : NSControlStateValueOff;
    return b;
}

- (NSTextField *)note:(NSString *)s width:(CGFloat)w {
    NSTextField *t = [NSTextField wrappingLabelWithString:s];
    t.font = [NSFont systemFontOfSize:NSFont.smallSystemFontSize];
    t.textColor = NSColor.secondaryLabelColor;
    t.preferredMaxLayoutWidth = w;
    [t.widthAnchor constraintEqualToConstant:w].active = YES;
    return t;
}

- (void)toggleSetting:(NSButton *)b {
    [NSUserDefaults.standardUserDefaults setBool:b.state == NSControlStateValueOn forKey:b.identifier];
    if ([b.identifier isEqualToString:kKeepOnTop]) [self applyWindowLevel];
    if ([b.identifier isEqualToString:kShowBuiltIn]) [self relayout];
}

- (void)updateMatchLabel {
    self.matchLabel.stringValue = [NSString stringWithFormat:@"%ld ms", (long)[NSUserDefaults.standardUserDefaults integerForKey:kMatchMs]];
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

- (NSTextField *)formLabel:(NSString *)s {
    NSTextField *t = [NSTextField labelWithString:s];
    t.alignment = NSTextAlignmentRight;
    return t;
}

// A standard two-column settings form: right-aligned labels, controls aligned on a common leading edge.
- (void)showSettings:(id)sender {
    NSUserDefaults *ud = NSUserDefaults.standardUserDefaults;
    NSGridView *grid = [NSGridView gridViewWithNumberOfColumns:2 rows:0];
    grid.rowSpacing = 8;
    grid.columnSpacing = 10;
    [grid addRowWithViews:@[[self formLabel:@"Window:"], [self checkbox:@"Keep RodentGym above other windows" key:kKeepOnTop]]];
    [grid addRowWithViews:@[[NSGridCell emptyContentView], [self checkbox:@"Show the built-in trackpad" key:kShowBuiltIn]]];

    NSGridRow *spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
    spacer.height = 6;
    [grid addRowWithViews:@[[self formLabel:@"Dropped clicks:"], [self checkbox:@"Play a sound" key:kDropSound]]];
    [grid addRowWithViews:@[[NSGridCell emptyContentView], [self checkbox:@"Log every click, not just problems" key:kLogAll]]];
    NSSlider *slider = [NSSlider sliderWithValue:[ud integerForKey:kMatchMs] minValue:150 maxValue:1000 target:self action:@selector(matchChanged:)];
    slider.numberOfTickMarks = 18;
    slider.allowsTickMarkValuesOnly = YES;
    slider.accessibilityLabel = @"Drop detection window";
    [slider.widthAnchor constraintEqualToConstant:240].active = YES;
    self.matchLabel = [NSTextField labelWithString:@""];
    self.matchLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
    [self updateMatchLabel];
    NSStackView *sliderRow = [NSStackView stackViewWithViews:@[slider, self.matchLabel]];
    [grid addRowWithViews:@[[self formLabel:@"Detection window:"], sliderRow]];
    [grid addRowWithViews:@[[NSGridCell emptyContentView],
                            [self note:@"How long to wait for macOS to deliver a click the hardware reported before calling it dropped. Raise it if you see false drops while the Mac is very busy." width:320]]];

    spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
    spacer.height = 6;
    NSMutableDictionary<NSNumber *, NSMutableArray *> *codes = [NSMutableDictionary dictionary];
    for (RGDevice *d in self.devices) {
        if (d->colorID < 0) continue;
        if (!codes[@(d->colorID)]) codes[@(d->colorID)] = [NSMutableArray array];
        [codes[@(d->colorID)] addObject:d.name];
    }
    NSDictionary *finishes = [ud dictionaryForKey:kFinishes];
    BOOL first = YES;
    for (NSNumber *code in [codes.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        const RGColour *known = colourForCode(code.intValue);
        NSPopUpButton *p = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
        [p addItemsWithTitles:@[known ? [NSString stringWithFormat:@"Automatic (%@)", known->name] : @"Automatic (unknown)",
                                @"White / silver", @"Black / space grey"]];
        p.identifier = code.stringValue;
        NSString *cur = finishes[code.stringValue];
        [p selectItemAtIndex:[cur isEqualToString:@"white"] ? 1 : [cur isEqualToString:@"black"] ? 2 : 0];
        p.target = self;
        p.action = @selector(colourChanged:);
        p.accessibilityLabel = [NSString stringWithFormat:@"Finish for colour code %@", code];
        NSTextField *names = [NSTextField labelWithString:[codes[code] componentsJoinedByString:@", "]];
        names.textColor = NSColor.secondaryLabelColor;
        names.lineBreakMode = NSLineBreakByTruncatingTail;
        [names.widthAnchor constraintLessThanOrEqualToConstant:150].active = YES;
        [grid addRowWithViews:@[[self formLabel:first ? @"Device colours:" : @""], [NSStackView stackViewWithViews:@[p, names]]]];
        first = NO;
    }
    if (codes.count == 0) [grid addRowWithViews:@[[self formLabel:@"Device colours:"], [self note:@"No connected device reports a colour code." width:320]]];

    spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
    spacer.height = 6;
    NSButton *reveal = [NSButton buttonWithTitle:@"Show in Finder" target:self action:@selector(revealLog:)];
    [grid addRowWithViews:@[[self formLabel:@"Log:"], [NSStackView stackViewWithViews:@[
        [NSTextField labelWithString:[LOG_PATH stringByAbbreviatingWithTildeInPath]], reveal]]]];

    [grid columnAtIndex:0].xPlacement = NSGridCellPlacementTrailing;
    grid.rowAlignment = NSGridRowAlignmentFirstBaseline;

    NSView *container = [NSView new];
    grid.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:grid];
    [NSLayoutConstraint activateConstraints:@[
        [grid.topAnchor constraintEqualToAnchor:container.topAnchor constant:22],
        [grid.bottomAnchor constraintEqualToAnchor:container.bottomAnchor constant:-22],
        [grid.leadingAnchor constraintEqualToAnchor:container.leadingAnchor constant:30],
        [grid.trailingAnchor constraintEqualToAnchor:container.trailingAnchor constant:-30]]];

    if (!self.settingsWindow) {
        self.settingsWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 560, 400)
            styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable backing:NSBackingStoreBuffered defer:NO];
        self.settingsWindow.title = @"RodentGym Settings";
        self.settingsWindow.releasedWhenClosed = NO;
        self.settingsWindow.tabbingMode = NSWindowTabbingModeDisallowed;
        [self.settingsWindow center];
    }
    self.settingsWindow.contentView = container;
    [container layoutSubtreeIfNeeded];
    [self.settingsWindow setContentSize:container.fittingSize];
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
    if (self.live)
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
        if (self.live) {
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
    if (self.live) [self log:[@"· Devices: " stringByAppendingString:names.count ? [names componentsJoinedByString:@"; "] : @"none"]];
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
    for (RGDevice *d in self.devices) if (RGCopyTouches(d->slot, t) > 0) return d;
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
            totalDrops++;
            lastDrop = now;
            if ([NSUserDefaults.standardUserDefaults boolForKey:kDropSound]) [[NSSound soundNamed:@"Basso"] play];
            [self showToast:[NSString stringWithFormat:@"%@ click dropped by macOS", kButtonName[b]]];
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

// Memory state goes in the window subtitle and on every dropped-click log line.
- (void)updateStatus {
    struct xsw_usage sw = {0};
    size_t len = sizeof(sw);
    sysctlbyname("vm.swapusage", &sw, &len, NULL, 0);
    int level = 0, pressure = 0;
    len = sizeof(level);
    sysctlbyname("kern.memorystatus_level", &level, &len, NULL, 0);
    len = sizeof(pressure);
    sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &len, NULL, 0);
    NSString *p = pressure >= 4 ? @"critical" : pressure >= 2 ? @"warning" : @"normal";
    statusLine = [NSString stringWithFormat:@"Memory free %d%% · pressure %@ · swap used %.1f GB", level, p, sw.xsu_used / 1073741824.0];
    if (self.live) {
        NSString *listening = hidOK && tapOK ? @"Listening" : @"Partly listening (see Help)";
        self.window.subtitle = [NSString stringWithFormat:@"%@ · %@", listening, statusLine];
    }
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    if (self.live) [self refreshPrefs];
    if (++statusTicks % 30 == 0) [self refreshBatteryAndColour];
}

#pragma mark Demo mode (anonymised data for README screenshots)

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
            d->battery = 72;
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
    self.window.subtitle = @"Listening · Memory free 58% · pressure normal · swap used 0.0 GB";
    [lines addObjectsFromArray:@[
        [NSString stringWithFormat:@"09:41:02 · RodentGym %@ started: button reports ok, click events ok", APP_VERSION],
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
        NSUInteger i = [args indexOfObject:@"--appearance"];   // for rendering docs in a fixed appearance
        if (i != NSNotFound && i + 1 < args.count)
            app.appearance = [NSAppearance appearanceNamed:[args[i + 1] isEqualToString:@"dark"] ? NSAppearanceNameDarkAqua : NSAppearanceNameAqua];
        i = [args indexOfObject:@"--render-icon"];
        if (i != NSNotFound && i + 1 < args.count) return writeIconPNG(args[i + 1], 1024) ? 0 : 1;

        i = [args indexOfObject:@"--snapshot-game"];
        if (i != NSNotFound && i + 1 < args.count) return [[RGCheeseStack new] writeDemoSnapshotTo:args[i + 1]] ? 0 : 1;
        i = [args indexOfObject:@"--snapshot-trainer"];
        if (i != NSNotFound && i + 1 < args.count) return [[RGGestureTrainer new] writeDemoSnapshotTo:args[i + 1]] ? 0 : 1;

        RGController *controller = [RGController new];
        i = [args indexOfObject:@"--snapshot"];
        if (i != NSNotFound && i + 1 < args.count) {
            controller.snapshotPath = args[i + 1];
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        } else {
            [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        }
        controller.demo = [args containsObject:@"--demo"];
        app.delegate = controller;
        [app run];
    }
    return 0;
}
