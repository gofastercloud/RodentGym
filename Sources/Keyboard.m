// Keyboard Tester — see Keyboard.h.

#import "Keyboard.h"
#import "UI.h"
#import <Carbon/Carbon.h>
#import <IOKit/IOKitLib.h>
#import <IOKit/hid/IOHIDKeys.h>
#import <IOKit/hid/IOHIDUsageTables.h>
#import <IOKit/hidsystem/ev_keymap.h>

#define MAX_CODES   256
#define TOP_KEY     200     // pseudo key code for the key at the top right: Touch ID, lock, eject or power
#define MAX_KEYS    160
#define CHATTER_GAP 0.030   // a release and re-press closer together than this is a bouncing switch, not a finger
#define STUCK_AFTER 4.0     // seconds a key can be held before it is flagged as possibly stuck

#pragma mark - Models

// Apple keyboards by USB / Bluetooth product ID:
//   family   0 ANSI, 1 ISO, 2 JIS when the product ID fixes it, or -1 to read the country code
//   layout   a layout name from KeyboardLayouts.inc, with %@ for the family
//   topKey   the key at the top right of the function row: eject, lock or touchid
//   globe    YES when the fn key carries the Globe symbol
typedef struct {
    int productID, family;
    __unsafe_unretained NSString *name, *years, *layout, *topKey;
    BOOL globe;
} RGKeyboardModel;

static const RGKeyboardModel kModels[] = {
#include "KeyboardModels.inc"
};

static const RGKeyboardModel *modelFor(int vendorID, int productID) {
    if (vendorID != 0x004c && vendorID != 0x05ac) return NULL;
    for (size_t i = 0; i < sizeof kModels / sizeof kModels[0]; i++) if (kModels[i].productID == productID) return &kModels[i];
    return NULL;
}

enum { RGFamilyANSI, RGFamilyISO, RGFamilyJIS };
static NSString *const kFamilyNames[] = {@"ANSI", @"ISO", @"JIS"};

// The HID country code a keyboard reports: Apple uses 13 for ISO, 15 for JIS and 33 for US. Anything
// else (including 0, "not given") leaves the family to be worked out from what is typed.
static int familyForCountryCode(int code) {
    return code == 13 ? RGFamilyISO : code == 15 ? RGFamilyJIS : code == 33 ? RGFamilyANSI : -1;
}

#pragma mark - Discovery (IORegistry only; no device is opened)

static id prop(io_registry_entry_t e, NSString *key, BOOL parents) {
    CFTypeRef v = parents
        ? IORegistryEntrySearchCFProperty(e, kIOServicePlane, (__bridge CFStringRef)key, kCFAllocatorDefault,
                                          kIORegistryIterateRecursively | kIORegistryIterateParents)
        : IORegistryEntryCreateCFProperty(e, (__bridge CFStringRef)key, kCFAllocatorDefault, 0);
    return CFBridgingRelease(v);
}

static int intProp(io_registry_entry_t e, NSString *key, int def) {
    id v = prop(e, key, YES);
    return [v respondsToSelector:@selector(intValue)] ? [v intValue] : def;
}

static NSString *stringProp(io_registry_entry_t e, NSString *key) {
    id v = prop(e, key, YES);
    return [v isKindOfClass:NSString.class] && [v length] ? v : nil;
}

// Accessory firmware is reported as BCD-style hex: 0x311 -> "3.1.1".
static NSString *firmware(int v) {
    if (v <= 0) return nil;
    NSString *hex = [NSString stringWithFormat:@"%x", v];
    NSMutableArray *parts = [NSMutableArray array];
    for (NSUInteger i = 0; i < hex.length; i++) [parts addObject:[hex substringWithRange:NSMakeRange(i, 1)]];
    return [parts componentsJoinedByString:@"."];
}

// Battery levels, keyed by serial number (the Bluetooth address for Bluetooth accessories) and name.
static NSDictionary<NSString *, NSNumber *> *batteryLevels(void) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)@{@"IOPropertyExistsMatch": @"BatteryPercent"}, &it) != KERN_SUCCESS)
        return out;
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        id v = prop(s, @"BatteryPercent", NO);
        NSString *serial = stringProp(s, @"SerialNumber"), *product = stringProp(s, @"Product");
        if ([v isKindOfClass:NSNumber.class]) {
            if (serial) out[[@"serial:" stringByAppendingString:serial.lowercaseString]] = v;
            if (product) out[[@"product:" stringByAppendingString:product]] = v;
        }
        IOObjectRelease(s);
    }
    IOObjectRelease(it);
    return out;
}

static NSString *macName(void) {
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

NSArray<NSDictionary *> *RGConnectedKeyboards(BOOL anonymise) {
    NSMutableArray *out = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSDictionary *match = @{@kIOProviderClassKey: @kIOHIDDeviceKey,
                            @kIOHIDPrimaryUsagePageKey: @(kHIDPage_GenericDesktop), @kIOHIDPrimaryUsageKey: @(kHIDUsage_GD_Keyboard)};
    io_iterator_t it = 0;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, (__bridge_retained CFDictionaryRef)match, &it) != KERN_SUCCESS) return out;
    NSDictionary *batteries = batteryLevels();
    io_service_t s;
    while ((s = IOIteratorNext(it))) {
        int vendor = intProp(s, @kIOHIDVendorIDKey, 0), product = intProp(s, @kIOHIDProductIDKey, 0);
        NSString *name = stringProp(s, @kIOHIDProductKey), *serial = stringProp(s, @kIOHIDSerialNumberKey);
        NSString *transport = stringProp(s, @kIOHIDTransportKey);
        BOOL builtIn = intProp(s, @"Built-In", 0) != 0;
        int version = intProp(s, @kIOHIDVersionNumberKey, 0);
        int country = intProp(s, @kIOHIDCountryCodeKey, 0);
        IOObjectRelease(s);
        if (!name) continue;
        // Security keys and other gadgets that type (YubiKeys, barcode scanners) also call themselves keyboards.
        NSString *lower = name.lowercaseString;
        if (vendor == 0x1050 || [lower containsString:@"yubikey"] || [lower containsString:@"security key"]) continue;
        NSString *key = builtIn ? @"builtin" : serial ? serial.lowercaseString : [NSString stringWithFormat:@"%@-%x-%x", name, vendor, product];
        if ([seen containsObject:key]) continue;
        [seen addObject:key];

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"key"] = key;
        d[@"vendorID"] = @(vendor);
        d[@"productID"] = @(product);
        d[@"builtIn"] = @(builtIn);
        const RGKeyboardModel *m = builtIn ? NULL : modelFor(vendor, product);
        int family = m && m->family >= 0 ? m->family : familyForCountryCode(country);
        if (family >= 0) d[@"family"] = @(family);
        if (builtIn) {
            d[@"name"] = @"Built-in keyboard";
            d[@"model"] = macName();
            d[@"layout"] = @"laptop_%@";
            d[@"topKey"] = @"touchid";
            d[@"globe"] = @YES;
            d[@"transport"] = @"Built in";
        } else {
            d[@"name"] = anonymise ? (m ? @"Magic Keyboard" : @"Keyboard") : name;
            d[@"model"] = m ? m->name : (vendor == 0x004c || vendor == 0x05ac) ? [NSString stringWithFormat:@"Apple keyboard (product 0x%04x)", product]
                                                                             : @"Keyboard from another maker";
            if (m) {
                d[@"years"] = m->years;
                d[@"layout"] = m->layout;
                d[@"topKey"] = m->topKey;
                d[@"globe"] = @(m->globe);
            } else {
                d[@"generic"] = @YES;   // drawn as a current Magic Keyboard; positions may differ
                d[@"layout"] = @"compact_%@_2021";
                d[@"topKey"] = @"none";
                d[@"globe"] = @NO;
            }
            if (transport) d[@"transport"] = transport;
            if (firmware(version) && m) d[@"firmware"] = firmware(version);
            if (serial && !anonymise) d[@"serial"] = serial;
            NSNumber *b = (serial ? batteries[[@"serial:" stringByAppendingString:serial.lowercaseString]] : nil) ?: batteries[[@"product:" stringByAppendingString:name]];
            if (b) d[@"battery"] = b;
        }
        [out addObject:d];
    }
    IOObjectRelease(it);
    // External keyboards first: they are the ones people bring to a tester.
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"builtIn"] compare:b[@"builtIn"]]; }];
    return out;
}

