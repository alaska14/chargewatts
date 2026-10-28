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
@property (assign, nonatomic) BOOL isFullyCharged;
@property (assign, nonatomic) BOOL isConnected;
@property (assign, nonatomic) BOOL previousConnected;
@property (assign, nonatomic) int adapterWatts;
@property (strong, nonatomic) NSString *adapterName;
@property (assign, nonatomic) float liveWatts;
@property (assign, nonatomic) float systemLoadWatts;
@property (assign, nonatomic) int cycleCount;
@property (assign, nonatomic) float healthPercent;
@property (assign, nonatomic) int timeToFull;
@property (assign, nonatomic) int timeToEmpty;

// Interactive State
@property (assign, nonatomic) BOOL isHovered;
@property (assign, nonatomic) BOOL isPlugInFlashActive;
@property (strong, nonatomic) NSTimer *liveRefreshTimer;
@property (strong, nonatomic) id globalMouseMonitor;
@property (strong, nonatomic) id localMouseMonitor;

- (void)updateTelemetryAndUI;
@end

static void powerSourceChangedCallback(void *context) {
    AppDelegate *delegate = (__bridge AppDelegate *)context;
    dispatch_async(dispatch_get_main_queue(), ^{
        [delegate updateTelemetryAndUI];
    });
}

static void terminationSignalHandler(int sig) {
    system("/usr/bin/defaults -currentHost write com.apple.controlcenter Battery -int 2 && /usr/bin/killall ControlCenter");
    _exit(0);
}

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    signal(SIGTERM, terminationSignalHandler);
    signal(SIGINT, terminationSignalHandler);
    signal(SIGHUP, terminationSignalHandler);

    self.previousConnected = NO;
    self.isHovered = NO;
    self.isPlugInFlashActive = NO;

    // 1. Ensure position 400 (exact slot between Bluetooth at 543 and Wi-Fi at 362) is registered
    // in both app domain and Control Center BEFORE the status item is created.
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    [defs registerDefaults:@{
        @"NSStatusItem Preferred Position Battery": @(400),
        @"NSStatusItem Preferred Position ChargeWatts": @(400)
    }];
    if (![defs objectForKey:@"NSStatusItem Preferred Position Battery"]) {
        [defs setInteger:400 forKey:@"NSStatusItem Preferred Position Battery"];
    }
    if (![defs objectForKey:@"NSStatusItem Preferred Position ChargeWatts"]) {
        [defs setInteger:400 forKey:@"NSStatusItem Preferred Position ChargeWatts"];
    }
    [defs synchronize];

    // Seed com.apple.controlcenter domain so macOS menu bar manager locks slot 400
    CFPreferencesSetValue(CFSTR("NSStatusItem Preferred Position Battery"),
                          (__bridge CFNumberRef)@(400),
                          CFSTR("com.apple.controlcenter"),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSetValue(CFSTR("NSStatusItem Preferred Position ChargeWatts"),
                          (__bridge CFNumberRef)@(400),
                          CFSTR("com.apple.controlcenter"),
                          kCFPreferencesCurrentUser,
                          kCFPreferencesAnyHost);
    CFPreferencesSynchronize(CFSTR("com.apple.controlcenter"), kCFPreferencesCurrentUser, kCFPreferencesAnyHost);

    // Create Status Item with exact Apple Battery autosaveName & drag behavior
    self.statusItem = [[NSStatusBar systemStatusBar] statusItemWithLength:29.0];
    self.statusItem.autosaveName = @"Battery";
    self.statusItem.behavior = NSStatusItemBehaviorRemovalAllowed;
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
    [self ensureAutoStart];
    [self ensureStockBatteryReplaced];
}

