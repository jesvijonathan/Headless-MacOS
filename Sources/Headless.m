// Headless — one agent for a MacBook that runs with no built-in panel.
//
//   • keeps the built-in display disabled whenever an external one is active
//   • manual Touch Bar + keyboard backlight brightness (no ambient light sensor)
//   • fan modes (auto / smart curve / custom RPM / max) via the root headless-fand daemon
//   • live CPU / memory / temperature / fan / battery stats on the Touch Bar at the desktop
//   • external monitor brightness (software dimming), resolution / refresh
//     rate, Night Shift, keep-awake, lock and display sleep, from the Control
//     Strip, menu bar, global shortcuts (⌃⌥⌘) and a small CLI
//
// Nothing polls. Work happens on display reconfiguration, wake, unlock,
// ControlStrip relaunch, Touch Bar state changes and settings changes.
//
// Runs from /Library/LaunchAgents in both LoginWindow and Aqua sessions. Before
// login it only enforces the display/brightness/awake state; once login
// completes it re-execs itself into the full UI.

#import <Cocoa/Cocoa.h>
#import <Carbon/Carbon.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/IOMessage.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <dlfcn.h>
#import <mach-o/dyld.h>
#import <notify.h>
#import <objc/message.h>
#import <os/log.h>
#import <sys/socket.h>
#import <sys/un.h>
#import <ifaddrs.h>
#import <net/if.h>

#define HKChangedNotify "dev.jesvi.headless.changed"
#define HKShowNotify "dev.jesvi.headless.show"
static NSString * const HKDisplaysChanged = @"HKDisplaysChanged";
static NSString * const TrayID = @"dev.jesvi.headless.tray";
static os_log_t HKLog;

@interface NSObject (HKPrivate)
- (id)copyPropertyForKey:(NSString *)key;
- (BOOL)setProperty:(id)value forKey:(NSString *)key;
- (id)initWithClientID:(NSString *)clientID;
- (BOOL)activateWithError:(NSError **)error;
- (BOOL)registerDisplayStateUpdateCallbackWithBlock:(id)block;
@end
@interface NSTouchBar (HKPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)bar systemTrayItemIdentifier:(NSString *)identifier;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)bar;
@end
@interface NSTouchBarItem (HKPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

static void After(double seconds, dispatch_block_t block) {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(seconds * NSEC_PER_SEC)), dispatch_get_main_queue(), block);
}

#pragma mark - Settings

static NSMutableDictionary *gSettings;

static NSString *SettingsPath(void) {
    const char *env = getenv("HEADLESS_SETTINGS");
    if (env && *env) return @(env);
    return [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/Headless/settings.plist"];
}

static void LoadSettings(void) {
    gSettings = [NSMutableDictionary dictionaryWithContentsOfFile:SettingsPath()] ?: [NSMutableDictionary dictionary];
}

static BOOL HasSetting(NSString *key) { return [gSettings[key] isKindOfClass:NSNumber.class]; }
static BOOL SettingBool(NSString *key, BOOL fallback) { return HasSetting(key) ? [gSettings[key] boolValue] : fallback; }
static double SettingLevel(NSString *key, double fallback) {
    double v = HasSetting(key) ? [gSettings[key] doubleValue] : fallback;
    return isfinite(v) ? fmax(0, fmin(1, v)) : fallback;
}

static BOOL SaveSettingsNow(void) {
    NSString *path = SettingsPath();
    [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:NULL];
    return [gSettings writeToFile:path atomically:YES];
}

// Sliders fire continuously; write once they settle.
static void SetSetting(NSString *key, id value) {
    static uint64_t generation;
    gSettings[key] = value;
    uint64_t mine = ++generation;
    After(0.5, ^{ if (mine == generation) SaveSettingsNow(); });
}

#pragma mark - Displays

typedef CGError (*SLSGetDisplayListFn)(uint32_t, CGDirectDisplayID *, uint32_t *);
typedef CGError (*SLSConfigureDisplayEnabledFn)(CGDisplayConfigRef, CGDirectDisplayID, bool);
static SLSGetDisplayListFn SLSGetDisplayList;
static SLSConfigureDisplayEnabledFn SLSConfigureDisplayEnabled;

typedef struct {
    CGDirectDisplayID ids[16];
    uint32_t count;
    CGDirectDisplayID internal;  // 0 when not enumerated
    CGDirectDisplayID external;  // main active external display, 0 when none
    bool internalLive;           // built-in display is online or active
} Displays;

static void LoadSkyLight(void) {
    void *lib = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    SLSGetDisplayList = lib ? (SLSGetDisplayListFn)dlsym(lib, "SLSGetDisplayList") : NULL;
    SLSConfigureDisplayEnabled = lib ? (SLSConfigureDisplayEnabledFn)dlsym(lib, "SLSConfigureDisplayEnabled") : NULL;
}

// SLSGetDisplayList also returns disabled displays, unlike CGGetOnlineDisplayList.
static bool ReadDisplays(Displays *d) {
    memset(d, 0, sizeof *d);
    if (!SLSGetDisplayList || SLSGetDisplayList(16, d->ids, &d->count) != kCGErrorSuccess) return false;
    for (uint32_t i = 0; i < d->count; i++) {
        CGDirectDisplayID id = d->ids[i];
        if (CGDisplayIsBuiltin(id)) {
            d->internal = id;
            d->internalLive = CGDisplayIsOnline(id) || CGDisplayIsActive(id);
        } else if (CGDisplayIsActive(id) && (!d->external || CGDisplayIsMain(id))) {
            d->external = id;
        }
    }
    return true;
}

static CGError SetInternalEnabled(const Displays *d, bool enabled) {
    if (!d->internal || !SLSConfigureDisplayEnabled) return kCGErrorFailure;
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err) return err;
    if (!enabled) for (uint32_t i = 0; i < d->count && !err; i++) err = CGConfigureDisplayMirrorOfDisplay(config, d->ids[i], kCGNullDirectDisplay);
    if (!err) err = SLSConfigureDisplayEnabled(config, d->internal, enabled);
    if (err) { CGCancelDisplayConfiguration(config); return err; }
    return CGCompleteDisplayConfiguration(config, kCGConfigureForSession);
}

static uint64_t gEnforceGeneration;
static int gEnforceAttempts;  // consecutive disables that have not stuck yet
static void EnforceHeadless(void);

static void ScheduleEnforce(double delay) {
    uint64_t mine = ++gEnforceGeneration;
    After(delay, ^{ if (mine == gEnforceGeneration) EnforceHeadless(); });
}

static void EnforceHeadless(void) {
    if (!SettingBool(@"Headless", YES)) return;
    Displays d;
    if (!ReadDisplays(&d) || !d.internal || !d.internalLive || !d.external) { gEnforceAttempts = 0; return; }
    // Something keeps re-enabling it: stop until the next wake/unlock/manual retry.
    if (gEnforceAttempts >= 5) return;
    gEnforceAttempts++;
    CGError err = SetInternalEnabled(&d, false);
    os_log(HKLog, "Built-in display was live; disabling (attempt %d) -> %d", gEnforceAttempts, err);
    ScheduleEnforce(gEnforceAttempts * 2.0);  // verify; resets the counter once it has stuck
}

static void RetryEnforce(double delay) { gEnforceAttempts = 0; ScheduleEnforce(delay); }

static void ApplyMonitorSoon(double delay);

static void DisplaysReconfigured(CGDirectDisplayID display, CGDisplayChangeSummaryFlags flags, void *info) {
    if (flags & kCGDisplayBeginConfigurationFlag) return;
    ScheduleEnforce(0.5);
    ApplyMonitorSoon(0.8);
    [NSNotificationCenter.defaultCenter postNotificationName:HKDisplaysChanged object:nil];
}

static void SetHeadless(BOOL on) {
    gSettings[@"Headless"] = @(on);
    SaveSettingsNow();
    Displays d;
    if (on) RetryEnforce(0);
    else if (ReadDisplays(&d) && d.internal && !d.internalLive) SetInternalEnabled(&d, true);
}

#pragma mark Display modes

static BOOL ModeIsHiDPI(CGDisplayModeRef m) { return CGDisplayModeGetPixelWidth(m) > CGDisplayModeGetWidth(m); }

static NSString *RateString(double hz) {
    return fabs(hz - round(hz)) < 0.01 ? [NSString stringWithFormat:@"%.0f Hz", hz] : [NSString stringWithFormat:@"%.2f Hz", hz];
}
static NSString *SizeString(CGDisplayModeRef m) {
    return [NSString stringWithFormat:@"%zu × %zu%@", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), ModeIsHiDPI(m) ? @" HiDPI" : @""];
}
static NSString *SizeKey(CGDisplayModeRef m) {
    return [NSString stringWithFormat:@"%zux%zu/%zu", CGDisplayModeGetWidth(m), CGDisplayModeGetHeight(m), CGDisplayModeGetPixelWidth(m)];
}
static NSString *ModeKey(CGDisplayModeRef m) {
    return [NSString stringWithFormat:@"%@@%.2f", SizeKey(m), CGDisplayModeGetRefreshRate(m)];
}

