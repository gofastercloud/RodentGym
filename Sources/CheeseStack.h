// Cheese Stack — a falling-block workout for your mouse or trackpad.
// Steer with the pointer, rotate with left and right click, drop by scrolling.
// Every button has to get through for you to play well, so it doubles as a click test.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

@interface RGCheeseStack : NSObject <NSWindowDelegate>

/// Total clicks RodentGym has flagged as dropped so far; the game shows how many happen during play.
@property (copy) long (^droppedClicks)(void);

/// A short warning about the user's input setup (e.g. secondary click switched off), or nil.
@property (copy) NSString *(^inputWarning)(void);

@property (strong, readonly) NSWindow *window;

- (void)show;

/// Shows the game with a frozen, anonymised demo scene (used to capture README screenshots).
- (void)showDemo;

/// Renders a demo game to a PNG (used for the README screenshot).
- (BOOL)writeDemoSnapshotTo:(NSString *)path;

@end
