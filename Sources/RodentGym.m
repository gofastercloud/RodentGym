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
#import <QuartzCore/QuartzCore.h>
#include <sys/sysctl.h>
#include <dlfcn.h>
#import <IOKit/ps/IOPowerSources.h>
#import "Multitouch.h"
#import "UI.h"
#import "CheeseStack.h"
#import "GestureTrainer.h"
#import "ForceSensor.h"
#import "LatencyMonitor.h"
#import "SelfTest.h"
#import "Bluetooth.h"
#import "Help.h"
#import "Keyboard.h"
#include <mach/mach_time.h>

#define APP_NAME    @"RodentGym"
#define APP_VERSION ((NSString *)[NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"0.6.0")
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

// Touch frames arrive on a MultitouchSupport thread; they are copied into fixed slots under a lock,
// along with running frame statistics (report rate, stalls, lost contacts) that only this thread
// sees every frame of.
typedef struct {
    MTDeviceRef mt;
    int count;
    MTFinger touches[MAX_TOUCHES];
    RGFrameStats stats;
    double lastContactTs;
    int prevCount;
    struct { int id, state; float x, y; } prev[MAX_TOUCHES];
} RGSlot;
static os_unfair_lock gLock = OS_UNFAIR_LOCK_INIT;
static RGSlot gSlots[MAX_DEVICES];
static int gSlotCount;

static BOOL isContact(int state) { return state >= RGTouchMake && state <= RGTouchBreak; }

static void accumulateStats(RGSlot *s, const MTFinger *f, int n, double ts) {
    RGFrameStats *st = &s->stats;
    BOOL contact = NO;
    for (int i = 0; i < n; i++) if (isContact(f[i].state)) { contact = YES; break; }
    if (n > 0) st->frames++;
    if (contact) {
        st->contactFrames++;
        double dt = ts - s->lastContactTs;
        if (s->lastContactTs > 0 && dt > 0 && dt < 0.5) {
            // Learn the device's frame time from the first few intervals, then flag ones far over it
            BOOL stall = st->intervals >= 20 && dt > MAX(st->typical * 2.5, st->typical + 0.008);
            st->intervals++;
            st->sum += dt;
            st->sumSq += dt * dt;
            if (stall) st->stalls++;
            else st->typical = st->intervals <= 20 ? st->sum / st->intervals : st->typical * 0.98 + dt * 0.02;
        }
        s->lastContactTs = ts;
    } else {
        s->lastContactTs = 0;   // the next contact starts a new run; idle time is not a stall
    }
    for (int i = 0; i < n; i++) {
        if (!isContact(f[i].state)) continue;
        BOOL seen = NO;
        for (int k = 0; k < s->prevCount; k++) if (s->prev[k].id == f[i].identifier && isContact(s->prev[k].state)) { seen = YES; break; }
        if (!seen) st->strokes++;
    }
    // A contact that disappears while still "touching", away from the edges, was lost by the sensor
    for (int k = 0; k < s->prevCount; k++) {
        if (s->prev[k].state != RGTouchTouching) continue;
        BOOL present = NO;
        for (int i = 0; i < n; i++) if (f[i].identifier == s->prev[k].id) { present = YES; break; }
        float x = s->prev[k].x, y = s->prev[k].y;
        if (!present && x > 0.08f && x < 0.92f && y > 0.08f && y < 0.92f) st->lost++;
    }
    s->prevCount = n;
    for (int i = 0; i < n; i++)
        s->prev[i] = (typeof(s->prev[0])){f[i].identifier, f[i].state, f[i].normalized.pos.x, f[i].normalized.pos.y};
}

static int contactCallback(MTDeviceRef dev, MTFinger *f, int n, double ts, int frame) {
    if (n < 0) n = 0;
    if (n > MAX_TOUCHES) n = MAX_TOUCHES;
    os_unfair_lock_lock(&gLock);
    for (int i = 0; i < gSlotCount; i++) {
        if (gSlots[i].mt != dev) continue;
        if (n) memcpy(gSlots[i].touches, f, sizeof(MTFinger) * (size_t)n);
        gSlots[i].count = n;
        accumulateStats(&gSlots[i], f, n, ts);
        break;
    }
    os_unfair_lock_unlock(&gLock);
    return 0;
}

void RGGetFrameStats(int slot, RGFrameStats *out) {
    os_unfair_lock_lock(&gLock);
    if (slot >= 0 && slot < gSlotCount) *out = gSlots[slot].stats;
    else memset(out, 0, sizeof *out);
    os_unfair_lock_unlock(&gLock);
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
static NSString *const kBuiltInMode = @"BuiltInTrackpadMode";   // 0 automatic (lid open), 1 always, 2 never
static NSString *const kDropSound = @"PlaySoundOnDrop";
static NSString *const kLogAll = @"LogEveryClick";
static NSString *const kMatchMs = @"MatchWindowMs";
static NSString *const kFinishes = @"ColourFinishes";   // { "<ColorID>": "white" | "black" } overrides
static NSString *const kBluetooth = @"MonitorBluetoothSignal";   // opt-in: needs Bluetooth permission

static double machMs(uint64_t later, uint64_t earlier) {
    static mach_timebase_info_data_t tb;
    if (!tb.denom) mach_timebase_info(&tb);
    if (later < earlier) return -1;
    return (double)(later - earlier) * tb.numer / tb.denom / 1e6;
}

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

// Battery details for Bluetooth and USB accessories, keyed by accessory identifier (serial number or
// Bluetooth address) and by name. The public IOPSCopyPowerSourcesList only returns the Mac's own
// battery; IOPSCopyPowerSourcesByType(0) — the call `pmset -g accps` uses — includes accessories.
static NSDictionary<NSString *, NSDictionary *> *accessoryPowerSources(void) {
    static CFTypeRef (*byType)(int);
    static dispatch_once_t once;
    dispatch_once(&once, ^{ byType = (CFTypeRef (*)(int))dlsym(RTLD_DEFAULT, "IOPSCopyPowerSourcesByType"); });
    CFTypeRef info = byType ? byType(0) : IOPSCopyPowerSourcesInfo();
    if (!info) return @{};
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    NSArray *list = CFBridgingRelease(IOPSCopyPowerSourcesList(info));
    for (id ps in list) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)ps);
        if (![d[@"Type"] isEqual:@"Accessory Source"]) continue;
        NSString *ident = d[@"Accessory Identifier"], *name = d[@"Name"];
        if ([ident isKindOfClass:NSString.class]) out[[@"id:" stringByAppendingString:ident.uppercaseString]] = d;
        if ([name isKindOfClass:NSString.class] && !out[[@"name:" stringByAppendingString:name]]) out[[@"name:" stringByAppendingString:name]] = d;
    }
    CFRelease(info);
    return out;
}

static void powerSourcesChanged(void *context);

// The Mac's marketing name from the device tree, e.g. "MacBook Pro (14-inch, M5)".
static NSString *macProductName(void) {
    io_registry_entry_t product = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/product");
    NSData *data = product ? CFBridgingRelease(IORegistryEntryCreateCFProperty(product, CFSTR("product-name"), kCFAllocatorDefault, 0)) : nil;
    if (product) IOObjectRelease(product);
    if ([data isKindOfClass:NSData.class] && data.length) {
        NSString *s = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        s = [s stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"\0"]];
        if (s.length) return s;
    }
    return @"this Mac";
}

// YES when a MacBook's lid is closed (clamshell mode with an external display).
static BOOL lidClosed(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return NO;
    id state = CFBridgingRelease(IORegistryEntryCreateCFProperty(root, CFSTR("AppleClamshellState"), kCFAllocatorDefault, 0));
    IOObjectRelease(root);
    return [state respondsToSelector:@selector(boolValue)] && [state boolValue];
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
    if (kind == RGKindBuiltIn) return [macProductName() stringByAppendingString:@" · Force Touch"];
    switch (productID) {
        case 0x030d: return @"Magic Mouse (1st generation)";
        case 0x030e: return @"Magic Trackpad (1st generation)";
        case 0x0269: return @"Magic Mouse 2 (Lightning)";
        case 0x0265: return @"Magic Trackpad 2 (Lightning)";
    }
    return [NSString stringWithFormat:@"%@ (product 0x%04x)", kind == RGKindMouse ? @"Magic Mouse" : @"Magic Trackpad", productID];
}

// Battery status in words and the colour to show it in, shared by devices and keyboards.
static NSString *powerStatusText(int battery, BOOL charging, BOOL charged, BOOL onCable, int lowWarn) {
    if (battery < 0) return nil;
    if (onCable && (charged || battery >= 100)) return @"Charged";
    if (charging) return @"Charging";
    if (onCable) return @"Plugged in";
    if (battery <= MAX(5, lowWarn)) return @"Low battery";
    return @"On battery";
}

static NSColor *batteryColourFor(int battery, BOOL charging, BOOL onCable, int lowWarn) {
    if (charging || (onCable && battery >= 100)) return NSColor.systemGreenColor;
    if (battery <= 10) return NSColor.systemRedColor;
    if (battery <= MAX(20, lowWarn)) return NSColor.systemOrangeColor;
    return NSColor.labelColor;
}

#pragma mark - Live visualisation model

#define TRAIL_LEN  48
#define TRAIL_LIFE 0.45   // seconds a trail point stays visible
#define MAX_PINGS  8
#define PING_LIFE  0.8    // seconds a click ripple lasts

typedef struct { int fid, count; float x[TRAIL_LEN], y[TRAIL_LEN]; double t[TRAIL_LEN]; } RGTrail;
typedef struct { float x, y; double start; int kind; } RGPing;   // kind: 1 left, 2 right, 3 dropped

static double gFrozenTime;   // set in demo mode so screenshots catch animations mid-flight
static double animNow(void) { return gFrozenTime > 0 ? gFrozenTime : CFAbsoluteTimeGetCurrent(); }

@interface RGDevice : NSObject {
@public
    MTDeviceRef mt;
    io_service_t service;
    int slot, family, vendorID, productID, battery, colorID;
    RGKind kind;
    double widthMM, heightMM;
    BOOL hidDown[4];
    long sent[4], dropped[4], remapped;
    RGTrail trails[MAX_TOUCHES];
    RGPing pings[MAX_PINGS];
    int pingHead;
    BOOL charging, charged, onCable;
    int lowWarn;
    int rssi;            // dBm, 0 when not monitored or not reported
    double rssiTime;
    NSRect surfaceRect;  // where the device was last drawn, for dragging the mouse's split line
    float dragDivision;  // 0 unless the split line is being dragged
}
@property (copy) NSString *name, *model, *firmware, *identifier, *transport;
@property (copy) NSString *productName;   // as the hardware names itself; used to match HID reports
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

// Where the secondary-click area starts, 0–1 across the mouse (Apple's default is 55%). While the
// split line is being dragged, the drag position wins.
- (float)division { return dragDivision > 0 ? dragDivision : intOf(self.prefs[@"MouseButtonDivision"], 55) / 100.0f; }

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

- (NSString *)powerStatus { return powerStatusText(battery, charging, charged, onCable, lowWarn); }
- (NSColor *)batteryColour { return batteryColourFor(battery, charging, onCable, lowWarn); }