// Desktop-usable modes, de-duplicated, largest and fastest first.
static NSArray *DisplayModes(CGDirectDisplayID display) {
    NSDictionary *options = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes: @YES};
    NSArray *all = CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)options));
    NSMutableDictionary *unique = [NSMutableDictionary dictionary];
    for (id m in all) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        if (CGDisplayModeIsUsableForDesktopGUI(mode) && !unique[ModeKey(mode)]) unique[ModeKey(mode)] = m;
    }
    return [unique.allValues sortedArrayUsingComparator:^NSComparisonResult(id a, id b) {
        CGDisplayModeRef x = (__bridge CGDisplayModeRef)a, y = (__bridge CGDisplayModeRef)b;
        if (CGDisplayModeGetWidth(x) != CGDisplayModeGetWidth(y)) return CGDisplayModeGetWidth(x) > CGDisplayModeGetWidth(y) ? NSOrderedAscending : NSOrderedDescending;
        if (CGDisplayModeGetHeight(x) != CGDisplayModeGetHeight(y)) return CGDisplayModeGetHeight(x) > CGDisplayModeGetHeight(y) ? NSOrderedAscending : NSOrderedDescending;
        if (ModeIsHiDPI(x) != ModeIsHiDPI(y)) return ModeIsHiDPI(x) ? NSOrderedAscending : NSOrderedDescending;
        double rx = CGDisplayModeGetRefreshRate(x), ry = CGDisplayModeGetRefreshRate(y);
        return rx == ry ? NSOrderedSame : rx > ry ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static CGError ApplyDisplayMode(CGDirectDisplayID display, CGDisplayModeRef mode) {
    CGDisplayConfigRef config = NULL;
    CGError err = CGBeginDisplayConfiguration(&config);
    if (err) return err;
    err = CGConfigureDisplayWithDisplayMode(config, display, mode, NULL);
    if (err) { CGCancelDisplayConfiguration(config); return err; }
    return CGCompleteDisplayConfiguration(config, kCGConfigurePermanently);
}

static NSString *DisplayName(CGDirectDisplayID display) {
    for (NSScreen *screen in NSScreen.screens)
        if ([screen.deviceDescription[@"NSScreenNumber"] unsignedIntValue] == display) return screen.localizedName;
    return @"External display";
}

#pragma mark - Brightness

static id gTouchBarClient, gKeyboardClient;

static id TouchBarClient(void) {
    if (gTouchBarClient) return gTouchBarClient;
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/DFRBrightness.framework/DFRBrightness", RTLD_NOW);
    id client = [[NSClassFromString(@"DFRBrightnessClient") alloc] init];
    if (![client respondsToSelector:@selector(copyPropertyForKey:)] || ![client respondsToSelector:@selector(setProperty:forKey:)]) return nil;
    NSDictionary *caps = [client copyPropertyForKey:@"BrightnessControlCapabilities"];
    if (![caps isKindOfClass:NSDictionary.class] || ![caps[@"DFR"] boolValue]) return nil;
    return gTouchBarClient = client;
}

static double TouchBarCurrent(void) {
    NSDictionary *b = [TouchBarClient() copyPropertyForKey:@"DisplayBrightness"];
    NSNumber *n = [b isKindOfClass:NSDictionary.class] ? b[@"Brightness"] : nil;
    return [n isKindOfClass:NSNumber.class] ? n.doubleValue : NAN;
}

static BOOL SetTouchBar(double level) {
    id client = TouchBarClient();
    if (!client) return NO;
    NSNumber *automatic = [client copyPropertyForKey:@"DisplayBrightnessAuto"];
    if ([automatic isKindOfClass:NSNumber.class] && automatic.boolValue) [client setProperty:@NO forKey:@"DisplayBrightnessAuto"];
    // Only brightness: power and idle dimming stay with macOS.
    return [client setProperty:@{@"Brightness": @(level)} forKey:@"DisplayBrightness"];
}

// Idempotent: writes only when the hardware drifted from the saved level.
static void ApplyTouchBar(void) {
    if (!TouchBarClient()) return;
    double want = SettingLevel(@"TouchBarLevel", 1.0);
    NSNumber *automatic = [gTouchBarClient copyPropertyForKey:@"DisplayBrightnessAuto"];
    // Hardware brightness is quantized (100% reads back as about 99.1%).
    if (fabs(TouchBarCurrent() - want) < 0.012 && !automatic.boolValue) return;
    if (SetTouchBar(want)) return;
    gTouchBarClient = nil;  // the service may have restarted under us
    SetTouchBar(want);
}

static id KeyboardClient(void) {
    if (gKeyboardClient) return gKeyboardClient;
    static void *framework;
    if (!framework) framework = dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
    id client = [[NSClassFromString(@"BrightnessSystemClient") alloc] initWithClientID:@"com.apple.controlstrip"];
    if (![client respondsToSelector:@selector(copyPropertyForKey:)] || ![client respondsToSelector:@selector(setProperty:forKey:)]) return nil;
    if ([client respondsToSelector:@selector(activateWithError:)] && ![client activateWithError:NULL]) return nil;
    return gKeyboardClient = client;
}

static double KeyboardCurrent(void) {
    NSNumber *n = [KeyboardClient() copyPropertyForKey:@"KeyboardBacklightBrightness"];
    return [n isKindOfClass:NSNumber.class] ? n.doubleValue : NAN;
}

static BOOL SetKeyboard(double level) {
    return [KeyboardClient() setProperty:@(level) forKey:@"KeyboardBacklightBrightness"];
}

// Only after launch/wake, never periodically, so macOS idle dimming still works.
static void ApplyKeyboard(void) {
    if (!HasSetting(@"KeyboardLevel")) return;
    double want = SettingLevel(@"KeyboardLevel", 1.0);
    if (fabs(KeyboardCurrent() - want) >= 0.01) SetKeyboard(want);
}

static void ApplyBrightnessSoon(double delay) {
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(delay, ^{ if (mine == generation) { ApplyTouchBar(); ApplyKeyboard(); } });
}

#pragma mark - Monitor brightness

// Many monitors/adapters do not answer DDC on Apple Silicon, so dim in software by
// scaling the gamma ramp. It lives only as long as this process (macOS restores it on
// exit), and never goes below a visible floor because it is the only screen.
static const double MonitorFloor = 0.12;
static BOOL gMonitorDimmed;

static void ApplyMonitor(void) {
    double level = SettingLevel(@"MonitorLevel", 1.0);
    if (level >= 0.995) {
        if (gMonitorDimmed) CGDisplayRestoreColorSyncSettings();
        gMonitorDimmed = NO;
        return;
    }
    Displays d;
    if (!ReadDisplays(&d)) return;
    float max = (float)(MonitorFloor + (1 - MonitorFloor) * level);
    for (uint32_t i = 0; i < d.count; i++)
        if (!CGDisplayIsBuiltin(d.ids[i]) && CGDisplayIsActive(d.ids[i]))
            CGSetDisplayTransferByFormula(d.ids[i], 0, max, 1, 0, max, 1, 0, max, 1);
    gMonitorDimmed = YES;
}

// macOS still keeps a "built-in display" brightness even with the panel gone; Apple's Control
// Strip brightness button and the brightness keys change it. Mirror it both ways so those
// controls dim the monitor instead of doing nothing.
static id BuiltinBrightnessClient(void) {
    static id client;
    if (!client) {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
        client = [[NSClassFromString(@"BrightnessSystemClient") alloc] initWithClientID:@"dev.jesvi.headless"];
        if (![client respondsToSelector:@selector(setProperty:forKey:)]) client = nil;
    }
    return client;
}

static double BuiltinBrightness(void) {
    NSDictionary *b = [BuiltinBrightnessClient() copyPropertyForKey:@"DisplayBrightness"];
    NSNumber *n = [b isKindOfClass:NSDictionary.class] ? b[@"Brightness"] : nil;
    return [n isKindOfClass:NSNumber.class] ? n.doubleValue : NAN;
}

static void SetBuiltinBrightness(double level) {
    if (SettingBool(@"BrightnessKeysControlMonitor", YES) && fabs(BuiltinBrightness() - level) >= 0.01)
        [BuiltinBrightnessClient() setProperty:@{@"Brightness": @(level)} forKey:@"DisplayBrightness"];
}

// Reconfiguration and wake reset gamma ramps; re-apply once things settle.
static void ApplyMonitorSoon(double delay) {
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(delay, ^{ if (mine == generation) ApplyMonitor(); });
}

#pragma mark - Night Shift, keep awake, lock

typedef struct { int hour, minute; } HKTime;
typedef struct { HKTime from, to; } HKSchedule;
typedef struct { BOOL active, enabled, sunSchedulePermitted; int mode; HKSchedule schedule; unsigned long long disableFlags; BOOL available; } HKBlueLightStatus;

static id BlueLightClient(void) {
    static id client;
    if (!client) {
        dlopen("/System/Library/PrivateFrameworks/CoreBrightness.framework/CoreBrightness", RTLD_NOW);
        client = [NSClassFromString(@"CBBlueLightClient") new];
    }
    return client;
}

static BOOL NightShiftOn(void) {
    id client = BlueLightClient();
    HKBlueLightStatus status = {0};
    return client && ((BOOL (*)(id, SEL, HKBlueLightStatus *))objc_msgSend)(client, @selector(getBlueLightStatus:), &status) && status.enabled;
}

static void SetNightShift(BOOL on) {
    id client = BlueLightClient();
    if (client) ((BOOL (*)(id, SEL, BOOL))objc_msgSend)(client, @selector(setEnabled:), on);
}

// Same as `caffeinate -s`: no system sleep while on AC power; displays may still sleep.
static IOPMAssertionID gAwakeAssertion;
static void UpdateKeepAwake(void) {
    BOOL want = SettingBool(@"KeepAwake", YES);
    if (want && !gAwakeAssertion) {
        IOPMAssertionCreateWithName(kIOPMAssertionTypePreventSystemSleep, kIOPMAssertionLevelOn, CFSTR("Headless: keep awake (headless server)"), &gAwakeAssertion);
    } else if (!want && gAwakeAssertion) {
        IOPMAssertionRelease(gAwakeAssertion);
        gAwakeAssertion = 0;
    }
}

static void LockScreen(void) {
    void *login = dlopen("/System/Library/PrivateFrameworks/login.framework/Versions/Current/login", RTLD_LAZY);
    void (*lock)(void) = login ? (void (*)(void))dlsym(login, "SACLockScreenImmediate") : NULL;
    if (lock) lock();
}

static void SleepDisplays(void) {
    [NSTask launchedTaskWithExecutableURL:[NSURL fileURLWithPath:@"/usr/bin/pmset"] arguments:@[@"displaysleepnow"] error:NULL terminationHandler:nil];
}

#pragma mark - Fans

// Fan control needs root, so it lives in the headless-fand LaunchDaemon; this is its client.
static NSDictionary *FanRequest(NSString *line) {
    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) return nil;
    struct sockaddr_un addr = {.sun_family = AF_UNIX};
    const char *path = getenv("HEADLESS_FAND_SOCKET");
    strlcpy(addr.sun_path, path ?: "/var/run/dev.jesvi.headless.fand.sock", sizeof addr.sun_path);
    struct timeval timeout = {6, 0};  // the first forced-mode write can take a few seconds
    setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, sizeof timeout);
    if (connect(fd, (struct sockaddr *)&addr, sizeof addr) != 0) { close(fd); return nil; }
    const char *request = [line stringByAppendingString:@"\n"].UTF8String;
    write(fd, request, strlen(request));
    NSMutableData *reply = [NSMutableData data];
    char chunk[1024];
    ssize_t n;
    while ((n = read(fd, chunk, sizeof chunk)) > 0) [reply appendBytes:chunk length:(NSUInteger)n];
    close(fd);
    id json = [NSJSONSerialization JSONObjectWithData:reply options:0 error:NULL];
    return [json isKindOfClass:NSDictionary.class] ? json : nil;
}

static void FanRequestAsync(NSString *line, void (^done)(NSDictionary *reply)) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSDictionary *reply = FanRequest(line);
        dispatch_async(dispatch_get_main_queue(), ^{ done(reply); });
    });
}

static NSString *FanSummary(NSDictionary *status) {
    if (!status) return @"Fan daemon not installed";
    NSDictionary *fan = [status[@"fans"] firstObject];
    return [NSString stringWithFormat:@"%.0f rpm · %.0f°", [fan[@"rpm"] doubleValue], [status[@"temp"] doubleValue]];
}

static NSString *FanModeTitle(NSString *mode) {
    return @{@"auto": @"Auto", @"smart": @"Smart", @"custom": @"Custom", @"max": @"Max"}[mode] ?: mode;
}

#pragma mark - System stats

static double CPUUsage(void) {
    static host_cpu_load_info_data_t last;
    host_cpu_load_info_data_t now;
    mach_msg_type_number_t count = HOST_CPU_LOAD_INFO_COUNT;
    if (host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, (host_info_t)&now, &count) != KERN_SUCCESS) return NAN;
    double busy = 0, total = 0;
    for (int i = 0; i < CPU_STATE_MAX; i++) {
        double ticks = (double)(now.cpu_ticks[i] - last.cpu_ticks[i]);
        total += ticks;
        if (i != CPU_STATE_IDLE) busy += ticks;
    }
    last = now;
    return total > 0 ? busy / total : NAN;
}

// Roughly Activity Monitor's "Memory Used": app (active) + wired + compressed.
static double MemoryUsage(void) {
    vm_statistics64_data_t vm;
    mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
    vm_size_t page = 0;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &count) != KERN_SUCCESS ||
        host_page_size(mach_host_self(), &page) != KERN_SUCCESS) return NAN;
    double used = (double)(vm.active_count + vm.wire_count + vm.compressor_page_count) * page;
    return used / (double)NSProcessInfo.processInfo.physicalMemory;
}

static double GPUUsage(void) {
    io_iterator_t iterator;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) return NAN;
    double usage = NAN;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        NSDictionary *stats = CFBridgingRelease(IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0));
        NSNumber *percent = [stats isKindOfClass:NSDictionary.class] ? stats[@"Device Utilization %"] : nil;
        if ([percent isKindOfClass:NSNumber.class]) usage = fmax(isnan(usage) ? 0 : usage, percent.doubleValue / 100);
        IOObjectRelease(service);
    }
    IOObjectRelease(iterator);
    return usage;
}

// Bytes/s in and out across all non-loopback interfaces since the previous call.
static void NetworkRates(double *down, double *up) {
    static uint64_t lastIn, lastOut;
    static CFAbsoluteTime lastTime;
    uint64_t in = 0, out = 0;
    struct ifaddrs *list;
    if (getifaddrs(&list) != 0) { *down = *up = NAN; return; }
    for (struct ifaddrs *i = list; i; i = i->ifa_next) {
        if (!i->ifa_addr || i->ifa_addr->sa_family != AF_LINK || (i->ifa_flags & IFF_LOOPBACK) || !i->ifa_data) continue;
        in += ((struct if_data *)i->ifa_data)->ifi_ibytes;
        out += ((struct if_data *)i->ifa_data)->ifi_obytes;
    }
    freeifaddrs(list);
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    double elapsed = now - lastTime;
    *down = lastTime && elapsed > 0 && in >= lastIn ? (in - lastIn) / elapsed : NAN;
    *up = lastTime && elapsed > 0 && out >= lastOut ? (out - lastOut) / elapsed : NAN;
    lastIn = in; lastOut = out; lastTime = now;
}

