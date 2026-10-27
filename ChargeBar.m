#import <Cocoa/Cocoa.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/IOKitLib.h>

extern CFDictionaryRef IOPSCopyExternalPowerAdapterDetails(void);

@interface AppDelegate : NSObject <NSApplicationDelegate>
@property (strong, nonatomic) NSStatusItem *statusItem;
@property (strong, nonatomic) NSTrackingArea *trackingArea;

// Telemetry
@property (assign, nonatomic) int capacity;
@property (assign, nonatomic) BOOL isCharging;
@property (assign, nonatomic) BOOL isConnected;
@property (assign, nonatomic) BOOL previousConnected;
@property (assign, nonatomic) int adapterWatts;
@property (strong, nonatomic) NSString *adapterName;
@property (assign, nonatomic) float liveWatts;
@property (assign, nonatomic) int cycleCount;
@property (assign, nonatomic) float healthPercent;
@property (assign, nonatomic) int timeToFull;
@property (assign, nonatomic) int timeToEmpty;

// Interactive State
@property (assign, nonatomic) BOOL isHovered;
@property (assign, nonatomic) BOOL isPlugInFlashActive;
@property (strong, nonatomic) NSTimer *liveRefreshTimer;

- (void)updateTelemetryAndUI;
@end

static void powerSourceChangedCallback(void *context) {
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate updateTelemetryAndUI];
    });
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.previousConnected = NO;
    self.isHovered = NO;
    self.isPlugInFlashActive = NO;

    // Create Status Item (Fixed length 32pt matching stock battery)
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:34.0];
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(statusItemClicked:);
    self.statusItem.button.title = @"";
    self.statusItem.button.imagePosition = NSImageOnly;
    [self.statusItem.button sendActionOn:(NSEventMaskLeftMouseUp | NSEventMaskRightMouseUp)];

    // Register IOKit Event Notification (0.0% CPU, Event-Driven)
    CFRunLoopSourceRef loopSource = IOPSNotificationCreateRunLoopSource(powerSourceChangedCallback, (__bridge void *)self);
    if (loopSource) {
        CFRunLoopAddSource(CFRunLoopGetCurrent(), loopSource, kCFRunLoopDefaultMode);
        CFRelease(loopSource);
    }

    [self updateTelemetryAndUI];
    [self setupTrackingArea];
}

- (void)setupTrackingArea {
    if (self.trackingArea) {
        [self.statusItem.button removeTrackingArea:self.trackingArea];
    }
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:self.statusItem.button.bounds
                                                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                       owner:self
                                                    userInfo:nil];
    [self.statusItem.button addTrackingArea:self.trackingArea];
}

#pragma mark - Mouse Hover Handling

- (void)mouseEntered:(NSEvent *)event {
    self.isHovered = YES;
    [self updateIconOnly];
}

- (void)mouseExited:(NSEvent *)event {
    self.isHovered = NO;
    [self updateIconOnly];
}

#pragma mark - Power Telemetry

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

    // 2. Power Adapter Details
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

    // 3. AppleSmartBattery (Hardware sensors)
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

#pragma mark - Constant Stock Battery Pill Rendering

