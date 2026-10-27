#import <Cocoa/Cocoa.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/IOKitLib.h>

extern CFDictionaryRef IOPSCopyExternalPowerAdapterDetails(void);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSTimer *chargingLiveTimer;

// Power Telemetry
@property (assign, nonatomic) int capacity;
@property (assign, nonatomic) BOOL isCharging;
@property (assign, nonatomic) BOOL isConnected;
@property (assign, nonatomic) int adapterWatts;
@property (strong, nonatomic) NSString *adapterName;
@property (assign, nonatomic) float liveWatts;
@property (assign, nonatomic) int cycleCount;
@property (assign, nonatomic) float healthPercent;
@property (assign, nonatomic) int timeToFull;
@property (assign, nonatomic) int timeToEmpty;

// User Preferences
@property (assign, nonatomic) BOOL showWattage;
@property (assign, nonatomic) BOOL showPercentage;
@property (assign, nonatomic) BOOL showIcon;
@property (assign, nonatomic) BOOL showLiveFlow; // Live wattage vs rated adapter wattage

- (void)updateTelemetryAndUI;
@end

static void powerSourceNotificationCallback(void *context) {
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate updateTelemetryAndUI];
    });
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Default preferences
    self.showWattage = YES;
    self.showPercentage = YES;
    self.showIcon = YES;
    self.showLiveFlow = NO;

    // Create status bar item
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    // Register IOKit Event Notification (0.0% CPU, Event-Driven)
    CFRunLoopSourceRef loopSource = IOPSNotificationCreateRunLoopSource(powerSourceNotificationCallback, (__bridge void *)self);
    if (loopSource) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, kCFRunLoopDefaultMode);
        CFRelease(loopSource);
    }

    [self updateTelemetryAndUI];
}

#pragma mark - Telemetry Extraction

- (void)readTelemetry {
    // 1. IOPowerSources
    CFTypeRef psInfo = IOPSCopyPowerSourcesInfo();
    CFArrayRef psList = IOPSCopyPowerSourcesList(psInfo);

    if (psList && CFArrayGetCount(psList) > 0) {
        CFDictionaryRef desc = IOPSGetPowerSourceDescription(psInfo, CFArrayGetValueAtIndex(psList, 0));
        NSDictionary *dict = (__bridge NSDictionary *)desc;
        self.capacity = [dict[@"Current Capacity"] intValue];
        self.isCharging = [dict[@"Is Charging"] boolValue];
        NSString *state = dict[@"Power Source State"];
        self.isConnected = [state isEqualToString:@"AC Power"];
        self.timeToFull = [dict[@"Time to Full Charge"] intValue];
        self.timeToEmpty = [dict[@"Time to Empty"] intValue];
    }
    if (psList) CFRelease(psList);
    if (psInfo) CFRelease(psInfo);

    // 2. Adapter Details
    CFDictionaryRef adapterDetails = IOPSCopyExternalPowerAdapterDetails();
    if (adapterDetails) {
        NSDictionary *aDict = (__bridge NSDictionary *)adapterDetails;
        self.adapterWatts = [aDict[@"Watts"] intValue];
        self.adapterName = aDict[@"Name"] ?: @"Power Adapter";
        CFRelease(adapterDetails);
    } else {
        self.adapterWatts = 0;
        self.adapterName = @"On Battery";
    }

    // 3. AppleSmartBattery (Live Voltage, Amperage, Cycle Count, Health)
    io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"));
    if (service) {
        CFMutableDictionaryRef props = NULL;
        IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0);
        NSDictionary *bDict = (__bridge NSDictionary *)props;

        int voltage = [bDict[@"Voltage"] intValue]; // mV
        int amperage = [bDict[@"Amperage"] intValue]; // mA
        self.liveWatts = (float)(voltage * amperage) / 1000000.0f;
        self.cycleCount = [bDict[@"CycleCount"] intValue];

        int designCap = [bDict[@"DesignCapacity"] intValue];
        int nominalCap = [bDict[@"NominalChargeCapacity"] intValue];
        if (designCap > 0 && nominalCap > 0) {
            self.healthPercent = ((float)nominalCap / (float)designCap) * 100.0f;
        } else {
            self.healthPercent = 100.0f;
        }

        if (props) CFRelease(props);
        IOObjectRelease(service);
    }
}

#pragma mark - UI Updates