#pragma mark - Layouts

enum { RGKeySystem = 1, RGKeyReturnTop = 2, RGKeyReturnBottom = 4, RGKeyHalf = 8 };
typedef struct { int code; CGFloat x, y, w, h; int flags; } RGKey;
typedef struct { RGKey keys[MAX_KEYS]; int count; CGFloat width, height; } RGLayout;

static void put(RGLayout *L, int code, CGFloat x, CGFloat y, CGFloat w, CGFloat h, int flags) {
    if (L->count >= MAX_KEYS) return;
    L->keys[L->count++] = (RGKey){code, x, y, w, h, flags};
    L->width = MAX(L->width, x + w);
    L->height = MAX(L->height, y + h);
}

// Lays out one row from a spec in KeyboardLayouts.inc (the format is described there).
static void row(RGLayout *L, CGFloat y, CGFloat h, const char *spec) {
    char buf[600], *save = NULL;
    strlcpy(buf, spec, sizeof buf);
    CGFloat x = 0;
    for (char *tok = strtok_r(buf, " ", &save); tok; tok = strtok_r(NULL, " ", &save)) {
        if (tok[0] == '@') { x = atof(tok + 1); continue; }
        CGFloat w = 1;
        const char *flags = "";
        char *p = strchr(tok, ':');
        if (p) {
            w = atof(p + 1);
            char *q = strchr(p + 1, ':');
            if (q) flags = q + 1;
        }
        int code = atoi(tok), f = 0;
        if (strchr(flags, 's')) f |= RGKeySystem;
        if (strchr(flags, 't')) f |= RGKeyReturnTop;
        if (strchr(flags, 'b')) f |= RGKeyReturnBottom;
        if (strchr(flags, 'v')) {                 // up and down arrows stacked in one column
            char *slash = strchr(tok, '/');
            put(L, code, x, y, w, h / 2, RGKeyHalf);
            if (slash) put(L, atoi(slash + 1), x, y + h / 2, w, h / 2, RGKeyHalf);
        } else if (strchr(flags, 'l')) {          // half height, sitting at the bottom of the row
            put(L, code, x, y + h / 2, w, h / 2, f | RGKeyHalf);
        } else if (strchr(flags, '2')) {
            put(L, code, x, y, w, h * 2, f);
        } else {
            put(L, code, x, y, w, h, f | (h < 0.9 ? RGKeyHalf : 0));
        }
        x += w;
    }
}

#include "KeyboardLayouts.inc"

static const RGLayoutSpec *layoutSpec(NSString *name) {
    const char *n = name.UTF8String;
    for (size_t i = 0; i < sizeof kLayoutAliases / sizeof kLayoutAliases[0]; i++)
        if (!strcmp(kLayoutAliases[i][0], n)) n = kLayoutAliases[i][1];
    for (size_t i = 0; i < sizeof kLayoutSpecs / sizeof kLayoutSpecs[0]; i++)
        if (!strcmp(kLayoutSpecs[i].name, n)) return &kLayoutSpecs[i];
    return NULL;
}

static void buildLayout(RGLayout *L, NSString *name) {
    memset(L, 0, sizeof *L);
    const RGLayoutSpec *spec = layoutSpec(name) ?: layoutSpec(@"compact_ANSI_2021");
    for (int r = 0; r < 6; r++) row(L, spec->y[r], spec->h[r], spec->rows[r]);
}

#pragma mark - Key names

// A keyboard type number (as UCKeyTranslate and the event system use them) for each physical
// family. The type of the keyboard last typed on is preferred when it is the right family.
static UInt32 kbdTypeFor(int family) {
    static const UInt32 want[] = {kKeyboardANSI, kKeyboardISO, kKeyboardJIS};
    UInt32 current = LMGetKbdType();
    if (KBGetLayoutType((SInt16)current) == want[family]) return current;
    for (UInt32 t = 0; t < 256; t++) if (KBGetLayoutType((SInt16)t) == want[family]) return t;
    return current;
}

static int familyForKbdType(UInt32 type) {
    UInt32 l = KBGetLayoutType((SInt16)type);
    return l == kKeyboardISO ? RGFamilyISO : l == kKeyboardJIS ? RGFamilyJIS : RGFamilyANSI;
}

// What the current input source types for each key, for the letter, number and symbol keys.
static NSDictionary<NSNumber *, NSString *> *characterLabels(int family) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    TISInputSourceRef src = TISCopyCurrentKeyboardLayoutInputSource();
    CFDataRef data = src ? TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) : NULL;
    if (!data) {   // input methods such as Japanese have no key layout of their own
        if (src) CFRelease(src);
        src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource();
        data = src ? TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) : NULL;
    }
    if (data) {
        const UCKeyboardLayout *layout = (const UCKeyboardLayout *)CFDataGetBytePtr(data);
        UInt32 type = kbdTypeFor(family);
        for (UInt16 code = 0; code < 128; code++) {
            UInt32 dead = 0;
            UniChar ch[4];
            UniCharCount n = 0;
            if (UCKeyTranslate(layout, code, kUCKeyActionDisplay, 0, type, kUCKeyTranslateNoDeadKeysMask, &dead, 4, &n, ch) != noErr || !n) continue;
            if (ch[0] < 0x21 || ch[0] == 0x7f || (ch[0] >= 0xF700 && ch[0] <= 0xF8FF)) continue;   // controls and function keys
            NSString *s = [NSString stringWithCharacters:ch length:n];
            NSString *upper = s.localizedUppercaseString;
            out[@(code)] = upper.length == s.length ? upper : s;
        }
    }
    if (src) CFRelease(src);
    return out;
}

// Labels for keys that don't type a character: a symbol or short name, and the word printed under
// it on Apple's own keycaps.
static void specialLabel(int code, NSString **main, NSString **sub) {
    static NSDictionary<NSNumber *, NSArray<NSString *> *> *names;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @{@53: @[@"esc", @""], @51: @[@"⌫", @"delete"], @117: @[@"⌦", @"delete"], @48: @[@"⇥", @"tab"],
                  @57: @[@"⇪", @"caps lock"], @36: @[@"↩", @"return"], @76: @[@"enter", @""], @110: @[@"menu", @""], @95: @[@",", @""],
                  @56: @[@"⇧", @"shift"], @60: @[@"⇧", @"shift"], @59: @[@"⌃", @"control"], @62: @[@"⌃", @"control"],
                  @58: @[@"⌥", @"option"], @61: @[@"⌥", @"option"], @55: @[@"⌘", @"command"], @54: @[@"⌘", @"command"],
                  @63: @[@"fn", @""], @49: @[@"", @""], @115: @[@"↖", @"home"], @119: @[@"↘", @"end"],
                  @116: @[@"⇞", @"page up"], @121: @[@"⇟", @"page down"], @71: @[@"⌧", @"clear"], @114: @[@"help", @""],
                  @102: @[@"英数", @""], @104: @[@"かな", @""], @123: @[@"◀", @""], @124: @[@"▶", @""], @125: @[@"▼", @""], @126: @[@"▲", @""],
                  @122: @[@"F1", @""], @120: @[@"F2", @""], @99: @[@"F3", @""], @118: @[@"F4", @""], @96: @[@"F5", @""],
                  @97: @[@"F6", @""], @98: @[@"F7", @""], @100: @[@"F8", @""], @101: @[@"F9", @""], @109: @[@"F10", @""],
                  @103: @[@"F11", @""], @111: @[@"F12", @""], @105: @[@"F13", @""], @107: @[@"F14", @""], @113: @[@"F15", @""],
                  @106: @[@"F16", @""], @64: @[@"F17", @""], @79: @[@"F18", @""], @80: @[@"F19", @""],
                  @82: @[@"0", @""], @83: @[@"1", @""], @84: @[@"2", @""], @85: @[@"3", @""], @86: @[@"4", @""], @87: @[@"5", @""],
                  @88: @[@"6", @""], @89: @[@"7", @""], @91: @[@"8", @""], @92: @[@"9", @""], @65: @[@".", @""], @67: @[@"*", @""],
                  @69: @[@"+", @""], @75: @[@"/", @""], @78: @[@"−", @""], @81: @[@"=", @""]};
    });
    NSArray *n = names[@(code)];
    *main = n ? n[0] : nil;
    *sub = n ? n[1] : nil;
}