- (NSImage *)renderConstantBatteryPillWithText:(NSString *)text capacity:(int)capacity {
    // Constant outer dimensions: 32x18 pt.
    // The battery pill NEVER jumps or resizes when text changes!
    CGFloat totalW = 32.0;
    CGFloat totalH = 18.0;

    CGFloat bodyW = 28.0;
    CGFloat bodyH = 13.0;
    CGFloat nubW = 1.6;
    CGFloat nubH = 4.6;
    CGFloat nubGap = 1.0;
    CGFloat radius = 3.8;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(totalW, totalH)];
    [image lockFocus];
    CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];

    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, totalW, totalH));

    NSRect bodyRect = NSMakeRect(0.5, (totalH - bodyH) / 2.0, bodyW, bodyH);

    // 1. Background Pill Frame (translucent 32% like stock macOS)
    NSBezierPath *framePath = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:radius yRadius:radius];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.32] set];
    [framePath fill];

    // 2. Battery Charge Fill (matches actual capacity fraction, constant regardless of text)
    CGFloat fillFraction = MAX(0.04f, MIN(1.0f, capacity / 100.0f));
    CGFloat fillW = bodyRect.size.width * fillFraction;
    NSRect fillRect = NSMakeRect(bodyRect.origin.x, bodyRect.origin.y, fillW, bodyRect.size.height);

    CGContextSaveGState(ctx);
    [framePath addClip];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:1.0] set];
    NSRectFill(fillRect);
    CGContextRestoreGState(ctx);

    // 3. Subtle Frame Stroke
    framePath.lineWidth = 1.0;
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.55] set];
    [framePath stroke];

    // 4. Right Terminal Nub
    CGFloat nubX = NSMaxX(bodyRect) + nubGap;
    CGFloat nubY = (totalH - nubH) / 2.0;
    NSRect nubRect = NSMakeRect(nubX, nubY, nubW, nubH);
    NSBezierPath *nubPath = [NSBezierPath bezierPathWithRoundedRect:nubRect xRadius:0.8 yRadius:0.8];
    [[NSColor colorWithCalibratedWhite:0.0 alpha:0.55] set];
    [nubPath fill];

    // 5. Centered Cutout Text inside Battery Body
    // Using 8.5pt Bold font to cleanly fit up to "140W"
    NSDictionary *attr = @{
        NSFontAttributeName: [NSFont systemFontOfSize:8.5 weight:NSFontWeightBold],
        NSForegroundColorAttributeName: [NSColor whiteColor]
    };
    NSSize textSize = [text sizeWithAttributes:attr];

    CGContextSaveGState(ctx);
    CGContextSetBlendMode(ctx, kCGBlendModeClear);
    NSPoint textPt = NSMakePoint(NSMidX(bodyRect) - textSize.width / 2.0, NSMidY(bodyRect) - textSize.height / 2.0 - 0.2);
    [text drawAtPoint:textPt withAttributes:attr];
    CGContextRestoreGState(ctx);

    [image unlockFocus];
    [image setTemplate:YES];
    return image;
}

#pragma mark - State Logic & Display Updates

- (void)updateIconOnly {
    NSString *displayText;

    int watts = self.adapterWatts;
    if (watts <= 0 && self.liveWatts > 0.5f) {
        watts = (int)roundf(self.liveWatts);
    }
    if (watts <= 0) {
        watts = 60; // fallback if charger details are pending
    }

    // Exact User Rules:
    // 1. When nothing is plugged in: totally stock percentage number (e.g. "98", no % sign).
    // 2. When plugged in:
    //    - Automatically show charging wattage followed by big 'W' (e.g. "67W") for 2.0 seconds.
    //    - Then switch back to percentage number ("98").
    //    - If mouse hovers over symbol while plugged in: change back to showing wattage ("67W").
    //    - When mouse leaves: swiftly switch back to percentage ("98").
    // 3. The battery sign NEVER changes or moves while numbers switch! Fill stays constant.
    if (self.isConnected && (self.isPlugInFlashActive || self.isHovered)) {
        displayText = [NSString stringWithFormat:@"%dW", watts];
    } else {
        displayText = [NSString stringWithFormat:@"%d", self.capacity];
    }

    NSImage *icon = [self renderConstantBatteryPillWithText:displayText capacity:self.capacity];
    self.statusItem.button.image = icon;
    self.statusItem.button.title = @"";
    self.statusItem.button.imagePosition = NSImageOnly;

    // Tooltip
    if (self.isConnected) {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeBar: %d%% · %dW (%@)", self.capacity, watts, self.adapterName];
    } else {
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeBar: %d%% · On Battery", self.capacity];
    }
}