static NSString *RateText(double bytesPerSecond) {
    if (!isfinite(bytesPerSecond)) return @"–";
    if (bytesPerSecond >= 1e6) return [NSString stringWithFormat:@"%.1fM", bytesPerSecond / 1e6];
    if (bytesPerSecond >= 1e3) return [NSString stringWithFormat:@"%.0fK", bytesPerSecond / 1e3];
    return [NSString stringWithFormat:@"%.0fB", bytesPerSecond];
}

// nil when there is nothing worth showing (on AC power and not charging).
static NSString *BatteryText(NSString **symbol) {
    NSString *text = nil;
    CFTypeRef info = IOPSCopyPowerSourcesInfo();
    NSArray *sources = info ? CFBridgingRelease(IOPSCopyPowerSourcesList(info)) : nil;
    for (id source in sources) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(info, (__bridge CFTypeRef)source);
        if (![d[@kIOPSTypeKey] isEqualToString:@kIOPSInternalBatteryType]) continue;
        double level = [d[@kIOPSCurrentCapacityKey] doubleValue] / fmax(1, [d[@kIOPSMaxCapacityKey] doubleValue]);
        BOOL plugged = [d[@kIOPSPowerSourceStateKey] isEqualToString:@kIOPSACPowerValue];
        *symbol = [d[@kIOPSIsChargingKey] boolValue] ? @"battery.100.bolt"
            : level > 0.85 ? @"battery.100" : level > 0.6 ? @"battery.75" : level > 0.35 ? @"battery.50" : level > 0.15 ? @"battery.25" : @"battery.0";
        if (plugged && ![d[@kIOPSIsChargingKey] boolValue]) break;
        text = [NSString stringWithFormat:@"%.0f%%", level * 100];
    }
    if (info) CFRelease(info);
    return text;
}

#pragma mark - Wake (both modes)

static void (^gOnWake)(void);
static io_connect_t gPowerPort;

static void PowerChanged(void *refcon, io_service_t service, natural_t type, void *argument) {
    if (type == kIOMessageCanSystemSleep || type == kIOMessageSystemWillSleep) IOAllowPowerChange(gPowerPort, (long)argument);
    else if (type == kIOMessageSystemHasPoweredOn && gOnWake) gOnWake();
}

static void ObservePower(void (^onWake)(void)) {
    gOnWake = onWake;
    IONotificationPortRef port = NULL;
    io_object_t notifier;
    gPowerPort = IORegisterForSystemPower(NULL, &port, PowerChanged, &notifier);
    if (gPowerPort) IONotificationPortSetDispatchQueue(port, dispatch_get_main_queue());
}

static void Woke(void) {
    RetryEnforce(1);
    ApplyBrightnessSoon(1);
    ApplyMonitorSoon(1.5);
    After(4, ^{ ApplyTouchBar(); });  // the Touch Bar panel can power up late
}

static void SettingsChangedElsewhere(void) {
    LoadSettings();
    UpdateKeepAwake();
    RetryEnforce(0);
    ApplyBrightnessSoon(0);
    ApplyMonitorSoon(0);
}

#pragma mark - Pre-login mode

static BOOL SessionLoggedIn(void) {
    NSDictionary *session = CFBridgingRelease(CGSessionCopyCurrentDictionary());
    return [session[(__bridge NSString *)kCGSessionLoginDoneKey] boolValue];
}

static int RunPreLogin(void) {
    os_log(HKLog, "Starting in login-window mode (uid %d)", getuid());
    CGDisplayRegisterReconfigurationCallback(DisplaysReconfigured, NULL);
    ObservePower(^{ Woke(); });
    int token;
    notify_register_dispatch(HKChangedNotify, &token, dispatch_get_main_queue(), ^(int t) { SettingsChangedElsewhere(); });
    UpdateKeepAwake();
    EnforceHeadless();
    ApplyBrightnessSoon(0);
    ApplyMonitorSoon(0);
    if (getuid() != 0) {
        // Same process continues into the user's session: become the full app at login.
        // This check only runs while the login window is up.
        static dispatch_source_t timer;  // must outlive this scope
        timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
        dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC, NSEC_PER_SEC);
        dispatch_source_set_event_handler(timer, ^{
            if (!SessionLoggedIn()) return;
            if (gAwakeAssertion) IOPMAssertionRelease(gAwakeAssertion);
            char path[PATH_MAX]; uint32_t size = sizeof path;
            if (_NSGetExecutablePath(path, &size) == 0) execl(path, path, NULL);
            exit(1);  // launchd restarts us
        });
        dispatch_resume(timer);
    }
    CFRunLoopRun();
    return 0;
}

#pragma mark - App

static NSImage *Symbol(NSString *name, NSString *fallback) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        ?: (fallback ? [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:nil] : nil);
}

typedef NS_ENUM(UInt32, HKHotKey) {
    HKTouchBarUp = 1, HKTouchBarDown, HKKeyboardUp, HKKeyboardDown,
    HKShowControls, HKReapply, HKLock, HKSleepDisplays, HKToggleAwake, HKToggleNightShift,
    HKMonitorUp, HKMonitorDown, HKCycleFans,
};

@interface HKApp : NSObject <NSApplicationDelegate, NSMenuDelegate, NSScrubberDataSource, NSScrubberDelegate, NSScrubberFlowLayoutDelegate>
@property NSStatusItem *statusItem;
@property NSCustomTouchBarItem *tray;
@property NSTouchBar *mainBar, *displayBar, *touchBarPage, *keyboardPage, *monitorPage;
@property NSTextField *touchBarValue, *keyboardValue, *monitorValue;
@property NSSlider *touchBarSlider, *keyboardSlider, *monitorSlider;
@property NSButton *displayButton, *nightShiftButton, *awakeButton, *headlessButton;
@property NSScrubber *modeScrubber;
@property NSArray *modes;
@property NSInteger currentModeIndex;
@property CGDirectDisplayID modesDisplay;
@property pid_t controlStripPID;
@property NSPanel *hud;
@property NSImageView *hudImage;
@property NSTextField *hudText;
@property NSTimer *safetyNet;
@property NSTouchBar *fanPage, *fanCustomPage;
@property NSDictionary<NSString *, NSButton *> *fanModeButtons;
@property NSTextField *fanReadout, *fanValue;
@property NSSlider *fanSlider;
@property NSDictionary *fanStatus;
@property NSDate *fanRefreshUntil;
@property NSTouchBar *statsBar;
@property NSDictionary<NSString *, NSButton *> *statButtons;
@property NSTimer *statsTimer;
@property NSTouchBar *presentedBar;
@property NSDate *presentedAt;
- (void)hotKey:(HKHotKey)key;
@end

static void (*SetControlStripPresence)(NSString *, BOOL);

static OSStatus HotKeyPressed(EventHandlerCallRef next, EventRef event, void *context) {
    EventHotKeyID key;
    GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL, sizeof key, NULL, &key);
    [(__bridge HKApp *)context hotKey:(HKHotKey)key.id];
    return noErr;
}

@implementation HKApp

- (void)applicationDidFinishLaunching:(NSNotification *)note {
    os_log(HKLog, "Starting full app");
    CGDisplayRegisterReconfigurationCallback(DisplaysReconfigured, NULL);
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(displaysChanged:) name:HKDisplaysChanged object:nil];
    __weak HKApp *weakSelf = self;
    ObservePower(^{ Woke(); [weakSelf registerTray]; });
    NSNotificationCenter *workspace = NSWorkspace.sharedWorkspace.notificationCenter;
    for (NSString *name in @[NSWorkspaceScreensDidWakeNotification, NSWorkspaceSessionDidBecomeActiveNotification])
        [workspace addObserver:self selector:@selector(woke:) name:name object:nil];
    [NSDistributedNotificationCenter.defaultCenter addObserver:self selector:@selector(woke:) name:@"com.apple.screenIsUnlocked" object:nil];
    // Fires on every app launch/quit; used to notice ControlStrip restarting.
    [NSWorkspace.sharedWorkspace addObserver:self forKeyPath:@"runningApplications" options:0 context:NULL];

    int token;
    notify_register_dispatch(HKChangedNotify, &token, dispatch_get_main_queue(), ^(int t) { SettingsChangedElsewhere(); [weakSelf refreshControls]; });
    notify_register_dispatch(HKShowNotify, &token, dispatch_get_main_queue(), ^(int t) { [weakSelf showControls:nil]; });
    for (NSString *page in @[@"display", @"touchbar", @"keyboard", @"monitor", @"fans", @"stats"]) {
        SEL action = [page isEqualToString:@"stats"] ? @selector(showStats:) : NSSelectorFromString([NSString stringWithFormat:@"show%@Page:", [page isEqualToString:@"touchbar"] ? @"TouchBar" : [page isEqualToString:@"fans"] ? @"Fan" : page.capitalizedString]);
        notify_register_dispatch([@HKShowNotify "." stringByAppendingString:page].UTF8String, &token, dispatch_get_main_queue(), ^(int t) {
            ((void (*)(id, SEL, id))objc_msgSend)(weakSelf, action, nil);
        });
    }

    id touchBar = TouchBarClient();
    if ([touchBar respondsToSelector:@selector(registerDisplayStateUpdateCallbackWithBlock:)])
        [touchBar registerDisplayStateUpdateCallbackWithBlock:^{ dispatch_async(dispatch_get_main_queue(), ^{ ApplyBrightnessSoon(0.3); }); }];

    [self buildStatusItem];
    [self buildTouchBar];
    [self registerHotKeys];
    [self observeBrightnessKeys];
    UpdateKeepAwake();
    EnforceHeadless();
    ApplyBrightnessSoon(0);
    ApplyMonitorSoon(0);
    [self controlStripMayHaveChanged];
    // Last line of defence for anything that changes without telling us. Cheap and
    // coalesced by the system (2 min tolerance).
    self.safetyNet = [NSTimer scheduledTimerWithTimeInterval:900 repeats:YES block:^(NSTimer *t) {
        ApplyTouchBar(); RetryEnforce(0); [weakSelf registerTray];
    }];
    self.safetyNet.tolerance = 120;
}

- (void)woke:(NSNotification *)note { Woke(); After(1, ^{ [self registerTray]; }); }

- (void)displaysChanged:(NSNotification *)note {
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(0.6, ^{ if (mine == generation) [self refreshControls]; });
}

#pragma mark Control Strip

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == (__bridge void *)TrayID) {
        NSTouchBar *bar = object;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (bar.visible) return;
            if (self.presentedBar == bar) self.presentedBar = nil;
            After(0.3, ^{ [self registerTray]; });
        });
        return;
    }
    dispatch_async(dispatch_get_main_queue(), ^{ [self controlStripMayHaveChanged]; });
}

