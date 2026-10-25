// Keyboard Tester — checks every key on a Magic Keyboard, an older Apple Wireless Keyboard or a
// Mac's built-in keyboard.
//
// Press each key once and it lights up. The tester also catches the faults a worn or damaged
// keyboard shows: keys that chatter (one press arrives as two), keys that stick down, and how many
// keys the keyboard can report at once (rollover).
//
// Privacy: keys are read only from RodentGym's own window while that window is in front, exactly
// as any text field reads them. Nothing is logged and no permission is needed. When the window is
// in the background the tester sees nothing at all.
//
// Keyboards are identified from the IORegistry (name, model, connection, firmware, battery), which
// needs no permission either. RodentGym never opens a keyboard device.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

/// Keyboards attached to this Mac. Each is a dictionary with name, key, model, productID, vendorID,
/// builtIn, and when known transport, firmware, serial, battery, colour, form ("compact", "numeric",
/// "laptop" or "classic"), topKey ("touchid", "lock", "eject", "power" or "none"), arrows ("t" for
/// half-height left and right arrows, "full" for full-height), functionRow ("full" or "half"), globe
/// (YES when the fn key carries the Globe symbol) and year. With `anonymise`, names are generic and
/// serial numbers are left out.
NSArray<NSDictionary *> *RGConnectedKeyboards(BOOL anonymise);   // Apple keyboards only

/// Draws a small picture of a keyboard (a dictionary from RGConnectedKeyboards) centred in `rect`.
void RGDrawKeyboardThumbnail(NSDictionary *keyboard, NSRect rect);

@interface RGKeyboardTester : NSObject <NSWindowDelegate, NSToolbarDelegate>

/// Writes a line to RodentGym's log. Only results (for example "Keyboard Tester: 78 of 78 keys") are
/// ever logged, never the keys themselves.
@property (copy, nullable) void (^log)(NSString *line);

/// The keyboards to offer, normally RodentGym's own list (Apple keyboards, with the built-in one
/// following the lid). Falls back to RGConnectedKeyboards when not set.
@property (copy, nullable) NSArray<NSDictionary *> *(^keyboardList)(void);

@property (strong, readonly, nullable) NSWindow *window;

- (void)show;

/// Shows the tester with the keyboard whose "key" matches already chosen.
- (void)showKeyboard:(NSString *)key;

/// Shows the window with a frozen demo (used to capture README screenshots).
- (void)showDemo;

/// Renders every built-in layout to `<dir>/<layout name>.png`, for checking layout data by eye.
+ (BOOL)writeLayoutsTo:(NSString *)dir;

@end

NS_ASSUME_NONNULL_END
