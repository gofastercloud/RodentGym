// See Bluetooth.h.
//
// Permission is requested with CoreBluetooth (creating a central manager is what makes macOS show
// the prompt, and its delegate tells us the answer). Signal strength comes from IOBluetooth's
// rawRSSI, an HCI Read RSSI on the existing connection, which works for the classic Bluetooth
// links Magic accessories use and doesn't disturb them.

#import "Bluetooth.h"
#import <IOBluetooth/IOBluetooth.h>
#import <CoreBluetooth/CoreBluetooth.h>

#define SAMPLE_INTERVAL 2.0

@interface RGBluetoothMonitor () <CBCentralManagerDelegate>
@property (readwrite) RGBluetoothState state;
@property (strong) CBCentralManager *central;
@property (strong) NSTimer *timer;
@end

@implementation RGBluetoothMonitor

+ (NSString *)normalisedAddress:(NSString *)s {
    if (![s isKindOfClass:NSString.class]) return nil;
    NSString *hex = [[[s stringByReplacingOccurrencesOfString:@"-" withString:@""]
                      stringByReplacingOccurrencesOfString:@":" withString:@""] lowercaseString];
    if (hex.length != 12) return nil;
    NSCharacterSet *notHex = [NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet;
    return [hex rangeOfCharacterFromSet:notHex].location == NSNotFound ? hex : nil;
}

+ (NSString *)qualityFor:(int)rssi {
    return rssi >= -60 ? @"Excellent" : rssi >= -70 ? @"Good" : rssi >= -80 ? @"Fair" : @"Poor";
}

- (void)setStateAndNotify:(RGBluetoothState)s {
    if (self.state == s) return;
    self.state = s;
    if (self.onChange) self.onChange();
}

- (void)start {
    if (self.state == RGBluetoothOn || self.state == RGBluetoothWaiting) return;
    CBManagerAuthorization auth = CBManager.authorization;
    if (auth == CBManagerAuthorizationDenied || auth == CBManagerAuthorizationRestricted) {
        [self setStateAndNotify:RGBluetoothDenied];
        return;
    }
    [self setStateAndNotify:RGBluetoothWaiting];
    // Shows the permission prompt the first time; afterwards it just reports the radio's state.
    self.central = [[CBCentralManager alloc] initWithDelegate:self queue:nil
                                                      options:@{CBCentralManagerOptionShowPowerAlertKey: @NO}];
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    self.central.delegate = nil;
    self.central = nil;
    [self setStateAndNotify:RGBluetoothOff];
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (self.state == RGBluetoothOff) return;
    CBManagerAuthorization auth = CBManager.authorization;
    if (auth == CBManagerAuthorizationDenied || auth == CBManagerAuthorizationRestricted) {
        [self.timer invalidate];
        self.timer = nil;
        [self setStateAndNotify:RGBluetoothDenied];
        return;
    }
    if (auth != CBManagerAuthorizationAllowedAlways) return;   // still waiting for an answer
    if (central.state == CBManagerStatePoweredOff) {
        [self.timer invalidate];
        self.timer = nil;
        [self setStateAndNotify:RGBluetoothPoweredOff];
        return;
    }
    if (central.state != CBManagerStatePoweredOn) return;
    [self setStateAndNotify:RGBluetoothOn];
    if (!self.timer) {
        self.timer = [NSTimer timerWithTimeInterval:SAMPLE_INTERVAL target:self selector:@selector(sample) userInfo:nil repeats:YES];
        self.timer.tolerance = 0.3;
        [NSRunLoop.mainRunLoop addTimer:self.timer forMode:NSRunLoopCommonModes];
    }
    [self sample];
}

- (void)sample {
    if (self.state != RGBluetoothOn) return;
    NSMutableDictionary<NSString *, NSNumber *> *out = [NSMutableDictionary dictionary];
    for (IOBluetoothDevice *d in IOBluetoothDevice.pairedDevices) {
        if (!d.isConnected) continue;
        BluetoothHCIRSSIValue rssi = d.rawRSSI;
        NSString *addr = [RGBluetoothMonitor normalisedAddress:d.addressString];
        if (addr && rssi < 0 && rssi > -127) out[addr] = @(rssi);   // 127 means "not available"
    }
    if (self.onSample) self.onSample(out);
}

- (NSString *)statusText {
    switch (self.state) {
        case RGBluetoothOff:        return @"Off";
        case RGBluetoothWaiting:    return @"Waiting for Bluetooth permission…";
        case RGBluetoothOn:         return @"On — sampling every 2 seconds";
        case RGBluetoothDenied:     return @"Bluetooth access is off for RodentGym. Allow it in Privacy & Security → Bluetooth.";
        case RGBluetoothPoweredOff: return @"Bluetooth is turned off.";
    }
    return @"";
}

@end