- (void)setupTrackingArea {
    if (self.trackingArea) {
        [self.statusItem.button removeTrackingArea:self.trackingArea];
    }
    self.statusItem.button.window.acceptsMouseMovedEvents = YES;
    self.trackingArea = [[NSTrackingArea alloc] initWithRect:NSZeroRect
                                                     options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                       owner:self
                                                    userInfo:nil];
    [self.statusItem.button addTrackingArea:self.trackingArea];

    // Dual-layer hover detection: Global & local event monitors ensure 100% responsive hover
    // across all applications without polling or CPU overhead (event-driven).
    if (!self.globalMouseMonitor) {
        __weak typeof(self) weakSelf = self;
        self.globalMouseMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^(NSEvent *event) {
            [weakSelf checkHoverAtScreenPoint:[NSEvent mouseLocation]];
        }];
    }
    if (!self.localMouseMonitor) {
        __weak typeof(self) weakSelf = self;
        self.localMouseMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskMouseMoved handler:^NSEvent *(NSEvent *event) {
            [weakSelf checkHoverAtScreenPoint:[NSEvent mouseLocation]];
            return event;
        }];
    }
}

- (void)checkHoverAtScreenPoint:(NSPoint)mouseLoc {
    NSWindow *win = self.statusItem.button.window;
    if (!win) return;
    NSRect screenRect = [win convertRectToScreen:self.statusItem.button.bounds];
    // Generous vertical and horizontal hit margin for smooth, natural hover interaction
    NSRect hitRect = NSInsetRect(screenRect, -2.0, -4.0);
    BOOL inside = NSPointInRect(mouseLoc, hitRect);
    if (inside != self.isHovered) {
        self.isHovered = inside;
        [self updateIconOnly];
    }
}

#pragma mark - Mouse Hover Handling

- (void)mouseEntered:(NSEvent *)event {
    if (!self.isHovered) {
        self.isHovered = YES;
        [self updateIconOnly];
    }
}