- (void)updateTelemetryAndUI {
    [self readTelemetry];

    // Manage live charging timer (only runs when charging, stops on battery for 0.0% CPU)
    if (self.isConnected && (self.isCharging || self.adapterWatts > 0)) {
        if (!self.chargingLiveTimer) {
            self.chargingLiveTimer = [NSTimer scheduledTimerWithTimeInterval:3.0 target:self selector:@selector(updateTelemetryAndUI) userInfo:nil repeats:YES];
        }
    } else {
        if (self.chargingLiveTimer) {
            [self.chargingLiveTimer invalidate];
            self.chargingLiveTimer = nil;
        }
    }

    // Determine Icon
    NSImage *icon = nil;
    if (self.showIcon) {
        if (self.isConnected) {
            icon = [NSImage imageWithSystemSymbolName:@"bolt.fill" accessibilityDescription:@"Charging"];
        } else {
            if (self.capacity >= 90) {
                icon = [NSImage imageWithSystemSymbolName:@"battery.100" accessibilityDescription:@"Battery 100%"];
            } else if (self.capacity >= 70) {
                icon = [NSImage imageWithSystemSymbolName:@"battery.75" accessibilityDescription:@"Battery 75%"];
            } else if (self.capacity >= 40) {
                icon = [NSImage imageWithSystemSymbolName:@"battery.50" accessibilityDescription:@"Battery 50%"];
            } else if (self.capacity >= 15) {
                icon = [NSImage imageWithSystemSymbolName:@"battery.25" accessibilityDescription:@"Battery 25%"];
            } else {
                icon = [NSImage imageWithSystemSymbolName:@"battery.0" accessibilityDescription:@"Battery Low"];
            }
        }
    }

    // Build Menu Bar Title String
    NSMutableArray *parts = [NSMutableArray array];

    if (self.showPercentage) {
        [parts addObject:[NSString stringWithFormat:@"%d%%", self.capacity]];
    }

    // Display wattage if plugged in and wattage display enabled
    if (self.isConnected && self.showWattage) {
        int displayWatts = self.adapterWatts;
        if (self.showLiveFlow && self.liveWatts > 0.5f) {
            displayWatts = (int)roundf(self.liveWatts);
        }
        if (displayWatts > 0) {
            [parts addObject:[NSString stringWithFormat:@"%dW", displayWatts]];
        }
    }

    NSString *title = [parts componentsJoinedByString:@" "];

    self.statusItem.button.image = icon;
    self.statusItem.button.title = title;
    self.statusItem.button.imagePosition = icon ? NSImageLeading : NSNoImage;

    // Tooltip
    if (self.isConnected) {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeBar: %d%% · %dW (%@)", self.capacity, self.adapterWatts, self.adapterName];
    } else {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeBar: %d%% · On Battery", self.capacity];
    }
}

#pragma mark - Menu & Interactivity

- (void)statusItemClicked:(id)sender {
    [self showMenu];
}