// Settings as label and value rows for the card: @[label, value, @(warn)].
- (NSArray<NSArray *> *)settingsRows {
    int z = self.secondaryZone;
    id dir = globalPref(@"com.apple.swipescrolldirection");
    NSString *scroll = (dir == nil || [dir boolValue]) ? @"Natural" : @"Standard";
    if (kind == RGKindMouse) {
        NSString *secondary = z == 1 ? @"Right side" : z == 2 ? @"Left side (left-handed)" : @"Off: every click is a left click";
        NSString *zoom = intOf(self.prefs[@"MouseOneFingerDoubleTapGesture"], 0) ? @"smart zoom on" : @"smart zoom off";
        return @[@[@"Secondary", secondary, @(z == 0)],
                 @[@"Split", z ? [NSString stringWithFormat:@"%d%% · %@", (int)lroundf(self.division * 100), zoom] : [zoom capitalizedString], @NO],
                 @[@"Scrolling", [NSString stringWithFormat:@"%@ · speed %.1f", scroll, [globalPref(@"com.apple.mouse.scaling") doubleValue]], @NO]];
    }
    static NSString *const pressure[] = {@"light", @"medium", @"firm"};
    int pr = MAX(0, MIN(2, intOf(self.prefs[@"FirstClickThreshold"], 1)));
    NSString *secondary = z == 1 ? @"Two fingers" : z == 2 ? @"Bottom-right corner" : z == 3 ? @"Bottom-left corner" : @"Off";
    NSString *clicking = [NSString stringWithFormat:@"Tap %@ · %@ · Force Click %@", intOf(self.prefs[@"Clicking"], 0) ? @"on" : @"off",
                          pressure[pr], [globalPref(@"com.apple.trackpad.forceClick") boolValue] ? @"on" : @"off"];
    return @[@[@"Secondary", secondary, @(z == 0)], @[@"Clicking", clicking, @NO],
             @[@"Scrolling", [NSString stringWithFormat:@"%@ · speed %.1f", scroll, [globalPref(@"com.apple.trackpad.scaling") doubleValue]], @NO]];
}

- (void)addPing:(int)pingKind at:(NSPoint)p {
    pings[pingHead] = (RGPing){(float)p.x, (float)p.y, animNow(), pingKind};
    pingHead = (pingHead + 1) % MAX_PINGS;
}

// Appends the latest touches to each finger's trail and lets old points age out.
- (void)updateTrails:(const MTFinger *)f count:(int)n now:(double)now {
    if (gFrozenTime > 0) return;
    for (int i = 0; i < n; i++) {
        RGTrail *tr = NULL;
        for (int k = 0; k < MAX_TOUCHES; k++) if (trails[k].count && trails[k].fid == f[i].identifier) { tr = &trails[k]; break; }
        if (!tr) for (int k = 0; k < MAX_TOUCHES; k++) if (!trails[k].count) { tr = &trails[k]; tr->fid = f[i].identifier; break; }
        if (!tr) continue;
        float x = f[i].normalized.pos.x, y = f[i].normalized.pos.y;
        if (tr->count && fabsf(x - tr->x[tr->count - 1]) < 0.001f && fabsf(y - tr->y[tr->count - 1]) < 0.001f) {
            tr->t[tr->count - 1] = now;   // resting finger: keep the head fresh without growing the tail
            continue;
        }
        if (tr->count == TRAIL_LEN) {
            memmove(tr->x, tr->x + 1, sizeof(float) * (TRAIL_LEN - 1));
            memmove(tr->y, tr->y + 1, sizeof(float) * (TRAIL_LEN - 1));
            memmove(tr->t, tr->t + 1, sizeof(double) * (TRAIL_LEN - 1));
            tr->count--;
        }
        tr->x[tr->count] = x; tr->y[tr->count] = y; tr->t[tr->count] = now;
        tr->count++;
    }
    for (int k = 0; k < MAX_TOUCHES; k++) {
        RGTrail *tr = &trails[k];
        int drop = 0;
        while (drop < tr->count && now - tr->t[drop] > TRAIL_LIFE) drop++;
        if (!drop) continue;
        tr->count -= drop;
        memmove(tr->x, tr->x + drop, sizeof(float) * (size_t)tr->count);
        memmove(tr->y, tr->y + drop, sizeof(float) * (size_t)tr->count);
        memmove(tr->t, tr->t + drop, sizeof(double) * (size_t)tr->count);
    }
}

- (BOOL)isAnimatingAt:(double)now {
    for (int k = 0; k < MAX_PINGS; k++) if (pings[k].start > 0 && now - pings[k].start < PING_LIFE) return YES;
    for (int k = 0; k < MAX_TOUCHES; k++) if (trails[k].count > 1) return YES;
    return NO;
}
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

NSBezierPath *RGSurfacePath(int kind, NSRect rect) { return surfacePath((RGKind)kind, rect); }
void RGDrawSurface(int kind, NSRect rect, BOOL darkTop) { drawSurface((RGKind)kind, rect, darkTop ? kDarkStyle : kLightStyle); }

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
#define KB_H      96.0    // a keyboard tile

@class RGView;

@interface RGController : NSObject <NSApplicationDelegate, NSToolbarDelegate> {
@public
    double hidPending[4], evtPending[4];
    __strong RGDevice *hidPendingDevice[4], *evtToucher[4];
    __strong NSString *hidPendingName[4];
    BOOL evtDown[4], anonHidDown[4];
    NSPoint hidPendingPos[4];
    uint64_t hidStamp[4], evtStamp[4];   // kernel HID report time; time the click event reached us
    long delivered[4], remappedTotal, totalDrops;
    double lastDrop;
    NSString *statusLine;
    NSMutableArray<NSString *> *lines;
    CFMachPortRef tap;
    IOHIDManagerRef hid;
    BOOL tapOK, hidOK;
    CFMutableArrayRef mtList;
    IONotificationPortRef notifyPort;
    io_iterator_t addIter, removeIter, kbAddIter, kbRemoveIter;
    int statusTicks;
    BOOL lidIsClosed;
}
@property (strong) NSWindow *window, *settingsWindow;
@property (strong) RGHelp *help;
@property (strong) RGView *view;
@property (strong) NSView *toast;
@property (strong) NSTextField *toastLabel;
@property (strong) RGCheeseStack *game;
@property (strong) RGGestureTrainer *trainer;
@property (strong) RGForceSensor *forceSensor;
@property (strong) RGLatencyMonitor *monitor;
@property (strong) RGSelfTest *selfTest;
@property (strong) RGKeyboardTester *keyboardTester;
@property (copy) NSArray<NSDictionary *> *keyboards;   // Apple keyboards, with battery from the power sources
@property (strong) RGBluetoothMonitor *bluetooth;
@property (strong) NSButton *bluetoothCheckbox;
@property (strong) NSTextField *bluetoothNote;
@property (strong) NSButton *bluetoothPrivacy;
@property (strong) NSGridRow *bluetoothPrivacyRow;
@property (strong) NSSlider *divisionSlider;
@property (strong) NSTextField *divisionLabel;
@property (strong) NSButton *divisionReset;
@property (strong) NSTextField *matchLabel;
@property (strong) NSArray<RGDevice *> *devices;
@property (strong) NSMutableDictionary *hidCache;
@property (strong) NSMutableDictionary<NSString *, NSString *> *lastSecondary;
@property (strong) NSFileHandle *logFile;
@property (strong) NSDateFormatter *shortFmt, *longFmt;
@property (copy) NSString *snapshotPath, *windowShotsDir;
@property BOOL demo, live;
- (NSArray<RGDevice *> *)visibleDevices;
- (NSArray<NSDictionary *> *)visibleKeyboards;
- (CGFloat)keyboardRowHeight;
- (void)finishName:(NSString *_Nullable *_Nonnull)name swatch:(NSColor *_Nullable *_Nonnull)swatch for:(RGDevice *)d;
- (void)showKeyboardTester:(id)sender;
- (void)refreshKeyboards;
- (RGStyle)styleFor:(RGDevice *)d;
- (NSString *)colourTextFor:(RGDevice *)d;
- (double)matchWindow;
- (CGFloat)topInset;
- (void)hidButton:(int)b down:(BOOL)down device:(IOHIDDeviceRef)h stamp:(uint64_t)stamp;
- (void)event:(int)b down:(BOOL)down stamp:(uint64_t)stamp;
- (void)rescanDevices:(id)sender;
- (void)refreshBatteryAndColour;
- (void)setDivision:(int)percent forDevice:(RGDevice *)d;
@end

#define MIN_DIVISION 35   // limits for the Magic Mouse split, in percent across the mouse
#define MAX_DIVISION 75

static void hidCallback(void *ctx, IOReturn result, void *sender, IOHIDValueRef value) {
    IOHIDElementRef el = IOHIDValueGetElement(value);
    if (IOHIDElementGetUsagePage(el) != kHIDPage_Button) return;
    uint32_t usage = IOHIDElementGetUsage(el);
    if (usage < 1 || usage > 3) return;
    [(__bridge RGController *)ctx hidButton:(int)usage down:IOHIDValueGetIntegerValue(value) != 0 device:IOHIDElementGetDevice(el)
                                      stamp:IOHIDValueGetTimeStamp(value)];
}

static CGEventRef tapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef ev, void *ctx) {
    RGController *c = (__bridge RGController *)ctx;
    uint64_t now = mach_absolute_time();   // when the click reached the session, i.e. when apps can see it
    switch (type) {
        case kCGEventTapDisabledByTimeout:
        case kCGEventTapDisabledByUserInput: CGEventTapEnable(c->tap, true); break;
        case kCGEventLeftMouseDown:  [c event:1 down:YES stamp:now]; break;
        case kCGEventLeftMouseUp:    [c event:1 down:NO stamp:now];  break;
        case kCGEventRightMouseDown: [c event:2 down:YES stamp:now]; break;
        case kCGEventRightMouseUp:   [c event:2 down:NO stamp:now];  break;
        case kCGEventOtherMouseDown: [c event:3 down:YES stamp:now]; break;
        case kCGEventOtherMouseUp:   [c event:3 down:NO stamp:now];  break;
        default: break;
    }
    return ev;
}

static void powerSourcesChanged(void *context) { [(__bridge RGController *)context refreshBatteryAndColour]; }

static void keyboardsChangedCallback(void *refcon, io_iterator_t it) {
    io_object_t o;
    while ((o = IOIteratorNext(it))) IOObjectRelease(o);
    RGController *c = (__bridge RGController *)refcon;
    [NSObject cancelPreviousPerformRequestsWithTarget:c selector:@selector(refreshKeyboards) object:nil];
    [c performSelector:@selector(refreshKeyboards) withObject:nil afterDelay:1.0];   // let the registry fill in
}

static void devicesChangedCallback(void *refcon, io_iterator_t it) {
    io_object_t o;
    while ((o = IOIteratorNext(it))) IOObjectRelease(o);
    RGController *c = (__bridge RGController *)refcon;
    [NSObject cancelPreviousPerformRequestsWithTarget:c selector:@selector(rescanDevices:) object:nil];
    [c performSelector:@selector(rescanDevices:) withObject:nil afterDelay:1.5];
}

#pragma mark - Main view

static NSString *transportSymbol(NSString *transport) {
    if ([transport isEqual:@"Bluetooth"] || [transport hasPrefix:@"Bluetooth"]) return @"antenna.radiowaves.left.and.right";
    if ([transport isEqual:@"USB"]) return @"cable.connector";
    return @"laptopcomputer";
}