- (void)updateTelemetryAndUI {
    [self readTelemetry];

    // Detect Transition to Plugged In
    BOOL wasConnected = self.previousConnected;
    self.previousConnected = self.isConnected;

    if (!wasConnected && self.isConnected) {
        // Charger was just connected!
        self.isPlugInFlashActive = YES;
        [self updateIconOnly];

        // After exactly 2.0 seconds, smoothly revert to percentage
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            if (self.isPlugInFlashActive) {
                self.isPlugInFlashActive = NO;
                [self updateIconOnly];
            }
        });
    } else {
        [self updateIconOnly];
    }

    // Manage Live Refresh Timer (Runs gently every 4s only when charging, stopped on battery)
    if (self.isConnected) {
        if (!self.liveRefreshTimer) {
            self.liveRefreshTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 target:self selector:@selector(updateTelemetryAndUI) userInfo:nil repeats:YES];
        }
    } else {
        if (self.liveRefreshTimer) {
            [self.liveRefreshTimer invalidate];
            self.liveRefreshTimer = nil;
        }
    }
}

#pragma mark - Menu & Actions

- (void)statusItemClicked:(id)sender {
    [self showMenu];
}

- (void)showMenu {
    [self readTelemetry];

    NSMenu *menu = [[NSMenu alloc] init];
    menu.autoenablesItems = NO;

    // 1. Power Header
    NSString *powerStr;
    if (self.isConnected) {
        int w = self.adapterWatts > 0 ? self.adapterWatts : (int)roundf(self.liveWatts);
        powerStr = [NSString stringWithFormat:@"⚡ Connected: %dW (%@)", w, self.adapterName];
    } else {
        powerStr = @"🔋 Power Source: Battery Power";
    }
    NSMenuItem *headerItem = [[NSMenuItem alloc] initWithTitle:powerStr action:nil keyEquivalent:@""];
    headerItem.enabled = NO;
    [menu addItem:headerItem];

    // 2. Battery Percentage
    NSString *statusStr = [NSString stringWithFormat:@"   Battery Level: %d%%", self.capacity];
    NSMenuItem *statusItem = [[NSMenuItem alloc] initWithTitle:statusStr action:nil keyEquivalent:@""];
    statusItem.enabled = NO;
    [menu addItem:statusItem];

    // 3. Live Power Flow
    NSString *flowStr;
    if (self.liveWatts > 0.05f) {
        flowStr = [NSString stringWithFormat:@"   Net Flow: +%.1f W (Into battery)", self.liveWatts];
    } else if (self.liveWatts < -0.05f) {
        flowStr = [NSString stringWithFormat:@"   Net Flow: %.1f W (System draw)", self.liveWatts];
    } else {
        flowStr = @"   Net Flow: 0.0 W (Idle / Wall Power)";
    }
    NSMenuItem *flowItem = [[NSMenuItem alloc] initWithTitle:flowStr action:nil keyEquivalent:@""];
    flowItem.enabled = NO;
    [menu addItem:flowItem];

    // 4. Health & Cycles
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

    // Action to Hide macOS Stock Battery Icon
    NSMenuItem *hideStockItem = [[NSMenuItem alloc] initWithTitle:@"🎛 Open Control Center Settings (Hide Stock Battery)" action:@selector(openControlCenterSettings) keyEquivalent:@""];
    hideStockItem.target = self;
    [menu addItem:hideStockItem];

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

- (void)openControlCenterSettings {
    // Open System Settings -> Control Center directly
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.ControlCenter-Settings.extension"]];
}

- (void)openFeedback {
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/alaska14/chargebar/issues"]];
}

- (void)showAbout {
    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = @"ChargeBar 1.1";
    about.informativeText = @"Stock-matching native battery icon with live wattage on plug-in & hover, adapter telemetry, and health monitoring.\n\nCrafted with native AppKit for 0.0% CPU overhead.";
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
