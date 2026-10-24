// Bluetooth link health — signal strength (RSSI) for connected Bluetooth devices.
//
// Off by default. Reading signal strength needs Bluetooth permission, so nothing here touches
// Bluetooth until the user turns monitoring on in Settings; that is when macOS asks.
//
// MIT License — see LICENSE.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, RGBluetoothState) {
    RGBluetoothOff,          // not monitoring
    RGBluetoothWaiting,      // waiting for the user to answer the permission prompt
    RGBluetoothOn,           // sampling
    RGBluetoothDenied,       // the user (or a profile) has refused Bluetooth access
    RGBluetoothPoweredOff,   // Bluetooth is switched off
};

@interface RGBluetoothMonitor : NSObject

@property (readonly) RGBluetoothState state;

/// Called on the main thread whenever `state` changes.
@property (copy, nullable) void (^onChange)(void);

/// Called on the main thread every couple of seconds while on, with signal strength in dBm for each
/// connected device, keyed by normalised Bluetooth address (see +normalisedAddress:).
@property (copy, nullable) void (^onSample)(NSDictionary<NSString *, NSNumber *> *rssiByAddress);

/// Starts monitoring, asking for Bluetooth permission first if macOS hasn't been asked yet.
- (void)start;
- (void)stop;

/// One line describing the state, for Settings and the Latency Monitor.
- (NSString *)statusText;

/// Lower-case hex with separators removed, so "A1-B2-…" and "a1:b2:…" compare equal. Nil if `s`
/// doesn't look like a Bluetooth address.
+ (nullable NSString *)normalisedAddress:(nullable NSString *)s;

/// Plain-English quality for a signal strength, e.g. "Excellent".
+ (NSString *)qualityFor:(int)rssi;

@end

NS_ASSUME_NONNULL_END