// A plain name for a key, for the "Last key" card and the report.
static NSString *keyName(int code, NSDictionary<NSNumber *, NSString *> *chars, NSString *topKey) {
    static NSDictionary<NSNumber *, NSString *> *words;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        words = @{@56: @"Left shift", @60: @"Right shift", @59: @"Left control", @62: @"Right control", @58: @"Left option",
                  @61: @"Right option", @55: @"Left command", @54: @"Right command", @63: @"fn (Globe)", @57: @"Caps lock",
                  @49: @"Space", @36: @"Return", @76: @"Enter", @48: @"Tab", @51: @"Delete", @117: @"Forward delete", @53: @"Escape",
                  @123: @"Left arrow", @124: @"Right arrow", @125: @"Down arrow", @126: @"Up arrow", @115: @"Home", @119: @"End",
                  @116: @"Page up", @121: @"Page down", @71: @"Clear", @114: @"Help", @102: @"Eisū (英数)", @104: @"Kana (かな)", @110: @"Contextual menu"};
    });
    if (code == TOP_KEY) return [topKey isEqual:@"eject"] ? @"Eject" : [topKey isEqual:@"lock"] ? @"Lock" : [topKey isEqual:@"power"] ? @"Power" : @"Touch ID";
    if (words[@(code)]) return words[@(code)];
    NSString *main = nil, *sub = nil;
    specialLabel(code, &main, &sub);
    BOOL keypad = (code >= 82 && code <= 92 && code != 90) || code == 65 || code == 67 || code == 69 || code == 75 || code == 78 || code == 81 || code == 95;
    if (keypad) return [@"Keypad " stringByAppendingString:main];
    if (main.length) return main;
    return chars[@(code)] ?: [NSString stringWithFormat:@"Key %d", code];
}

// Media and system keys arrive as system-defined events, not key presses. These are the function
// row positions each one sits on, on every Apple keyboard since 2007 (F3 to F6 vary by model and
// are handled by the system before any app can see them).
static int functionKeyForMediaKey(int nxKey) {
    switch (nxKey) {
        case NX_KEYTYPE_BRIGHTNESS_DOWN: return 122;
        case NX_KEYTYPE_BRIGHTNESS_UP: return 120;
        case NX_KEYTYPE_ILLUMINATION_DOWN: return 96;
        case NX_KEYTYPE_ILLUMINATION_UP: return 97;
        case NX_KEYTYPE_PREVIOUS: case NX_KEYTYPE_REWIND: return 98;
        case NX_KEYTYPE_PLAY: return 100;
        case NX_KEYTYPE_NEXT: case NX_KEYTYPE_FAST: return 101;
        case NX_KEYTYPE_MUTE: return 109;
        case NX_KEYTYPE_SOUND_DOWN: return 103;
        case NX_KEYTYPE_SOUND_UP: return 111;
        case NX_KEYTYPE_EJECT: return TOP_KEY;
    }
    return -1;
}

#pragma mark - Tester state

typedef struct {
    BOOL down, tested, stuck;
    int presses, chatter;
    double downAt, upAt, longest;
} RGKeyState;

@class RGKeyboardView;

@interface RGKeyboardTester () {
@public
    RGLayout layout;
    RGKeyState keys[MAX_CODES];
    int family, rollover, maxRollover, lastCode, testable, testedCount;
    double lastHeld;
    BOOL capsOn, demo, autoFamily, mediaSeen;
    int eventFamily;   // the family of the keyboard last typed on, from the event's keyboard type; -1 until a key arrives
}
@property (strong, readwrite) NSWindow *window;
@property (strong) RGKeyboardView *view;
@property (strong) NSPopUpButton *keyboardPopup, *layoutPopup;
@property (copy) NSArray<NSDictionary *> *keyboards;
@property (copy) NSDictionary *current;
@property (copy) NSDictionary<NSNumber *, NSString *> *chars;
@property (strong) id monitor;
@property (strong) NSTimer *timer;
@property (copy) NSString *layoutOverride;   // nil for automatic, or "compact"/"full" plus a family
- (NSString *)layoutDescription;
- (NSString *)labelFor:(int)code main:(NSString *_Nullable *_Nullable)main sub:(NSString *_Nullable *_Nullable)sub;
@end

#pragma mark - View

static NSColor *srgb(CGFloat r, CGFloat g, CGFloat b, CGFloat a) { return [NSColor colorWithSRGBRed:r green:g blue:b alpha:a]; }

@interface RGKeyboardView : NSView
@property (weak) RGKeyboardTester *kt;
@end

@implementation RGKeyboardView

- (BOOL)isFlipped { return YES; }
- (BOOL)acceptsFirstResponder { return YES; }

- (CGFloat)stripHeight { return 132; }

- (NSRect)keyboardCard {
    CGFloat top = self.safeAreaInsets.top + 16;
    return NSMakeRect(20, top, self.bounds.size.width - 40, MAX(260, self.bounds.size.height - top - 20 - self.stripHeight - 16));
}

- (NSRect)stripCard:(int)i {
    NSRect k = self.keyboardCard;
    CGFloat w = (k.size.width - 2 * 12) / 3;
    return NSMakeRect(k.origin.x + i * (w + 12), NSMaxY(k) + 16, w, self.stripHeight);
}

