// Gesture Trainer — a checklist of the gestures you have switched on, ticked off as you do them.
//
// Gestures macOS delivers to apps (clicks, pinch, rotate, smart zoom, scroll, swipes) are captured on
// the practice pad. System gestures (Mission Control, App Exposé, full-screen app swipes, squeeze and
// spread, Notification Centre) are recognised from raw touch data and named; macOS still acts on them.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

@interface RGGestureTrainer : NSObject <NSWindowDelegate>

/// Connected devices: @{ @"name": NSString, @"kind": @"mouse" | @"trackpad", @"slot": NSNumber, @"prefs": NSDictionary }
/// where prefs is the MultitouchPreferences dictionary the driver is applying.
@property (copy) NSArray<NSDictionary *> *(^devices)(void);

/// Receives one line per recognised gesture, for RodentGym's log.
@property (copy) void (^log)(NSString *line);

@property (strong, readonly) NSWindow *window;

- (void)show;

/// Shows the window with anonymised demo data (used to capture README screenshots).
- (void)showDemo;

/// Renders an anonymised demo of the trainer to a PNG (used for the README screenshot).
- (BOOL)writeDemoSnapshotTo:(NSString *)path;

@end
