// Hardware Self-Test — three short checks that find real faults in a Magic Mouse or trackpad:
//
//   Surface coverage  wipe a finger over the whole surface; areas that never respond are dead zones,
//                     and contacts the sensor loses mid-stroke are counted.
//   Phantom touch     hands off for 10 seconds; any contact the device reports is a sensor, moisture
//                     or interference problem.
//   Haptics           Force Touch trackpads only: play three haptic patterns and confirm you felt them.
//
// Results can be copied as a plain-text report for an Apple support case.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RGSelfTest : NSObject <NSWindowDelegate, NSToolbarDelegate>

/// Connected devices: dictionaries with name, key, kind ("mouse" or "trackpad"), builtIn, slot, model,
/// firmware, serial, transport, productID, darkTop, widthMM and heightMM.
@property (copy, nullable) NSArray<NSDictionary *> *(^devices)(void);

/// Writes a line to RodentGym's log.
@property (copy, nullable) void (^log)(NSString *line);

/// The Latency Monitor's summary, appended to copied reports.
@property (copy, nullable) NSString *_Nullable (^latencySummary)(void);

@property (strong, readonly, nullable) NSWindow *window;

- (void)show;

/// Shows the window with a frozen demo (used to capture README screenshots).
- (void)showDemo;

/// Renders the demo to a PNG (used for the README screenshot).
- (BOOL)writeDemoSnapshotTo:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