- (void)showMenu {
    [self readTelemetry];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    // 1. Live Power Header
    NSString *powerStateStr;
    if (self.isConnected) {
        if (self.adapterWatts > 0) {
            powerStateStr = [NSString stringWithFormat:@"⚡ Connected: %dW (%@)", self.adapterWatts, self.adapterName];
        } else {
            powerStateStr = [NSString stringWithFormat:@"⚡ Connected: %@", self.adapterName];
        }
    } else {
        powerStateStr = [NSString stringWithFormat:@"🔋 Power Source: Battery Power"];
    }
    NSMenuItem *headerItem = [[NSMenuItem alloc] initWithTitle:powerStateStr action:nil keyEquivalent:@""];
    headerItem.enabled = NO;
    [menu addItem:headerItem];

    // 2. Battery Percentage & State
    NSString *chargeStatusStr = self.isCharging ? @"Charging" : (self.isConnected ? @"Fully Charged / On AC" : @"Discharging");
    NSString *statusStr = [NSString stringWithFormat:@"   Battery: %d%% (%@)", self.capacity, chargeStatusStr];
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusStr action:nil keyEquivalent:@""];
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    // 3. Live Wattage Flow
    NSString *flowStr;
    if (self.liveWatts > 0.05f) {
        flowStr = [NSString stringWithFormat:@"   Net Flow: +%.1f W (Into battery)", self.liveWatts];
    } else if (self.liveWatts < -0.05f) {
        flowStr = [NSString stringWithFormat:@"   Net Flow: %.1f W (System draw)", self.liveWatts];
    } else {
        flowStr = @"   Net Flow: 0.0 W (Idle / Wall Powered)";
    }
    NSMenuItem *flowItem = [[NSMenuItem alloc] initWithTitle:flowStr action:nil keyEquivalent:@""];
    flowItem.enabled = NO;
    [menu addItem:flowItem];

    // 4. Battery Health & Cycle Count
    NSString *healthStr = [NSString stringWithFormat:@"   Health: %.1f%%  ·  %d Cycles", self.healthPercent, self.cycleCount];
    NSMenuItem *healthItem = [[NSMenuItem alloc] initWithTitle:healthStr action:nil keyEquivalent:@""];
    healthItem.enabled = NO;
    [menu addItem:healthItem];

    // 5. Time Remaining
    if (self.isCharging && self.timeToFull > 0 && self.timeToFull < 1000) {
        int h = self.timeToFull / 60;
        int m = self.timeToFull % 60;
        NSString *timeStr = [NSString stringWithFormat:@"   Time to Full: %dh %02dm", h, m];
        NSMenuItem *tItem = [[NSMenuItem alloc] initWithTitle:timeStr action:nil keyEquivalent:@""];
        tItem.enabled = NO;
        [menu addItem:tItem];
    } else if (!self.isConnected && self.timeToEmpty > 0 && self.timeToEmpty < 10000) {
        int h = self.timeToEmpty / 60;
        int m = self.timeToEmpty % 60;
        NSString *timeStr = [NSString stringWithFormat:@"   Time Remaining: %dh %02dm", h, m];
        NSMenuItem *tItem = [[NSMenuItem alloc] initWithTitle:timeStr action:nil keyEquivalent:@""];
        tItem.enabled = NO;
        [menu addItem:tItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // Preferences Toggles
    NSMenuItem *wattToggle = [[NSMenuItem alloc] initWithTitle:@"Show Charging Wattage" action:@selector(toggleWattage) keyEquivalent:@"w"];
    wattToggle.state = self.showWattage ? NSControlStateValueOn : NSControlStateValueOff;
    wattToggle.target = self;
    [menu addItem:wattToggle];

    NSMenuItem *pctToggle = [[NSMenuItem alloc] initWithTitle:@"Show Battery Percentage" action:@selector(togglePercentage) keyEquivalent:@"p"];
    pctToggle.state = self.showPercentage ? NSControlStateValueOn : NSControlStateValueOff;
    pctToggle.target = self;
    [menu addItem:pctToggle];

    NSMenuItem *iconToggle = [[NSMenuItem alloc] initWithTitle:@"Show Battery Icon" action:@selector(toggleIcon) keyEquivalent:@"i"];
    iconToggle.state = self.showIcon ? NSControlStateValueOn : NSControlStateValueOff;
    iconToggle.target = self;
    [menu addItem:iconToggle];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *tipItem = [[NSMenuItem alloc] initWithTitle:@"💡 Tip: Hide macOS battery in Settings → Control Center" action:nil keyEquivalent:@""];
    tipItem.enabled = NO;
    [menu addItem:tipItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *feedbackItem = [[NSMenuItem alloc] initWithTitle:@"💬 Send Feedback / Feature Request..." action:@selector(openFeedback) keyEquivalent:@""];
    feedbackItem.target = self;
    [menu addItem:feedbackItem];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About ChargeBar" action:@selector(showAbout) keyEquivalent:@""];
    aboutItem.target = self;
    [menu addItem:aboutItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ChargeBar" action:@selector(quitApp) keyEquivalent:@"q"];
    quitItem.target = self;
    [menu addItem:quitItem];

    self.statusItem.menu = menu;
    [self.statusItem.button performClick:nil];
    self.statusItem.menu = nil;
}

- (void)toggleWattage {
    self.showWattage = !self.showWattage;
    [self updateTelemetryAndUI];
}

- (void)togglePercentage {
    self.showPercentage = !self.showPercentage;
    [self updateTelemetryAndUI];
}

- (void)toggleIcon {
    self.showIcon = !self.showIcon;
    [self updateTelemetryAndUI];
}

- (void)openFeedback {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/alaska14/chargebar/issues"]];
}

- (void)showAbout {
    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = @"ChargeBar 1.0";
    about.informativeText = @"Featherlight menu bar battery monitor with real-time charging wattage, adapter telemetry, and battery health.\n\nCrafted with native AppKit for 0.0% CPU overhead.";
    [about addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [about runModal];
}

- (void)quitApp {
    [NSApp terminate:nil];
}

@end

int main(int argc, const char * argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