- (void)drawRect:(NSRect)dirty {
    RGKeyboardTester *kt = self.kt;
    if (!kt) return;
    [NSColor.windowBackgroundColor setFill];
    NSRectFill(self.bounds);
    NSRect card = self.keyboardCard;
    RGDrawCard(card, 18);
    RGDrawText(@"Press every key once", NSMakeRect(card.origin.x + 20, card.origin.y + 16, card.size.width - 40, 20),
               [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    RGDrawText(@"Keys light up as they work. Shortcuts are paused while this window is in front, so ⌘Q and friends are safe to test.",
               NSMakeRect(card.origin.x + 20, card.origin.y + 37, card.size.width - 360, 16),
               [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
    [self drawLegend:NSMakeRect(NSMaxX(card) - 340, card.origin.y + 18, 320, 16)];
    NSRect area = NSInsetRect(NSMakeRect(card.origin.x, card.origin.y + 60, card.size.width, card.size.height - 60), 28, 20);
    [self drawKeyboardIn:area];
    [self drawStrip];
}

- (void)drawLegend:(NSRect)r {
    NSArray *items = @[@[@"Not yet", NSColor.tertiaryLabelColor], @[@"Works", NSColor.systemGreenColor],
                       @[@"Held", NSColor.systemBlueColor], @[@"Chatter or stuck", NSColor.systemOrangeColor]];
    NSFont *f = [NSFont systemFontOfSize:11];
    CGFloat x = NSMaxX(r);
    for (NSArray *it in items.reverseObjectEnumerator) {
        CGFloat w = [it[0] sizeWithAttributes:@{NSFontAttributeName: f}].width;
        x -= w;
        RGDrawText(it[0], NSMakeRect(x, r.origin.y, w + 2, 16), f, NSColor.secondaryLabelColor, NSTextAlignmentLeft);
        x -= 14;
        [(NSColor *)it[1] setFill];
        [[NSBezierPath bezierPathWithRoundedRect:NSMakeRect(x, r.origin.y + 3, 10, 10) xRadius:3 yRadius:3] fill];
        x -= 16;
    }
}

// Aluminium and keycap colours for the keyboard's finish.
- (void)finishFor:(NSDictionary *)d case:(NSColor **)body cap:(NSColor **)cap ink:(NSColor **)ink {
    NSString *colour = d[@"colour"];
    BOOL dark = [colour isEqual:@"black"] || [colour isEqual:@"space grey"];
    *body = dark ? srgb(0.22, 0.22, 0.24, 1) : srgb(0.84, 0.85, 0.86, 1);
    *cap = dark ? srgb(0.10, 0.10, 0.11, 1) : srgb(0.985, 0.985, 0.99, 1);
    *ink = dark ? srgb(0.92, 0.92, 0.94, 1) : srgb(0.16, 0.16, 0.18, 1);
}

- (NSBezierPath *)pathForKey:(const RGKey *)k origin:(NSPoint)o unit:(CGFloat)u {
    CGFloat inset = u * 0.06, radius = u * 0.12;
    NSRect r = NSMakeRect(o.x + k->x * u, o.y + k->y * u, k->w * u, k->h * u);
    r = NSInsetRect(r, inset, inset);
    if (k->flags & RGKeyReturnTop) r.size.height += inset * 2 + 1;                  // join the two halves of an ISO Return
    if (k->flags & RGKeyReturnBottom) { r.origin.y -= inset * 2 + 1; r.size.height += inset * 2 + 1; }
    return [NSBezierPath bezierPathWithRoundedRect:r xRadius:radius yRadius:radius];
}

- (void)drawKeyboardIn:(NSRect)area {
    RGKeyboardTester *kt = self.kt;
    RGLayout *L = &kt->layout;
    if (!L->count) return;
    CGFloat pad = 0.42;
    CGFloat u = floor(MIN(area.size.width / (L->width + 2 * pad), area.size.height / (L->height + 2 * pad)) * 2) / 2;
    NSSize size = NSMakeSize((L->width + 2 * pad) * u, (L->height + 2 * pad) * u);
    NSRect board = NSMakeRect(round(NSMidX(area) - size.width / 2), round(NSMidY(area) - size.height / 2), size.width, size.height);
    NSPoint origin = NSMakePoint(board.origin.x + pad * u, board.origin.y + pad * u);

    NSColor *body, *cap, *ink;
    [self finishFor:kt.current case:&body cap:&cap ink:&ink];
    NSBezierPath *shell = [NSBezierPath bezierPathWithRoundedRect:board xRadius:u * 0.5 yRadius:u * 0.5];
    [NSGraphicsContext saveGraphicsState];
    NSShadow *sh = [NSShadow new];
    sh.shadowColor = [NSColor colorWithWhite:0 alpha:0.28];
    sh.shadowBlurRadius = u * 0.5;
    sh.shadowOffset = NSMakeSize(0, -u * 0.12);
    [sh set];
    [body setFill];
    [shell fill];
    [NSGraphicsContext restoreGraphicsState];
    NSGradient *metal = [[NSGradient alloc] initWithStartingColor:[body blendedColorWithFraction:0.35 ofColor:NSColor.whiteColor]
                                                      endingColor:[body blendedColorWithFraction:0.18 ofColor:NSColor.blackColor]];
    [metal drawInBezierPath:shell angle:90];

    double now = NSProcessInfo.processInfo.systemUptime;
    for (int i = 0; i < L->count; i++) {
        const RGKey *k = &L->keys[i];
        RGKeyState *s = &kt->keys[k->code];
        NSBezierPath *p = [self pathForKey:k origin:origin unit:u];
        BOOL system = k->flags & RGKeySystem;
        BOOL warn = s->chatter > 0 || s->stuck;
        NSColor *fill = cap;
        if (s->down) fill = [cap blendedColorWithFraction:0.72 ofColor:NSColor.systemBlueColor];
        else if (warn) fill = [cap blendedColorWithFraction:0.6 ofColor:NSColor.systemOrangeColor];
        else if (s->tested) fill = [cap blendedColorWithFraction:0.55 ofColor:NSColor.systemGreenColor];
        // keycap: a darker skirt below, then the top
        [NSGraphicsContext saveGraphicsState];
        NSAffineTransform *t = [NSAffineTransform transform];
        [t translateXBy:0 yBy:s->down ? 0 : u * 0.03];
        NSBezierPath *skirt = [p copy];
        [skirt transformUsingAffineTransform:t];
        [[NSColor colorWithWhite:0 alpha:0.22] setFill];
        [skirt fill];
        [NSGraphicsContext restoreGraphicsState];
        if (s->down) {
            NSAffineTransform *press = [NSAffineTransform transform];
            [press translateXBy:0 yBy:u * 0.02];
            [p transformUsingAffineTransform:press];
        }
        [fill setFill];
        [p fill];
        if (system) {
            NSBezierPath *dash = [p copy];
            CGFloat pattern[] = {3, 3};
            [dash setLineDash:pattern count:2 phase:0];
            dash.lineWidth = 1;
            [[ink colorWithAlphaComponent:0.35] setStroke];
            [dash stroke];
        }
        if (s->stuck && fmod(now, 1.0) < 0.5) {
            p.lineWidth = 2;
            [NSColor.systemRedColor setStroke];
            [p stroke];
        }
        [self drawLabelFor:k state:s in:p.bounds unit:u ink:system ? [ink colorWithAlphaComponent:0.45] : ink];
    }
}

- (void)drawLabelFor:(const RGKey *)k state:(RGKeyState *)s in:(NSRect)r unit:(CGFloat)u ink:(NSColor *)ink {
    RGKeyboardTester *kt = self.kt;
    if (k->flags & RGKeyReturnBottom) return;   // the label sits on the top half
    NSString *main = nil, *sub = nil;
    [kt labelFor:k->code main:&main sub:&sub];
    NSString *symbol = nil;
    if (k->code == TOP_KEY) {
        NSString *top = kt.current[@"topKey"];
        symbol = [top isEqual:@"eject"] ? @"eject.fill" : [top isEqual:@"lock"] ? @"lock.fill" : [top isEqual:@"power"] ? @"power" : @"touchid";
        main = nil;
    } else if (k->code == 63 && [kt.current[@"globe"] boolValue]) symbol = @"globe";
    if (symbol) {
        NSImage *img = [RGSymbol(symbol, keyName(k->code, kt.chars, kt.current[@"topKey"])) imageWithSymbolConfiguration:
                        [NSImageSymbolConfiguration configurationWithPointSize:MAX(8, u * 0.24) weight:NSFontWeightRegular]];
        NSImage *tinted = [NSImage imageWithSize:img.size flipped:NO drawingHandler:^BOOL(NSRect dst) {
            [img drawInRect:dst];
            [ink set];
            NSRectFillUsingOperation(dst, NSCompositingOperationSourceAtop);
            return YES;
        }];
        NSRect ir = NSMakeRect(NSMidX(r) - img.size.width / 2, NSMidY(r) - img.size.height / 2 - (main.length ? u * 0.1 : 0), img.size.width, img.size.height);
        if (k->code == 63) {   // Globe at the bottom left, "fn" at the top right, as on the keycap
            ir.origin = NSMakePoint(r.origin.x + u * 0.13, NSMaxY(r) - img.size.height - u * 0.11);
            NSRect inner = NSInsetRect(r, u * 0.13, u * 0.1);
            RGDrawText(@"fn", NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width, u * 0.24), [NSFont systemFontOfSize:MAX(8, u * 0.17)], ink, NSTextAlignmentRight);
            main = nil;
        }
        [tinted drawInRect:ir fromRect:NSZeroRect operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
    }
    if (k->code == 57) {   // caps lock light
        CGFloat d = MAX(4, u * 0.09);
        NSRect led = NSMakeRect(r.origin.x + u * 0.14, r.origin.y + u * 0.14, d, d);
        [(kt->capsOn ? NSColor.systemGreenColor : [ink colorWithAlphaComponent:0.18]) setFill];
        [[NSBezierPath bezierPathWithOvalInRect:led] fill];
    }
    if (!main.length) return;
    BOOL fkey = main.length >= 2 && [main hasPrefix:@"F"] && isdigit([main characterAtIndex:1]);
    BOOL word = main.length > 2 && !fkey;
    BOOL small = (k->flags & RGKeyHalf) || k->h < 0.9 || fkey || word;
    CGFloat size = small ? MAX(7, u * 0.19) : MAX(9, u * (main.length > 1 && !sub.length ? 0.24 : 0.32));
    NSFont *f = [NSFont systemFontOfSize:size weight:NSFontWeightRegular];
    if (sub.length && r.size.height > u * 0.7 && (k->w >= 1.2 || u >= 44)) {
        // Apple style: symbol at the top, word along the bottom, both towards the outer edge
        BOOL right = k->code == 51 || k->code == 36 || k->code == 60 || k->code == 54 || k->code == 61 || k->code == 62 || k->code == 76;
        NSTextAlignment al = right ? NSTextAlignmentRight : NSTextAlignmentLeft;
        NSRect inner = NSInsetRect(r, u * 0.13, u * 0.1);
        RGDrawText(main, NSMakeRect(inner.origin.x, inner.origin.y, inner.size.width, size + 4), [NSFont systemFontOfSize:MAX(8, u * 0.2)], ink, al);
        NSFont *subFont = [NSFont systemFontOfSize:MAX(7, u * 0.15)];
        CGFloat subWidth = [sub sizeWithAttributes:@{NSFontAttributeName: subFont}].width;
        if (subWidth > inner.size.width) subFont = [NSFont systemFontOfSize:subFont.pointSize * inner.size.width / subWidth];
        RGDrawText(sub, NSMakeRect(inner.origin.x, NSMaxY(inner) - MAX(9, u * 0.18) - 3, inner.size.width + 2, MAX(9, u * 0.18) + 3),
                   subFont, ink, al);
        return;
    }
    NSDictionary *a = @{NSFontAttributeName: f};
    NSSize z = [main sizeWithAttributes:a];
    if (z.width > r.size.width - 6) {
        f = [NSFont systemFontOfSize:size * (r.size.width - 6) / z.width];
        z = [main sizeWithAttributes:@{NSFontAttributeName: f}];
    }
    RGDrawText(main, NSMakeRect(r.origin.x, NSMidY(r) - z.height / 2, r.size.width, z.height + 1), f, ink, NSTextAlignmentCenter);
}

- (void)drawCardTitle:(NSString *)title symbol:(NSString *)symbol in:(NSRect)t {
    NSImage *icon = [RGSymbol(symbol, title) imageWithSymbolConfiguration:
                     [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightMedium]];
    [icon drawInRect:NSMakeRect(t.origin.x + 16, t.origin.y + 15, icon.size.width, icon.size.height) fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver fraction:0.6 respectFlipped:YES hints:nil];
    RGDrawText(title.uppercaseString, NSMakeRect(t.origin.x + 40, t.origin.y + 15, t.size.width - 56, 16),
               [NSFont systemFontOfSize:11 weight:NSFontWeightSemibold], NSColor.secondaryLabelColor, NSTextAlignmentLeft);
}

- (void)drawLines:(NSArray<NSString *> *)lines from:(CGFloat)y in:(NSRect)t font:(NSFont *)f colour:(NSColor *)c {
    for (NSString *line in lines) {
        RGDrawText(line, NSMakeRect(t.origin.x + 16, y, t.size.width - 32, 17), f, c, NSTextAlignmentLeft);
        y += 18;
    }
}

- (void)drawStrip {
    RGKeyboardTester *kt = self.kt;
    NSDictionary *d = kt.current;
    NSFont *body = [NSFont systemFontOfSize:12], *mono = [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular];

    NSRect t = [self stripCard:0];
    RGDrawCard(t, 16);
    [self drawCardTitle:@"Keyboard" symbol:@"keyboard" in:t];
    RGDrawText(d[@"name"] ?: @"Any keyboard", NSMakeRect(t.origin.x + 16, t.origin.y + 38, t.size.width - 32, 20),
               [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    NSMutableArray *lines = [NSMutableArray array];
    NSString *model = d[@"model"];
    if (model.length) [lines addObject:d[@"years"] ? [NSString stringWithFormat:@"%@ · %@", model, d[@"years"]] : model];
    [lines addObject:kt.layoutDescription];
    NSMutableArray *conn = [NSMutableArray array];
    if (d[@"transport"]) [conn addObject:d[@"transport"]];
    if (d[@"firmware"]) [conn addObject:[@"firmware " stringByAppendingString:d[@"firmware"]]];
    if (d[@"battery"]) [conn addObject:[NSString stringWithFormat:@"battery %@%%", d[@"battery"]]];
    if (conn.count) [lines addObject:[conn componentsJoinedByString:@" · "]];
    [self drawLines:lines from:t.origin.y + 62 in:t font:body colour:NSColor.secondaryLabelColor];

    t = [self stripCard:1];
    RGDrawCard(t, 16);
    [self drawCardTitle:@"Progress" symbol:@"checklist" in:t];
    BOOL done = kt->testable && kt->testedCount >= kt->testable;
    NSString *count = [NSString stringWithFormat:@"%d of %d keys", kt->testedCount, kt->testable];
    RGDrawText(count, NSMakeRect(t.origin.x + 16, t.origin.y + 38, t.size.width - 140, 20),
               [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
    if (done) RGDrawPill(NSMakeRect(NSMaxX(t) - 16 - 96, t.origin.y + 37, 96, 22), @"All work", NSColor.systemGreenColor);
    NSRect bar = NSMakeRect(t.origin.x + 16, t.origin.y + 64, t.size.width - 32, 6);
    [NSColor.quaternaryLabelColor setFill];
    [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:3 yRadius:3] fill];
    bar.size.width *= kt->testable ? MIN(1.0, (double)kt->testedCount / kt->testable) : 0;
    [NSColor.systemGreenColor setFill];
    if (bar.size.width > 0) [[NSBezierPath bezierPathWithRoundedRect:bar xRadius:3 yRadius:3] fill];
    int chatterKeys = 0, stuckKeys = 0;
    for (int c = 0; c < MAX_CODES; c++) { if (kt->keys[c].chatter) chatterKeys++; if (kt->keys[c].stuck) stuckKeys++; }
    NSArray *stats = @[[NSString stringWithFormat:@"Rollover   %@", kt->maxRollover ? [NSString stringWithFormat:@"%d keys at once", kt->maxRollover] : @"–"],
                       [NSString stringWithFormat:@"Chatter    %@", chatterKeys ? [NSString stringWithFormat:@"%d key%@", chatterKeys, chatterKeys == 1 ? @"" : @"s"] : @"none"],
                       [NSString stringWithFormat:@"Stuck      %@", stuckKeys ? [NSString stringWithFormat:@"%d key%@", stuckKeys, stuckKeys == 1 ? @"" : @"s"] : @"none"]];
    [self drawLines:stats from:t.origin.y + 80 in:t font:mono colour:NSColor.labelColor];
    if (chatterKeys || stuckKeys) {
        NSRect dot = NSMakeRect(NSMaxX(t) - 26, t.origin.y + 84 + (chatterKeys ? 18 : 36), 9, 9);
        [NSColor.systemOrangeColor setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }

    t = [self stripCard:2];
    RGDrawCard(t, 16);
    [self drawCardTitle:@"Last key" symbol:@"keyboard.badge.ellipsis" in:t];
    if (kt->lastCode >= 0) {
        RGKeyState *s = &kt->keys[kt->lastCode];
        RGDrawText(keyName(kt->lastCode, kt.chars, d[@"topKey"]), NSMakeRect(t.origin.x + 16, t.origin.y + 38, t.size.width - 32, 20),
                   [NSFont systemFontOfSize:15 weight:NSFontWeightSemibold], NSColor.labelColor, NSTextAlignmentLeft);
        NSMutableArray *info = [NSMutableArray array];
        [info addObject:kt->lastCode == TOP_KEY ? @"System key" : [NSString stringWithFormat:@"Key code %d (0x%02X)", kt->lastCode, kt->lastCode]];
        NSString *held = s->down ? @"held now" : [NSString stringWithFormat:@"held %.0f ms", kt->lastHeld * 1000];
        [info addObject:[NSString stringWithFormat:@"Pressed %d× · %@", s->presses, held]];
        if (s->chatter) [info addObject:[NSString stringWithFormat:@"Chattered %d× (re-pressed within %.0f ms)", s->chatter, CHATTER_GAP * 1000]];
        [self drawLines:info from:t.origin.y + 62 in:t font:body colour:NSColor.secondaryLabelColor];
    } else {
        NSString *hint = kt->demo ? @"" : @"Type anything to begin. Hold fn (Globe) while you press F1–F12 so they arrive as function keys rather than brightness and volume.";
        NSMutableParagraphStyle *ps = [NSMutableParagraphStyle new];
        ps.lineBreakMode = NSLineBreakByWordWrapping;
        [hint drawInRect:NSMakeRect(t.origin.x + 16, t.origin.y + 40, t.size.width - 32, 60)
          withAttributes:@{NSFontAttributeName: body, NSForegroundColorAttributeName: NSColor.secondaryLabelColor, NSParagraphStyleAttributeName: ps}];
    }
}

- (void)mouseDown:(NSEvent *)e { [self.window makeFirstResponder:self]; }

- (BOOL)isAccessibilityElement { return YES; }
- (NSAccessibilityRole)accessibilityRole { return NSAccessibilityGroupRole; }
- (NSString *)accessibilityLabel { return @"Keyboard tester"; }
- (NSString *)accessibilityValue {
    RGKeyboardTester *kt = self.kt;
    NSString *last = kt->lastCode >= 0 ? [@". Last key: " stringByAppendingString:keyName(kt->lastCode, kt.chars, kt.current[@"topKey"])] : @"";
    return [NSString stringWithFormat:@"%d of %d keys work%@", kt->testedCount, kt->testable, last];
}
@end

#pragma mark - Controller

static NSToolbarItemIdentifier const kKeyboardItem = @"keyboard", kLayoutItem = @"layout", kResetItem = @"reset", kReportItem = @"report";

// Right- and left-hand modifier bits in an event's device-dependent flags (IOLLEvent.h, NX_DEVICE*KEYMASK).
static uint64_t modifierMask(int code) {
    switch (code) {
        case 59: return 0x0001;  case 62: return 0x2000;   // control
        case 56: return 0x0002;  case 60: return 0x0004;   // shift
        case 55: return 0x0008;  case 54: return 0x0010;   // command
        case 58: return 0x0020;  case 61: return 0x0040;   // option
        case 63: return NSEventModifierFlagFunction;
    }
    return 0;
}

@implementation RGKeyboardTester

- (instancetype)init {
    if ((self = [super init])) {
        lastCode = -1;
        eventFamily = -1;
        autoFamily = YES;
    }
    return self;
}

#pragma mark Layout

// The family drawn: an override from the Layout menu, else the country code the keyboard reports,
// else the keyboard type of the last key event, else what macOS thinks is attached.
- (int)resolvedFamily {
    if (self.layoutOverride) return (int)[self.layoutOverride substringFromIndex:self.layoutOverride.length - 1].integerValue;
    if (self.current[@"family"]) return [self.current[@"family"] intValue];
    if (demo) return RGFamilyANSI;
    if (eventFamily >= 0) return eventFamily;
    return familyForKbdType(LMGetKbdType());
}

- (NSString *)familySource {
    if (self.layoutOverride) return @"chosen";
    if (self.current[@"family"]) return @"from the keyboard";
    if (eventFamily >= 0 && !demo) return @"detected";
    return @"from macOS";
}

// The layout name, e.g. "compact_ISO_2021". An override keeps the keyboard's generation when the
// shape matches, and otherwise uses the 2021 design.
- (NSString *)layoutName {
    NSString *pattern = self.current[@"layout"] ?: @"compact_%@_2021";
    if (self.layoutOverride) {
        NSString *form = [self.layoutOverride hasPrefix:@"full"] ? @"full" : @"compact";
        if (![pattern hasPrefix:form]) pattern = [form stringByAppendingString:@"_%@_2021"];
    }
    return [NSString stringWithFormat:pattern, kFamilyNames[family]];
}

- (void)rebuildLayout {
    family = self.resolvedFamily;
    buildLayout(&layout, self.layoutName);
    self.chars = characterLabels(family);
    [self recount];
    self.view.needsDisplay = YES;
}

- (void)recount {
    NSMutableIndexSet *codes = [NSMutableIndexSet indexSet];
    for (int i = 0; i < layout.count; i++) if (!(layout.keys[i].flags & RGKeySystem)) [codes addIndex:(NSUInteger)layout.keys[i].code];
    testable = (int)codes.count;
    __block int n = 0;
    [codes enumerateIndexesUsingBlock:^(NSUInteger c, BOOL *stop) { if (self->keys[c].tested) n++; }];
    testedCount = n;
}

- (NSString *)layoutDescription {
    NSString *name = self.layoutName;
    NSString *shape = [name hasPrefix:@"full"] ? @"Full size with numeric keypad" : [name hasPrefix:@"laptop"] ? @"Built-in"
                    : [name hasPrefix:@"classic"] ? @"Compact, aluminium" : @"Compact";
    return [NSString stringWithFormat:@"%@ · %@ (%@)", shape, kFamilyNames[family], self.familySource];
}

- (NSString *)labelFor:(int)code main:(NSString **)main sub:(NSString **)sub {
    NSString *m = nil, *s = nil;
    specialLabel(code, &m, &s);
    BOOL keypad = (code >= 82 && code <= 92) || code == 65 || code == 67 || code == 69 || code == 75 || code == 78 || code == 81 || code == 95;
    if (!m || (!keypad && self.chars[@(code)] && code != 49)) {
        NSString *c = self.chars[@(code)];
        if (c) { m = c; s = nil; }
    }
    if (main) *main = m;
    if (sub) *sub = s;
    return m ?: @"";
}

#pragma mark Window

- (void)buildWindow {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1120, 700)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable |
                  NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"Keyboard Tester";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.tabbingMode = NSWindowTabbingModeDisallowed;
    self.window.contentMinSize = NSMakeSize(900, 600);

    self.keyboardPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 220, 28) pullsDown:NO];
    self.keyboardPopup.target = self;
    self.keyboardPopup.action = @selector(keyboardChanged:);
    self.keyboardPopup.accessibilityLabel = @"Keyboard";
    self.layoutPopup = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 210, 28) pullsDown:NO];
    self.layoutPopup.target = self;
    self.layoutPopup.action = @selector(layoutChanged:);
    self.layoutPopup.accessibilityLabel = @"Layout";
    [self.layoutPopup addItemWithTitle:@"Automatic layout"];
    self.layoutPopup.lastItem.representedObject = nil;
    [self.layoutPopup.menu addItem:NSMenuItem.separatorItem];
    for (NSString *form in @[@"compact", @"full"]) {
        for (int f = 0; f < 3; f++) {
            NSString *title = [NSString stringWithFormat:@"%@ · %@", [form isEqual:@"full"] ? @"With numeric keypad" : @"Compact", kFamilyNames[f]];
            [self.layoutPopup addItemWithTitle:title];
            self.layoutPopup.lastItem.representedObject = [NSString stringWithFormat:@"%@%d", form, f];
        }
    }

    NSToolbar *toolbar = [[NSToolbar alloc] initWithIdentifier:@"KeyboardTesterToolbar"];
    toolbar.delegate = self;
    toolbar.displayMode = NSToolbarDisplayModeIconOnly;
    self.window.toolbar = toolbar;
    self.window.toolbarStyle = NSWindowToolbarStyleUnified;

    self.view = [[RGKeyboardView alloc] initWithFrame:NSMakeRect(0, 0, 1120, 700)];
    self.view.kt = self;
    self.window.contentView = self.view;
    [self.window center];
    [self.window setFrameAutosaveName:@"RodentGymKeyboardTester"];
}

- (NSArray<NSToolbarItemIdentifier> *)toolbarDefaultItemIdentifiers:(NSToolbar *)toolbar {
    return @[kKeyboardItem, kLayoutItem, NSToolbarFlexibleSpaceItemIdentifier, kResetItem, kReportItem];
}
- (NSArray<NSToolbarItemIdentifier> *)toolbarAllowedItemIdentifiers:(NSToolbar *)toolbar { return [self toolbarDefaultItemIdentifiers:toolbar]; }

- (NSToolbarItem *)toolbar:(NSToolbar *)toolbar itemForItemIdentifier:(NSToolbarItemIdentifier)ident willBeInsertedIntoToolbar:(BOOL)flag {
    NSToolbarItem *item = [[NSToolbarItem alloc] initWithItemIdentifier:ident];
    if ([ident isEqualToString:kKeyboardItem]) {
        item.label = @"Keyboard";
        item.view = self.keyboardPopup;
    } else if ([ident isEqualToString:kLayoutItem]) {
        item.label = @"Layout";
        item.view = self.layoutPopup;
    } else if ([ident isEqualToString:kResetItem]) {
        item.label = @"Start Over";
        item.image = RGSymbol(@"arrow.counterclockwise", @"Start over");
        item.toolTip = @"Clear every key and start again";
        item.target = self;
        item.action = @selector(reset:);
        item.bordered = YES;
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

#pragma mark Keyboards and layout choice

- (void)reloadKeyboards {
    NSArray *list = demo ? self.keyboards : RGConnectedKeyboards(NO);
    NSString *keep = self.current[@"key"];
    self.keyboards = list;
    [self.keyboardPopup removeAllItems];
    for (NSDictionary *d in list) [self.keyboardPopup addItemWithTitle:d[@"name"]];
    if (!list.count) [self.keyboardPopup addItemWithTitle:@"No keyboard found"];
    NSDictionary *pick = list.firstObject;
    for (NSDictionary *d in list) if ([d[@"key"] isEqual:keep]) pick = d;
    self.current = pick;
    if (pick) [self.keyboardPopup selectItemAtIndex:(NSInteger)[list indexOfObject:pick]];
    [self rebuildLayout];
}

- (void)keyboardChanged:(NSPopUpButton *)p {
    NSInteger i = p.indexOfSelectedItem;
    if (i < 0 || i >= (NSInteger)self.keyboards.count) return;
    self.current = self.keyboards[(NSUInteger)i];
    [self rebuildLayout];
}

- (void)layoutChanged:(NSPopUpButton *)p {
    self.layoutOverride = p.selectedItem.representedObject;
    [self rebuildLayout];
}

- (void)reset:(id)sender {
    memset(keys, 0, sizeof keys);
    rollover = maxRollover = 0;
    lastCode = -1;
    lastHeld = 0;
    mediaSeen = NO;
    [self recount];
    self.view.needsDisplay = YES;
}

#pragma mark Key events

// Keys are read with a local event monitor, which only ever sees events addressed to RodentGym, and
// only while this window is the key window. Key events are consumed so that shortcuts such as ⌘Q
// or ⌘W don't fire mid-test. Media keys are passed on so volume still works.
- (void)startListening {
    if (self.monitor || demo) return;
    __weak RGKeyboardTester *weakSelf = self;
    NSEventMask mask = NSEventMaskKeyDown | NSEventMaskKeyUp | NSEventMaskFlagsChanged | NSEventMaskSystemDefined;
    self.monitor = [NSEvent addLocalMonitorForEventsMatchingMask:mask handler:^NSEvent *(NSEvent *e) {
        RGKeyboardTester *s = weakSelf;
        if (!s || NSApp.keyWindow != s.window || !s.window.visible) return e;
        return [s handle:e] ? nil : e;
    }];
}

- (void)stopListening {
    if (self.monitor) [NSEvent removeMonitor:self.monitor];
    self.monitor = nil;
}

// The keyboard type travels with each key event, so the drawing can follow whichever keyboard is
// being typed on (ANSI, ISO or JIS).
- (void)noteFamily:(NSEvent *)e {
    CGEventRef cg = e.CGEvent;
    if (!cg) return;
    int64_t type = CGEventGetIntegerValueField(cg, kCGKeyboardEventKeyboardType);
    if (type <= 0) return;
    int f = familyForKbdType((UInt32)type);
    if (f == eventFamily) return;
    eventFamily = f;
    if (!self.layoutOverride && f != family) [self rebuildLayout];
}

- (BOOL)handle:(NSEvent *)e {
    double t = e.timestamp;
    switch (e.type) {
        case NSEventTypeKeyDown:
            [self noteFamily:e];
            if (!e.isARepeat) [self key:e.keyCode down:YES at:t];
            return YES;
        case NSEventTypeKeyUp:
            [self key:e.keyCode down:NO at:t];
            return YES;
        case NSEventTypeFlagsChanged: {
            [self noteFamily:e];
            int code = e.keyCode;
            if (code == 57) {   // caps lock reports one change per press, and toggles
                capsOn = (e.modifierFlags & NSEventModifierFlagCapsLock) != 0;
                [self tap:57];
                return YES;
            }
            uint64_t m = modifierMask(code);
            if (!m) return YES;
            BOOL down = (e.modifierFlags & m) != 0;
            if (down == keys[code].down) down = !keys[code].down;   // a keyboard that doesn't report left and right separately
            [self key:code down:down at:t];
            return YES;
        }
        case NSEventTypeSystemDefined:
            if (e.subtype == 8) {   // media keys: brightness, playback, volume, eject
                int nx = (int)(((NSUInteger)e.data1 & 0xFFFF0000) >> 16);
                BOOL down = (((NSUInteger)e.data1 & 0xFF00) >> 8) == 0xA, repeat = ((NSUInteger)e.data1 & 0x1) != 0;
                int code = functionKeyForMediaKey(nx);
                if (code >= 0 && !repeat) {
                    mediaSeen = YES;
                    [self key:code down:down at:t];
                }
            }
            return NO;
        default:
            return NO;
    }
}

- (void)key:(int)code down:(BOOL)down at:(double)t {
    if (code < 0 || code >= MAX_CODES) return;
    RGKeyState *s = &keys[code];
    if (down) {
        if (s->down) return;
        if (s->presses > 0 && s->upAt > 0 && t - s->upAt < CHATTER_GAP) s->chatter++;
        s->down = YES;
        s->tested = YES;
        s->downAt = t;
        s->presses++;
        lastCode = code;
        rollover++;
        maxRollover = MAX(maxRollover, rollover);
    } else {
        if (!s->down) {   // pressed before the window came to the front
            s->tested = YES;
            s->upAt = t;
        } else {
            s->down = NO;
            s->stuck = NO;
            s->upAt = t;
            double held = t - s->downAt;
            s->longest = MAX(s->longest, held);
            if (code == lastCode) lastHeld = held;
            rollover = MAX(0, rollover - 1);
        }
    }
    [self recount];
    self.view.needsDisplay = YES;
}

// A key that reports a single change per press (caps lock).
- (void)tap:(int)code {
    RGKeyState *s = &keys[code];
    s->tested = YES;
    s->presses++;
    lastCode = code;
    lastHeld = 0;
    [self recount];
    self.view.needsDisplay = YES;
}

// Without the window in front, key releases go elsewhere; forget what was held.
- (void)releaseAll {
    for (int c = 0; c < MAX_CODES; c++) { keys[c].down = NO; keys[c].stuck = NO; }
    rollover = 0;
    self.view.needsDisplay = YES;
}

- (void)tick {
    double now = NSProcessInfo.processInfo.systemUptime;
    BOOL any = NO;
    for (int c = 0; c < MAX_CODES; c++) {
        RGKeyState *s = &keys[c];
        if (!s->down) continue;
        any = YES;
        if (!s->stuck && now - s->downAt > STUCK_AFTER) s->stuck = YES;
    }
    if (any) self.view.needsDisplay = YES;
}

#pragma mark Report

- (NSString *)namesFor:(BOOL (^)(int code, RGKeyState *s))test {
    NSMutableArray *names = [NSMutableArray array];
    NSMutableIndexSet *seen = [NSMutableIndexSet indexSet];
    for (int i = 0; i < layout.count; i++) {
        int c = layout.keys[i].code;
        if ((layout.keys[i].flags & RGKeySystem) || [seen containsIndex:(NSUInteger)c]) continue;
        [seen addIndex:(NSUInteger)c];
        if (test(c, &keys[c])) [names addObject:keyName(c, self.chars, self.current[@"topKey"])];
    }
    return names.count ? [names componentsJoinedByString:@", "] : @"none";
}

- (NSString *)report {
    NSDictionary *d = self.current ?: @{};
    NSDateFormatter *fmt = [NSDateFormatter new];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    NSMutableString *r = [NSMutableString stringWithString:@"RodentGym Keyboard Tester\n"];
    [r appendFormat:@"Date: %@\n", [fmt stringFromDate:NSDate.date]];
    [r appendFormat:@"Mac: %@ · %@\n", macName(), NSProcessInfo.processInfo.operatingSystemVersionString];
    [r appendFormat:@"Keyboard: %@ — %@%@\n", d[@"name"] ?: @"unknown", d[@"model"] ?: @"", d[@"years"] ? [@" · " stringByAppendingString:d[@"years"]] : @""];
    NSMutableArray *conn = [NSMutableArray array];
    if (d[@"transport"]) [conn addObject:d[@"transport"]];
    if (d[@"firmware"]) [conn addObject:[@"firmware " stringByAppendingString:d[@"firmware"]]];
    if (d[@"battery"]) [conn addObject:[NSString stringWithFormat:@"battery %@%%", d[@"battery"]]];
    if (conn.count) [r appendFormat:@"Connection: %@\n", [conn componentsJoinedByString:@" · "]];
    if (d[@"serial"]) [r appendFormat:@"Serial / address: %@\n", d[@"serial"]];
    [r appendFormat:@"Layout: %@\n\n", self.layoutDescription];
    [r appendFormat:@"Keys working: %d of %d\n", testedCount, testable];
    [r appendFormat:@"Not pressed: %@\n", [self namesFor:^BOOL(int c, RGKeyState *s) { return !s->tested; }]];
    NSMutableArray *chatter = [NSMutableArray array];
    for (int c = 0; c < MAX_CODES; c++)
        if (keys[c].chatter) [chatter addObject:[NSString stringWithFormat:@"%@ (%d×)", keyName(c, self.chars, d[@"topKey"]), keys[c].chatter]];
    [r appendFormat:@"Chatter (re-pressed within %.0f ms): %@\n", CHATTER_GAP * 1000, chatter.count ? [chatter componentsJoinedByString:@", "] : @"none"];
    [r appendFormat:@"Held longer than %.0f s: %@\n", STUCK_AFTER, [self namesFor:^BOOL(int c, RGKeyState *s) { return s->longest > STUCK_AFTER || s->stuck; }]];
    [r appendFormat:@"Highest rollover: %d keys at once\n", maxRollover];
    [r appendString:@"\nSystem keys (Touch ID, lock, and anything macOS handles itself) can't be seen by apps and aren't counted.\n"];
    return r;
}

- (void)copyReport:(id)sender {
    [NSPasteboard.generalPasteboard clearContents];
    [NSPasteboard.generalPasteboard setString:self.report forType:NSPasteboardTypeString];
    self.window.subtitle = @"Report copied";
    [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(clearSubtitle) object:nil];
    [self performSelector:@selector(clearSubtitle) withObject:nil afterDelay:2.5];
}

- (void)clearSubtitle { self.window.subtitle = @""; }

#pragma mark Lifecycle

- (void)show {
    if (!self.window) [self buildWindow];
    [self reloadKeyboards];
    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:self.view];
    [self startListening];
    if (!self.timer && !demo) {
        self.timer = [NSTimer timerWithTimeInterval:0.1 target:self selector:@selector(tick) userInfo:nil repeats:YES];
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    if (!demo)
        [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(inputSourceChanged:)
            name:(__bridge NSString *)kTISNotifySelectedKeyboardInputSourceChanged object:nil];
}

- (void)inputSourceChanged:(NSNotification *)n {
    self.chars = characterLabels(family);
    self.view.needsDisplay = YES;
}

- (void)windowDidBecomeKey:(NSNotification *)n {
    if (demo) return;
    NSString *before = [[self.keyboards valueForKey:@"key"] componentsJoinedByString:@","];
    NSArray *now = RGConnectedKeyboards(NO);
    if (![[[now valueForKey:@"key"] componentsJoinedByString:@","] isEqual:before]) [self reloadKeyboards];
}

- (void)windowDidResignKey:(NSNotification *)n { [self releaseAll]; }

- (void)windowWillClose:(NSNotification *)n {
    [self stopListening];
    [self.timer invalidate];
    self.timer = nil;
    [NSDistributedNotificationCenter.defaultCenter removeObserver:self];
    [self releaseAll];
    if (!demo && testedCount > 0 && self.log) {
        int chatterKeys = 0;
        for (int c = 0; c < MAX_CODES; c++) if (keys[c].chatter) chatterKeys++;
        self.log([NSString stringWithFormat:@"· Keyboard Tester: %d of %d keys work on %@ · rollover %d · %@", testedCount, testable,
                  self.current[@"name"] ?: @"the keyboard", maxRollover,
                  chatterKeys ? [NSString stringWithFormat:@"chatter on %d key%@", chatterKeys, chatterKeys == 1 ? @"" : @"s"] : @"no chatter"]);
    }
}

#pragma mark Demo

- (void)showDemo {
    demo = YES;
    self.keyboards = @[@{@"name": @"Magic Keyboard", @"key": @"demo-keyboard", @"model": @"Magic Keyboard with Touch ID",
                         @"years": @"2021", @"layout": @"compact_%@_2021", @"family": @0, @"topKey": @"touchid",
                         @"globe": @YES, @"transport": @"Bluetooth", @"firmware": @"2.0.6", @"battery": @84, @"builtIn": @NO}];
    [self show];
    // Most of the board done, working from the left; shift and G held at the moment of the screenshot
    for (int i = 0; i < layout.count; i++) {
        const RGKey *k = &layout.keys[i];
        if (k->flags & RGKeySystem) continue;
        if (k->x < 9.2 || k->y < 1.2) keys[k->code].tested = YES;
        keys[k->code].presses = keys[k->code].tested ? 1 : 0;
    }
    keys[56].down = keys[5].down = YES;
    keys[5].presses = 2;
    lastCode = 5;
    maxRollover = 6;
    [self recount];
    self.view.needsDisplay = YES;
}

// Renders every layout to <dir>/<name>.png, for checking the layout data by eye.
+ (BOOL)writeLayoutsTo:(NSString *)dir {
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSMutableArray *names = [NSMutableArray array];
    for (size_t i = 0; i < sizeof kLayoutSpecs / sizeof kLayoutSpecs[0]; i++) [names addObject:@(kLayoutSpecs[i].name)];
    BOOL ok = YES;
    for (NSString *name in names) {
        RGKeyboardTester *kt = [RGKeyboardTester new];
        kt->demo = YES;
        NSArray *parts = [name componentsSeparatedByString:@"_"];
        int fam = [parts[1] isEqual:@"ISO"] ? RGFamilyISO : [parts[1] isEqual:@"JIS"] ? RGFamilyJIS : RGFamilyANSI;
        NSString *pattern = [name stringByReplacingOccurrencesOfString:parts[1] withString:@"%@"];
        BOOL old = [name hasSuffix:@"2015"] || [name hasSuffix:@"2017"] || [name hasPrefix:@"classic"];
        kt.keyboards = @[@{@"name": name, @"key": name, @"model": name, @"layout": pattern, @"family": @(fam),
                           @"topKey": old ? @"eject" : @"touchid", @"globe": @(!old)}];
        [kt show];
        [kt.window setContentSize:NSMakeSize(1120, 600)];
        [kt.window orderOut:nil];
        NSView *v = kt.view;
        [v layoutSubtreeIfNeeded];
        NSBitmapImageRep *rep = [v bitmapImageRepForCachingDisplayInRect:v.bounds];
        [v cacheDisplayInRect:v.bounds toBitmapImageRep:rep];
        NSString *path = [dir stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"png"]];
        ok &= [[rep representationUsingType:NSBitmapImageFileTypePNG properties:@{}] writeToFile:path atomically:YES];
        [kt.window close];
    }
    return ok;
}

@end