- (void)controlStripMayHaveChanged {
    pid_t pid = [NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.controlstrip"].firstObject.processIdentifier;
    if (pid <= 0 || pid == self.controlStripPID) return;
    self.controlStripPID = pid;
    os_log(HKLog, "ControlStrip pid %d; registering tray item", pid);
    // A freshly launched ControlStrip can ignore registrations for a moment; repeat (idempotent).
    for (NSNumber *delay in @[@0.5, @2, @5]) After(delay.doubleValue, ^{ [self registerTray]; });
    After(0.5, ^{ ApplyTouchBar(); });
    After(5.5, ^{ if (self.presentedBar == self.statsBar) self.presentedBar = nil; [self frontmostChanged:nil]; });
}

- (void)registerTray {
    if (!self.tray || ![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) return;
    [NSTouchBarItem addSystemTrayItem:self.tray];
    if (SetControlStripPresence) SetControlStripPresence(TrayID, YES);
}

#pragma mark Touch Bar

- (NSButton *)barButton:(NSString *)symbol fallback:(NSString *)fallback title:(NSString *)title action:(SEL)action {
    NSImage *image = Symbol(symbol, fallback);
    NSButton *button = image && !title ? [NSButton buttonWithImage:image target:self action:action]
                                       : [NSButton buttonWithTitle:title ?: @"" image:image target:self action:action];
    button.imagePosition = title ? NSImageLeading : NSImageOnly;
    if (!title) [button.widthAnchor constraintEqualToConstant:52].active = YES;
    return button;
}

- (NSButton *)fixedWidth:(CGFloat)width button:(NSButton *)button {
    [button.widthAnchor constraintEqualToConstant:width].active = YES;
    return button;
}

- (NSCustomTouchBarItem *)item:(NSString *)identifier view:(NSView *)view label:(NSString *)label {
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:identifier];
    item.view = view;
    item.customizationLabel = label;
    view.accessibilityLabel = label;
    return item;
}

// Plain Touch Bar slider between two tappable icons (−/+ 10%). NSSliderTouchBarItem's
// accessory slots crop wide symbols such as light.min, so build it by hand.
- (NSCustomTouchBarItem *)slider:(NSSlider **)out width:(CGFloat)width min:(NSString *)minSymbol max:(NSString *)maxSymbol label:(NSString *)label action:(SEL)action {
    NSSlider *slider = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:action];
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    [slider.widthAnchor constraintEqualToConstant:width].active = YES;
    NSButton *(^step)(NSString *, NSInteger) = ^NSButton *(NSString *symbol, NSInteger delta) {
        NSButton *button = [NSButton buttonWithImage:Symbol(symbol, delta < 0 ? @"minus" : @"plus") target:self action:@selector(stepSlider:)];
        button.bordered = NO;
        button.tag = delta;
        button.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:15 weight:NSFontWeightRegular];
        button.contentTintColor = NSColor.secondaryLabelColor;
        [button.widthAnchor constraintEqualToConstant:34].active = YES;
        return button;
    };
    NSStackView *stack = [NSStackView stackViewWithViews:@[step(minSymbol, -10), slider, step(maxSymbol, 10)]];
    stack.spacing = 4;
    *out = slider;
    return [self item:@"slider" view:stack label:label];
}

- (void)stepSlider:(NSButton *)button {
    for (NSView *view in button.superview.subviews) {
        if (![view isKindOfClass:NSSlider.class]) continue;
        NSSlider *slider = (NSSlider *)view;
        double step = (slider.maxValue - slider.minValue) * button.tag / 100;
        slider.doubleValue = fmax(slider.minValue, fmin(slider.maxValue, round(slider.doubleValue + step)));
        [NSApp sendAction:slider.action to:slider.target from:slider];
    }
}

- (void)buildTouchBar {
    void *dfr = dlopen("/System/Library/PrivateFrameworks/DFRFoundation.framework/DFRFoundation", RTLD_LAZY);
    SetControlStripPresence = dfr ? dlsym(dfr, "DFRElementSetControlStripPresenceForIdentifier") : NULL;
    void (*showCloseBox)(BOOL) = dfr ? dlsym(dfr, "DFRSystemModalShowsCloseBoxWhenFrontMost") : NULL;
    if (!SetControlStripPresence || ![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)] ||
        ![NSTouchBar respondsToSelector:@selector(presentSystemModalTouchBar:systemTrayItemIdentifier:)]) {
        os_log_error(HKLog, "Touch Bar system tray API unavailable; menu bar and shortcuts only");
        return;
    }
    if (showCloseBox) showCloseBox(YES);

    NSSlider *slider;
    NSCustomTouchBarItem *touchBarItem = [self slider:&slider width:320 min:@"sun.min" max:@"sun.max.fill" label:@"Touch Bar Brightness" action:@selector(touchBarSliderMoved:)];
    self.touchBarSlider = slider;
    NSCustomTouchBarItem *keyboardItem = [self slider:&slider width:320 min:@"light.min" max:@"light.max" label:@"Keyboard Backlight" action:@selector(keyboardSliderMoved:)];
    self.keyboardSlider = slider;
    self.touchBarValue = [self valueLabel];
    self.keyboardValue = [self valueLabel];
    self.touchBarPage = [self sliderPage:touchBarItem value:self.touchBarValue];
    self.keyboardPage = [self sliderPage:keyboardItem value:self.keyboardValue];
    NSCustomTouchBarItem *monitorItem = [self slider:&slider width:180 min:@"sun.min" max:@"sun.max.fill" label:@"Monitor Brightness" action:@selector(monitorSliderMoved:)];
    self.monitorSlider = slider;
    self.monitorValue = [self valueLabel];
    self.monitorPage = [NSTouchBar new];
    self.monitorPage.templateItems = [NSSet setWithArray:@[
        [self item:@"back" view:[self barButton:@"chevron.left" fallback:nil title:nil action:@selector(showMainPage:)] label:@"Back"],
        monitorItem,
        [self item:@"value" view:self.monitorValue label:@"Level"],
        [self item:@"sleep" view:[self fixedWidth:96 button:[self barButton:@"zzz" fallback:@"powersleep" title:@"Sleep" action:@selector(sleepDisplays:)]] label:@"Sleep Display"],
        [self item:@"modes" view:[self fixedWidth:100 button:[self barButton:@"rectangle.expand.vertical" fallback:@"aspectratio" title:@"Modes" action:@selector(showDisplayPage:)]] label:@"Resolution"],
    ]];
    self.monitorPage.defaultItemIdentifiers = @[@"back", @"slider", @"value", NSTouchBarItemIdentifierFixedSpaceSmall, @"sleep", @"modes"];
    self.displayButton = [self barButton:@"display" fallback:nil title:@"Monitor" action:@selector(showMonitorPage:)];
    self.awakeButton = [self barButton:@"cup.and.saucer.fill" fallback:@"bolt.fill" title:@"Awake" action:@selector(toggleAwake:)];
    self.nightShiftButton = [self barButton:@"moon.fill" fallback:nil title:@"Night" action:@selector(toggleNightShift:)];
    NSButton *fansButton = [self barButton:@"fan.fill" fallback:@"wind" title:@"Fans" action:@selector(showFanPage:)];
    NSButton *touchBarButton = [self barButton:@"sun.max.fill" fallback:nil title:@"Touch Bar" action:@selector(showTouchBarPage:)];
    NSButton *keyboardButton = [self barButton:@"keyboard" fallback:@"light.max" title:@"Keyboard" action:@selector(showKeyboardPage:)];
    // Labelled buttons only fit the ~640 pt modal area with a slightly smaller title.
    NSArray *row = @[touchBarButton, keyboardButton, self.displayButton, self.nightShiftButton, self.awakeButton, fansButton];
    NSArray *widths = @[@102, @100, @92, @82, @86, @78];
    for (NSUInteger i = 0; i < row.count; i++) {
        NSButton *button = row[i];
        button.font = [NSFont systemFontOfSize:13];
        button.imageHugsTitle = YES;
        [self fixedWidth:[widths[i] doubleValue] button:button];
    }
    NSArray *mainItems = @[
        [self item:@"tb" view:touchBarButton label:@"Touch Bar Brightness"],
        [self item:@"kb" view:keyboardButton label:@"Keyboard Backlight"],
        [self item:@"display" view:self.displayButton label:@"Monitor"],
        [self item:@"nightshift" view:self.nightShiftButton label:@"Night Shift"],
        [self item:@"awake" view:self.awakeButton label:@"Keep Awake"],
        [self item:@"fans" view:fansButton label:@"Fans"],
    ];
    self.mainBar = [NSTouchBar new];
    self.mainBar.templateItems = [NSSet setWithArray:mainItems];
    self.mainBar.defaultItemIdentifiers = @[@"tb", @"kb", @"display", @"nightshift", @"awake", @"fans"];

    [self buildFanPages];
    [self buildStatsBar];

    self.headlessButton = [self barButton:@"laptopcomputer" fallback:nil title:@"Built-in Off" action:@selector(toggleHeadless:)];
    NSScrubberFlowLayout *layout = [NSScrubberFlowLayout new];
    layout.itemSpacing = 6;
    self.modeScrubber = [[NSScrubber alloc] initWithFrame:NSMakeRect(0, 0, 320, 30)];
    self.modeScrubber.scrubberLayout = layout;
    self.modeScrubber.mode = NSScrubberModeFree;
    self.modeScrubber.selectionBackgroundStyle = NSScrubberSelectionStyle.roundedBackgroundStyle;
    self.modeScrubber.showsAdditionalContentIndicators = YES;
    self.modeScrubber.dataSource = self;
    self.modeScrubber.delegate = self;
    [self.modeScrubber registerClass:NSScrubberTextItemView.class forItemIdentifier:@"mode"];
    [self.modeScrubber.widthAnchor constraintEqualToConstant:320].active = YES;
    NSArray *displayItems = @[
        [self item:@"back" view:[self barButton:@"chevron.left" fallback:nil title:nil action:@selector(showMonitorPage:)] label:@"Back"],
        [self item:@"headless" view:self.headlessButton label:@"Built-in Display"],
        [self item:@"redetect" view:[self barButton:@"arrow.clockwise" fallback:nil title:nil action:@selector(reapply:)] label:@"Re-detect Displays"],
        [self item:@"modes" view:self.modeScrubber label:@"Resolution"],
    ];
    self.displayBar = [NSTouchBar new];
    self.displayBar.templateItems = [NSSet setWithArray:displayItems];
    self.displayBar.defaultItemIdentifiers = @[@"back", @"headless", @"redetect", NSTouchBarItemIdentifierFixedSpaceSmall, @"modes"];

    self.tray = [[NSCustomTouchBarItem alloc] initWithIdentifier:TrayID];
    self.tray.view = [self barButton:@"slider.horizontal.3" fallback:nil title:nil action:@selector(showControls:)];
    self.tray.view.accessibilityLabel = @"Headless controls";
    [self watchVisibility:@[self.mainBar, self.displayBar, self.touchBarPage, self.keyboardPage, self.monitorPage,
                            self.fanPage, self.fanCustomPage, self.statsBar]];
    // ControlStrip resolves private tray items through the app's current Touch Bar.
    NSApp.touchBar = self.mainBar;
    [self refreshControls];
    [self registerTray];
}

- (NSTextField *)valueLabel {
    NSTextField *label = [NSTextField labelWithString:@"100%"];
    label.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightMedium];
    label.alignment = NSTextAlignmentRight;
    [label.widthAnchor constraintEqualToConstant:52].active = YES;
    return label;
}

// ‹  ☼ ━━━━━━━━━━━━━━━━ ☀  83%
- (NSTouchBar *)sliderPage:(NSCustomTouchBarItem *)slider value:(NSTextField *)value {
    NSTouchBar *bar = [NSTouchBar new];
    bar.templateItems = [NSSet setWithArray:@[
        [self item:@"back" view:[self barButton:@"chevron.left" fallback:nil title:nil action:@selector(showMainPage:)] label:@"Back"],
        slider,
        [self item:@"value" view:value label:@"Level"],
    ]];
    bar.defaultItemIdentifiers = @[@"back", NSTouchBarItemIdentifierFixedSpaceSmall, @"slider", @"value"];
    return bar;
}

