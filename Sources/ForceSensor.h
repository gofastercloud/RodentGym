// Force Sensor — a scrolling graph of click pressure from a Force Touch trackpad.
//
// Pressure comes from NSEvent pressure events (stage 0 touch, stage 1 click, stage 2 Force Click),
// which macOS sends only for Force Touch trackpads. Left clicks draw blue, right clicks orange; a
// click that arrives with no pressure data (a Magic Mouse, say) draws dashed.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

@interface RGForceSensor : NSObject <NSWindowDelegate, NSToolbarDelegate>

/// Connected devices, in the same form as RGGestureTrainer.devices; used to show click-pressure settings.
@property (copy) NSArray<NSDictionary *> *(^devices)(void);

@property (strong, readonly) NSWindow *window;

- (void)show;

/// Shows the window with a frozen demo trace (used to capture README screenshots).
- (void)showDemo;

/// Renders the demo trace to a PNG (used for the README screenshot).
- (BOOL)writeDemoSnapshotTo:(NSString *)path;

@end