// A small capsule with an SF Symbol (or a colour swatch) and a label. Returns the width it took,
// including spacing, or 0 if it wouldn't fit before maxX.
static CGFloat drawChip(NSString *symbol, NSString *label, NSColor *swatch, CGFloat x, CGFloat y, CGFloat maxX) {
    NSFont *f = [NSFont systemFontOfSize:11 weight:NSFontWeightMedium];
    CGFloat tw = ceil([label sizeWithAttributes:@{NSFontAttributeName: f}].width);
    NSImage *img = nil;
    if (symbol && !swatch) {
        NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:10 weight:NSFontWeightMedium]
            configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:NSColor.secondaryLabelColor]];
        img = [RGSymbol(symbol, label) imageWithSymbolConfiguration:cfg];
    }
    CGFloat iw = swatch ? 10 : img ? img.size.width : 0;
    CGFloat w = 8 + (iw > 0 ? iw + 5 : 0) + tw + 9;
    if (x + w > maxX) return 0;
    NSRect r = NSMakeRect(x, y, w, 20);
    [[NSColor.labelColor colorWithAlphaComponent:0.07] setFill];
    [[NSBezierPath bezierPathWithRoundedRect:r xRadius:10 yRadius:10] fill];
    CGFloat ix = x + 8;
    if (swatch) {
        NSBezierPath *dot = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(ix, y + 5, 10, 10)];
        [swatch setFill];
        [dot fill];
        dot.lineWidth = 0.75;
        [[NSColor.labelColor colorWithAlphaComponent:0.3] setStroke];
        [dot stroke];
    } else if (img) {
        [img drawInRect:NSMakeRect(ix, y + 10 - img.size.height / 2, img.size.width, img.size.height) fromRect:NSZeroRect
              operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    RGDrawText(label, NSMakeRect(ix + (iw > 0 ? iw + 5 : 0), y + 3, tw + 2, 15), f, NSColor.labelColor, NSTextAlignmentLeft);
    return w + 6;
}

@interface RGView : NSView
@property (weak) RGController *c;
@property (strong) CADisplayLink *link;
@property (strong) RGDevice *dragging;   // a Magic Mouse whose split line is being dragged
@end

@implementation RGView

- (BOOL)isFlipped { return YES; }

#pragma mark Dragging the Magic Mouse split

- (BOOL)hasDraggableSplit:(RGDevice *)d {
    return d->kind == RGKindMouse && d.secondaryZone != 0 && !NSIsEmptyRect(d->surfaceRect) && !self.c.demo;
}

- (CGFloat)splitXFor:(RGDevice *)d {
    NSRect s = d->surfaceRect;
    return s.origin.x + s.size.width * (d.secondaryZone == 1 ? d.division : 1 - d.division);
}

- (void)resetCursorRects {
    for (NSUInteger i = 0; i < self.c.visibleKeyboards.count; i++)
        [self addCursorRect:[self keyboardRect:i] cursor:NSCursor.pointingHandCursor];
    for (RGDevice *d in self.c.visibleDevices)
        if ([self hasDraggableSplit:d])
            [self addCursorRect:NSMakeRect([self splitXFor:d] - 7, d->surfaceRect.origin.y, 14, d->surfaceRect.size.height)
                         cursor:NSCursor.resizeLeftRightCursor];
}

- (void)mouseDown:(NSEvent *)e {
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSArray<NSDictionary *> *kbs = self.c.visibleKeyboards;
    for (NSUInteger i = 0; i < kbs.count; i++)
        if (NSPointInRect(p, [self keyboardRect:i])) { [self.c showKeyboardTester:kbs[i][@"key"]]; return; }
    for (RGDevice *d in self.c.visibleDevices) {
        if (![self hasDraggableSplit:d]) continue;
        if (fabs(p.x - [self splitXFor:d]) <= 7 && NSMinY(d->surfaceRect) <= p.y && p.y <= NSMaxY(d->surfaceRect)) {
            self.dragging = d;
            d->dragDivision = d.division;
            self.needsDisplay = YES;
            return;
        }
    }
}

- (void)mouseDragged:(NSEvent *)e {
    RGDevice *d = self.dragging;
    if (!d) return;
    NSPoint p = [self convertPoint:e.locationInWindow fromView:nil];
    NSRect s = d->surfaceRect;
    float across = (float)((p.x - s.origin.x) / s.size.width);
    float div = d.secondaryZone == 1 ? across : 1 - across;
    d->dragDivision = MAX(MIN_DIVISION, MIN(MAX_DIVISION, lroundf(div * 100))) / 100.0f;
    self.needsDisplay = YES;
}

- (void)mouseUp:(NSEvent *)e {
    RGDevice *d = self.dragging;
    if (!d) return;
    self.dragging = nil;
    int percent = (int)lroundf(d->dragDivision * 100);
    [self.c setDivision:percent forDevice:d];
    d->dragDivision = 0;
    [self.window invalidateCursorRectsForView:self];
    self.needsDisplay = YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && !self.link) {
        self.link = [self displayLinkWithTarget:self selector:@selector(frame:)];
        [self.link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    } else if (!self.window) {
        [self.link invalidate];
        self.link = nil;
    }
}

- (void)frame:(CADisplayLink *)link {
    double now = animNow();
    MTFinger t[MAX_TOUCHES];
    for (RGDevice *d in self.c.visibleDevices)
        if (RGCopyTouches(d->slot, t) > 0 || [d isAnimatingAt:now]) { self.needsDisplay = YES; return; }
}

- (NSRect)cardRect:(NSUInteger)i {
    return NSMakeRect(MARGIN + i * (CARD_W + MARGIN), self.c.topInset + 12, CARD_W, CARD_H);
}
- (NSRect)keyboardRect:(NSUInteger)i {
    NSUInteger n = MAX(1, self.c.visibleKeyboards.count);
    CGFloat w = (self.bounds.size.width - (n + 1) * MARGIN) / n;
    return NSMakeRect(MARGIN + i * (w + MARGIN), self.c.topInset + 12 + CARD_H + MARGIN, w, KB_H);
}
- (NSRect)deliveredRect {
    return NSMakeRect(MARGIN, self.c.topInset + 12 + CARD_H + MARGIN + self.c.keyboardRowHeight, self.bounds.size.width - 2 * MARGIN, DELIVER_H);
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
    NSArray<NSDictionary *> *kbs = c.visibleKeyboards;
    for (NSUInteger i = 0; i < kbs.count; i++) [self drawKeyboard:kbs[i] in:[self keyboardRect:i]];
    [self drawDelivered:self.deliveredRect];
    [self drawLog:self.logRect];
}

- (void)drawCard:(RGDevice *)d in:(NSRect)card {
    RGController *c = self.c;
    RGDrawCard(card, 16);
    CGFloat x = card.origin.x + 16, y = card.origin.y, iw = card.size.width - 32;
    NSString *title = c.demo ? (d->kind == RGKindMouse ? @"Magic Mouse" : @"Magic Trackpad") : d.name;
    CGFloat headW = d->battery >= 0 ? iw - 96 : iw;
    RGDrawText(title, NSMakeRect(x, y + 14, headW, 20), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    NSString *sub = d.model;
    RGDrawText(sub, NSMakeRect(x, y + 35, headW, 16), [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    if (d->battery >= 0) [self drawBattery:d topRight:NSMakePoint(x + iw, y + 14)];

    // Surface, drawn at the sensor's real aspect ratio
    NSRect area = NSMakeRect(x + 6, y + 62, iw - 12, 190);
    double aspect = (d->widthMM > 0 && d->heightMM > 0) ? d->widthMM / d->heightMM : (d->kind == RGKindMouse ? 0.57 : 1.41);
    NSSize sz = (area.size.width / area.size.height > aspect) ? NSMakeSize(area.size.height * aspect, area.size.height)
                                                              : NSMakeSize(area.size.width, area.size.width / aspect);
    NSRect s = NSMakeRect(round(NSMidX(area) - sz.width / 2), round(NSMidY(area) - sz.height / 2), round(sz.width), round(sz.height));
    RGStyle style = [c styleFor:d];
    if (!NSEqualRects(d->surfaceRect, s)) { d->surfaceRect = s; [self.window invalidateCursorRectsForView:self]; }
    drawSurface(d->kind, s, style);
    [self drawZones:d surface:s dark:style.darkTop];
    [self drawTouches:d surface:s];
    if (d->kind == RGKindBuiltIn && c->lidIsClosed) {
        NSBezierPath *veil = surfacePath(d->kind, s);
        [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.72] setFill];
        [veil fill];
        RGDrawText(@"Lid closed", NSMakeRect(s.origin.x, NSMidY(s) - 18, s.size.width, 20),
                   [NSFont systemFontOfSize:14 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentCenter);
        RGDrawText(@"Open the lid to use this trackpad", NSMakeRect(s.origin.x, NSMidY(s) + 4, s.size.width, 16),
                   [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentCenter);
    }

    // What the hardware reports
    CGFloat ly = y + 266, lw = (iw - 56 - 8) / 2;
    text(@"Sends", x, ly + 7, [NSFont systemFontOfSize:12 weight:NSFontWeightMedium], NSColor.secondaryLabelColor);
    RGDrawLight(NSMakeRect(x + 56, ly, lw, 30), @"Left", d->hidDown[1], NSColor.systemGreenColor);
    RGDrawLight(NSMakeRect(x + 56 + lw + 8, ly, lw, 30), @"Right", d->hidDown[2], NSColor.systemGreenColor);

    // Hardware at a glance: firmware, connection (with signal when monitored) and finish
    CGFloat cx = x, cy = ly + 40;
    if (d.firmware) cx += drawChip(@"cpu", d.firmware, nil, cx, cy, x + iw);
    if (d.transport) cx += drawChip(transportSymbol(d.transport),
                                    d->rssi ? [NSString stringWithFormat:@"%@ · %d dBm", d.transport, d->rssi] : d.transport, nil, cx, cy, x + iw);
    NSString *finish = nil;
    NSColor *swatch = nil;
    [c finishName:&finish swatch:&swatch for:d];
    if (finish) cx += drawChip(nil, finish, swatch, cx, cy, x + iw);

    // The settings the driver is applying, as a small table
    NSMutableArray *rows = [d.settingsRows mutableCopy];
    if (d.identifier.length && !c.demo)
        [rows addObject:@[[d.transport isEqual:@"Bluetooth"] ? @"Address" : @"Serial", d.identifier, @NO, @YES]];
    CGFloat ty = cy + 28;
    for (NSArray *r in rows) {
        BOOL warn = [r[2] boolValue], mono = r.count > 3;
        RGDrawText(r[0], NSMakeRect(x, ty, 66, 15), [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        NSFont *vf = warn ? [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold]
                   : mono ? [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular] : [NSFont systemFontOfSize:11];
        RGDrawText(r[1], NSMakeRect(x + 70, ty, iw - 70, 15), vf, warn ? NSColor.systemOrangeColor : NSColor.labelColor, NSTextAlignmentLeft);
        ty += 16;
    }
    NSFont *mono = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightRegular];
    CGFloat fy = card.origin.y + CARD_H - 22;
    [[NSColor.separatorColor colorWithAlphaComponent:0.6] setFill];
    NSRectFillUsingOperation(NSMakeRect(x, fy - 6, iw, 1), NSCompositingOperationSourceOver);
    text([NSString stringWithFormat:@"Sent  L %ld  R %ld", d->sent[1], d->sent[2]], x, fy, mono, NSColor.labelColor);
    long drops = d->dropped[1] + d->dropped[2] + d->dropped[3];
    rtext([NSString stringWithFormat:@"Dropped  L %ld  R %ld", d->dropped[1], d->dropped[2]], x + iw, fy,
          drops ? [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold] : mono, drops ? NSColor.systemRedColor : NSColor.labelColor);
}

// A keyboard tile: a small drawing, name and model, connection details, battery, and a way into
// the Keyboard Tester (clicking anywhere on the tile opens it).
- (void)drawKeyboard:(NSDictionary *)k in:(NSRect)t {
    RGController *c = self.c;
    RGDrawCard(t, 16);
    CGFloat x = t.origin.x + 16, y = t.origin.y, right = NSMaxX(t) - 16;
    BOOL builtIn = [k[@"builtIn"] boolValue], lidShut = builtIn && c->lidIsClosed;
    if (t.size.width >= 420) {
        NSRect thumb = NSMakeRect(x, y + 14, 150, KB_H - 28);
        RGDrawKeyboardThumbnail(k, thumb);
        if (lidShut) {
            [[NSColor.windowBackgroundColor colorWithAlphaComponent:0.7] setFill];
            NSRectFillUsingOperation(thumb, NSCompositingOperationSourceOver);
        }
        x += 168;
    }
    BOOL hasBattery = k[@"battery"] != nil;
    CGFloat textW = right - x - (hasBattery || lidShut ? 104 : 0);
    RGDrawText(k[@"name"] ?: @"Keyboard", NSMakeRect(x, y + 14, textW, 20), [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold],
               NSColor.labelColor, NSTextAlignmentLeft);
    NSString *model = k[@"years"] ? [NSString stringWithFormat:@"%@ · %@", k[@"model"], k[@"years"]] : k[@"model"];
    RGDrawText(model ?: @"", NSMakeRect(x, y + 35, textW, 16), [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    NSString *link = @"Keyboard Tester ⌘B ›";
    NSFont *lf = [NSFont systemFontOfSize:12 weight:NSFontWeightMedium];
    CGFloat lw = [link sizeWithAttributes:@{NSFontAttributeName: lf}].width + 2;
    CGFloat cx = x, cy = y + KB_H - 32;
    if (k[@"firmware"]) cx += drawChip(@"cpu", k[@"firmware"], nil, cx, cy, right - lw - 12);
    if (k[@"transport"]) cx += drawChip(transportSymbol(k[@"transport"]), k[@"transport"], nil, cx, cy, right - lw - 12);
    if (k[@"family"]) {
        static NSString *const families[] = {@"ANSI", @"ISO", @"JIS"};
        cx += drawChip(@"keyboard", families[MAX(0, MIN(2, [k[@"family"] intValue]))], nil, cx, cy, right - lw - 12);
    }
    RGDrawText(link, NSMakeRect(right - lw, cy + 2, lw, 16), lf, NSColor.linkColor, NSTextAlignmentRight);
    if (lidShut) {
        RGDrawText(@"Lid closed", NSMakeRect(right - 104, y + 15, 104, 18), [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold],
                   NSColor.secondaryLabelColor, NSTextAlignmentRight);
    } else if (hasBattery) {
        int level = [k[@"battery"] intValue], low = k[@"lowWarn"] ? [k[@"lowWarn"] intValue] : 20;
        BOOL charging = [k[@"charging"] boolValue], onCable = [k[@"onCable"] boolValue];
        [self drawBatteryLevel:level charging:charging onCable:onCable status:k[@"powerStatus"]
                        colour:batteryColourFor(level, charging, onCable, low) topRight:NSMakePoint(right, y + 14)];
    }
}

// Battery glyph (level, with a bolt while charging), percentage and status, right-aligned.
- (void)drawBattery:(RGDevice *)d topRight:(NSPoint)tr {
    [self drawBatteryLevel:d->battery charging:d->charging onCable:d->onCable status:d.powerStatus colour:d.batteryColour topRight:tr];
}

- (void)drawBatteryLevel:(int)level charging:(BOOL)charging onCable:(BOOL)onCable status:(NSString *)status
                  colour:(NSColor *)colour topRight:(NSPoint)tr {
    NSString *symbol = charging ? @"battery.100percent.bolt"
                     : level >= 88 ? @"battery.100percent" : level >= 63 ? @"battery.75percent"
                     : level >= 38 ? @"battery.50percent" : level >= 13 ? @"battery.25percent" : @"battery.0percent";
    NSImageSymbolConfiguration *cfg = [[NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithHierarchicalColor:colour]];
    NSImage *img = [RGSymbol(symbol, status ?: @"Battery") imageWithSymbolConfiguration:cfg];
    NSFont *pctFont = [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightSemibold];
    NSString *pct = [NSString stringWithFormat:@"%d%%", level];
    CGFloat pw = [pct sizeWithAttributes:@{NSFontAttributeName: pctFont}].width;
    NSSize is = img.size;
    NSRect imgRect = NSMakeRect(tr.x - is.width, tr.y + 10 - is.height / 2, is.width, is.height);
    [img drawInRect:imgRect fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    RGDrawText(pct, NSMakeRect(imgRect.origin.x - pw - 6, tr.y + 1, pw + 2, 18), pctFont,
               charging || level > 20 ? NSColor.labelColor : colour, NSTextAlignmentRight);
    RGDrawText(status ?: @"", NSMakeRect(tr.x - 96, tr.y + 21, 96, 15), [NSFont systemFontOfSize:11],
               charging || onCable ? NSColor.systemGreenColor : (level <= 20 ? colour : NSColor.secondaryLabelColor), NSTextAlignmentRight);
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
            // A grab handle: the split can be dragged
            BOOL dragging = d->dragDivision > 0;
            NSRect handle = NSMakeRect(splitX - 4.5, s.origin.y + s.size.height * 0.30 - 14, 9, 28);
            [NSGraphicsContext saveGraphicsState];
            NSShadow *sh = [NSShadow new];
            sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.3];
            sh.shadowBlurRadius = 3;
            sh.shadowOffset = NSMakeSize(0, -1);
            [sh set];
            [(dragging ? accent : NSColor.whiteColor) setFill];
            [[NSBezierPath bezierPathWithRoundedRect:handle xRadius:4.5 yRadius:4.5] fill];
            [NSGraphicsContext restoreGraphicsState];
            NSBezierPath *rim = [NSBezierPath bezierPathWithRoundedRect:NSInsetRect(handle, 0.5, 0.5) xRadius:4 yRadius:4];
            rim.lineWidth = 1;
            [accent setStroke];
            [rim stroke];
            if (dragging) {
                NSString *pct = [NSString stringWithFormat:@"%d%%", (int)lroundf(div * 100)];
                NSFont *pf = [NSFont monospacedDigitSystemFontOfSize:11 weight:NSFontWeightBold];
                CGFloat pw = [pct sizeWithAttributes:@{NSFontAttributeName: pf}].width + 14;
                NSRect tag = NSMakeRect(splitX - pw / 2, handle.origin.y - 24, pw, 18);
                [accent setFill];
                [[NSBezierPath bezierPathWithRoundedRect:tag xRadius:9 yRadius:9] fill];
                centred(pct, NSInsetRect(tag, 0, 2), pf, NSColor.whiteColor);
            }
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

// Is a contact at (x, y) in this device's secondary-click area right now?
static BOOL inSecondary(RGDevice *d, float x, float y, int fingers) {
    int z = d.secondaryZone;
    float div = d.division;
    if (d->kind == RGKindMouse) return (z == 1 && x >= div) || (z == 2 && x <= 1 - div);
    if (z == 1) return fingers >= 2;
    if (z >= 2) return y <= 0.28f && (z == 2 ? x >= 0.75f : x <= 0.25f);
    return NO;
}

static NSColor *pingColour(int kind) {
    return kind == 3 ? NSColor.systemRedColor : kind == 2 ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
}

static double easeOutCubic(double t) { return 1 - pow(1 - t, 3); }

- (void)drawTouches:(RGDevice *)d surface:(NSRect)s {
    double now = animNow();
    MTFinger t[MAX_TOUCHES];
    int n = RGCopyTouches(d->slot, t);
    [d updateTrails:t count:n now:now];
    CGFloat scale = MIN(s.size.width, s.size.height);
    CGFloat dotR = MAX(7, scale * 0.045);
    NSPoint (^toView)(float, float) = ^NSPoint(float x, float y) {
        return NSMakePoint(s.origin.x + x * s.size.width, s.origin.y + (1 - y) * s.size.height);
    };
    CGContextRef ctx = NSGraphicsContext.currentContext.CGContext;

    [NSGraphicsContext saveGraphicsState];
    [surfacePath(d->kind, NSInsetRect(s, -2, -2)) addClip];

    // Trails: tapered, fading, with a soft glow in the finger's colour
    for (int k = 0; k < MAX_TOUCHES; k++) {
        RGTrail *tr = &d->trails[k];
        if (tr->count < 2) continue;
        NSColor *c = inSecondary(d, tr->x[tr->count - 1], tr->y[tr->count - 1], n) ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 9, [c colorWithAlphaComponent:0.6].CGColor);
        CGContextBeginTransparencyLayer(ctx, NULL);
        for (int i = 1; i < tr->count; i++) {
            double life = 1 - (now - tr->t[i]) / TRAIL_LIFE;
            if (life <= 0) continue;
            CGFloat along = (CGFloat)i / (tr->count - 1);
            NSBezierPath *seg = [NSBezierPath bezierPath];
            [seg moveToPoint:toView(tr->x[i - 1], tr->y[i - 1])];
            [seg lineToPoint:toView(tr->x[i], tr->y[i])];
            seg.lineWidth = 1 + along * dotR * 1.25;
            seg.lineCapStyle = i == tr->count - 1 ? NSLineCapStyleRound : NSLineCapStyleButt;
            [[c colorWithAlphaComponent:0.9 * life * (0.15 + 0.85 * along)] setStroke];
            [seg stroke];
        }
        CGContextEndTransparencyLayer(ctx);
        CGContextRestoreGState(ctx);
    }

    // Pings: an eased double ripple with a bright core; dropped clicks get a red ✕
    BOOL reduce = RGReduceMotion();
    CGFloat reach = scale * 0.32;
    for (int k = 0; k < MAX_PINGS; k++) {
        RGPing *pg = &d->pings[k];
        double age = now - pg->start;
        if (pg->start <= 0 || age < 0 || age > PING_LIFE) continue;
        double tt = age / PING_LIFE, e = easeOutCubic(tt);
        NSColor *c = pingColour(pg->kind);
        NSPoint centre = toView(pg->x, pg->y);
        if (reduce) {
            CGFloat r = reach * 0.45;
            [[c colorWithAlphaComponent:0.45 * (1 - tt)] setFill];
            [[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x - r, centre.y - r, 2 * r, 2 * r)] fill];
        } else {
            CGContextSaveGState(ctx);
            CGContextSetShadowWithColor(ctx, CGSizeZero, 12, [c colorWithAlphaComponent:0.7].CGColor);
            for (int ring = 0; ring < 2; ring++) {
                double rt = (age - ring * 0.11) / PING_LIFE;
                if (rt <= 0) continue;
                double re = easeOutCubic(MIN(1, rt));
                CGFloat r = dotR * 0.8 + reach * (ring ? 0.7 : 1.0) * re;
                NSBezierPath *ringPath = [NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x - r, centre.y - r, 2 * r, 2 * r)];
                ringPath.lineWidth = (ring ? 1.5 : 3.0) * (1 - re) + 0.75;
                [[c colorWithAlphaComponent:(ring ? 0.55 : 0.95) * pow(1 - MIN(1, rt), 1.6)] setStroke];
                [ringPath stroke];
            }
            CGFloat core = dotR * (1.1 - 0.6 * e);
            NSGradient *glow = [[NSGradient alloc] initWithStartingColor:[blend(c, NSColor.whiteColor, 0.6) colorWithAlphaComponent:pow(1 - tt, 2)]
                                                             endingColor:[c colorWithAlphaComponent:0]];
            [glow drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:NSMakeRect(centre.x - core * 2, centre.y - core * 2, core * 4, core * 4)]
                relativeCenterPosition:NSZeroPoint];
            CGContextRestoreGState(ctx);
        }
        if (pg->kind == 3) {
            CGFloat x = dotR * 0.7;
            NSBezierPath *cross = [NSBezierPath bezierPath];
            [cross moveToPoint:NSMakePoint(centre.x - x, centre.y - x)];
            [cross lineToPoint:NSMakePoint(centre.x + x, centre.y + x)];
            [cross moveToPoint:NSMakePoint(centre.x + x, centre.y - x)];
            [cross lineToPoint:NSMakePoint(centre.x - x, centre.y + x)];
            cross.lineWidth = 2.5;
            cross.lineCapStyle = NSLineCapStyleRound;
            [[NSColor.systemRedColor colorWithAlphaComponent:1 - tt] setStroke];
            [cross stroke];
        }
    }

    // Fingers: a lit bead with a glow and a fine rim
    for (int i = 0; i < n; i++) {
        float tx = t[i].normalized.pos.x, ty = t[i].normalized.pos.y;
        NSPoint p = toView(tx, ty);
        NSColor *c = inSecondary(d, tx, ty, n) ? NSColor.systemOrangeColor : NSColor.systemBlueColor;
        CGFloat r = dotR + MIN(t[i].size, 2.5f) * dotR * 0.25;
        NSRect dot = NSMakeRect(p.x - r, p.y - r, 2 * r, 2 * r);
        CGContextSaveGState(ctx);
        CGContextSetShadowWithColor(ctx, CGSizeZero, 14, [c colorWithAlphaComponent:0.75].CGColor);
        [c setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
        CGContextRestoreGState(ctx);
        NSGradient *bead = [[NSGradient alloc] initWithStartingColor:blend(c, NSColor.whiteColor, 0.55) endingColor:c];
        [bead drawInBezierPath:[NSBezierPath bezierPathWithOvalInRect:dot] relativeCenterPosition:NSMakePoint(-0.3, -0.35)];
        NSBezierPath *rim = [NSBezierPath bezierPathWithOvalInRect:NSInsetRect(dot, 0.6, 0.6)];
        rim.lineWidth = 1.2;
        [[NSColor colorWithWhite:1 alpha:0.75] setStroke];
        [rim stroke];
    }
    [NSGraphicsContext restoreGraphicsState];
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
        NSString *battery = d->battery >= 0 ? [NSString stringWithFormat:@" Battery %d percent, %@.", d->battery, d.powerStatus.lowercaseString] : @"";
        NSString *label = [NSString stringWithFormat:@"%@, %@.%@ Sending %@. %@. %@. Sent %ld left and %ld right clicks, dropped %ld.",
                           d.name, d.model, battery,
                           d->hidDown[1] ? @"left" : d->hidDown[2] ? @"right" : @"nothing",
                           [d.settingsLines componentsJoinedByString:@". "], [c colourTextFor:d],
                           d->sent[1], d->sent[2], d->dropped[1] + d->dropped[2]];
        [a addObject:[self element:label frame:[self cardRect:i]]];
    }
    NSArray<NSDictionary *> *kbs = c.visibleKeyboards;
    for (NSUInteger i = 0; i < kbs.count; i++) {
        NSDictionary *k = kbs[i];
        NSString *battery = k[@"battery"] ? [NSString stringWithFormat:@" Battery %@ percent, %@.", k[@"battery"], [k[@"powerStatus"] lowercaseString] ?: @""] : @"";
        [a addObject:[self element:[NSString stringWithFormat:@"%@, %@.%@ Click to open the Keyboard Tester.", k[@"name"], k[@"model"], battery]
                             frame:[self keyboardRect:i]]];
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
                *const kTBTrainer = @"gestureTrainer", *const kTBForce = @"forceSensor", *const kTBReset = @"resetCounters",
                *const kTBMonitor = @"latencyMonitor", *const kTBSelfTest = @"selfTest", *const kTBKeyboard = @"keyboardTester";

@implementation RGController

+ (void)initialize {
    [NSUserDefaults.standardUserDefaults registerDefaults:@{
        kKeepOnTop: @NO, kBuiltInMode: @0, kDropSound: @YES, kLogAll: @YES, kMatchMs: @400, kFinishes: @{}, kBluetooth: @NO}];
}

- (double)matchWindow { return MAX(100, [NSUserDefaults.standardUserDefaults integerForKey:kMatchMs]) / 1000.0; }

- (BOOL)showBuiltIn {
    NSInteger mode = [NSUserDefaults.standardUserDefaults integerForKey:kBuiltInMode];
    return mode == 1 || (mode == 0 && !lidIsClosed);
}

- (NSArray<RGDevice *> *)visibleDevices {
    BOOL showBuiltIn = self.showBuiltIn && !self.demo;
    NSMutableArray *a = [NSMutableArray array];
    for (RGDevice *d in self.devices) if (d->kind != RGKindBuiltIn || showBuiltIn) [a addObject:d];
    return a;
}

// Apple keyboards to show: the built-in one follows the same lid rule as the built-in trackpad.
- (NSArray<NSDictionary *> *)visibleKeyboards {
    BOOL showBuiltIn = self.showBuiltIn && !self.demo;
    NSMutableArray *a = [NSMutableArray array];
    for (NSDictionary *k in self.keyboards) if (![k[@"builtIn"] boolValue] || showBuiltIn) [a addObject:k];
    return a;
}

- (CGFloat)keyboardRowHeight { return self.visibleKeyboards.count ? KB_H + MARGIN : 0; }

// Re-reads the keyboards and their batteries, logging connects, disconnects and charging changes.
- (void)refreshKeyboards {
    NSArray *list;
    if (self.demo) {
        list = @[@{@"name": @"Magic Keyboard", @"key": @"demo-keyboard", @"model": @"Magic Keyboard with Touch ID", @"years": @"2021",
                   @"layout": @"compact_%@_2021", @"family": @0, @"topKey": @"touchid", @"globe": @YES, @"transport": @"Bluetooth",
                   @"firmware": @"2.0.6", @"battery": @91, @"powerStatus": @"On battery", @"builtIn": @NO}];
    } else {
        NSDictionary *power = accessoryPowerSources();
        NSMutableArray *m = [NSMutableArray array];
        for (NSDictionary *k in RGConnectedKeyboards(NO)) {
            NSMutableDictionary *d = [k mutableCopy];
            NSDictionary *ps = [k[@"builtIn"] boolValue] ? nil
                : (k[@"serial"] ? power[[@"id:" stringByAppendingString:[k[@"serial"] uppercaseString]]] : nil) ?: power[[@"name:" stringByAppendingString:k[@"name"]]];
            int level = k[@"battery"] ? [k[@"battery"] intValue] : -1, low = 20;
            BOOL charging = NO, charged = NO, onCable = NO;
            if (ps) {
                level = [ps[@"Current Capacity"] intValue];
                charging = [ps[@"Is Charging"] boolValue];
                charged = [ps[@"Is Charged"] boolValue];
                onCable = [ps[@"Power Source State"] isEqual:@"AC Power"];
                if (ps[@"Low Warn Level"]) low = [ps[@"Low Warn Level"] intValue];
            }
            if (level >= 0) {
                d[@"battery"] = @(level);
                d[@"charging"] = @(charging);
                d[@"onCable"] = @(onCable);
                d[@"lowWarn"] = @(low);
                d[@"powerStatus"] = powerStatusText(level, charging, charged, onCable, low);
            }
            [m addObject:d];
        }
        list = m;
    }
    if (self.live && self.keyboards) {
        NSMutableDictionary *before = [NSMutableDictionary dictionary], *after = [NSMutableDictionary dictionary];
        for (NSDictionary *k in self.keyboards) if (![k[@"builtIn"] boolValue]) before[k[@"key"]] = k;
        for (NSDictionary *k in list) if (![k[@"builtIn"] boolValue]) after[k[@"key"]] = k;
        for (NSString *key in before) if (!after[key]) [self log:[NSString stringWithFormat:@"· %@ disconnected", before[key][@"name"]]];
        for (NSString *key in after) {
            NSDictionary *b = before[key], *a = after[key];
            if (!b) [self log:[NSString stringWithFormat:@"· %@ connected", a[@"name"]]];
            else if (b[@"powerStatus"] && a[@"powerStatus"] && ![b[@"powerStatus"] isEqual:a[@"powerStatus"]])
                [self log:[NSString stringWithFormat:@"· %@: %@ (%@%%)", a[@"name"], [a[@"powerStatus"] lowercaseString], a[@"battery"]]];
        }
    }
    NSUInteger shown = self.visibleKeyboards.count;
    self.keyboards = list;
    if (self.visibleKeyboards.count != shown) [self relayout];
    else self.view.needsDisplay = YES;
}

// The colour name and a swatch for the card's finish chip.
- (void)finishName:(NSString **)name swatch:(NSColor **)swatch for:(RGDevice *)d {
    *name = nil;
    *swatch = nil;
    if (d->colorID < 0) return;
    NSString *override = [self finishOverrideFor:d];
    RGStyle style = [self styleFor:d];
    *swatch = style.darkTop ? rgb(0.22, 0.22, 0.24) : rgb(style.rimR, style.rimG, style.rimB);
    if (override) { *name = [override isEqualToString:@"black"] ? @"Black" : @"White"; return; }
    const RGColour *c = colourForCode(d->colorID);
    *name = c ? [c->name componentsSeparatedByString:@" / "].firstObject : [NSString stringWithFormat:@"Colour %d", d->colorID];
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
    lidIsClosed = lidClosed();
    self.hidCache = [NSMutableDictionary dictionary];
    self.lastSecondary = [NSMutableDictionary dictionary];
    self.shortFmt = [NSDateFormatter new];
    self.shortFmt.dateFormat = @"HH:mm:ss";
    self.longFmt = [NSDateFormatter new];
    self.longFmt.dateFormat = @"yyyy-MM-dd HH:mm:ss.SSS";
    if (self.live) [self openLogFile];
    self.monitor = [RGLatencyMonitor new];
    __weak RGController *weakSelf = self;
    self.monitor.devices = ^NSArray<NSDictionary *> * { return weakSelf.deviceInfos; };
    self.monitor.bluetoothStatus = ^NSString * { return weakSelf.bluetoothGraphStatus; };
    self.monitor.openSettings = ^{ [weakSelf showSettings:nil]; };
    self.bluetooth = [RGBluetoothMonitor new];
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
        if ([args containsObject:@"--demo-force"]) { self.forceSensor = [RGForceSensor new]; [self.forceSensor showDemo]; }
        if ([args containsObject:@"--demo-latency"]) [self.monitor showDemo];
        if ([args containsObject:@"--demo-selftest"]) { self.selfTest = [RGSelfTest new]; [self.selfTest showDemo]; }
        if (self.windowShotsDir) {
            [self prepareWindowShots];
            [self performSelector:@selector(writeWindowShots) withObject:nil afterDelay:2.0];
        }
    } else {
        [self setupHID];
        [self setupTap];
        [self watchDevices];
        [self.monitor start];
        [self setupBluetooth];
        [self updateStatus];
        [self log:[NSString stringWithFormat:@"· %@ %@ started: button reports %@, click events %@ | %@", APP_NAME, APP_VERSION,
                   hidOK ? @"ok" : @"unavailable", tapOK ? @"ok" : @"unavailable", statusLine]];
        NSArray *args = NSProcessInfo.processInfo.arguments;   // open the Gym straight away, e.g. from a shortcut
        if ([args containsObject:@"--show-trainer"]) [self showTrainer:nil];
        if ([args containsObject:@"--show-game"]) [self showGame:self];
        if ([args containsObject:@"--show-force"]) [self showForce:nil];
        if ([args containsObject:@"--show-latency"]) [self showMonitor:nil];
        if ([args containsObject:@"--show-selftest"]) [self showSelfTest:nil];
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
    [self add:dev title:@"Latency Monitor" action:@selector(showMonitor:) key:@"d" modifiers:0 symbol:@"waveform.path.ecg"];
    [self add:dev title:@"Hardware Self-Test" action:@selector(showSelfTest:) key:@"e" modifiers:0 symbol:@"checkmark.seal"];
    [self add:dev title:@"Keyboard Tester" action:@selector(showKeyboardTester:) key:@"b" modifiers:0 symbol:@"keyboard"];
    [dev addItem:NSMenuItem.separatorItem];
    [self add:dev title:@"Open Log File" action:@selector(openLog:) key:@"l" modifiers:0 symbol:@"doc.text"];

    NSMenu *gym = [self addMenu:@"Gym" to:bar];
    [self add:gym title:@"Cheese Stack" action:@selector(showGame:) key:@"g" modifiers:0 symbol:@"gamecontroller"];
    [self add:gym title:@"Gesture Trainer" action:@selector(showTrainer:) key:@"t" modifiers:0 symbol:@"hand.draw"];
    [self add:gym title:@"Force Sensor" action:@selector(showForce:) key:@"j" modifiers:0 symbol:@"gauge.with.dots.needle.67percent"];

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
        if (self.windowShotsDir) { self.window.alphaValue = 0; self.window.ignoresMouseEvents = YES; }
        [self.window makeKeyAndOrderFront:nil];
    }
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kTBMouse, kTBTrackpad, NSToolbarFlexibleSpaceItemIdentifier, kTBMonitor, kTBSelfTest, kTBKeyboard, NSToolbarSpaceItemIdentifier,
             kTBGame, kTBTrainer, kTBForce, NSToolbarSpaceItemIdentifier, kTBReset];
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
        kTBForce:    @[@"Force Sensor", @"gauge.with.dots.needle.67percent", @"Graph click pressure from a Force Touch trackpad", @"showForce:"],
        kTBMonitor:  @[@"Latency Monitor", @"waveform.path.ecg", @"Graph click latency, touch report rate and Bluetooth signal", @"showMonitor:"],
        kTBSelfTest: @[@"Hardware Self-Test", @"checkmark.seal", @"Test a device for dead zones, phantom touches and a working haptic engine", @"showSelfTest:"],
        kTBKeyboard: @[@"Keyboard Tester", @"keyboard", @"Check every key on a keyboard for dead, chattering or stuck keys", @"showKeyboardTester:"],
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
    CGFloat h = self.topInset + 12 + CARD_H + MARGIN + self.keyboardRowHeight + DELIVER_H + MARGIN + LOG_H + MARGIN;
    NSRect old = self.window.frame;
    NSRect frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h)];
    frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
    [self.window setFrame:frame display:YES];
    // The toolbar height is only final once the window has its size; recompute once.
    CGFloat h2 = self.topInset + 12 + CARD_H + MARGIN + self.keyboardRowHeight + DELIVER_H + MARGIN + LOG_H + MARGIN;
    if (fabs(h2 - h) > 0.5) {
        frame = [self.window frameRectForContentRect:NSMakeRect(0, 0, w, h2)];
        frame.origin = NSMakePoint(old.origin.x, NSMaxY(old) - frame.size.height);
        [self.window setFrame:frame display:YES];
    }
    [self positionToast];
    [self.window invalidateCursorRectsForView:self.view];
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
        self.trainer.devices = ^NSArray<NSDictionary *> * { return weakSelf.deviceInfos; };
        self.trainer.log = ^(NSString *line) { [weakSelf log:line]; };
    }
    [self.trainer show];
    [self applyWindowLevel];
    [self activate];
}

// Devices as plain dictionaries for the Gym and diagnostic windows.
- (NSArray<NSDictionary *> *)deviceInfos {
    NSMutableArray *a = [NSMutableArray array];
    for (RGDevice *d in self.visibleDevices) {
        NSMutableDictionary *m = [@{@"name": d.name, @"key": d.key, @"kind": d->kind == RGKindMouse ? @"mouse" : @"trackpad",
                                    @"builtIn": @(d->kind == RGKindBuiltIn), @"slot": @(d->slot), @"prefs": d.prefs ?: @{},
                                    @"model": d.model ?: @"", @"productID": @(d->productID), @"darkTop": @([self styleFor:d].darkTop),
                                    @"widthMM": @(d->widthMM), @"heightMM": @(d->heightMM)} mutableCopy];
        if (d.firmware) m[@"firmware"] = d.firmware;
        if (d.transport) m[@"transport"] = d.transport;
        if (d.identifier) m[@"serial"] = d.identifier;
        [a addObject:m];
    }
    return a;
}

- (void)showMonitor:(id)sender {
    [self.monitor show];
    [self applyWindowLevel];
    [self activate];
}

- (void)showSelfTest:(id)sender {
    if (!self.selfTest) {
        self.selfTest = [RGSelfTest new];
        __weak RGController *weakSelf = self;
        self.selfTest.devices = ^NSArray<NSDictionary *> * { return weakSelf.deviceInfos; };
        self.selfTest.log = ^(NSString *line) { [weakSelf log:line]; };
        self.selfTest.latencySummary = ^NSString * { return weakSelf.monitor.summary; };
    }
    [self.selfTest show];
    [self applyWindowLevel];
    [self activate];
}

- (void)showKeyboardTester:(id)sender {
    if (!self.keyboardTester) {
        self.keyboardTester = [RGKeyboardTester new];
        __weak RGController *weakSelf = self;
        self.keyboardTester.log = ^(NSString *line) { [weakSelf log:line]; };
        self.keyboardTester.keyboardList = ^NSArray<NSDictionary *> * { return weakSelf.visibleKeyboards; };
    }
    if ([sender isKindOfClass:NSString.class]) [self.keyboardTester showKeyboard:sender];
    else [self.keyboardTester show];
    [self applyWindowLevel];
    [self activate];
}

#pragma mark Magic Mouse split

// The split between the primary and secondary click areas is the driver's MouseButtonDivision
// preference (55% by default). System Settings has no control for it. RodentGym pushes a new
// value to the driver so it applies straight away, and saves it in the mouse preference domains
// so it survives reconnects and restarts. This is the only setting RodentGym ever changes, and
// only when you move the split yourself.
- (void)setDivision:(int)percent forDevice:(RGDevice *)d {
    percent = MAX(MIN_DIVISION, MIN(MAX_DIVISION, percent));
    d->dragDivision = 0;
    int before = intOf(d.prefs[@"MouseButtonDivision"], 55);
    if (percent == before) { [self updateDivisionControls]; self.view.needsDisplay = YES; return; }
    NSNumber *value = @(percent);
    kern_return_t kr = IORegistryEntrySetCFProperties(d->service, (__bridge CFDictionaryRef)@{@"MouseButtonDivision": value});
    NSDictionary *now = regProp(d->service, @"MultitouchPreferences", NO);
    if (intOf(now[@"MouseButtonDivision"], before) != percent) {
        // Some drivers only take the whole preferences dictionary
        NSMutableDictionary *all = [([now isKindOfClass:NSDictionary.class] ? now : d.prefs) mutableCopy];
        all[@"MouseButtonDivision"] = value;
        kr = IORegistryEntrySetCFProperties(d->service, (__bridge CFDictionaryRef)@{@"MultitouchPreferences": all});
        now = regProp(d->service, @"MultitouchPreferences", NO);
    }
    for (NSString *domain in @[@"com.apple.AppleMultitouchMouse", @"com.apple.driver.AppleBluetoothMultitouch.mouse"]) {
        CFPreferencesSetAppValue(CFSTR("MouseButtonDivision"), (__bridge CFNumberRef)value, (__bridge CFStringRef)domain);
        CFPreferencesAppSynchronize((__bridge CFStringRef)domain);
    }
    BOOL applied = intOf(now[@"MouseButtonDivision"], before) == percent;
    if ([now isKindOfClass:NSDictionary.class]) d.prefs = now;
    [self log:applied
        ? [NSString stringWithFormat:@"≠ %@: split moved from %d%% to %d%%", d.name, before, percent]
        : [NSString stringWithFormat:@"✗ %@: couldn't move the split to %d%% (driver said 0x%x). Saved for next time the mouse connects.", d.name, percent, kr]];
    [self updateDivisionControls];
    self.view.needsDisplay = YES;
}

- (RGDevice *)splitMouse {
    for (RGDevice *d in self.devices) if (d->kind == RGKindMouse) return d;
    return nil;
}

- (void)divisionSliderChanged:(NSSlider *)s {
    RGDevice *d = self.splitMouse;
    if (!d) return;
    int percent = (int)lround(s.doubleValue);
    self.divisionLabel.stringValue = [NSString stringWithFormat:@"%d%%", percent];
    NSEventType type = NSApp.currentEvent.type;
    if (type == NSEventTypeLeftMouseDragged || type == NSEventTypeLeftMouseDown) {   // preview while the knob moves
        d->dragDivision = percent / 100.0f;
        self.view.needsDisplay = YES;
    } else {
        [self setDivision:percent forDevice:d];   // mouse up, keyboard or VoiceOver
    }
}

- (void)resetDivision:(id)sender {
    RGDevice *d = self.splitMouse;
    if (d) [self setDivision:55 forDevice:d];
}

- (void)updateDivisionControls {
    RGDevice *d = self.splitMouse;
    if (!d || d->dragDivision > 0) return;
    int percent = intOf(d.prefs[@"MouseButtonDivision"], 55);
    self.divisionSlider.doubleValue = percent;
    self.divisionLabel.stringValue = [NSString stringWithFormat:@"%d%%", percent];
    self.divisionReset.enabled = percent != 55;
    self.divisionSlider.enabled = d.secondaryZone != 0;
}

#pragma mark Bluetooth signal (opt-in)

- (void)setupBluetooth {
    __weak RGController *weakSelf = self;
    self.bluetooth.onChange = ^{ [weakSelf bluetoothStateChanged]; };
    self.bluetooth.onSample = ^(NSDictionary<NSString *, NSNumber *> *rssi) { [weakSelf bluetoothSample:rssi]; };
    if ([NSUserDefaults.standardUserDefaults boolForKey:kBluetooth]) [self.bluetooth start];
}

- (void)bluetoothStateChanged {
    RGBluetoothState s = self.bluetooth.state;
    if (s == RGBluetoothOn) [self log:@"· Bluetooth signal monitoring on"];
    if (s == RGBluetoothDenied) {
        [self log:@"✗ Bluetooth signal monitoring needs Bluetooth access: allow RodentGym in Privacy & Security → Bluetooth"];
        [NSUserDefaults.standardUserDefaults setBool:NO forKey:kBluetooth];
    }
    if (s != RGBluetoothOn) for (RGDevice *d in self.devices) d->rssi = 0;
    [self updateBluetoothSettingsUI];
    self.view.needsDisplay = YES;
}

- (void)bluetoothSample:(NSDictionary<NSString *, NSNumber *> *)rssi {
    double now = CFAbsoluteTimeGetCurrent();
    for (RGDevice *d in self.devices) {
        NSString *addr = [RGBluetoothMonitor normalisedAddress:d.identifier];
        NSNumber *v = addr ? rssi[addr] : nil;
        if (!v) { if (now - d->rssiTime > 10) d->rssi = 0; continue; }
        int before = d->rssi;
        d->rssi = v.intValue;
        d->rssiTime = now;
        [self.monitor recordSignal:d->rssi device:d.key name:d.name];
        if (before && before >= -80 && d->rssi < -80)
            [self log:[NSString stringWithFormat:@"· %@: Bluetooth signal poor (%d dBm)", d.name, d->rssi]];
    }
    self.view.needsDisplay = YES;
}

// Nil when the monitor has signal data to show; otherwise why not.
- (NSString *)bluetoothGraphStatus {
    switch (self.bluetooth.state) {
        case RGBluetoothOff: return @"Bluetooth signal monitoring is off. Turn it on in Settings (⌘,).";
        case RGBluetoothOn: return nil;
        default: return self.bluetooth.statusText;
    }
}

- (void)toggleBluetooth:(NSButton *)b {
    BOOL on = b.state == NSControlStateValueOn;
    [NSUserDefaults.standardUserDefaults setBool:on forKey:kBluetooth];
    if (on) [self.bluetooth start];
    else { [self.bluetooth stop]; [self log:@"· Bluetooth signal monitoring off"]; }
    [self updateBluetoothSettingsUI];
}

- (void)openBluetoothPrivacy:(id)sender {
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth"]];
}

- (void)updateBluetoothSettingsUI {
    RGBluetoothState s = self.bluetooth.state;
    self.bluetoothCheckbox.state = (s == RGBluetoothOn || s == RGBluetoothWaiting || s == RGBluetoothPoweredOff) ? NSControlStateValueOn : NSControlStateValueOff;
    NSString *base = @"Graphs signal strength in the Latency Monitor and shows it on each device. macOS asks for Bluetooth permission the first time you turn this on.";
    self.bluetoothNote.stringValue = s == RGBluetoothOff ? base : self.bluetooth.statusText;
    self.bluetoothNote.textColor = s == RGBluetoothDenied ? NSColor.systemOrangeColor : NSColor.secondaryLabelColor;
    self.bluetoothPrivacyRow.hidden = s != RGBluetoothDenied;
}

- (void)showForce:(id)sender {
    if (!self.forceSensor) {
        self.forceSensor = [RGForceSensor new];
        __weak RGController *weakSelf = self;
        self.forceSensor.devices = ^NSArray<NSDictionary *> * { return weakSelf.deviceInfos; };
    }
    [self.forceSensor show];
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
    if (!self.help) self.help = [RGHelp new];
    [self.help show];
    [self applyWindowLevel];
    [self activate];
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
}

- (void)builtInModeChanged:(NSPopUpButton *)p {
    [NSUserDefaults.standardUserDefaults setInteger:p.indexOfSelectedItem forKey:kBuiltInMode];
    [self relayout];
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
    NSPopUpButton *builtIn = [[NSPopUpButton alloc] initWithFrame:NSZeroRect pullsDown:NO];
    [builtIn addItemsWithTitles:@[@"Automatic (when the lid is open)", @"Always show", @"Never show"]];
    [builtIn selectItemAtIndex:MIN(2, MAX(0, [ud integerForKey:kBuiltInMode]))];
    builtIn.target = self;
    builtIn.action = @selector(builtInModeChanged:);
    builtIn.accessibilityLabel = @"Built-in trackpad and keyboard";
    [grid addRowWithViews:@[[self formLabel:@"Built-in trackpad and keyboard:"], builtIn]];

    NSGridRow *spacer;
    if (self.splitMouse) {
        spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
        spacer.height = 6;
        self.divisionSlider = [NSSlider sliderWithValue:55 minValue:MIN_DIVISION maxValue:MAX_DIVISION
                                                 target:self action:@selector(divisionSliderChanged:)];
        self.divisionSlider.numberOfTickMarks = (MAX_DIVISION - MIN_DIVISION) / 5 + 1;
        self.divisionSlider.accessibilityLabel = @"Magic Mouse split";
        [self.divisionSlider.widthAnchor constraintEqualToConstant:200].active = YES;
        self.divisionLabel = [NSTextField labelWithString:@"55%"];
        self.divisionLabel.font = [NSFont monospacedDigitSystemFontOfSize:NSFont.systemFontSize weight:NSFontWeightRegular];
        self.divisionReset = [NSButton buttonWithTitle:@"Reset to 55%" target:self action:@selector(resetDivision:)];
        self.divisionReset.controlSize = NSControlSizeSmall;
        [grid addRowWithViews:@[[self formLabel:@"Magic Mouse split:"],
                                [NSStackView stackViewWithViews:@[self.divisionSlider, self.divisionLabel, self.divisionReset]]]];
        [grid addRowWithViews:@[[NSGridCell emptyContentView], [self note:
            @"Where the right-click area starts, across the mouse from the left (from the right when left-handed). "
            @"Apple's default is 55%, and System Settings has no control for it. You can also drag the split line on the mouse." width:320]]];
        [self updateDivisionControls];
    }

    spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
    spacer.height = 6;
    self.bluetoothCheckbox = [NSButton checkboxWithTitle:@"Monitor signal strength" target:self action:@selector(toggleBluetooth:)];
    [grid addRowWithViews:@[[self formLabel:@"Bluetooth:"], self.bluetoothCheckbox]];
    self.bluetoothNote = [self note:@"" width:320];
    [grid addRowWithViews:@[[NSGridCell emptyContentView], self.bluetoothNote]];
    self.bluetoothPrivacy = [NSButton buttonWithTitle:@"Open Privacy & Security…" target:self action:@selector(openBluetoothPrivacy:)];
    self.bluetoothPrivacyRow = [grid addRowWithViews:@[[NSGridCell emptyContentView], self.bluetoothPrivacy]];
    [self updateBluetoothSettingsUI];

    spacer = [grid addRowWithViews:@[[NSGridCell emptyContentView], [NSGridCell emptyContentView]]];
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
    d.productName = [product isKindOfClass:NSString.class] ? product : @"Multitouch device";
    d.name = builtIn ? @"Built-in trackpad" : d.productName;
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
    if (self.demo) {   // screenshots never show a real device's name or serial number
        d.name = d->kind == RGKindMouse ? @"Magic Mouse" : d->kind == RGKindTrackpad ? @"Magic Trackpad" : @"Built-in trackpad";
        d.identifier = nil;
    }
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
        memset(&gSlots[i], 0, sizeof gSlots[i]);
        gSlots[i].mt = (MTDeviceRef)CFArrayGetValueAtIndex(mtList, i);
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
    // Connects and disconnects, for the log and the Latency Monitor (built-in trackpads come and go with the lid)
    if (self.live && self.devices) {
        NSMutableDictionary<NSString *, RGDevice *> *before = [NSMutableDictionary dictionary], *after = [NSMutableDictionary dictionary];
        for (RGDevice *d in self.devices) if (d->kind != RGKindBuiltIn) before[d.key] = d;
        for (RGDevice *d in found) if (d->kind != RGKindBuiltIn) after[d.key] = d;
        for (NSString *k in before) if (!after[k]) {
            [self log:[NSString stringWithFormat:@"· %@ disconnected", before[k].name]];
            [self.monitor recordLink:NO device:before[k].name];
        }
        for (NSString *k in after) if (!before[k]) {
            [self log:[NSString stringWithFormat:@"· %@ connected", after[k].name]];
            [self.monitor recordLink:YES device:after[k].name];
        }
    }
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
    NSDictionary *power = accessoryPowerSources();
    for (RGDevice *d in self.devices) {
        NSString *bySerial = d.identifier ? [@"serial:" stringByAppendingString:d.identifier] : @"";
        NSString *byName = [@"product:" stringByAppendingString:d.productName];
        NSNumber *b = batt[bySerial] ?: batt[byName], *c = col[bySerial] ?: col[byName];
        d->colorID = c ? c.intValue : -1;
        NSDictionary *ps = (d.identifier ? power[[@"id:" stringByAppendingString:d.identifier.uppercaseString]] : nil)
                        ?: power[[@"name:" stringByAppendingString:d.productName]];
        NSString *before = d->battery >= 0 ? d.powerStatus : nil;
        if (ps) {
            d->battery = [ps[@"Current Capacity"] intValue];
            d->charging = [ps[@"Is Charging"] boolValue];
            d->charged = [ps[@"Is Charged"] boolValue];
            d->onCable = [ps[@"Power Source State"] isEqual:@"AC Power"];
            d->lowWarn = ps[@"Low Warn Level"] ? [ps[@"Low Warn Level"] intValue] : 20;
        } else {
            d->battery = b ? b.intValue : -1;
            d->charging = d->charged = d->onCable = NO;
            d->lowWarn = 20;
        }
        NSString *after = d->battery >= 0 ? d.powerStatus : nil;
        if (self.live && before && after && ![before isEqualToString:after])
            [self log:[NSString stringWithFormat:@"· %@: %@ (%d%%)", d.name, after.lowercaseString, d->battery]];
    }
    [self refreshKeyboards];
    self.view.needsDisplay = YES;
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
    if (self.settingsWindow.visible) [self updateDivisionControls];
}

- (void)watchDevices {
    CFRunLoopSourceRef power = IOPSNotificationCreateRunLoopSource(powerSourcesChanged, (__bridge void *)self);
    if (power) {
        CFRunLoopAddSource(CFRunLoopGetMain(), power, kCFRunLoopCommonModes);
        CFRelease(power);
    }
    notifyPort = IONotificationPortCreate(kIOMainPortDefault);
    CFRunLoopAddSource(CFRunLoopGetMain(), IONotificationPortGetRunLoopSource(notifyPort), kCFRunLoopCommonModes);
    io_object_t o;
    IOServiceAddMatchingNotification(notifyPort, kIOFirstMatchNotification, IOServiceMatching("AppleMultitouchDevice"),
                                     devicesChangedCallback, (__bridge void *)self, &addIter);
    while ((o = IOIteratorNext(addIter))) IOObjectRelease(o);   // arm the notification
    IOServiceAddMatchingNotification(notifyPort, kIOTerminatedNotification, IOServiceMatching("AppleMultitouchDevice"),
                                     devicesChangedCallback, (__bridge void *)self, &removeIter);
    while ((o = IOIteratorNext(removeIter))) IOObjectRelease(o);
    // Keyboards, for the keyboard tiles (read from the registry only; never opened)
    for (int i = 0; i < 2; i++) {
        NSDictionary *kb = @{@kIOProviderClassKey: @kIOHIDDeviceKey,
                             @kIOHIDPrimaryUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDPrimaryUsageKey: @(kHIDUsage_GD_Keyboard)};
        io_iterator_t *iter = i ? &kbRemoveIter : &kbAddIter;
        IOServiceAddMatchingNotification(notifyPort, i ? kIOTerminatedNotification : kIOFirstMatchNotification,
                                         (__bridge_retained CFDictionaryRef)kb, keyboardsChangedCallback, (__bridge void *)self, iter);
        while ((o = IOIteratorNext(*iter))) IOObjectRelease(o);
    }
}

#pragma mark Button reports and click events

- (void)setupHID {
    hid = IOHIDManagerCreate(kCFAllocatorDefault, kIOHIDOptionsTypeNone);
    // Button reports come from each device's mouse interface (primary usage Generic Desktop / Mouse),
    // so that is all that is matched, plus the Magic Trackpads over USB by product ID. Matching on
    // primary usage keeps keyboards out: a keyboard's primary usage is Keyboard, even when it also
    // has a mouse collection, so IOHIDManagerOpen never opens one.
    NSArray *matches = @[@{@kIOHIDPrimaryUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDPrimaryUsageKey: @(kHIDUsage_GD_Mouse)},
                         @{@kIOHIDVendorIDKey: @0x05ac, @kIOHIDProductIDKey: @0x0265},
                         @{@kIOHIDVendorIDKey: @0x05ac, @kIOHIDProductIDKey: @0x030e}];
    IOHIDManagerSetDeviceMatchingMultiple(hid, (__bridge CFArrayRef)matches);
    IOHIDManagerRegisterInputValueCallback(hid, hidCallback, (__bridge void *)self);
    IOHIDManagerScheduleWithRunLoop(hid, CFRunLoopGetMain(), kCFRunLoopCommonModes);
    IOHIDManagerOpen(hid, kIOHIDOptionsTypeNone);
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
        if (([serial isKindOfClass:NSString.class] && [d.identifier isEqualToString:serial]) || [d.productName isEqualToString:product]) { match = d; break; }
    self.hidCache[key] = match ?: NSNull.null;
    return match;
}

// Where a click happened on the device, in its normalised coordinates: the finger doing the
// clicking on a mouse, the middle of the fingers on a trackpad, or a sensible default.
- (NSPoint)pingPointFor:(RGDevice *)d button:(int)b {
    MTFinger t[MAX_TOUCHES];
    int n = RGCopyTouches(d->slot, t);
    if (n == 0) return d->kind == RGKindMouse ? NSMakePoint(b == 2 ? 0.78 : 0.28, 0.76) : NSMakePoint(0.5, 0.45);
    if (d->kind == RGKindMouse) {
        int best = 0;
        for (int i = 1; i < n; i++) {
            BOOL better = (b == 2) == (d.secondaryZone != 2) ? t[i].normalized.pos.x > t[best].normalized.pos.x
                                                             : t[i].normalized.pos.x < t[best].normalized.pos.x;
            if (better) best = i;
        }
        return NSMakePoint(t[best].normalized.pos.x, t[best].normalized.pos.y);
    }
    float x = 0, y = 0;
    for (int i = 0; i < n; i++) { x += t[i].normalized.pos.x; y += t[i].normalized.pos.y; }
    return NSMakePoint(x / n, y / n);
}

- (RGDevice *)touchedDevice {
    MTFinger t[MAX_TOUCHES];
    for (RGDevice *d in self.devices) if (RGCopyTouches(d->slot, t) > 0) return d;
    return nil;
}

- (BOOL)logAll { return [NSUserDefaults.standardUserDefaults boolForKey:kLogAll]; }

- (void)hidButton:(int)b down:(BOOL)down device:(IOHIDDeviceRef)h stamp:(uint64_t)stamp {
    NSString *name = nil;
    RGDevice *d = [self deviceForHID:h name:&name];
    BOOL *state = d ? d->hidDown : anonHidDown;
    if (!down) { state[b] = NO; self.view.needsDisplay = YES; return; }
    if (state[b]) return;   // the same press reported by a second HID interface
    state[b] = YES;
    if (d) d->sent[b]++;
    double now = CFAbsoluteTimeGetCurrent(), win = self.matchWindow;
    int o = otherButton(b);
    if (evtPending[b] > 0 && now - evtPending[b] < win) {
        evtPending[b] = 0;
        [self matched:b name:name latency:machMs(evtStamp[b], stamp)];
    } else if (o && evtPending[o] > 0 && now - evtPending[o] < win) {
        evtPending[o] = 0;
        [self sent:b delivered:o device:d name:name latency:machMs(evtStamp[o], stamp)];
    } else {
        hidPending[b] = now; hidPendingDevice[b] = d; hidPendingName[b] = name; hidStamp[b] = stamp;
    }
    if (d) {
        hidPendingPos[b] = [self pingPointFor:d button:b];
        [d addPing:b at:hidPendingPos[b]];
    }
    self.view.needsDisplay = YES;
}

- (void)event:(int)b down:(BOOL)down stamp:(uint64_t)stamp {
    if (!down) { evtDown[b] = NO; self.view.needsDisplay = YES; return; }
    evtDown[b] = YES;
    delivered[b]++;
    int o = otherButton(b);
    if (hidPending[b] > 0) {
        hidPending[b] = 0;
        [self matched:b name:hidPendingName[b] latency:machMs(stamp, hidStamp[b])];
    } else if (o && hidPending[o] > 0) {
        hidPending[o] = 0;
        [self sent:o delivered:b device:hidPendingDevice[o] name:hidPendingName[o] latency:machMs(stamp, hidStamp[o])];
    } else {
        evtStamp[b] = stamp;
        evtPending[b] = CFAbsoluteTimeGetCurrent();
        evtToucher[b] = [self touchedDevice];
        if (evtToucher[b]) [evtToucher[b] addPing:b at:[self pingPointFor:evtToucher[b] button:b]];   // e.g. trackpad clicks with no button report
    }
    self.view.needsDisplay = YES;
}

static NSString *latencyText(double ms) { return ms >= 0 ? [NSString stringWithFormat:@" · %.1f ms", ms] : @""; }

- (void)matched:(int)b name:(NSString *)name latency:(double)ms {
    [self.monitor recordClick:b latency:ms device:name];
    if (self.logAll) [self log:[NSString stringWithFormat:@"✓ %@ click: %@%@", kButtonName[b], name ?: @"unknown device", latencyText(ms)]];
}

- (void)sent:(int)from delivered:(int)to device:(RGDevice *)d name:(NSString *)name latency:(double)ms {
    [self.monitor recordClick:to latency:ms device:name];
    if (d && d->kind != RGKindMouse && from == 1 && to == 2) {   // a trackpad's secondary click: expected
        if (self.logAll) [self log:[NSString stringWithFormat:@"✓ Right click: %@ (%@)%@", name, d.secondaryDescription.lowercaseString, latencyText(ms)]];
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
            if (d) { d->dropped[b]++; [d addPing:3 at:hidPendingPos[b]]; }
            totalDrops++;
            lastDrop = now;
            [self.monitor recordDrop:b device:hidPendingName[b]];
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
    BOOL closed = lidClosed();
    if (closed != lidIsClosed) {
        lidIsClosed = closed;
        BOOL hasPad = NO, hasKeyboard = NO;
        for (RGDevice *d in self.devices) if (d->kind == RGKindBuiltIn) hasPad = YES;
        for (NSDictionary *k in self.keyboards) if ([k[@"builtIn"] boolValue]) hasKeyboard = YES;
        if ((hasPad || hasKeyboard) && self.live) {
            NSString *what = hasPad && hasKeyboard ? @"built-in trackpad and keyboard are" : hasPad ? @"built-in trackpad is" : @"built-in keyboard is";
            [self log:[NSString stringWithFormat:closed ? @"· Lid closed: the %@ unavailable" : @"· Lid opened: the %@ available", what]];
            [self relayout];
        }
    }
    CFPreferencesAppSynchronize(kCFPreferencesAnyApplication);
    if (self.live) [self refreshPrefs];
    if (++statusTicks % 30 == 0) [self refreshBatteryAndColour];
    self.view.needsDisplay = YES;   // settings or battery may have changed
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
            d->battery = 72; d->onCable = NO; d->charging = NO; d->lowWarn = 20;
        } else {
            f[0].normalized.pos = (MTPoint){0.40f, 0.52f};
            f[1].normalized.pos = (MTPoint){0.55f, 0.56f};
            f[0].size = f[1].size = 1.0f;
            n = 2;
            d->sent[1] = 64; d->sent[2] = 0;
            d->battery = 86; d->charging = YES; d->onCable = YES; d->lowWarn = 20;
        }
        os_unfair_lock_lock(&gLock);
        memcpy(gSlots[d->slot].touches, f, sizeof(MTFinger) * (size_t)n);
        gSlots[d->slot].count = n;
        os_unfair_lock_unlock(&gLock);
    }
    gFrozenTime = CFAbsoluteTimeGetCurrent();
    for (RGDevice *d in self.devices) {
        if (d->kind == RGKindMouse) {
            d->pings[0] = (RGPing){0.76f, 0.78f, gFrozenTime - 0.22, 2};
            d->pings[1] = (RGPing){0.30f, 0.40f, gFrozenTime - 0.5, 1};
        } else if (d->kind == RGKindTrackpad) {
            for (int f = 0; f < 2; f++) {
                RGTrail *tr = &d->trails[f];
                tr->fid = f + 1;
                tr->count = 30;
                for (int i = 0; i < 30; i++) {
                    float u = i / 29.0f;
                    tr->x[i] = (f ? 0.22f : 0.08f) + u * 0.33f;
                    tr->y[i] = (f ? 0.42f : 0.38f) + 0.14f * u + 0.05f * sinf(u * 3.1f);
                    tr->t[i] = gFrozenTime - (1 - u) * 0.4;
                }
            }
        }
    }
    evtDown[2] = YES;
    delivered[1] = 192; delivered[2] = 31;
    hidOK = tapOK = YES;
    self.window.subtitle = @"Listening";
    [lines addObjectsFromArray:@[
        [NSString stringWithFormat:@"09:41:02 · RodentGym %@ started: button reports ok, click events ok", APP_VERSION],
        @"09:41:02 · Devices: Magic Mouse (Magic Mouse 2 (Lightning), firmware 3.1.1); Magic Trackpad (Magic Trackpad 2 (Lightning), firmware 8.7.1)",
        @"09:41:09 ✓ Left click: Magic Mouse · 4.6 ms",
        @"09:41:11 ✓ Right click: Magic Trackpad (click or tap with two fingers) · 3.9 ms",
        @"09:41:15 ≠ Magic Mouse: secondary click changed from \"Off — whole surface clicks left\" to \"Right side (right-handed)\"",
        @"09:41:18 ✓ Right click: Magic Mouse · 5.2 ms",
        @"09:42:40 ✗ DROPPED right click: Magic Mouse sent it, macOS delivered nothing | secondary click: Right side (right-handed) | Memory free 21% · pressure warning",
        @"09:42:44 ✓ Right click: Magic Mouse · 31.7 ms"]];
    self.view.needsDisplay = YES;
}

// Every window, in demo mode, for the README and website. The windows are invisible and ignore the
// mouse while they're rendered.
- (NSArray<NSArray *> *)shotWindows {
    NSMutableArray *a = [NSMutableArray arrayWithObject:@[@"main", self.window]];
    if (self.monitor.window) [a addObject:@[@"latency-monitor", self.monitor.window]];
    if (self.selfTest.window) [a addObject:@[@"self-test", self.selfTest.window]];
    if (self.keyboardTester.window) [a addObject:@[@"keyboard-tester", self.keyboardTester.window]];
    if (self.forceSensor.window) [a addObject:@[@"force-sensor", self.forceSensor.window]];
    if (self.trainer.window) [a addObject:@[@"gesture-trainer", self.trainer.window]];
    if (self.game.window) [a addObject:@[@"cheese-stack", self.game.window]];
    if (self.help.window) [a addObject:@[@"help", self.help.window]];
    if (self.settingsWindow) [a addObject:@[@"settings", self.settingsWindow]];
    return a;
}

- (void)hideForShot:(NSWindow *)w size:(NSSize)size {
    w.alphaValue = 0;
    w.ignoresMouseEvents = YES;
    if (size.width > 0) [w setContentSize:size];
}

- (void)prepareWindowShots {
    [self.monitor showDemo];
    [self hideForShot:self.monitor.window size:NSMakeSize(1040, 720)];
    self.selfTest = [RGSelfTest new];
    [self.selfTest showDemo];
    [self hideForShot:self.selfTest.window size:NSMakeSize(1060, 700)];
    self.keyboardTester = [RGKeyboardTester new];
    [self.keyboardTester showDemo];
    [self hideForShot:self.keyboardTester.window size:NSMakeSize(1120, 680)];
    self.forceSensor = [RGForceSensor new];
    [self.forceSensor showDemo];
    [self hideForShot:self.forceSensor.window size:NSMakeSize(900, 620)];
    self.trainer = [RGGestureTrainer new];
    [self.trainer showDemo];
    [self hideForShot:self.trainer.window size:NSZeroSize];
    [self showGame:nil];
    [self.game showDemo];
    [self hideForShot:self.game.window size:NSZeroSize];
    self.help = [RGHelp new];
    [self.help showTopic:@"Latency Monitor"];
    [self hideForShot:self.help.window size:NSMakeSize(940, 640)];
    [self showSettings:nil];
    [self hideForShot:self.settingsWindow size:NSZeroSize];
}

- (void)writeWindowShots {
    BOOL dark = [NSApp.effectiveAppearance bestMatchFromAppearancesWithNames:@[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]] == NSAppearanceNameDarkAqua;
    [NSFileManager.defaultManager createDirectoryAtPath:self.windowShotsDir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSArray *shot in self.shotWindows) {
        NSString *file = [NSString stringWithFormat:@"%@-%@.png", shot[0], dark ? @"dark" : @"light"];
        if (!RGWriteWindowPNG(shot[1], [self.windowShotsDir stringByAppendingPathComponent:file])) NSLog(@"Couldn't render %@", file);
    }
    [NSApp terminate:nil];
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
        i = [args indexOfObject:@"--snapshot-force"];
        if (i != NSNotFound && i + 1 < args.count) return [[RGForceSensor new] writeDemoSnapshotTo:args[i + 1]] ? 0 : 1;
        i = [args indexOfObject:@"--snapshot-latency"];
        if (i != NSNotFound && i + 1 < args.count) return [[RGLatencyMonitor new] writeDemoSnapshotTo:args[i + 1]] ? 0 : 1;
        i = [args indexOfObject:@"--snapshot-selftest"];
        if (i != NSNotFound && i + 1 < args.count) return [[RGSelfTest new] writeDemoSnapshotTo:args[i + 1]] ? 0 : 1;
        i = [args indexOfObject:@"--keyboard-layouts"];
        if (i != NSNotFound && i + 1 < args.count) return [RGKeyboardTester writeLayoutsTo:args[i + 1]] ? 0 : 1;
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
        i = [args indexOfObject:@"--window-shots"];   // render every window with demo data, then quit
        if (i != NSNotFound && i + 1 < args.count) {
            controller.windowShotsDir = args[i + 1];
            controller.demo = YES;
            [app setActivationPolicy:NSApplicationActivationPolicyAccessory];
        }
        app.delegate = controller;
        [app run];
    }
    return 0;
}