// ‹  Auto  Smart  Custom  Max      1650 rpm · 63°
- (void)buildFanPages {
    NSMutableDictionary *buttons = [NSMutableDictionary dictionary];
    NSMutableArray *items = [NSMutableArray arrayWithObject:
        [self item:@"back" view:[self barButton:@"chevron.left" fallback:nil title:nil action:@selector(showMainPage:)] label:@"Back"]];
    NSDictionary *symbols = @{@"auto": @"a.circle", @"smart": @"thermometer.medium", @"custom": @"slider.horizontal.3", @"max": @"wind"};
    for (NSString *mode in @[@"auto", @"smart", @"custom", @"max"]) {
        NSButton *button = [self fixedWidth:96 button:[self barButton:symbols[mode] fallback:@"fan" title:FanModeTitle(mode) action:@selector(fanModeTapped:)]];
        button.identifier = mode;
        buttons[mode] = button;
        [items addObject:[self item:mode view:button label:[FanModeTitle(mode) stringByAppendingString:@" Fans"]]];
    }
    self.fanModeButtons = buttons;
    self.fanReadout = [NSTextField labelWithString:@"…"];
    self.fanReadout.font = [NSFont monospacedDigitSystemFontOfSize:14 weight:NSFontWeightMedium];
    self.fanReadout.textColor = NSColor.secondaryLabelColor;
    [items addObject:[self item:@"readout" view:self.fanReadout label:@"Fan Speed"]];
    self.fanPage = [NSTouchBar new];
    self.fanPage.templateItems = [NSSet setWithArray:items];
    self.fanPage.defaultItemIdentifiers = @[@"back", @"auto", @"smart", @"custom", @"max", NSTouchBarItemIdentifierFixedSpaceSmall, @"readout"];

    NSSlider *slider;
    NSCustomTouchBarItem *sliderItem = [self slider:&slider width:300 min:@"fan" max:@"fan.fill" label:@"Custom Fan Speed" action:@selector(fanSliderMoved:)];
    self.fanSlider = slider;
    self.fanValue = [self valueLabel];
    [self.fanValue.widthAnchor constraintEqualToConstant:90].active = YES;
    self.fanCustomPage = [NSTouchBar new];
    self.fanCustomPage.templateItems = [NSSet setWithArray:@[
        [self item:@"back" view:[self barButton:@"chevron.left" fallback:nil title:nil action:@selector(showFanPage:)] label:@"Back"],
        sliderItem,
        [self item:@"value" view:self.fanValue label:@"RPM"],
    ]];
    self.fanCustomPage.defaultItemIdentifiers = @[@"back", NSTouchBarItemIdentifierFixedSpaceSmall, @"slider", @"value"];
}

// ⚙︎  CPU 12%  Mem 54%  63°  1650 rpm  100%   — shown while the desktop (Finder) is frontmost
- (void)buildStatsBar {
    NSMutableDictionary *buttons = [NSMutableDictionary dictionary];
    NSMutableArray *items = [NSMutableArray array];
    NSArray *specs = @[
        @[@"clock", @"", @"showControls:", @110],
        @[@"cpu", @"cpu", @"openActivityMonitor:", @60],
        @[@"gpu", @"cube.transparent", @"openActivityMonitor:", @58],
        @[@"memory", @"memorychip", @"openActivityMonitor:", @100],
        @[@"temp", @"thermometer.medium", @"showFanPage:", @54],
        @[@"fan", @"fan.fill", @"showFanPage:", @68],
        @[@"network", @"", @"openActivityMonitor:", @92],
        @[@"battery", @"battery.100", @"showControls:", @92],
    ];
    for (NSArray *spec in specs) {
        BOOL clock = [spec[0] isEqualToString:@"clock"];
        NSButton *button = [spec[1] length] == 0 ? [NSButton buttonWithTitle:@"–" target:self action:NSSelectorFromString(spec[2])]
                                 : [self barButton:spec[1] fallback:@"circle" title:@"–" action:NSSelectorFromString(spec[2])];
        button.font = [NSFont monospacedDigitSystemFontOfSize:13 weight:clock ? NSFontWeightMedium : NSFontWeightRegular];
        button.imageHugsTitle = YES;
        button.bordered = clock;  // the clock doubles as the "open controls" button
        [button.widthAnchor constraintEqualToConstant:[spec[3] doubleValue]].active = YES;
        buttons[spec[0]] = button;
        [items addObject:[self item:spec[0] view:button label:spec[0]]];
    }
    self.statButtons = buttons;
    self.statsBar = [NSTouchBar new];
    self.statsBar.templateItems = [NSSet setWithArray:items];
    self.statsBar.defaultItemIdentifiers = @[@"clock", @"cpu", @"gpu", @"memory", @"temp", @"fan", @"network"];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(frontmostChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    After(1, ^{ [self frontmostChanged:nil]; });
}

// The app area of the Touch Bar belongs to the frontmost app; at the desktop (Finder) show
// stats there instead, and get out of the way as soon as any other app comes forward.
- (void)frontmostChanged:(NSNotification *)note {
    BOOL desktop = [NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:@"com.apple.finder"];
    BOOL ourPanelInUse = self.presentedBar && self.presentedBar != self.statsBar && self.presentedAt.timeIntervalSinceNow > -60;
    if (desktop && SettingBool(@"DesktopStats", YES) && !ourPanelInUse) {
        // A bar presented while the previous one is still closing gets dropped; let it settle.
        After(0.5, ^{
            if ([NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier isEqualToString:@"com.apple.finder"]) [self showStats:nil];
        });
    } else if (!desktop && self.presentedBar == self.statsBar) {
        [self hideStats];
    }
}

- (void)showStats:(id)sender {
    if (!self.statsBar) return;
    // Battery takes the network slot when it matters (on battery or charging).
    NSString *symbol;
    BOOL battery = BatteryText(&symbol) != nil;
    self.statsBar.defaultItemIdentifiers = @[@"clock", @"cpu", @"gpu", @"memory", @"temp", @"fan", battery ? @"battery" : @"network"];
    for (NSString *key in @[@"cpu", @"gpu", @"memory", @"network"]) self.statButtons[key].title = @"–";
    double down, up;
    CPUUsage();  // prime the deltas; first real values arrive with the first tick
    NetworkRates(&down, &up);
    [self present:self.statsBar];
    After(0.6, ^{ [self updateStats]; });
    [self.statsTimer invalidate];
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self updateStats]; }];
    self.statsTimer.tolerance = 0.5;
}

- (void)hideStats {
    [self.statsTimer invalidate];
    self.statsTimer = nil;
    [NSTouchBar dismissSystemModalTouchBar:self.statsBar];
    self.presentedBar = nil;
}

- (void)updateStats {
    if (self.presentedBar != self.statsBar) { [self.statsTimer invalidate]; self.statsTimer = nil; return; }
    static NSDateFormatter *time, *date;
    if (!time) {
        time = [NSDateFormatter new];
        [time setLocalizedDateFormatFromTemplate:@"jmm"];   // follows the 12/24-hour setting
        date = [NSDateFormatter new];
        [date setLocalizedDateFormatFromTemplate:@"EEEd"];
    }
    NSDate *now = [NSDate date];
    self.statButtons[@"clock"].title = [NSString stringWithFormat:@"%@ · %@", [time stringFromDate:now], [date stringFromDate:now]];
    double cpu = CPUUsage(), memory = MemoryUsage();
    self.statButtons[@"cpu"].title = isfinite(cpu) ? [NSString stringWithFormat:@"%.0f%%", cpu * 100] : @"–";
    double memoryGB = memory * NSProcessInfo.processInfo.physicalMemory / 1073741824.0;
    self.statButtons[@"memory"].title = isfinite(memory) ? [NSString stringWithFormat:@"%.1fG | %.0f%%", memoryGB, memory * 100] : @"–";
    double gpu = GPUUsage(), down, up;
    self.statButtons[@"gpu"].title = isfinite(gpu) ? [NSString stringWithFormat:@"%.0f%%", gpu * 100] : @"–";
    NetworkRates(&down, &up);
    self.statButtons[@"network"].title = [NSString stringWithFormat:@"↓%@ ↑%@", RateText(down), RateText(up)];
    NSString *batterySymbol = @"battery.100";
    NSString *battery = BatteryText(&batterySymbol);
    self.statButtons[@"battery"].title = battery ?: @"–";
    self.statButtons[@"battery"].image = Symbol(batterySymbol, @"bolt.fill");
    FanRequestAsync(@"status", ^(NSDictionary *status) {
        NSDictionary *fan = [status[@"fans"] firstObject];
        self.statButtons[@"temp"].title = status ? [NSString stringWithFormat:@"%.0f°", [status[@"temp"] doubleValue]] : @"–";
        self.statButtons[@"fan"].title = fan ? [NSString stringWithFormat:@"%.0f", [fan[@"rpm"] doubleValue]] : @"–";
        self.statButtons[@"fan"].contentTintColor = [status[@"mode"] isEqualToString:@"auto"] || !status ? nil : NSColor.systemBlueColor;
    });
}

- (void)openActivityMonitor:(id)sender {
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"]
                                        configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)toggleDesktopStats:(id)sender {
    BOOL on = !SettingBool(@"DesktopStats", YES);
    gSettings[@"DesktopStats"] = @(on);
    SaveSettingsNow();
    if (on) [self frontmostChanged:nil];
    else if (self.presentedBar == self.statsBar) [self hideStats];
}

- (void)showFanPage:(id)sender {
    [self present:self.fanPage];
    self.fanRefreshUntil = [NSDate dateWithTimeIntervalSinceNow:60];
    [self refreshFans];
}

// Live readout while the page is likely visible: every 2 s for a minute after opening.
- (void)refreshFans {
    FanRequestAsync(@"status", ^(NSDictionary *status) {
        [self showFanStatus:status];
        if (status && self.fanRefreshUntil.timeIntervalSinceNow > 0) After(2, ^{ [self refreshFans]; });
    });
}

- (void)showFanStatus:(NSDictionary *)status {
    self.fanStatus = status;
    self.fanReadout.stringValue = FanSummary(status);
    for (NSString *mode in self.fanModeButtons) {
        NSButton *button = self.fanModeButtons[mode];
        button.enabled = status != nil;
        [self setToggle:button on:[status[@"mode"] isEqualToString:mode] color:[mode isEqualToString:@"max"] ? NSColor.systemRedColor : NSColor.systemBlueColor];
    }
    NSDictionary *fan = [status[@"fans"] firstObject];
    if (fan) {
        self.fanSlider.minValue = [fan[@"min"] doubleValue];
        self.fanSlider.maxValue = [fan[@"max"] doubleValue];
    }
}

- (void)fanModeTapped:(NSButton *)button {
    if ([button.identifier isEqualToString:@"custom"]) {
        self.fanSlider.doubleValue = [self.fanStatus[@"custom"] doubleValue];
        self.fanValue.stringValue = [NSString stringWithFormat:@"%.0f rpm", self.fanSlider.doubleValue];
        [self present:self.fanCustomPage];
        [self sendFanRequest:[NSString stringWithFormat:@"set custom %.0f", self.fanSlider.doubleValue] hud:NO];
        return;
    }
    [self sendFanRequest:[@"set " stringByAppendingString:button.identifier] hud:YES];
}

- (void)fanSliderMoved:(NSSlider *)slider {
    double rpm = round(slider.doubleValue / 50) * 50;
    self.fanValue.stringValue = [NSString stringWithFormat:@"%.0f rpm", rpm];
    // Dragging fires continuously; send once it settles.
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(0.3, ^{ if (mine == generation) [self sendFanRequest:[NSString stringWithFormat:@"set custom %.0f", rpm] hud:NO]; });
}

- (void)sendFanRequest:(NSString *)request hud:(BOOL)hud {
    FanRequestAsync(request, ^(NSDictionary *reply) {
        if (!reply || reply[@"error"]) {
            [self hud:@"exclamationmark.triangle.fill" text:reply[@"error"] ? @"Fans: not allowed" : @"Fan daemon not installed"];
            return;
        }
        [self showFanStatus:reply];
        if (hud) [self hud:@"fan.fill" text:[NSString stringWithFormat:@"Fans: %@", FanModeTitle(reply[@"mode"])]];
    });
}

// Closing a system-modal bar (✕, app switch, dismiss) drops our Control Strip item, so
// re-register whenever one of our bars stops being visible.
- (void)watchVisibility:(NSArray<NSTouchBar *> *)bars {
    for (NSTouchBar *bar in bars) [bar addObserver:self forKeyPath:@"visible" options:0 context:(__bridge void *)TrayID];
}

