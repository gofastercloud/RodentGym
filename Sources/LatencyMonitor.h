// Latency Monitor — click latency, touch report rate and Bluetooth signal on one time axis, with
// dropped clicks and connects/disconnects marked across all of them.
//
// Click latency is the time from the Mac receiving a device's button report (the kernel's HID
// timestamp) to the click event reaching the login session, where RodentGym watches it. Report
// rate and stalls come from every touch frame MultitouchSupport delivers.
//
// The monitor records from launch, so the window shows the last two minutes when opened.
//
// MIT License — see LICENSE.

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface RGLatencyMonitor : NSObject <NSWindowDelegate, NSToolbarDelegate>

/// Connected devices: dictionaries with name, key, kind ("mouse" or "trackpad"), builtIn and slot.
@property (copy, nullable) NSArray<NSDictionary *> *(^devices)(void);

/// Nil while Bluetooth monitoring is on and working; otherwise a sentence saying why there is no signal graph.
@property (copy, nullable) NSString *_Nullable (^bluetoothStatus)(void);

/// Opens RodentGym's Settings window.
@property (copy, nullable) void (^openSettings)(void);

@property (strong, readonly, nullable) NSWindow *window;

/// Starts sampling touch report rates (call once, when watching live devices).
- (void)start;

- (void)recordClick:(int)button latency:(double)ms device:(nullable NSString *)name;
- (void)recordDrop:(int)button device:(nullable NSString *)name;
- (void)recordSignal:(int)rssi device:(NSString *)key name:(NSString *)name;
- (void)recordLink:(BOOL)connected device:(NSString *)name;

/// A few lines summarising the session, for reports.
- (NSString *)summary;

- (void)show;

/// Shows the window with frozen demo data (used to capture README screenshots).
- (void)showDemo;

/// Renders the demo to a PNG (used for the README screenshot).
- (BOOL)writeDemoSnapshotTo:(NSString *)path;

@end

NS_ASSUME_NONNULL_END