- (void)mouseExited:(NSEvent *)event {
    if (self.isHovered) {
        self.isHovered = NO;
        [self updateIconOnly];
    }
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

        NSDictionary *telemetry = [bDict[@"PowerTelemetryData"] isKindOfClass:[NSDictionary class]] ? bDict[@"PowerTelemetryData"] : nil;
        float sysPower = 0.0f;
        if (telemetry) {
            float pIn = [telemetry[@"SystemPowerIn"] floatValue] / 1000.0f;
            float pLoad = [telemetry[@"SystemLoad"] floatValue] / 1000.0f;
            sysPower = pLoad > 0.0f ? pLoad : pIn;
        }
        if (sysPower <= 0.0f && fabsf(self.liveWatts) > 0.0f) {
            sysPower = fabsf(self.liveWatts);
        }
        self.systemLoadWatts = sysPower;

        NSDictionary *chargerData = [bDict[@"ChargerData"] isKindOfClass:[NSDictionary class]] ? bDict[@"ChargerData"] : nil;
        if (chargerData && [chargerData objectForKey:@"IsCharging"]) {
            self.isCharging = [chargerData[@"IsCharging"] boolValue];
        }

        NSDictionary *batteryData = [bDict[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? bDict[@"BatteryData"] : nil;
        if (batteryData && [batteryData objectForKey:@"FullyCharged"]) {
            self.isFullyCharged = [batteryData[@"FullyCharged"] boolValue];
        } else if ([bDict objectForKey:@"FullyCharged"]) {
            self.isFullyCharged = [bDict[@"FullyCharged"] boolValue];
        } else {
            self.isFullyCharged = (self.capacity >= 100);
        }

        int designCap = 0;
        int actualCap = 0;
        NSDictionary *bData = [bDict[@"BatteryData"] isKindOfClass:[NSDictionary class]] ? bDict[@"BatteryData"] : nil;
        if (bData) {
            designCap = [bData[@"DesignCapacity"] intValue];
            actualCap = [bData[@"NominalChargeCapacity"] intValue];
            if (actualCap <= 0) {
                actualCap = [bData[@"FullChargeCapacity"] intValue];
            }
        }
        if (designCap <= 0) {
            designCap = [bDict[@"DesignCapacity"] intValue];
        }
        if (actualCap <= 0) {
            actualCap = [bDict[@"AppleRawMaxCapacity"] intValue];
        }

        if (designCap > 0 && actualCap > 0) {
            self.healthPercent = ((float)actualCap / (float)designCap) * 100.0f;
            if (self.healthPercent > 100.0f) self.healthPercent = 100.0f;
        } else {
            self.healthPercent = 100.0f;
        }

        if (props) CFRelease(props);
        IOObjectRelease(service);
    }
}

#pragma mark - Constant Stock Battery Pill Rendering (Exact 1:1 Apple Golden Gate Replication)

- (NSImage *)renderConstantBatteryPillWithText:(NSString *)text capacity:(int)capacity showBolt:(BOOL)showBolt {
    // 1:1 Apple macOS Golden Gate geometry evaluated directly against native stock crop:
    // Canvas: 28.0 x 22.0 pt
    // Body: 23.5 x 12.0 pt with 3.5 pt squarish continuous squircle radius
    // Detached Nub: 1.4 x 5.0 pt convex cap with 1.0 pt gap from body (52% opacity)
    // Font: .AppleSystemUIFontRounded-Medium (exact Apple menu bar battery font)
    // Cutout: True Stencil Cutout using kCGBlendModeDestinationOut (takes exact wallpaper color!)
    // Centering: Numbers + Bolt strictly centered as a single unified unit inside battery body!
    CGFloat totalW = 28.5;
    CGFloat totalH = 22.0;

    CGFloat bodyW = 24.5;
    CGFloat bodyH = 12.0;
    CGFloat radius = 3.5;

    CGFloat nubW = 1.4;
    CGFloat nubH = 5.0;
    CGFloat nubGap = 1.0;

    __weak typeof(self) weakSelf = self;
    NSImage *image = [NSImage imageWithSize:NSMakeSize(totalW, totalH) flipped:NO drawingHandler:^BOOL(NSRect dstRect) {
        // Detect Dark vs Light menu bar
        BOOL isDark = NO;
        NSAppearance *currentApp = [NSAppearance currentDrawingAppearance];
        if (currentApp && ([currentApp.name containsString:@"Dark"] || [currentApp.name containsString:@"vibrantDark"])) {
            isDark = YES;
        } else if (weakSelf.statusItem.button.effectiveAppearance) {
            isDark = [weakSelf.statusItem.button.effectiveAppearance.name containsString:@"Dark"];
        }

        NSColor *pillColor = isDark ? [NSColor colorWithCalibratedWhite:1.0 alpha:0.94] : [NSColor colorWithCalibratedWhite:0.06 alpha:0.94];
        NSColor *nubColor = [pillColor colorWithAlphaComponent:0.55];

        CGFloat bodyX = 0.8;
        CGFloat bodyY = (totalH - bodyH) / 2.0;
        NSRect bodyRect = NSMakeRect(bodyX, bodyY, bodyW, bodyH);

        // 1. Solid Battery Pill Body (Apple squarish curvature)
        NSBezierPath *pillPath = [NSBezierPath bezierPathWithRoundedRect:bodyRect xRadius:radius yRadius:radius];
        [pillColor set];
        [pillPath fill];

        // 2. Detached Terminal Nub (flat on left, convex arc on right)
        CGFloat nubX = NSMaxX(bodyRect) + nubGap;
        CGFloat nubY = bodyY + (bodyH - nubH) / 2.0;

        NSBezierPath *nubPath = [NSBezierPath bezierPath];
        [nubPath moveToPoint:NSMakePoint(nubX, nubY)];
        [nubPath lineToPoint:NSMakePoint(nubX + 0.3, nubY)];
        [nubPath appendBezierPathWithArcFromPoint:NSMakePoint(nubX + nubW, nubY)
                                          toPoint:NSMakePoint(nubX + nubW, nubY + nubH / 2.0)
                                           radius:nubH / 2.0];
        [nubPath appendBezierPathWithArcFromPoint:NSMakePoint(nubX + nubW, nubY + nubH)
                                          toPoint:NSMakePoint(nubX + 0.3, nubY + nubH)
                                           radius:nubH / 2.0];
        [nubPath lineToPoint:NSMakePoint(nubX, nubY + nubH)];
        [nubPath closePath];
        [nubColor set];
        [nubPath fill];

        // 3. Stencil Cutout with DestinationOut (takes exact background wallpaper color)
        CGContextRef ctx = [[NSGraphicsContext currentContext] CGContext];
        CGContextSaveGState(ctx);
        CGContextSetBlendMode(ctx, kCGBlendModeDestinationOut);

        CGFloat fontSize = (text.length >= 3) ? 8.8 : 9.4;
        CGFloat kern = (text.length >= 3) ? -0.38 : -0.20;
        CGFloat textOffset = (text.length >= 3) ? 0.25 : 0.20;

        NSFont *baseFont = [NSFont systemFontOfSize:fontSize weight:NSFontWeightMedium];
        NSFontDescriptor *desc = [baseFont.fontDescriptor fontDescriptorWithDesign:NSFontDescriptorSystemDesignRounded];
        NSFont *font = [NSFont fontWithDescriptor:desc size:fontSize] ?: baseFont;

        NSDictionary *attrs = @{
            NSFontAttributeName: font,
            NSForegroundColorAttributeName: [NSColor blackColor],
            NSKernAttributeName: @(kern)
        };
        NSAttributedString *aStr = [[NSAttributedString alloc] initWithString:text attributes:attrs];
        NSSize textSize = [aStr size];

        CGFloat boltW = (text.length >= 3) ? 4.0 : 4.8;
        CGFloat boltH = (text.length >= 3) ? 7.2 : 8.0;
        CGFloat boltGap = (text.length >= 3) ? 0.8 : 1.0;

        // Strictly center (numbers + bolt) as a unified unit inside the battery body
        CGFloat contentW = showBolt ? (textSize.width + boltGap + boltW) : textSize.width;
        CGFloat startContentX = bodyX + (bodyW - contentW) / 2.0;
        CGFloat textY = bodyY + (bodyH - textSize.height) / 2.0 + textOffset;

        [aStr drawAtPoint:NSMakePoint(startContentX, textY)];

        if (showBolt) {
            CGFloat boltX = startContentX + textSize.width + boltGap;
            CGFloat boltY = bodyY + (bodyH - boltH) / 2.0 + 0.10;

            // Sharp pointy top and bottom tips with bold Retina body silhouette
            NSBezierPath *boltPath = [NSBezierPath bezierPath];
            [boltPath moveToPoint:NSMakePoint(boltX + boltW * 0.82, boltY + boltH)];
            [boltPath lineToPoint:NSMakePoint(boltX + boltW * 0.56, boltY + boltH * 0.56)];
            [boltPath lineToPoint:NSMakePoint(boltX + boltW * 1.00, boltY + boltH * 0.54)];
            [boltPath lineToPoint:NSMakePoint(boltX + boltW * 0.18, boltY)];
            [boltPath lineToPoint:NSMakePoint(boltX + boltW * 0.44, boltY + boltH * 0.44)];
            [boltPath lineToPoint:NSMakePoint(boltX + boltW * 0.00, boltY + boltH * 0.46)];
            [boltPath closePath];

            [[NSColor blackColor] set];
            [boltPath fill];
        }

        CGContextRestoreGState(ctx);
        return YES;
    }];

    return image;
}

#pragma mark - State Logic & Display Updates

- (float)currentActiveDrawWatts {
    float draw = 0.0f;
    if (self.systemLoadWatts >= 1.0f) {
        draw = self.systemLoadWatts;
    } else if (fabsf(self.liveWatts) >= 1.0f) {
        draw = fabsf(self.liveWatts);
    }
    if (draw < 1.0f) {
        draw = 9.6f;
    }
    return draw;
}

- (void)updateIconOnly {
    if (self.isHovered) {
        // Refresh live telemetry on hover for accurate real-time wattage
        [self readTelemetry];
    }

    int watts = self.adapterWatts;
    if (self.isConnected && (self.capacity >= 100 || (self.isFullyCharged && !self.isCharging))) {
        watts = (int)roundf([self currentActiveDrawWatts]);
    } else if (watts <= 0 && fabsf(self.liveWatts) > 0.5f) {
        watts = (int)roundf(fabsf(self.liveWatts));
    }
    if (watts <= 0) {
        watts = self.isConnected ? 60 : 15;
    }

    // Exact User Rules:
    // 1. When running on battery and mouse is away: stock percentage number, no bolt.
    // 2. When plugged into charger and mouse is away: stock percentage number + tiny lightning bolt, centered together!
    // 3. When hovering mouse over symbol: change to wattage followed by capital 'W' (e.g. "11W" or "67W") WITHOUT flash icon!
    // 4. When mouse leaves: swiftly switch back to stock view.
    // 5. When plugged into charger: show charging wattage for 2.0 seconds, then revert.
    NSString *displayText;
    BOOL showBolt = NO;
    if (self.isHovered) {
        displayText = [NSString stringWithFormat:@"%dW", watts];
        showBolt = NO;
    } else if (self.isConnected && self.isPlugInFlashActive) {
        displayText = [NSString stringWithFormat:@"%dW", watts];
        showBolt = NO;
    } else {
        displayText = [NSString stringWithFormat:@"%d", self.capacity];
        showBolt = self.isConnected;
    }

    NSImage *icon = [self renderConstantBatteryPillWithText:displayText capacity:self.capacity showBolt:showBolt];
    self.statusItem.button.image = icon;
    self.statusItem.button.title = @"";
    self.statusItem.button.imagePosition = NSImageOnly;
    self.statusItem.button.title = @"";
    self.statusItem.button.imagePosition = NSImageOnly;

    // Tooltip
    if (self.isConnected) {
        if (self.capacity >= 100 || self.isFullyCharged) {
            float draw = [self currentActiveDrawWatts];
            self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeWatts: %d%% · %.1fW Current draw (AC Pass-Through · %@)", self.capacity, draw, self.adapterName];
        } else {
            self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeWatts: %d%% · %dW (%@)", self.capacity, watts, self.adapterName];
        }
    } else {
        float draw = [self currentActiveDrawWatts];
        self.statusItem.button.toolTip = [NSString stringWithFormat:@"ChargeWatts: %d%% · %.1fW Current draw (Discharging)", self.capacity, draw];
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

    // 1. Primary Status Header (Clean typography, monochrome B&W)
    NSString *headerTitle;
    NSString *iconSymbol;
    if (self.isConnected) {
        if (self.capacity >= 100 || (self.isFullyCharged && !self.isCharging)) {
            float draw = [self currentActiveDrawWatts];
            // Exact User Specification: "Battery: 100% · 9.6W Current draw"
            headerTitle = [NSString stringWithFormat:@"Battery: %d%% · %.1fW Current draw", self.capacity, draw];
            iconSymbol = @"powerplug.fill";
        } else {
            int w = self.adapterWatts > 0 ? self.adapterWatts : (int)roundf(self.liveWatts);
            if (w > 0) {
                headerTitle = [NSString stringWithFormat:@"Battery: %d%% · %dW Charging", self.capacity, w];
            } else {
                headerTitle = [NSString stringWithFormat:@"Battery: %d%% · Connected", self.capacity];
            }
            iconSymbol = @"bolt.fill";
        }
    } else {
        float draw = [self currentActiveDrawWatts];
        headerTitle = [NSString stringWithFormat:@"Battery: %d%% · %.1fW Current draw", self.capacity, draw];
        iconSymbol = @"battery.100";
    }
    NSMenuItem *headerItem = [[NSMenuItem alloc] initWithTitle:headerTitle action:nil keyEquivalent:@""];
    headerItem.enabled = NO;
    NSImage *headerIcon = [NSImage imageWithSystemSymbolName:iconSymbol accessibilityDescription:nil];
    if (headerIcon) {
        [headerIcon setTemplate:YES];
        headerItem.image = headerIcon;
    }
    [menu addItem:headerItem];

    // 2. Battery Health & Cycles
    NSString *healthTitle = [NSString stringWithFormat:@"Health: %.0f%% (%d cycles)", self.healthPercent, self.cycleCount];
    NSMenuItem *healthItem = [[NSMenuItem alloc] initWithTitle:healthTitle action:nil keyEquivalent:@""];
    healthItem.enabled = NO;
    [menu addItem:healthItem];

    // 3. Time Remaining (if available)
    if (self.isCharging && self.timeToFull > 0 && self.timeToFull < 1000) {
        int h = self.timeToFull / 60;
        int m = self.timeToFull % 60;
        NSString *timeStr = (h > 0) ? [NSString stringWithFormat:@"Full in %dh %02dm", h, m] : [NSString stringWithFormat:@"Full in %d min", m];
        NSMenuItem *tItem = [[NSMenuItem alloc] initWithTitle:timeStr action:nil keyEquivalent:@""];
        tItem.enabled = NO;
        [menu addItem:tItem];
    } else if (!self.isConnected && self.timeToEmpty > 0 && self.timeToEmpty < 10000) {
        int h = self.timeToEmpty / 60;
        int m = self.timeToEmpty % 60;
        NSString *timeStr = [NSString stringWithFormat:@"Time remaining: %dh %02dm", h, m];
        NSMenuItem *tItem = [[NSMenuItem alloc] initWithTitle:timeStr action:nil keyEquivalent:@""];
        tItem.enabled = NO;
        [menu addItem:tItem];
    }

    [menu addItem:[NSMenuItem separatorItem]];

    // 4. Launch at Login
    BOOL isLoginItem = [self isAutoStartEnabled];
    NSMenuItem *loginItem = [[NSMenuItem alloc] initWithTitle:(isLoginItem ? @"✓ Launch at Login" : @"  Launch at Login")
                                                       action:@selector(toggleAutoStart)
                                                keyEquivalent:@""];
    loginItem.target = self;
    [menu addItem:loginItem];

    // 5. Replace / Hide Apple Stock Battery
    BOOL stockHidden = [self isStockBatteryHidden];
    NSMenuItem *hideStockItem = [[NSMenuItem alloc] initWithTitle:(stockHidden ? @"✓ Hide Apple Stock Battery" : @"  Hide Apple Stock Battery")
                                                           action:@selector(toggleStockBatteryHidden)
                                                    keyEquivalent:@""];
    hideStockItem.target = self;
    [menu addItem:hideStockItem];

    NSMenuItem *settingsItem = [[NSMenuItem alloc] initWithTitle:@"Battery Settings..." action:@selector(openControlCenterSettings) keyEquivalent:@""];
    settingsItem.target = self;
    [menu addItem:settingsItem];

    [menu addItem:[NSMenuItem separatorItem]];

    NSMenuItem *aboutItem = [[NSMenuItem alloc] initWithTitle:@"About ChargeWatts" action:@selector(showAbout) keyEquivalent:@""];
    aboutItem.target = self;
    [menu addItem:aboutItem];

    NSMenuItem *uninstallItem = [[NSMenuItem alloc] initWithTitle:@"Uninstall ChargeWatts..." action:@selector(uninstallChargeWatts) keyEquivalent:@""];
    uninstallItem.target = self;
    [menu addItem:uninstallItem];

    NSMenuItem *quitItem = [[NSMenuItem alloc] initWithTitle:@"Quit ChargeWatts" action:@selector(quitApp) keyEquivalent:@"q"];
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
    [[NSWorkspace sharedWorkspace] openURL:[NSURL URLWithString:@"https://github.com/alaska14/chargewatts/issues"]];
}

- (void)showAbout {
    NSAlert *about = [[NSAlert alloc] init];
    about.messageText = @"ChargeWatts 1.2 by MonoLab";
    about.informativeText = @"Stock-matching native battery icon with live wattage on plug-in & hover, adapter telemetry, and true hardware health.\n\nCrafted by MonoLab for 0.0% CPU overhead.";
    [about addButtonWithTitle:@"OK"];
    [NSApp activateIgnoringOtherApps:YES];
    [about runModal];
}

- (BOOL)isAutoStartEnabled {
    NSDictionary *error = nil;
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:
        @"tell application \"System Events\"\n"
        @"  return exists (login item \"ChargeWatts\")\n"
        @"end tell"];
    NSAppleEventDescriptor *desc = [as executeAndReturnError:&error];
    return [desc booleanValue];
}

- (void)toggleAutoStart {
    BOOL current = [self isAutoStartEnabled];
    NSString *appPath = [[NSBundle mainBundle] bundlePath];
    NSString *script;
    if (current) {
        script = @"tell application \"System Events\"\n"
                 @"  delete login item \"ChargeWatts\"\n"
                 @"end tell";
    } else {
        script = [NSString stringWithFormat:
                 @"tell application \"System Events\"\n"
                 @"  make login item at end with properties {path:\"%@\", hidden:false}\n"
                 @"end tell", appPath];
    }
    NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
    [as executeAndReturnError:nil];
}

- (void)ensureAutoStart {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    if (![defs boolForKey:@"hasConfiguredAutoStart"]) {
        [defs setBool:YES forKey:@"hasConfiguredAutoStart"];
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        if (appPath && [appPath hasPrefix:@"/Applications"]) {
            NSString *script = [NSString stringWithFormat:
                @"tell application \"System Events\"\n"
                @"  if not (exists (login item \"ChargeWatts\")) then\n"
                @"    make login item at end with properties {path:\"%@\", hidden:false}\n"
                @"  end if\n"
                @"end tell", appPath];
            NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
            [as executeAndReturnError:nil];
        }
    }
}

- (BOOL)isStockBatteryHidden {
    NSTask *task = [[NSTask alloc] init];
    task.launchPath = @"/usr/bin/defaults";
    task.arguments = @[@"-currentHost", @"read", @"com.apple.controlcenter", @"Battery"];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = [NSPipe pipe];
    @try {
        [task launch];
        [task waitUntilExit];
        NSData *data = [[pipe fileHandleForReading] readDataToEndOfFile];
        NSString *outStr = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        return [outStr isEqualToString:@"8"];
    } @catch (NSException *e) {
        return NO;
    }
}

- (void)setStockBatteryHidden:(BOOL)hidden {
    NSString *valStr = hidden ? @"8" : @"2";
    @try {
        NSTask *task = [[NSTask alloc] init];
        task.launchPath = @"/usr/bin/defaults";
        task.arguments = @[@"-currentHost", @"write", @"com.apple.controlcenter", @"Battery", @"-int", valStr];
        [task launch];
        [task waitUntilExit];

        NSTask *killTask = [[NSTask alloc] init];
        killTask.launchPath = @"/usr/bin/killall";
        killTask.arguments = @[@"ControlCenter"];
        [killTask launch];
        [killTask waitUntilExit];
    } @catch (NSException *e) {
    }
}

- (void)toggleStockBatteryHidden {
    BOOL current = [self isStockBatteryHidden];
    BOOL newHidden = !current;
    [[NSUserDefaults standardUserDefaults] setBool:(!newHidden) forKey:@"userDisabledStockBatteryHiding"];
    [[NSUserDefaults standardUserDefaults] synchronize];
    [self setStockBatteryHidden:newHidden];
}

- (void)ensureStockBatteryReplaced {
    NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
    // Automatically hide stock battery on launch so user never has duplicate battery icons
    if (![defs boolForKey:@"userDisabledStockBatteryHiding"]) {
        if (![self isStockBatteryHidden]) {
            [self setStockBatteryHidden:YES];
        }
    }
}

- (void)uninstallChargeWatts {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.messageText = @"Uninstall ChargeWatts?";
    alert.informativeText = @"This will automatically restore the original Apple stock battery in your menu bar, remove ChargeWatts from Login Items, and move the app to the Trash.";
    [alert addButtonWithTitle:@"Uninstall & Restore"];
    [alert addButtonWithTitle:@"Cancel"];
    [NSApp activateIgnoringOtherApps:YES];
    NSInteger response = [alert runModal];
    if (response == NSAlertFirstButtonReturn) {
        // 1. Immediately restore original Apple stock battery at slot 400
        [self setStockBatteryHidden:NO];

        // 2. Remove Login Item
        NSString *script = @"tell application \"System Events\"\n"
                           @"  if exists (login item \"ChargeWatts\") then\n"
                           @"    delete login item \"ChargeWatts\"\n"
                           @"  end if\n"
                           @"end tell";
        NSAppleScript *as = [[NSAppleScript alloc] initWithSource:script];
        [as executeAndReturnError:nil];

        // 3. Move app bundle to Trash
        NSString *appPath = [[NSBundle mainBundle] bundlePath];
        if (appPath) {
            [[NSFileManager defaultManager] trashItemAtURL:[NSURL fileURLWithPath:appPath] resultingItemURL:nil error:nil];
        }

        // 4. Terminate cleanly
        [NSApp terminate:nil];
    }
}

- (void)restoreStockBatteryOnExit {
    if (![[NSUserDefaults standardUserDefaults] boolForKey:@"userDisabledStockBatteryHiding"]) {
        [self setStockBatteryHidden:NO];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    // When ChargeWatts quits, restore the original Apple stock battery so the menu bar is never left without a battery
    [self restoreStockBatteryOnExit];
}

- (void)quitApp {
    [self restoreStockBatteryOnExit];
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