- (void)present:(NSTouchBar *)bar {
    if (!bar) return;
    [self registerTray];
    self.presentedBar = bar;
    self.presentedAt = [NSDate date];
    [NSTouchBar presentSystemModalTouchBar:bar systemTrayItemIdentifier:TrayID];
}

- (void)showControls:(id)sender { [self refreshControls]; [self present:self.mainBar]; }
- (void)showMainPage:(id)sender { [self showControls:sender]; }
- (void)showTouchBarPage:(id)sender { [self refreshControls]; [self present:self.touchBarPage]; }
- (void)showKeyboardPage:(id)sender { [self refreshControls]; [self present:self.keyboardPage]; }
- (void)showMonitorPage:(id)sender { [self refreshControls]; [self present:self.monitorPage]; }
- (void)showDisplayPage:(id)sender {
    [self reloadModes];
    [self present:self.displayBar];
}

- (void)refreshControls {
    self.touchBarSlider.doubleValue = round(SettingLevel(@"TouchBarLevel", 1.0) * 100);
    double keyboard = HasSetting(@"KeyboardLevel") ? SettingLevel(@"KeyboardLevel", 1.0) : KeyboardCurrent();
    self.keyboardSlider.doubleValue = isfinite(keyboard) ? round(keyboard * 100) : 100;
    self.monitorSlider.doubleValue = round(SettingLevel(@"MonitorLevel", 1.0) * 100);
    [self showValues];
    [self setToggle:self.nightShiftButton on:NightShiftOn() color:NSColor.systemOrangeColor];
    [self setToggle:self.awakeButton on:SettingBool(@"KeepAwake", YES) color:NSColor.systemBlueColor];
    [self setToggle:self.headlessButton on:SettingBool(@"Headless", YES) color:NSColor.systemGreenColor];
    [self reloadModes];
}

- (void)setToggle:(NSButton *)button on:(BOOL)on color:(NSColor *)color {
    button.bezelColor = on ? color : nil;
    button.state = on ? NSControlStateValueOn : NSControlStateValueOff;
}

- (void)reloadModes {
    if (!self.modeScrubber) return;
    Displays d;
    ReadDisplays(&d);
    self.modesDisplay = d.external;
    self.modes = d.external ? DisplayModes(d.external) : @[];
    CGDisplayModeRef current = d.external ? CGDisplayCopyDisplayMode(d.external) : NULL;
    NSUInteger index = NSNotFound;
    for (NSUInteger i = 0; current && i < self.modes.count; i++)
        if ([ModeKey((__bridge CGDisplayModeRef)self.modes[i]) isEqualToString:ModeKey(current)]) index = i;
    CGDisplayModeRelease(current);
    self.currentModeIndex = index == NSNotFound ? -1 : (NSInteger)index;
    [self.modeScrubber reloadData];
    if (index != NSNotFound) [self.modeScrubber scrollItemAtIndex:index toAlignment:NSScrubberAlignmentCenter];
}

- (NSString *)scrubberTitle:(NSInteger)index {
    CGDisplayModeRef mode = (__bridge CGDisplayModeRef)self.modes[index];
    return [NSString stringWithFormat:@"%@  %@", SizeString(mode), RateString(CGDisplayModeGetRefreshRate(mode))];
}
- (NSInteger)numberOfItemsForScrubber:(NSScrubber *)scrubber { return (NSInteger)self.modes.count; }
- (NSScrubberItemView *)scrubber:(NSScrubber *)scrubber viewForItemAtIndex:(NSInteger)index {
    NSScrubberTextItemView *view = [scrubber makeItemWithIdentifier:@"mode" owner:nil];
    view.title = index == self.currentModeIndex ? [@"✓ " stringByAppendingString:[self scrubberTitle:index]] : [self scrubberTitle:index];
    return view;
}
- (NSSize)scrubber:(NSScrubber *)scrubber layout:(NSScrubberFlowLayout *)layout sizeForItemAtIndex:(NSInteger)index {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:0]};
    return NSMakeSize(ceil([[self scrubberTitle:index] sizeWithAttributes:attrs].width) + 40, 30);
}
- (void)scrubber:(NSScrubber *)scrubber didSelectItemAtIndex:(NSInteger)index {
    if (index >= 0 && index < (NSInteger)self.modes.count) [self applyMode:self.modes[index]];
}

#pragma mark Actions

- (void)applyMode:(id)mode {
    CGError err = ApplyDisplayMode(self.modesDisplay, (__bridge CGDisplayModeRef)mode);
    if (err) [self hud:@"exclamationmark.triangle.fill" text:[NSString stringWithFormat:@"Mode failed (%d)", err]];
    else [self hud:@"display" text:[self scrubberTitle:(NSInteger)[self.modes indexOfObject:mode]]];
}

- (void)setTouchBarLevel:(double)level {
    level = fmax(0, fmin(1, level));
    SetSetting(@"TouchBarLevel", @(level));
    SetTouchBar(level);
    self.touchBarSlider.doubleValue = round(level * 100);
    [self showValues];
}

- (void)showValues {
    self.touchBarValue.stringValue = [NSString stringWithFormat:@"%.0f%%", self.touchBarSlider.doubleValue];
    self.keyboardValue.stringValue = [NSString stringWithFormat:@"%.0f%%", self.keyboardSlider.doubleValue];
    self.monitorValue.stringValue = [NSString stringWithFormat:@"%.0f%%", self.monitorSlider.doubleValue];
}

- (void)setKeyboardLevel:(double)level {
    level = fmax(0, fmin(1, level));
    SetSetting(@"KeyboardLevel", @(level));
    SetKeyboard(level);
    self.keyboardSlider.doubleValue = round(level * 100);
    [self showValues];
}

- (void)setMonitorLevel:(double)level {
    level = fmax(0, fmin(1, level));
    SetSetting(@"MonitorLevel", @(level));
    ApplyMonitor();
    SetBuiltinBrightness(level);
    self.monitorSlider.doubleValue = round(level * 100);
    [self showValues];
}

- (void)observeBrightnessKeys {
    id client = BuiltinBrightnessClient();
    if (![client respondsToSelector:@selector(registerNotificationBlock:)] || ![client respondsToSelector:@selector(registerNotificationForKeys:)]) return;
    __weak HKApp *weakSelf = self;
    ((void (*)(id, SEL, id))objc_msgSend)(client, @selector(registerNotificationBlock:), ^(NSString *key, id value) {
        NSNumber *n = [value isKindOfClass:NSDictionary.class] ? value[@"Brightness"] : nil;
        if (![n isKindOfClass:NSNumber.class]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf builtinBrightnessChanged:n.doubleValue]; });
    });
    ((BOOL (*)(id, SEL, id))objc_msgSend)(client, @selector(registerNotificationForKeys:), @[@"DisplayBrightness"]);
    SetBuiltinBrightness(SettingLevel(@"MonitorLevel", 1.0));
}

- (void)builtinBrightnessChanged:(double)level {
    if (!SettingBool(@"BrightnessKeysControlMonitor", YES) || fabs(level - SettingLevel(@"MonitorLevel", 1.0)) < 0.01) return;
    [self setMonitorLevel:level];
    [self hud:@"sun.max.fill" text:[NSString stringWithFormat:@"Monitor  %.0f%%", level * 100]];
}

- (void)toggleBrightnessKeys:(id)sender {
    gSettings[@"BrightnessKeysControlMonitor"] = @(!SettingBool(@"BrightnessKeysControlMonitor", YES));
    SaveSettingsNow();
    SetBuiltinBrightness(SettingLevel(@"MonitorLevel", 1.0));
}

- (void)monitorSliderMoved:(id)sender { [self setMonitorLevel:round([self sliderValue:sender]) / 100]; }
- (void)touchBarSliderMoved:(id)sender { [self setTouchBarLevel:round([self sliderValue:sender]) / 100]; }
- (void)keyboardSliderMoved:(id)sender { [self setKeyboardLevel:round([self sliderValue:sender]) / 100]; }
- (double)sliderValue:(id)sender {
    return [(NSSlider *)sender doubleValue];
}

- (void)toggleNightShift:(id)sender {
    BOOL on = !NightShiftOn();
    SetNightShift(on);
    [self refreshControls];
    [self hud:on ? @"moon.fill" : @"moon" text:on ? @"Night Shift On" : @"Night Shift Off"];
}

- (void)toggleAwake:(id)sender {
    BOOL on = !SettingBool(@"KeepAwake", YES);
    gSettings[@"KeepAwake"] = @(on);
    SaveSettingsNow();
    UpdateKeepAwake();
    [self refreshControls];
    [self hud:on ? @"cup.and.saucer.fill" : @"zzz" text:on ? @"Keep Awake On" : @"Normal Sleep"];
}

- (void)toggleHeadless:(id)sender {
    BOOL on = !SettingBool(@"Headless", YES);
    SetHeadless(on);
    [self refreshControls];
    [self hud:on ? @"display" : @"laptopcomputer" text:on ? @"Built-in Display Off" : @"Built-in Display Allowed"];
}

- (void)reapply:(id)sender {
    RetryEnforce(0);
    ApplyBrightnessSoon(0);
    ApplyMonitorSoon(0);
    [self registerTray];
    [self refreshControls];
    [self hud:@"arrow.clockwise" text:@"Displays Re-applied"];
}

- (void)lock:(id)sender { [self dismissBar]; LockScreen(); }
- (void)sleepDisplays:(id)sender { [self dismissBar]; SleepDisplays(); }

- (void)restartTouchBar:(id)sender {
    [[NSRunningApplication runningApplicationsWithBundleIdentifier:@"com.apple.controlstrip"].firstObject forceTerminate];
    // runningApplications KVO re-registers once it relaunches.
}

- (void)dismissBar {
    if ([NSTouchBar respondsToSelector:@selector(dismissSystemModalTouchBar:)]) {
        [NSTouchBar dismissSystemModalTouchBar:self.mainBar];
        for (NSTouchBar *bar in @[self.displayBar, self.touchBarPage, self.keyboardPage, self.monitorPage, self.fanPage, self.fanCustomPage]) [NSTouchBar dismissSystemModalTouchBar:bar];
        self.presentedBar = nil;
    }
}

- (void)quit:(id)sender { [NSApp terminate:nil]; }

- (void)applicationWillTerminate:(NSNotification *)note {
    if (SetControlStripPresence) SetControlStripPresence(TrayID, NO);
    if (self.tray && [NSTouchBarItem respondsToSelector:@selector(removeSystemTrayItem:)]) [NSTouchBarItem removeSystemTrayItem:self.tray];
}

#pragma mark Shortcuts

- (void)registerHotKeys {
    EventTypeSpec spec = {kEventClassKeyboard, kEventHotKeyPressed};
    InstallApplicationEventHandler(&HotKeyPressed, 1, &spec, (__bridge void *)self, NULL);
    struct { HKHotKey key; UInt32 code; } keys[] = {
        {HKTouchBarUp, kVK_UpArrow}, {HKTouchBarDown, kVK_DownArrow},
        {HKKeyboardUp, kVK_RightArrow}, {HKKeyboardDown, kVK_LeftArrow},
        {HKShowControls, kVK_ANSI_T}, {HKReapply, kVK_ANSI_H}, {HKLock, kVK_ANSI_L},
        {HKSleepDisplays, kVK_ANSI_S}, {HKToggleAwake, kVK_ANSI_A}, {HKToggleNightShift, kVK_ANSI_N},
        {HKMonitorUp, kVK_ANSI_Equal}, {HKMonitorDown, kVK_ANSI_Minus}, {HKCycleFans, kVK_ANSI_F},
    };
    for (size_t i = 0; i < sizeof keys / sizeof *keys; i++) {
        EventHotKeyRef ref;
        RegisterEventHotKey(keys[i].code, cmdKey | optionKey | controlKey, (EventHotKeyID){'HDLS', keys[i].key}, GetApplicationEventTarget(), 0, &ref);
    }
}

- (void)hotKey:(HKHotKey)key {
    switch (key) {
        case HKTouchBarUp: case HKTouchBarDown: {
            double level = round(SettingLevel(@"TouchBarLevel", 1.0) * 10 + (key == HKTouchBarUp ? 1 : -1)) / 10;
            [self setTouchBarLevel:level];
            [self hud:@"sun.max.fill" text:[NSString stringWithFormat:@"Touch Bar  %.0f%%", SettingLevel(@"TouchBarLevel", 1.0) * 100]];
            break;
        }
        case HKKeyboardUp: case HKKeyboardDown: {
            double current = HasSetting(@"KeyboardLevel") ? SettingLevel(@"KeyboardLevel", 1.0) : KeyboardCurrent();
            if (!isfinite(current)) current = 1;
            [self setKeyboardLevel:round(current * 10 + (key == HKKeyboardUp ? 1 : -1)) / 10];
            [self hud:@"light.max" text:[NSString stringWithFormat:@"Keyboard  %.0f%%", SettingLevel(@"KeyboardLevel", 1.0) * 100]];
            break;
        }
        case HKShowControls: [self showControls:nil]; break;
        case HKReapply: [self reapply:nil]; break;
        case HKLock: [self lock:nil]; break;
        case HKSleepDisplays: [self sleepDisplays:nil]; break;
        case HKToggleAwake: [self toggleAwake:nil]; break;
        case HKToggleNightShift: [self toggleNightShift:nil]; break;
        case HKCycleFans: {
            FanRequestAsync(@"status", ^(NSDictionary *status) {
                NSString *mode = status[@"mode"];
                NSString *next = [mode isEqualToString:@"auto"] ? @"smart" : [mode isEqualToString:@"smart"] ? @"max" : @"auto";
                [self sendFanRequest:[@"set " stringByAppendingString:next] hud:YES];
            });
            break;
        }
        case HKMonitorUp: case HKMonitorDown:
            [self setMonitorLevel:round(SettingLevel(@"MonitorLevel", 1.0) * 10 + (key == HKMonitorUp ? 1 : -1)) / 10];
            [self hud:@"display" text:[NSString stringWithFormat:@"Monitor  %.0f%%", SettingLevel(@"MonitorLevel", 1.0) * 100]];
            break;
    }
}

#pragma mark HUD

- (void)hud:(NSString *)symbol text:(NSString *)text {
    if (!self.hud) {
        self.hud = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 240, 52) styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel backing:NSBackingStoreBuffered defer:YES];
        self.hud.level = NSStatusWindowLevel;
        self.hud.opaque = NO;
        self.hud.backgroundColor = NSColor.clearColor;
        self.hud.ignoresMouseEvents = YES;
        self.hud.hasShadow = YES;
        self.hud.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary | NSWindowCollectionBehaviorFullScreenAuxiliary;
        NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:self.hud.contentView.bounds];
        background.material = NSVisualEffectMaterialHUDWindow;
        background.state = NSVisualEffectStateActive;
        background.wantsLayer = YES;
        background.layer.cornerRadius = 14;
        background.layer.masksToBounds = YES;
        self.hudImage = [NSImageView imageViewWithImage:[NSImage new]];
        self.hudImage.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:20 weight:NSFontWeightMedium];
        self.hudImage.contentTintColor = NSColor.labelColor;
        self.hudText = [NSTextField labelWithString:@""];
        self.hudText.font = [NSFont systemFontOfSize:15 weight:NSFontWeightMedium];
        NSStackView *stack = [NSStackView stackViewWithViews:@[self.hudImage, self.hudText]];
        stack.spacing = 10;
        stack.translatesAutoresizingMaskIntoConstraints = NO;
        [background addSubview:stack];
        [NSLayoutConstraint activateConstraints:@[
            [stack.centerXAnchor constraintEqualToAnchor:background.centerXAnchor],
            [stack.centerYAnchor constraintEqualToAnchor:background.centerYAnchor],
        ]];
        self.hud.contentView = background;
    }
    self.hudImage.image = Symbol(symbol, @"checkmark");
    self.hudText.stringValue = text;
    NSRect screen = NSScreen.mainScreen.visibleFrame;
    [self.hud setFrameOrigin:NSMakePoint(NSMidX(screen) - 120, NSMinY(screen) + 110)];
    self.hud.alphaValue = 1;
    [self.hud orderFrontRegardless];
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(1.3, ^{
        if (mine != generation) return;
        [NSAnimationContext runAnimationGroup:^(NSAnimationContext *context) {
            context.duration = 0.25;
            self.hud.animator.alphaValue = 0;
        } completionHandler:^{ if (mine == generation) [self.hud orderOut:nil]; }];
    });
}

#pragma mark Menu bar

- (void)buildStatusItem {
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    self.statusItem.button.image = Symbol(@"display", nil);
    self.statusItem.button.toolTip = @"Headless";
    self.statusItem.menu = [NSMenu new];
    self.statusItem.menu.delegate = self;
}

- (NSMenuItem *)menuItem:(NSString *)title action:(SEL)action key:(NSString *)key symbol:(NSString *)symbol {
    NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title action:action keyEquivalent:key ?: @""];
    item.target = self;
    if (key) item.keyEquivalentModifierMask = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;
    if (symbol) item.image = Symbol(symbol, nil);
    return item;
}

- (NSMenuItem *)sliderRow:(NSString *)symbol value:(double)value action:(SEL)action label:(NSString *)label {
    NSView *row = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 270, 30)];
    NSImageView *icon = [NSImageView imageViewWithImage:Symbol(symbol, nil)];
    icon.frame = NSMakeRect(14, 7, 18, 16);
    icon.contentTintColor = NSColor.secondaryLabelColor;
    NSSlider *slider = [NSSlider sliderWithValue:value minValue:0 maxValue:100 target:self action:action];
    slider.frame = NSMakeRect(40, 5, 180, 20);
    slider.continuous = YES;
    slider.accessibilityLabel = label;
    NSTextField *percent = [NSTextField labelWithString:[NSString stringWithFormat:@"%.0f%%", value]];
    percent.frame = NSMakeRect(222, 7, 40, 16);
    percent.alignment = NSTextAlignmentRight;
    percent.font = [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightRegular];
    percent.textColor = NSColor.secondaryLabelColor;
    percent.identifier = @"percent";
    [row addSubview:icon]; [row addSubview:slider]; [row addSubview:percent];
    NSMenuItem *item = [NSMenuItem new];
    item.view = row;
    return item;
}

- (void)menuSliderMoved:(NSSlider *)slider {
    for (NSView *view in slider.superview.subviews)
        if ([view.identifier isEqualToString:@"percent"]) ((NSTextField *)view).stringValue = [NSString stringWithFormat:@"%.0f%%", round(slider.doubleValue)];
}
- (void)menuTouchBarMoved:(NSSlider *)slider { [self menuSliderMoved:slider]; [self touchBarSliderMoved:slider]; }
- (void)menuFanMode:(NSMenuItem *)item {
    NSString *mode = item.representedObject;
    if ([mode isEqualToString:@"custom"]) {
        NSDictionary *status = FanRequest(@"status");
        [self sendFanRequest:[NSString stringWithFormat:@"set custom %.0f", [status[@"custom"] doubleValue]] hud:YES];
    } else {
        [self sendFanRequest:[@"set " stringByAppendingString:mode] hud:YES];
    }
}
- (void)menuFanMoved:(NSSlider *)slider {
    double rpm = round(slider.doubleValue / 50) * 50;
    for (NSView *view in slider.superview.subviews)
        if ([view.identifier isEqualToString:@"percent"]) ((NSTextField *)view).stringValue = [NSString stringWithFormat:@"%.0f rpm", rpm];
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(0.3, ^{ if (mine == generation) [self sendFanRequest:[NSString stringWithFormat:@"set custom %.0f", rpm] hud:NO]; });
}
- (void)menuMonitorMoved:(NSSlider *)slider { [self menuSliderMoved:slider]; [self monitorSliderMoved:slider]; }
- (void)menuKeyboardMoved:(NSSlider *)slider { [self menuSliderMoved:slider]; [self keyboardSliderMoved:slider]; }

- (void)pickMode:(NSMenuItem *)item { [self applyMode:item.representedObject]; }

// Rebuilt on every open, so it always reflects the live state.
- (void)menuNeedsUpdate:(NSMenu *)menu {
    [menu removeAllItems];
    Displays d;
    ReadDisplays(&d);
    CGDisplayModeRef current = d.external ? CGDisplayCopyDisplayMode(d.external) : NULL;

    NSString *header = current ? [NSString stringWithFormat:@"%@ — %@ @ %@", DisplayName(d.external), SizeString(current), RateString(CGDisplayModeGetRefreshRate(current))] : @"No external display";
    NSMenuItem *headerItem = [menu addItemWithTitle:header action:nil keyEquivalent:@""];
    headerItem.image = Symbol(@"display", nil);
    headerItem.enabled = NO;

    if (current) {
        self.modesDisplay = d.external;
        NSArray *modes = DisplayModes(d.external);
        NSMenu *sizes = [NSMenu new], *rates = [NSMenu new];
        NSMutableSet *seen = [NSMutableSet set];
        for (id m in modes) {
            CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
            BOOL sameSize = [SizeKey(mode) isEqualToString:SizeKey(current)];
            if (sameSize) {
                NSMenuItem *rate = [self menuItem:RateString(CGDisplayModeGetRefreshRate(mode)) action:@selector(pickMode:) key:nil symbol:nil];
                rate.representedObject = m;
                rate.state = [ModeKey(mode) isEqualToString:ModeKey(current)];
                [rates addItem:rate];
            }
            if ([seen containsObject:SizeKey(mode)]) continue;
            [seen addObject:SizeKey(mode)];
            // Prefer keeping the current refresh rate when switching resolution.
            id pick = m;
            for (id other in modes)
                if ([SizeKey((__bridge CGDisplayModeRef)other) isEqualToString:SizeKey(mode)] &&
                    fabs(CGDisplayModeGetRefreshRate((__bridge CGDisplayModeRef)other) - CGDisplayModeGetRefreshRate(current)) < 0.5) pick = other;
            NSMenuItem *size = [self menuItem:SizeString(mode) action:@selector(pickMode:) key:nil symbol:nil];
            size.representedObject = pick;
            size.state = sameSize;
            [sizes addItem:size];
        }
        [menu addItemWithTitle:@"Resolution" action:nil keyEquivalent:@""].submenu = sizes;
        [menu addItemWithTitle:@"Refresh Rate" action:nil keyEquivalent:@""].submenu = rates;
    }
    CGDisplayModeRelease(current);
    NSMenuItem *headless = [self menuItem:@"Keep Built-in Display Off" action:@selector(toggleHeadless:) key:nil symbol:nil];
    headless.state = SettingBool(@"Headless", YES);
    [menu addItem:headless];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Monitor  ⌃⌥⌘ − ="]];
    [menu addItem:[self sliderRow:@"display" value:round(SettingLevel(@"MonitorLevel", 1.0) * 100) action:@selector(menuMonitorMoved:) label:@"Monitor brightness"]];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Touch Bar  ⌃⌥⌘↑↓"]];
    [menu addItem:[self sliderRow:@"sun.max.fill" value:round(SettingLevel(@"TouchBarLevel", 1.0) * 100) action:@selector(menuTouchBarMoved:) label:@"Touch Bar brightness"]];
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:@"Keyboard Backlight  ⌃⌥⌘←→"]];
    double keyboard = HasSetting(@"KeyboardLevel") ? SettingLevel(@"KeyboardLevel", 1.0) : KeyboardCurrent();
    [menu addItem:[self sliderRow:@"keyboard" value:isfinite(keyboard) ? round(keyboard * 100) : 100 action:@selector(menuKeyboardMoved:) label:@"Keyboard backlight"]];

    [menu addItem:NSMenuItem.separatorItem];
    NSDictionary *fans = FanRequest(@"status");
    [menu addItem:[NSMenuItem sectionHeaderWithTitle:[NSString stringWithFormat:@"Fans  ⌃⌥⌘F  —  %@", FanSummary(fans)]]];
    if (fans) {
        for (NSString *mode in @[@"auto", @"smart", @"custom", @"max"]) {
            NSMenuItem *item = [self menuItem:FanModeTitle(mode) action:@selector(menuFanMode:) key:nil symbol:nil];
            item.representedObject = mode;
            item.state = [fans[@"mode"] isEqualToString:mode];
            [menu addItem:item];
        }
        NSDictionary *fan = [fans[@"fans"] firstObject];
        NSMenuItem *row = [self sliderRow:@"fan" value:0 action:@selector(menuFanMoved:) label:@"Custom fan speed"];
        for (NSView *view in row.view.subviews) {
            if ([view isKindOfClass:NSSlider.class]) {
                NSSlider *slider = (NSSlider *)view;
                slider.minValue = [fan[@"min"] doubleValue];
                slider.maxValue = [fan[@"max"] doubleValue];
                slider.doubleValue = [fans[@"custom"] doubleValue];
                slider.frame = NSMakeRect(40, 5, 160, 20);
            } else if ([view.identifier isEqualToString:@"percent"]) {
                view.frame = NSMakeRect(200, 7, 64, 16);
                ((NSTextField *)view).stringValue = [NSString stringWithFormat:@"%.0f rpm", [fans[@"custom"] doubleValue]];
            }
        }
        [menu addItem:row];
    }

    [menu addItem:NSMenuItem.separatorItem];
    NSMenuItem *awake = [self menuItem:@"Keep Mac Awake" action:@selector(toggleAwake:) key:@"a" symbol:@"cup.and.saucer"];
    awake.state = SettingBool(@"KeepAwake", YES);
    [menu addItem:awake];
    NSMenuItem *night = [self menuItem:@"Night Shift" action:@selector(toggleNightShift:) key:@"n" symbol:@"moon"];
    night.state = NightShiftOn();
    [menu addItem:night];
    NSMenuItem *stats = [self menuItem:@"System Stats on Desktop Touch Bar" action:@selector(toggleDesktopStats:) key:nil symbol:@"gauge.with.dots.needle.50percent"];
    stats.state = SettingBool(@"DesktopStats", YES);
    [menu addItem:stats];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Lock Screen" action:@selector(lock:) key:@"l" symbol:@"lock"]];
    [menu addItem:[self menuItem:@"Sleep Display" action:@selector(sleepDisplays:) key:@"s" symbol:@"zzz"]];
    [menu addItem:[self menuItem:@"Show Touch Bar Controls" action:@selector(showControls:) key:@"t" symbol:@"slider.horizontal.3"]];
    [menu addItem:[self menuItem:@"Re-apply Display Settings" action:@selector(reapply:) key:@"h" symbol:@"arrow.clockwise"]];
    NSMenuItem *brightnessKeys = [self menuItem:@"Brightness Keys Control Monitor" action:@selector(toggleBrightnessKeys:) key:nil symbol:@"sun.max"];
    brightnessKeys.state = SettingBool(@"BrightnessKeysControlMonitor", YES);
    [menu addItem:brightnessKeys];
    [menu addItem:[self menuItem:@"Restart Touch Bar" action:@selector(restartTouchBar:) key:nil symbol:@"arrow.triangle.2.circlepath"]];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Quit Headless (until next login)" action:@selector(quit:) key:nil symbol:nil]];
}

@end

#pragma mark - CLI

static int Usage(void) {
    fprintf(stderr,
        "usage: Headless <command>\n"
        "  status                      show displays, brightness and toggles\n"
        "  apply                       re-apply everything now\n"
        "  touchbar <0-100>            Touch Bar brightness\n"
        "  keyboard <0-100>            keyboard backlight\n"
        "  monitor <0-100>             external monitor brightness (software dimming)\n"
        "  headless on|off             keep the built-in display disabled\n"
        "  awake on|off                prevent system sleep on AC power\n"
        "  nightshift on|off|toggle\n"
        "  fan [auto|smart|max|<rpm>]  fan mode (needs the headless-fand daemon)\n"
        "  fan curve <low°C> <high°C>  smart-mode curve (default 60 90)\n"
        "  modes                       list modes for the external display\n"
        "  mode <index>                switch to a mode from `modes`\n"
        "  lock | sleep-display | show [touchbar|keyboard|monitor|display|fans|stats]\n");
    return 2;
}

static BOOL ParsePercent(const char *s, double *out) {
    char *end = NULL;
    double v = strtod(s, &end) / 100;
    if (!*s || *end || !isfinite(v) || v < 0 || v > 1) return NO;
    *out = v;
    return YES;
}

static int ParseSwitch(const char *s) { return !strcmp(s, "on") ? 1 : !strcmp(s, "off") ? 0 : -1; }

static int RunCLI(int argc, const char **argv) {
    NSString *cmd = @(argv[1]);
    const char *arg = argc > 2 ? argv[2] : NULL;
    Displays d;
    double level;
    int on;
    if ([cmd isEqualToString:@"status"]) {
        ReadDisplays(&d);
        for (uint32_t i = 0; i < d.count; i++) {
            CGDirectDisplayID id = d.ids[i];
            CGDisplayModeRef mode = CGDisplayIsActive(id) ? CGDisplayCopyDisplayMode(id) : NULL;
            printf("display %u  %-9s %s%s%s\n", id, CGDisplayIsBuiltin(id) ? "built-in" : "external",
                   CGDisplayIsActive(id) ? "active" : CGDisplayIsOnline(id) ? "online" : "off",
                   CGDisplayIsMain(id) ? " main" : "",
                   mode ? [NSString stringWithFormat:@"  %@ @ %@", SizeString(mode), RateString(CGDisplayModeGetRefreshRate(mode))].UTF8String : "");
            CGDisplayModeRelease(mode);
        }
        printf("headless      %s\n", SettingBool(@"Headless", YES) ? "on" : "off");
        printf("touch bar     %.0f%% saved, %.0f%% actual\n", SettingLevel(@"TouchBarLevel", 1.0) * 100, TouchBarCurrent() * 100);
        printf("monitor       %.0f%%\n", SettingLevel(@"MonitorLevel", 1.0) * 100);
        printf("keyboard      %s saved, %.0f%% actual\n", HasSetting(@"KeyboardLevel") ? [NSString stringWithFormat:@"%.0f%%", SettingLevel(@"KeyboardLevel", 1.0) * 100].UTF8String : "not", KeyboardCurrent() * 100);
        printf("keep awake    %s\n", SettingBool(@"KeepAwake", YES) ? "on" : "off");
        printf("night shift   %s\n", NightShiftOn() ? "on" : "off");
        NSDictionary *fans = FanRequest(@"status");
        printf("fans          %s%s\n", fans ? [FanModeTitle(fans[@"mode"]) stringByAppendingString:@", "].UTF8String : "", FanSummary(fans).UTF8String);
        return 0;
    }
    if ([cmd isEqualToString:@"apply"]) { EnforceHeadless(); ApplyTouchBar(); ApplyKeyboard(); }
    else if ([cmd isEqualToString:@"touchbar"] && arg && ParsePercent(arg, &level)) { gSettings[@"TouchBarLevel"] = @(level); SaveSettingsNow(); if (!SetTouchBar(level)) return 1; }
    else if ([cmd isEqualToString:@"monitor"] && arg && ParsePercent(arg, &level)) { gSettings[@"MonitorLevel"] = @(level); SaveSettingsNow(); }
    else if ([cmd isEqualToString:@"keyboard"] && arg && ParsePercent(arg, &level)) { gSettings[@"KeyboardLevel"] = @(level); SaveSettingsNow(); if (!SetKeyboard(level)) return 1; }
    else if ([cmd isEqualToString:@"headless"] && arg && (on = ParseSwitch(arg)) >= 0) SetHeadless(on);
    else if ([cmd isEqualToString:@"awake"] && arg && (on = ParseSwitch(arg)) >= 0) { gSettings[@"KeepAwake"] = @(on); SaveSettingsNow(); }
    else if ([cmd isEqualToString:@"nightshift"] && arg) {
        on = !strcmp(arg, "toggle") ? !NightShiftOn() : ParseSwitch(arg);
        if (on < 0) return Usage();
        SetNightShift(on);
    } else if ([cmd isEqualToString:@"modes"] || [cmd isEqualToString:@"mode"]) {
        if (!ReadDisplays(&d) || !d.external) { fprintf(stderr, "No active external display\n"); return 1; }
        NSArray *modes = DisplayModes(d.external);
        if ([cmd isEqualToString:@"mode"]) {
            char *end = NULL;
            long index = arg ? strtol(arg, &end, 10) : -1;
            if (!arg || *end || index < 0 || index >= (long)modes.count) return Usage();
            CGError err = ApplyDisplayMode(d.external, (__bridge CGDisplayModeRef)modes[index]);
            if (err) { fprintf(stderr, "Display configuration failed (%d)\n", err); return 1; }
            return 0;
        }
        CGDisplayModeRef current = CGDisplayCopyDisplayMode(d.external);
        for (NSUInteger i = 0; i < modes.count; i++) {
            CGDisplayModeRef m = (__bridge CGDisplayModeRef)modes[i];
            printf("%3lu %s %-22s %s\n", (unsigned long)i, [ModeKey(m) isEqualToString:ModeKey(current)] ? "*" : " ", SizeString(m).UTF8String, RateString(CGDisplayModeGetRefreshRate(m)).UTF8String);
        }
        CGDisplayModeRelease(current);
        return 0;
    }
    else if ([cmd isEqualToString:@"fan"]) {
        NSString *request = @"status";
        if (arg && !strcmp(arg, "curve") && argc > 4) request = [NSString stringWithFormat:@"curve %s %s", argv[3], argv[4]];
        else if (arg && atoi(arg) > 0) request = [NSString stringWithFormat:@"set custom %d", atoi(arg)];
        else if (arg) request = [NSString stringWithFormat:@"set %s", arg];
        NSDictionary *reply = FanRequest(request);
        if (!reply) { fprintf(stderr, "Fan daemon not running (install with `make install`)\n"); return 1; }
        if (reply[@"error"]) { fprintf(stderr, "%s\n", [reply[@"error"] UTF8String]); return 1; }
        printf("%s: %s (smart curve %.0f–%.0f°C)\n", FanModeTitle(reply[@"mode"]).UTF8String, FanSummary(reply).UTF8String, [reply[@"low"] doubleValue], [reply[@"high"] doubleValue]);
        return 0;
    }
    else if ([cmd isEqualToString:@"lock"]) LockScreen();
    else if ([cmd isEqualToString:@"sleep-display"]) SleepDisplays();
    else if ([cmd isEqualToString:@"show"]) { notify_post(arg ? [NSString stringWithFormat:@HKShowNotify ".%s", arg].UTF8String : HKShowNotify); return 0; }
    else return Usage();
    notify_post(HKChangedNotify);  // the running agent reloads settings and re-applies
    return 0;
}

#pragma mark - main

int main(int argc, const char **argv) {
    @autoreleasepool {
        HKLog = os_log_create("dev.jesvi.headless", "agent");
        LoadSkyLight();
        LoadSettings();
        // Finder may pass -psn_… arguments; anything else is a CLI command.
        if (argc > 1 && argv[1][0] != '-') return RunCLI(argc, argv);
        if (getuid() == 0 || !SessionLoggedIn() || (argc > 1 && !strcmp(argv[1], "--prelogin"))) return RunPreLogin();

        NSString *bundleID = NSBundle.mainBundle.bundleIdentifier;
        BOOL alreadyRunning = NO;
        for (NSRunningApplication *other in [NSRunningApplication runningApplicationsWithBundleIdentifier:bundleID ?: @""])
            if (other.processIdentifier != getpid()) alreadyRunning = YES;
        if (alreadyRunning) {
            notify_post(HKShowNotify);  // already running: just bring up the controls
            return 0;
        }
        NSApplication *app = NSApplication.sharedApplication;
        app.activationPolicy = NSApplicationActivationPolicyAccessory;
        HKApp *delegate = [HKApp new];
        app.delegate = delegate;
        [app run];
    }
    return 0;
}
