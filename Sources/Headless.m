// Headless — one agent for a MacBook that runs with no built-in panel.
//
//   • keeps the built-in display disabled whenever an external one is active
//   • manual Touch Bar + keyboard backlight brightness (no ambient light sensor)
//   • fan modes (auto / smart curve / custom RPM / max) via the root headless-fand daemon
//   • live CPU / memory / temperature / fan / battery stats on the Touch Bar at the desktop
//   • reversed scroll direction for wheel mice, leaving trackpad natural scrolling alone
//   • a status panel on the login and lock screens (the Touch Bar belongs to loginwindow there)
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
#import <sys/stat.h>
#import <sys/sysctl.h>
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
    NSString *folder = path.stringByDeletingLastPathComponent;
    [NSFileManager.defaultManager createDirectoryAtPath:folder withIntermediateDirectories:YES attributes:nil error:NULL];
    // The login-window copy runs as root: keep the file owned by whoever owns the folder (the
    // user), or their own session could no longer save settings.
    struct stat owner;
    BOOL keepOwner = getuid() == 0 && stat(folder.fileSystemRepresentation, &owner) == 0;
    BOOL ok = [gSettings writeToFile:path atomically:YES];
    if (ok && keepOwner) chown(path.fileSystemRepresentation, owner.st_uid, owner.st_gid);
    return ok;
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

// Read-only SMC access: temperatures and fan speed need no privileges (only writes do,
// which is why fan *control* lives in the root daemon).
typedef struct {
    uint32_t key;
    struct { char major, minor, build, reserved; uint16_t release; } vers;
    struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } pLimitData;
    struct { uint32_t dataSize, dataType; uint8_t dataAttributes; } keyInfo;
    uint8_t result, status, data8;
    uint32_t data32;
    uint8_t bytes[32];
} SMCParam;

_Static_assert(sizeof(SMCParam) == 80, "AppleSMC expects an 80-byte parameter block");

static io_connect_t SMCConnection(void) {
    static io_connect_t connection;
    if (!connection) {
        io_service_t smc = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (smc) { IOServiceOpen(smc, mach_task_self(), 0, &connection); IOObjectRelease(smc); }
    }
    return connection;
}

static BOOL SMCCall(SMCParam *in, SMCParam *out) {
    size_t size = sizeof *out;
    memset(out, 0, sizeof *out);
    return SMCConnection() && IOConnectCallStructMethod(SMCConnection(), 2, in, sizeof *in, out, &size) == KERN_SUCCESS && out->result == 0;
}

static uint32_t FourCC(const char *s) { return (uint32_t)s[0] << 24 | (uint32_t)s[1] << 16 | (uint32_t)s[2] << 8 | (uint32_t)s[3]; }

// Key info looked up once per key, so each later read is a single kernel call.
typedef struct { uint32_t key, size, type; } SMCKey;

static BOOL SMCLookup(uint32_t key, SMCKey *out) {
    SMCParam in = {.key = key, .data8 = 9}, info;  // 9: key info
    if (!SMCCall(&in, &info)) return NO;
    *out = (SMCKey){key, info.keyInfo.dataSize, info.keyInfo.dataType};
    return YES;
}

static double SMCValue(const SMCKey *k) {
    SMCParam in = {.key = k->key, .data8 = 5}, out;  // 5: read bytes
    in.keyInfo.dataSize = k->size;
    if (!SMCCall(&in, &out)) return NAN;
    uint32_t type = k->type;
    if (type == FourCC("flt ") && k->size == 4) { float f; memcpy(&f, out.bytes, 4); return f; }
    if (type == FourCC("sp78")) return (int16_t)(out.bytes[0] << 8 | out.bytes[1]) / 256.0;
    if (type == FourCC("fpe2")) return (out.bytes[0] << 6) + (out.bytes[1] >> 2);
    if (type == FourCC("ui8 ")) return out.bytes[0];
    if (type == FourCC("ui16")) return out.bytes[0] << 8 | out.bytes[1];
    if (type == FourCC("ui32")) return (uint32_t)out.bytes[0] << 24 | (uint32_t)out.bytes[1] << 16 | (uint32_t)out.bytes[2] << 8 | out.bytes[3];
    return NAN;
}

static double SMCRead(uint32_t key) {
    SMCKey k;
    return SMCLookup(key, &k) ? SMCValue(&k) : NAN;
}

// CPU/GPU die sensors (Tc, Te, Tp, Tg), discovered once.
enum { MaxSensors = 160, HotSensors = 8 };
static SMCKey gSensors[MaxSensors];
static int gSensorCount = -1;

static int SensorCount(void) {
    if (gSensorCount >= 0) return gSensorCount;
    gSensorCount = 0;
    double count = SMCRead(FourCC("#KEY"));
    for (uint32_t i = 0; isfinite(count) && i < (uint32_t)count && gSensorCount < MaxSensors; i++) {
        SMCParam in = {.data8 = 8, .data32 = i}, out;  // 8: key at index
        if (!SMCCall(&in, &out)) continue;
        char a = (char)(out.key >> 24), b = (char)(out.key >> 16);
        SMCKey k;
        if (a == 'T' && (b == 'c' || b == 'e' || b == 'p' || b == 'g') && SMCLookup(out.key, &k)) {
            double v = SMCValue(&k);
            if (v > 15 && v < 125) gSensors[gSensorCount++] = k;
        }
    }
    return gSensorCount;
}

static int CompareDescending(const void *a, const void *b) {
    double x = *(const double *)a, y = *(const double *)b;
    return x < y ? 1 : x > y ? -1 : 0;
}

// Temperature of the busy part of the chip: mean of the 4 hottest SoC sensors. Each SMC read
// is a kernel round trip to the SMC (~170 µs), so only the 8 that were hottest at the last
// full scan are read; a full rescan every 30 calls keeps that set honest.
static double SocTemperature(void) {
    static int hot[HotSensors], hotCount, sinceScan;
    int n = SensorCount();
    if (!n) return NAN;
    double values[MaxSensors];
    int read = 0;
    if (!hotCount || ++sinceScan >= 30) {
        sinceScan = 0;
        double ranked[MaxSensors][2];
        for (int i = 0; i < n; i++) { ranked[i][0] = SMCValue(&gSensors[i]); ranked[i][1] = i; }
        qsort(ranked, (size_t)n, sizeof ranked[0], CompareDescending);
        hotCount = 0;
        for (int i = 0; i < n && hotCount < HotSensors; i++) {
            if (!(ranked[i][0] > 15 && ranked[i][0] < 125)) continue;
            hot[hotCount++] = (int)ranked[i][1];
            values[read++] = ranked[i][0];
        }
    } else {
        for (int i = 0; i < hotCount; i++) {
            double v = SMCValue(&gSensors[hot[i]]);
            if (v > 15 && v < 125) values[read++] = v;
        }
    }
    if (!read) return NAN;
    qsort(values, (size_t)read, sizeof values[0], CompareDescending);
    double sum = 0;
    int top = read < 4 ? read : 4;
    for (int i = 0; i < top; i++) sum += values[i];
    return sum / top;
}

static NSUInteger SocSensorCount(void) { return (NSUInteger)SensorCount(); }

static double FanRPM(void) {
    static SMCKey fan;
    if (!fan.key && !SMCLookup(FourCC("F0Ac"), &fan)) return NAN;
    return SMCValue(&fan);
}

static double GPUUsage(void) {
    static io_service_t gpu;  // the accelerator that reports utilisation, found once
    if (!gpu) {
        io_iterator_t iterator;
        if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"), &iterator) != KERN_SUCCESS) return NAN;
        io_object_t service;
        while ((service = IOIteratorNext(iterator))) {
            CFTypeRef stats = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0);
            if (stats && !gpu) gpu = service; else IOObjectRelease(service);
            if (stats) CFRelease(stats);
        }
        IOObjectRelease(iterator);
        if (!gpu) return NAN;
    }
    NSDictionary *stats = CFBridgingRelease(IORegistryEntryCreateCFProperty(gpu, CFSTR("PerformanceStatistics"), kCFAllocatorDefault, 0));
    NSNumber *percent = [stats isKindOfClass:NSDictionary.class] ? stats[@"Device Utilization %"] : nil;
    return [percent isKindOfClass:NSNumber.class] ? percent.doubleValue / 100 : NAN;
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

// Charge level, with a symbol for the state: charging, on power (not charging), or on battery.
// nil on Macs without a battery.
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
        if (plugged && ![d[@kIOPSIsChargingKey] boolValue]) *symbol = @"powerplug.fill";
        text = [NSString stringWithFormat:@"%.0f%%", level * 100];
    }
    if (info) CFRelease(info);
    return text;
}

#pragma mark - Mouse scroll direction

// Wheel mice send scroll events with no gesture phase; trackpads (and Magic Mouse) do. So
// with natural scrolling on for the trackpad, flipping phase-less events gives the mouse
// the classic direction. Needs Accessibility permission to modify events.
static CFMachPortRef gScrollTap;

static CGEventRef ScrollTapped(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *info) {
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        if (gScrollTap) CGEventTapEnable(gScrollTap, true);
        return event;
    }
    if (type != kCGEventScrollWheel ||
        CGEventGetIntegerValueField(event, kCGScrollWheelEventScrollPhase) ||
        CGEventGetIntegerValueField(event, kCGScrollWheelEventMomentumPhase)) return event;
    int64_t line1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1);
    int64_t line2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2);
    double fixedY = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1);
    double fixedX = CGEventGetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2);
    int64_t point1 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1);
    int64_t point2 = CGEventGetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis1, -line1);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventDeltaAxis2, -line2);
    CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis1, -fixedY);
    CGEventSetDoubleValueField(event, kCGScrollWheelEventFixedPtDeltaAxis2, -fixedX);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis1, -point1);
    CGEventSetIntegerValueField(event, kCGScrollWheelEventPointDeltaAxis2, -point2);
    return event;
}

static BOOL ScrollReversalActive(void) { return gScrollTap && CGEventTapIsEnabled(gScrollTap); }

static void UpdateScrollReversal(BOOL promptForPermission) {
    BOOL want = SettingBool(@"ReverseMouseScroll", NO);
    if (want && !gScrollTap) {
        NSDictionary *options = @{(__bridge id)kAXTrustedCheckOptionPrompt: @(promptForPermission)};
        if (!AXIsProcessTrustedWithOptions((__bridge CFDictionaryRef)options)) {
            os_log(HKLog, "Mouse scroll reversal waiting for Accessibility permission");
            return;
        }
        gScrollTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                      CGEventMaskBit(kCGEventScrollWheel), ScrollTapped, NULL);
        os_log(HKLog, "Mouse scroll reversal %{public}s", gScrollTap ? "active" : "could not create event tap");
        if (!gScrollTap) return;
        CFRunLoopSourceRef source = CFMachPortCreateRunLoopSource(NULL, gScrollTap, 0);
        CFRunLoopAddSource(CFRunLoopGetMain(), source, kCFRunLoopCommonModes);
        CFRelease(source);
    } else if (!want && gScrollTap) {
        CGEventTapEnable(gScrollTap, false);
        CFMachPortInvalidate(gScrollTap);
        CFRelease(gScrollTap);
        gScrollTap = NULL;
    }
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

static void StartLoginPanel(void);

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
    // A minimal AppKit app, only for the on-screen status panel (no menu bar, no Touch Bar).
    NSApplication *app = NSApplication.sharedApplication;
    app.activationPolicy = NSApplicationActivationPolicyProhibited;
    StartLoginPanel();
    [app run];
    return 0;
}

#pragma mark - App

static NSImage *Symbol(NSString *name, NSString *fallback) {
    return [NSImage imageWithSystemSymbolName:name accessibilityDescription:nil]
        ?: (fallback ? [NSImage imageWithSystemSymbolName:fallback accessibilityDescription:nil] : nil);
}

// The desktop stats row, drawn as one view. Seven buttons cost an Auto Layout pass and a
// font lookup per label per tick; this draws text and cached icons directly and only when a
// value actually changed. Taps are mapped to segments by position.
@interface HKStatsView : NSView
@property (copy) void (^tapped)(NSString *segment);
@property (nonatomic, copy) NSArray<NSString *> *segments;
- (void)setText:(NSString *)text forSegment:(NSString *)segment;
- (void)setSymbol:(NSString *)symbol tint:(NSColor *)tint forSegment:(NSString *)segment;
@end

@implementation HKStatsView {
    NSMutableDictionary<NSString *, NSString *> *_texts;
    NSMutableDictionary<NSString *, NSImage *> *_icons;
    NSDictionary *_textAttributes, *_clockAttributes;
    NSMutableDictionary<NSString *, NSNumber *> *_widths;
}

// The Touch Bar drops an item that doesn't fit beside the close button, so the row stays within
// this width: the leftover space is shared out as equal gaps between segments.
static const CGFloat StatsWidth = 604;

// key → @[default symbol, shortest text]. Each segment is as wide as its icon plus the widest
// text it has shown since the row appeared, so the gaps stay even and the row only shifts when
// a value gains a digit, never back and forth.
static NSDictionary<NSString *, NSArray *> *StatSegments(void) {
    static NSDictionary *segments;
    if (!segments) segments = @{
        @"clock": @[@"", @"–"], @"cpu": @[@"cpu", @"8%"], @"gpu": @[@"cube.transparent", @"8%"],
        @"memory": @[@"memorychip", @"8.8G | 8%"], @"temp": @[@"thermometer.medium", @"88°"], @"fan": @[@"fan.fill", @"8888"],
        @"network": @[@"", @"↓8K ↑8B"], @"battery": @[@"battery.100", @"8%"],
    };
    return segments;
}

- (CGFloat)gap {
    CGFloat used = 0;
    for (NSString *key in self.segments) used += [self widthOfSegment:key];
    NSUInteger gaps = self.segments.count > 1 ? self.segments.count - 1 : 1;
    return floor(MIN(18, MAX(4, (StatsWidth - used) / gaps)));
}

- (CGFloat)widthOfSegment:(NSString *)key {
    NSNumber *cached = _widths[key];
    if (cached) return cached.doubleValue;
    NSDictionary *attributes = [key isEqualToString:@"clock"] ? _clockAttributes : _textAttributes;
    NSString *text = _texts[key];
    CGFloat width = ceil([StatSegments()[key][1] sizeWithAttributes:attributes].width);
    if (text) width = MAX(width, ceil([text sizeWithAttributes:attributes].width));
    if (_icons[key]) width += ceil(_icons[key].size.width) + 5;
    _widths[key] = @(width);
    return width;
}

- (instancetype)initWithFrame:(NSRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _texts = [NSMutableDictionary dictionary];
        _icons = [NSMutableDictionary dictionary];
        _widths = [NSMutableDictionary dictionary];
        NSColor *white = [NSColor colorWithWhite:1 alpha:0.92];
        _textAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightRegular], NSForegroundColorAttributeName: white};
        _clockAttributes = @{NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:13 weight:NSFontWeightMedium], NSForegroundColorAttributeName: white};
        self.allowedTouchTypes = NSTouchTypeMaskDirect;
    }
    return self;
}

- (void)setSegments:(NSArray<NSString *> *)segments {
    _segments = [segments copy];
    [_widths removeAllObjects];
    for (NSString *key in segments)
        if (!_icons[key] && [StatSegments()[key][0] length]) [self setSymbol:StatSegments()[key][0] tint:nil forSegment:key];
    [self invalidateIntrinsicContentSize];
    self.needsDisplay = YES;
}

- (NSSize)intrinsicContentSize {
    CGFloat width = 0, gap = self.gap;
    for (NSString *key in self.segments) width += [self widthOfSegment:key] + gap;
    return NSMakeSize(MAX(0, width - gap), 30);
}

- (NSRect)rectForSegment:(NSString *)segment {
    CGFloat x = 0, gap = self.gap;
    for (NSString *key in self.segments) {
        CGFloat width = [self widthOfSegment:key];
        if ([key isEqualToString:segment]) return NSMakeRect(x, 0, width, NSHeight(self.bounds));
        x += width + gap;
    }
    return NSZeroRect;
}

- (void)setText:(NSString *)text forSegment:(NSString *)segment {
    if ([_texts[segment] isEqualToString:text]) return;
    _texts[segment] = text;
    [self segmentChanged:segment];
}

- (void)setSymbol:(NSString *)symbol tint:(NSColor *)tint forSegment:(NSString *)segment {
    NSImageSymbolConfiguration *config = [[NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular]
        configurationByApplyingConfiguration:[NSImageSymbolConfiguration configurationWithPaletteColors:@[tint ?: [NSColor colorWithWhite:1 alpha:0.92]]]];
    _icons[segment] = [Symbol(symbol, @"circle") imageWithSymbolConfiguration:config];
    [self segmentChanged:segment];
}

- (void)segmentChanged:(NSString *)segment {
    CGFloat before = _widths[segment].doubleValue;
    [_widths removeObjectForKey:segment];
    CGFloat now = [self widthOfSegment:segment];
    if (now < before) _widths[segment] = @(now = before);  // keep the widest
    if (before && now != before) {  // wider: the gaps and everything after it move
        [self invalidateIntrinsicContentSize];
        self.needsDisplay = YES;
    } else {
        [self setNeedsDisplayInRect:[self rectForSegment:segment]];  // repaint just this segment
    }
}

- (void)drawRect:(NSRect)dirty {
    CGFloat x = 0, gap = self.gap, mid = NSMidY(self.bounds);
    for (NSString *key in self.segments) {
        CGFloat width = [self widthOfSegment:key], textX = x;
        if (![self needsToDrawRect:NSMakeRect(x, 0, width + gap, NSHeight(self.bounds))]) { x += width + gap; continue; }
        NSImage *icon = _icons[key];
        if (icon) {
            NSSize size = icon.size;
            [icon drawInRect:NSMakeRect(x, round(mid - size.height / 2), size.width, size.height)];
            textX += size.width + 5;
        }
        BOOL clock = [key isEqualToString:@"clock"];
        NSDictionary *attributes = clock ? _clockAttributes : _textAttributes;
        NSString *text = _texts[key] ?: @"–";
        NSSize size = [text sizeWithAttributes:attributes];
        [text drawAtPoint:NSMakePoint(textX, round(mid - size.height / 2)) withAttributes:attributes];
        if (clock) {  // separator after the clock
            [[NSColor colorWithWhite:1 alpha:0.25] setFill];
            NSRectFill(NSMakeRect(x + width + gap / 2 - 0.5, mid - 10, 1, 20));
        }
        x += width + gap;
    }
}

- (void)touchesEndedWithEvent:(NSEvent *)event {
    NSTouch *touch = [[event touchesMatchingPhase:NSTouchPhaseEnded inView:self] anyObject];
    CGFloat at = [touch locationInView:self].x, x = 0, gap = self.gap;
    for (NSString *key in self.segments) {
        x += [self widthOfSegment:key] + gap;
        if (at < x) { if (self.tapped) self.tapped(key); return; }
    }
}
@end

#pragma mark - Login / lock screen panel

// On the login and lock screens the Touch Bar belongs to loginwindow, so Headless shows a small
// panel on the screen instead. Ordinary windows sit below those screens; this one is moved into
// a window-server space at the level macOS uses for notifications over the lock screen.
typedef int (*SLSMainConnectionIDFn)(void);
typedef uint64_t (*SLSSpaceCreateFn)(int, int, CFDictionaryRef);
typedef CGError (*SLSSpaceSetAbsoluteLevelFn)(int, uint64_t, int);
typedef CGError (*SLSShowSpacesFn)(int, CFArrayRef);
typedef CGError (*SLSSpaceAddWindowsAndRemoveFromSpacesFn)(int, uint64_t, CFArrayRef, int);

static BOOL RaiseAboveLockScreen(NSWindow *window) {
    static uint64_t space;
    static int connection;
    void *sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY);
    SLSMainConnectionIDFn mainConnection = sky ? dlsym(sky, "SLSMainConnectionID") : NULL;
    SLSSpaceCreateFn createSpace = sky ? dlsym(sky, "SLSSpaceCreate") : NULL;
    SLSSpaceSetAbsoluteLevelFn setLevel = sky ? dlsym(sky, "SLSSpaceSetAbsoluteLevel") : NULL;
    SLSShowSpacesFn showSpaces = sky ? dlsym(sky, "SLSShowSpaces") : NULL;
    SLSSpaceAddWindowsAndRemoveFromSpacesFn addWindows = sky ? dlsym(sky, "SLSSpaceAddWindowsAndRemoveFromSpaces") : NULL;
    if (!mainConnection || !createSpace || !setLevel || !showSpaces || !addWindows) return NO;
    if (!space) {
        connection = mainConnection();
        space = createSpace(connection, 1, NULL);
        if (!space) return NO;
        setLevel(connection, space, 400);  // "notification center at screen lock"
        showSpaces(connection, (__bridge CFArrayRef)@[@(space)]);
    }
    addWindows(connection, space, (__bridge CFArrayRef)@[@(window.windowNumber)], 7);
    return YES;
}

@interface HKStatusPanel : NSObject
+ (instancetype)shared;
- (void)show;
- (void)hide;
@end

@implementation HKStatusPanel {
    NSPanel *_panel;
    NSTextField *_time, *_date;
    NSDictionary<NSString *, NSTextField *> *_stats;
    NSDictionary<NSString *, NSImageView *> *_statIcons;
    NSDictionary<NSString *, NSSlider *> *_sliders;
    NSDictionary<NSString *, NSTextField *> *_sliderValues;
    NSSegmentedControl *_fans;
    NSButton *_nightShift, *_awake;
    NSTimer *_timer;
}

static NSArray<NSString *> *PanelFanModes(void) { return @[@"auto", @"smart", @"custom", @"max"]; }

+ (instancetype)shared {
    static HKStatusPanel *panel;
    if (!panel) panel = [HKStatusPanel new];
    return panel;
}

- (NSTextField *)label:(CGFloat)size weight:(NSFontWeight)weight alpha:(CGFloat)alpha {
    NSTextField *label = [NSTextField labelWithString:@""];
    label.font = [NSFont monospacedDigitSystemFontOfSize:size weight:weight];
    label.textColor = [NSColor colorWithWhite:1 alpha:alpha];
    return label;
}

- (NSImageView *)icon:(NSString *)symbol {
    NSImageView *icon = [NSImageView imageViewWithImage:Symbol(symbol, @"circle")];
    icon.contentTintColor = [NSColor colorWithWhite:1 alpha:0.6];
    icon.symbolConfiguration = [NSImageSymbolConfiguration configurationWithPointSize:13 weight:NSFontWeightRegular];
    [icon.widthAnchor constraintEqualToConstant:20].active = YES;
    return icon;
}

- (NSStackView *)statCell:(NSString *)key symbol:(NSString *)symbol icons:(NSMutableDictionary *)icons labels:(NSMutableDictionary *)labels {
    NSImageView *icon = [self icon:symbol];
    NSTextField *value = [self label:13 weight:NSFontWeightRegular alpha:0.92];
    value.stringValue = @"–";
    icons[key] = icon;
    labels[key] = value;
    NSStackView *cell = [NSStackView stackViewWithViews:@[icon, value]];
    cell.spacing = 6;
    return cell;
}

- (NSArray<NSView *> *)sliderRow:(NSString *)key symbol:(NSString *)symbol title:(NSString *)title
                         sliders:(NSMutableDictionary *)sliders values:(NSMutableDictionary *)values {
    NSTextField *name = [self label:12 weight:NSFontWeightRegular alpha:0.7];
    name.stringValue = title;
    NSSlider *slider = [NSSlider sliderWithValue:100 minValue:0 maxValue:100 target:self action:@selector(sliderMoved:)];
    slider.continuous = YES;
    slider.identifier = key;
    NSTextField *value = [self label:12 weight:NSFontWeightRegular alpha:0.8];
    value.alignment = NSTextAlignmentRight;
    sliders[key] = slider;
    values[key] = value;
    return @[[self icon:symbol], name, slider, value];
}

- (NSButton *)toggle:(NSString *)title symbol:(NSString *)symbol action:(SEL)action {
    NSButton *button = [NSButton buttonWithTitle:title image:Symbol(symbol, @"circle") target:self action:action];
    button.imagePosition = NSImageLeading;
    button.bezelStyle = NSBezelStyleRounded;
    button.controlSize = NSControlSizeRegular;
    return button;
}

- (void)build {
    _panel = [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 480, 300)
                                        styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                          backing:NSBackingStoreBuffered defer:NO];
    _panel.opaque = NO;
    _panel.backgroundColor = NSColor.clearColor;
    _panel.hasShadow = YES;
    _panel.level = NSScreenSaverWindowLevel;
    _panel.canBecomeVisibleWithoutLogin = YES;
    _panel.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces | NSWindowCollectionBehaviorStationary |
                                NSWindowCollectionBehaviorIgnoresCycle | NSWindowCollectionBehaviorFullScreenAuxiliary;
    _panel.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];

    NSVisualEffectView *background = [[NSVisualEffectView alloc] initWithFrame:_panel.contentView.bounds];
    background.material = NSVisualEffectMaterialHUDWindow;
    background.state = NSVisualEffectStateActive;
    background.wantsLayer = YES;
    background.layer.cornerRadius = 18;
    background.layer.masksToBounds = YES;
    _panel.contentView = background;

    // Clock
    _time = [self label:30 weight:NSFontWeightLight alpha:1];
    _date = [self label:13 weight:NSFontWeightRegular alpha:0.7];
    NSStackView *timeRow = [NSStackView stackViewWithViews:@[_time, _date]];
    timeRow.alignment = NSLayoutAttributeLastBaseline;
    timeRow.spacing = 10;

    // Stats: two rows of four, in aligned columns
    NSMutableDictionary *icons = [NSMutableDictionary dictionary], *labels = [NSMutableDictionary dictionary];
    NSGridView *stats = [NSGridView gridViewWithViews:@[
        @[[self statCell:@"cpu" symbol:@"cpu" icons:icons labels:labels], [self statCell:@"gpu" symbol:@"cube.transparent" icons:icons labels:labels],
          [self statCell:@"memory" symbol:@"memorychip" icons:icons labels:labels], [self statCell:@"temp" symbol:@"thermometer.medium" icons:icons labels:labels]],
        @[[self statCell:@"fan" symbol:@"fan.fill" icons:icons labels:labels], [self statCell:@"network" symbol:@"network" icons:icons labels:labels],
          [self statCell:@"battery" symbol:@"battery.100" icons:icons labels:labels], [self statCell:@"uptime" symbol:@"clock.arrow.circlepath" icons:icons labels:labels]],
    ]];
    stats.columnSpacing = 18;
    stats.rowSpacing = 8;
    _stats = labels;
    _statIcons = icons;

    // Brightness and fans, in aligned columns
    _fans = [NSSegmentedControl segmentedControlWithLabels:@[@"Auto", @"Smart", @"Custom", @"Max"]
                                              trackingMode:NSSegmentSwitchTrackingSelectOne target:self action:@selector(fanModeChosen:)];
    _fans.segmentDistribution = NSSegmentDistributionFillEqually;
    NSTextField *fanName = [self label:12 weight:NSFontWeightRegular alpha:0.7];
    fanName.stringValue = @"Fans";
    NSMutableDictionary *sliders = [NSMutableDictionary dictionary], *values = [NSMutableDictionary dictionary];
    NSGridView *brightness = [NSGridView gridViewWithViews:@[
        [self sliderRow:@"MonitorLevel" symbol:@"display" title:@"Monitor" sliders:sliders values:values],
        [self sliderRow:@"TouchBarLevel" symbol:@"sun.max.fill" title:@"Touch Bar" sliders:sliders values:values],
        [self sliderRow:@"KeyboardLevel" symbol:@"light.max" title:@"Keyboard" sliders:sliders values:values],
        @[[self icon:@"fan"], fanName, _fans, NSGridCell.emptyContentView],
    ]];
    [brightness mergeCellsInHorizontalRange:NSMakeRange(2, 2) verticalRange:NSMakeRange(3, 1)];
    [brightness rowAtIndex:3].topPadding = 4;
    [_fans.widthAnchor constraintEqualToConstant:336].active = YES;  // lines up with the end of the percentages
    brightness.columnSpacing = 8;
    brightness.rowSpacing = 6;
    [brightness columnAtIndex:2].width = 300;
    [brightness columnAtIndex:3].width = 40;
    brightness.yPlacement = NSGridCellPlacementCenter;
    _sliders = sliders;
    _sliderValues = values;

    // Toggles
    _nightShift = [self toggle:@"Night Shift" symbol:@"moon.fill" action:@selector(toggleNightShift:)];
    _awake = [self toggle:@"Keep Awake" symbol:@"cup.and.saucer.fill" action:@selector(toggleAwake:)];
    NSButton *sleep = [self toggle:@"Sleep Display" symbol:@"moon.zzz.fill" action:@selector(sleepDisplay:)];
    for (NSButton *button in @[_nightShift, _awake]) button.buttonType = NSButtonTypePushOnPushOff;
    NSStackView *toggles = [NSStackView stackViewWithViews:@[_nightShift, _awake, sleep]];
    toggles.spacing = 8;

    NSBox *line1 = [NSBox new], *line2 = [NSBox new];
    line1.boxType = line2.boxType = NSBoxSeparator;
    NSStackView *stack = [NSStackView stackViewWithViews:@[timeRow, stats, line1, brightness, line2, toggles]];
    stack.orientation = NSUserInterfaceLayoutOrientationVertical;
    stack.alignment = NSLayoutAttributeLeading;
    stack.spacing = 12;
    stack.edgeInsets = NSEdgeInsetsMake(18, 20, 18, 20);
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [background addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:background.leadingAnchor],
        [stack.trailingAnchor constraintEqualToAnchor:background.trailingAnchor],
        [stack.topAnchor constraintEqualToAnchor:background.topAnchor],
        [stack.bottomAnchor constraintEqualToAnchor:background.bottomAnchor],
        [line1.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
        [line2.widthAnchor constraintEqualToAnchor:stack.widthAnchor constant:-40],
    ]];
    [_panel setContentSize:stack.fittingSize];
}

- (void)show {
    if (!_panel) [self build];
    NSScreen *screen = NSScreen.mainScreen ?: NSScreen.screens.firstObject;
    NSRect frame = screen.frame;
    [_panel setFrameOrigin:NSMakePoint(NSMinX(frame) + 36, NSMinY(frame) + 36)];
    CPUUsage();  // prime the deltas
    double down, up;
    NetworkRates(&down, &up);
    [self update];
    [_panel orderFrontRegardless];
    if (!RaiseAboveLockScreen(_panel)) os_log_error(HKLog, "Could not raise the status panel above the lock screen");
    [_timer invalidate];
    _timer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self update]; }];
    _timer.tolerance = 0.5;
}

- (void)hide {
    [_timer invalidate];
    _timer = nil;
    [_panel orderOut:nil];
}

static NSString *UptimeText(void) {
    struct timeval boot;
    size_t size = sizeof boot;
    if (sysctlbyname("kern.boottime", &boot, &size, NULL, 0) != 0) return @"–";
    long minutes = (long)(time(NULL) - boot.tv_sec) / 60;
    if (minutes >= 1440) return [NSString stringWithFormat:@"%ldd %ldh", minutes / 1440, minutes / 60 % 24];
    return [NSString stringWithFormat:@"%ldh %ldm", minutes / 60, minutes % 60];
}

- (void)update {
    static NSDateFormatter *time, *date;
    if (!time) {
        time = [NSDateFormatter new];
        [time setLocalizedDateFormatFromTemplate:@"jmm"];
        date = [NSDateFormatter new];
        [date setLocalizedDateFormatFromTemplate:@"EEEEdMMMM"];
    }
    NSDate *now = [NSDate date];
    _time.stringValue = [time stringFromDate:now];
    _date.stringValue = [date stringFromDate:now];

    double cpu = CPUUsage(), gpu = GPUUsage(), memory = MemoryUsage(), temperature = SocTemperature(), rpm = FanRPM(), down, up;
    NetworkRates(&down, &up);
    _stats[@"cpu"].stringValue = isfinite(cpu) ? [NSString stringWithFormat:@"%.0f%%", cpu * 100] : @"–";
    _stats[@"gpu"].stringValue = isfinite(gpu) ? [NSString stringWithFormat:@"%.0f%%", gpu * 100] : @"–";
    _stats[@"memory"].stringValue = isfinite(memory) ? [NSString stringWithFormat:@"%.1fG | %.0f%%", memory * NSProcessInfo.processInfo.physicalMemory / 1073741824.0, memory * 100] : @"–";
    _stats[@"temp"].stringValue = isfinite(temperature) ? [NSString stringWithFormat:@"%.0f°C", temperature] : @"–";
    _stats[@"fan"].stringValue = isfinite(rpm) ? [NSString stringWithFormat:@"%.0f rpm", rpm] : @"–";
    _stats[@"network"].stringValue = [NSString stringWithFormat:@"↓%@ ↑%@", RateText(down), RateText(up)];
    NSString *symbol = @"battery.100";
    _stats[@"battery"].stringValue = BatteryText(&symbol) ?: @"–";
    _statIcons[@"battery"].image = Symbol(symbol, @"battery.100");
    _stats[@"uptime"].stringValue = UptimeText();

    double keyboard = HasSetting(@"KeyboardLevel") ? SettingLevel(@"KeyboardLevel", 1.0) : KeyboardCurrent();
    NSDictionary *levels = @{@"MonitorLevel": @(SettingLevel(@"MonitorLevel", 1.0)), @"TouchBarLevel": @(SettingLevel(@"TouchBarLevel", 1.0)),
                             @"KeyboardLevel": @(isfinite(keyboard) ? keyboard : 1.0)};
    for (NSString *key in levels) {
        double percent = round([levels[key] doubleValue] * 100);
        if (!_sliders[key].highlighted) _sliders[key].doubleValue = percent;
        _sliderValues[key].stringValue = [NSString stringWithFormat:@"%.0f%%", round(_sliders[key].doubleValue)];
    }
    _nightShift.state = NightShiftOn();
    _awake.state = SettingBool(@"KeepAwake", YES);
    FanRequestAsync(@"status", ^(NSDictionary *status) {
        NSUInteger index = [PanelFanModes() indexOfObject:status[@"mode"] ?: @""];
        self->_fans.enabled = status != nil;
        self->_fans.selectedSegment = index == NSNotFound ? -1 : (NSInteger)index;
        self->_statIcons[@"fan"].contentTintColor = index == NSNotFound || index == 0 ? [NSColor colorWithWhite:1 alpha:0.6] : NSColor.systemBlueColor;
    });
}

- (void)sliderMoved:(NSSlider *)slider {
    double level = round(slider.doubleValue) / 100;
    NSString *key = slider.identifier;
    SetSetting(key, @(level));
    if ([key isEqualToString:@"MonitorLevel"]) { ApplyMonitor(); SetBuiltinBrightness(level); }
    else if ([key isEqualToString:@"TouchBarLevel"]) SetTouchBar(level);
    else SetKeyboard(level);
    _sliderValues[key].stringValue = [NSString stringWithFormat:@"%.0f%%", level * 100];
}

- (void)fanModeChosen:(NSSegmentedControl *)control {
    NSString *mode = PanelFanModes()[(NSUInteger)control.selectedSegment];
    if ([mode isEqualToString:@"custom"]) {  // the last custom speed
        FanRequestAsync(@"status", ^(NSDictionary *status) {
            FanRequestAsync([NSString stringWithFormat:@"set custom %.0f", [status[@"custom"] doubleValue]], ^(NSDictionary *reply) { [self update]; });
        });
    } else {
        FanRequestAsync([@"set " stringByAppendingString:mode], ^(NSDictionary *reply) { [self update]; });
    }
}

- (void)toggleNightShift:(NSButton *)sender { SetNightShift(!NightShiftOn()); [self update]; }

- (void)toggleAwake:(NSButton *)sender {
    gSettings[@"KeepAwake"] = @(!SettingBool(@"KeepAwake", YES));
    SaveSettingsNow();
    UpdateKeepAwake();
    [self update];
}

- (void)sleepDisplay:(NSButton *)sender { SleepDisplays(); }
@end

static BOOL gScreenLocked;

static void StartLoginPanel(void) {
    if (SettingBool(@"LockScreenPanel", YES)) [HKStatusPanel.shared show];
}

typedef NS_ENUM(UInt32, HKHotKey) {
    HKTouchBarUp = 1, HKTouchBarDown, HKKeyboardUp, HKKeyboardDown,
    HKShowControls, HKReapply, HKLock, HKSleepDisplays, HKToggleAwake, HKToggleNightShift,
    HKMonitorUp, HKMonitorDown, HKCycleFans, HKShowStats,
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
@property HKStatsView *statsView;
@property NSTimer *statsTimer;
@property NSTouchBar *presentedBar;
@property NSDate *presentedAt;
@property BOOL screensaverRunning;
@property BOOL closingStatsOurselves;  // so only the user's ✕ on the stats returns to the menu
@property BOOL statsFromMenu;          // stats opened with the menu's Stats button
@property BOOL statsManual;            // stats opened by the user, not shown automatically at the desktop
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
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsLocked" object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *n) { gScreenLocked = YES; if (SettingBool(@"LockScreenPanel", YES)) [HKStatusPanel.shared show]; }];
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.screenIsUnlocked" object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *n) { gScreenLocked = NO; [HKStatusPanel.shared hide]; }];
    // Fires on every app launch/quit; used to notice ControlStrip restarting.
    [NSWorkspace.sharedWorkspace addObserver:self forKeyPath:@"runningApplications" options:0 context:NULL];

    int token;
    notify_register_dispatch(HKChangedNotify, &token, dispatch_get_main_queue(), ^(int t) { SettingsChangedElsewhere(); UpdateScrollReversal(YES); [weakSelf refreshControls]; });
    notify_register_dispatch(HKShowNotify, &token, dispatch_get_main_queue(), ^(int t) { [weakSelf showControls:nil]; });
    notify_register_dispatch(HKShowNotify ".panel", &token, dispatch_get_main_queue(), ^(int t) {
        [weakSelf previewPanel:nil];
    });
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
    UpdateScrollReversal(YES);
    [NSDistributedNotificationCenter.defaultCenter addObserverForName:@"com.apple.accessibility.api" object:nil queue:NSOperationQueue.mainQueue
                                                           usingBlock:^(NSNotification *n) { After(1, ^{ UpdateScrollReversal(NO); }); }];
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

static BOOL RecentClickOrKey(void) {
    for (NSNumber *type in @[@(kCGEventLeftMouseDown), @(kCGEventRightMouseDown), @(kCGEventOtherMouseDown), @(kCGEventKeyDown)])
        if (CGEventSourceSecondsSinceLastEventType(kCGEventSourceStateCombinedSessionState, (CGEventType)type.intValue) < 0.6) return YES;
    return NO;
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == (__bridge void *)TrayID) {
        NSTouchBar *bar = object;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (bar.visible) return;
            if (self.presentedBar == bar) self.presentedBar = nil;
            After(0.3, ^{ [self registerTray]; });
            if (bar != self.statsBar) return;
            // macOS also closes the stats when the frontmost app changes its own Touch Bar, e.g. on a
            // click in a video. The ✕ is a Touch Bar tap, not a click or key press, so a click or
            // key press just before the close means it was interrupted, not dismissed.
            BOOL ours = self.closingStatsOurselves, interrupted = !ours && RecentClickOrKey();
            self.closingStatsOurselves = NO;
            if (interrupted && SettingBool(@"KeepStatsOpen", YES) && (self.statsManual || self.atDesktop)) {
                os_log(HKLog, "Stats interrupted; showing them again");
                After(0.3, ^{ if (!self.presentedBar) [self presentStats]; });
                return;
            }
            // ✕ on stats opened from the menu steps back to the menu; ✕ there closes everything.
            if (!ours && !interrupted && self.statsFromMenu) After(0.3, ^{ [self showControls:nil]; });
            self.statsFromMenu = NO;
            self.statsManual = NO;
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
    // A freshly launched ControlStrip ignores registrations for several seconds; repeat (idempotent).
    for (NSNumber *delay in @[@1, @3, @6, @10]) After(delay.doubleValue, ^{ [self registerTray]; });
    After(0.5, ^{ ApplyTouchBar(); });
    After(5.5, ^{ if (self.presentedBar == self.statsBar) self.presentedBar = nil; [self frontmostChanged:nil]; });
}

- (void)registerTray {
    if (!self.tray || ![NSTouchBarItem respondsToSelector:@selector(addSystemTrayItem:)]) return;
    [NSTouchBarItem addSystemTrayItem:self.tray];
    if (SetControlStripPresence) SetControlStripPresence(TrayID, YES);
}

// Apple's brightness button drives the built-in panel; with no panel it does nothing. Drop it
// from the collapsed Control Strip so our ☀︎ (monitor brightness) takes its place. Only writes,
// and restarts ControlStrip, when the layout actually has to change.
- (void)updateControlStripLayout {
    static NSString * const Native = @"com.apple.system.brightness";
    CFStringRef domain = CFSTR("com.apple.controlstrip");
    NSArray *current = CFBridgingRelease(CFPreferencesCopyAppValue(CFSTR("MiniCustomized"), domain));
    NSArray *base = [current isKindOfClass:NSArray.class] ? current
        : @[Native, @"com.apple.system.volume", @"com.apple.system.mute", @"com.apple.system.siri"];
    NSMutableArray *wanted = [base mutableCopy];
    if (SettingBool(@"ReplaceBrightnessButton", YES)) [wanted removeObject:Native];
    else if (![wanted containsObject:Native]) [wanted insertObject:Native atIndex:0];
    if ([wanted isEqualToArray:base]) return;
    CFPreferencesSetAppValue(CFSTR("MiniCustomized"), (__bridge CFArrayRef)wanted, domain);
    CFPreferencesAppSynchronize(domain);
    os_log(HKLog, "Control Strip layout updated; restarting ControlStrip");
    [self restartTouchBar:nil];  // runningApplications KVO re-registers our item afterwards
}

- (void)toggleBrightnessButton:(id)sender {
    gSettings[@"ReplaceBrightnessButton"] = @(!SettingBool(@"ReplaceBrightnessButton", YES));
    SaveSettingsNow();
    [self updateControlStripLayout];
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

    self.displayButton = [self barButton:@"display" fallback:nil title:@"Monitor" action:@selector(showMonitorPage:)];
    self.awakeButton = [self barButton:@"cup.and.saucer.fill" fallback:@"bolt.fill" title:@"Awake" action:@selector(toggleAwake:)];
    self.nightShiftButton = [self barButton:@"moon.fill" fallback:nil title:@"Night" action:@selector(toggleNightShift:)];
    NSButton *fansButton = [self barButton:@"fan.fill" fallback:@"wind" title:@"Fans" action:@selector(showFanPage:)];
    NSButton *statsButton = [self fixedWidth:52 button:[self barButton:@"gauge.with.dots.needle.50percent" fallback:@"chart.bar" title:nil action:@selector(showStatsFromMenu:)]];
    NSButton *touchBarButton = [self barButton:@"sun.max.fill" fallback:nil title:@"Touch Bar" action:@selector(showTouchBarPage:)];
    NSButton *keyboardButton = [self barButton:@"keyboard" fallback:@"light.max" title:@"Keyboard" action:@selector(showKeyboardPage:)];
    // Labelled buttons only fit the ~640 pt modal area with a slightly smaller title.
    NSArray *row = @[touchBarButton, keyboardButton, self.displayButton, self.nightShiftButton, self.awakeButton, fansButton];
    NSArray *widths = @[@96, @104, @92, @72, @80, @72];
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
        [self item:@"stats" view:statsButton label:@"System Stats"],
    ];
    self.mainBar = [NSTouchBar new];
    self.mainBar.templateItems = [NSSet setWithArray:mainItems];
    self.mainBar.defaultItemIdentifiers = @[@"tb", @"kb", @"display", @"nightshift", @"awake", @"fans", @"stats"];

    [self buildStatsBar];

    self.tray = [[NSCustomTouchBarItem alloc] initWithIdentifier:TrayID];
    // Sits where Apple's (dead) brightness button was. Tap: the controls menu.
    self.tray.view = [self barButton:@"slider.horizontal.3" fallback:nil title:nil action:@selector(showControls:)];
    self.tray.view.accessibilityLabel = @"Headless controls";
    [self watchVisibility:@[self.mainBar, self.statsBar]];
    After(2, ^{ [self updateControlStripLayout]; });
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
    if (self.fanPage) return;
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
    self.statsView = [[HKStatsView alloc] initWithFrame:NSMakeRect(0, 0, 600, 30)];
    __weak HKApp *weakSelf = self;
    self.statsView.tapped = ^(NSString *segment) {
        if ([segment isEqualToString:@"clock"] || [segment isEqualToString:@"battery"]) [weakSelf showControls:nil];
        else if ([segment isEqualToString:@"temp"] || [segment isEqualToString:@"fan"]) [weakSelf showFanPage:nil];
        else [weakSelf openActivityMonitor:nil];
    };
    self.statsBar = [NSTouchBar new];
    self.statsBar.templateItems = [NSSet setWithObject:[self item:@"stats" view:self.statsView label:@"System Stats"]];
    self.statsBar.defaultItemIdentifiers = @[@"stats"];
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(frontmostChanged:) name:NSWorkspaceDidActivateApplicationNotification object:nil];
    // The screensaver does not reliably become the "active app"; it does announce itself.
    NSDistributedNotificationCenter *center = NSDistributedNotificationCenter.defaultCenter;
    [center addObserver:self selector:@selector(screensaverStarted:) name:@"com.apple.screensaver.didstart" object:nil];
    [center addObserver:self selector:@selector(screensaverStopped:) name:@"com.apple.screensaver.didstop" object:nil];
    After(1, ^{ [self frontmostChanged:nil]; });
}

// The app area of the Touch Bar belongs to the frontmost app; at the desktop (Finder) or in
// the screensaver show stats there instead, and get out of the way for any other app.
static BOOL ShowsStats(NSString *bundleID) {
    return [@[@"com.apple.finder", @"com.apple.ScreenSaver.Engine"] containsObject:bundleID ?: @""];
}

- (BOOL)atDesktop {
    return self.screensaverRunning || ShowsStats(NSWorkspace.sharedWorkspace.frontmostApplication.bundleIdentifier);
}

- (void)frontmostChanged:(NSNotification *)note {
    if (!gScrollTap) UpdateScrollReversal(NO);  // permission may have just been granted
    // Don't cover a Headless panel the user has open right now.
    BOOL ourPanelInUse = self.presentedBar && self.presentedBar != self.statsBar && self.presentedBar.visible;
    if (self.atDesktop && SettingBool(@"DesktopStats", YES) && !ourPanelInUse) {
        // A bar presented while the previous one is still closing gets dropped: let it settle,
        // then check it actually appeared and retry once if not.
        After(0.5, ^{
            if (!self.atDesktop) return;
            [self presentStats];
            After(1.0, ^{ if (self.atDesktop && !self.statsBar.visible) [self presentStats]; });
        });
    } else if (!self.atDesktop && self.presentedBar == self.statsBar && !(self.statsManual && SettingBool(@"KeepStatsOpen", YES))) {
        [self hideStats];
    }
}

- (void)screensaverStarted:(NSNotification *)note { self.screensaverRunning = YES; [self frontmostChanged:nil]; }
- (void)screensaverStopped:(NSNotification *)note { self.screensaverRunning = NO; [self frontmostChanged:nil]; }

// Opened by the user (menu, shortcut, CLI): with Keep Stats Open it stays until ✕.
- (void)showStats:(id)sender {
    self.statsManual = YES;
    [self presentStats];
}

- (void)presentStats {
    if (!self.statsBar) return;
    NSString *symbol;
    BOOL battery = BatteryText(&symbol) != nil;  // desktops have none
    self.statsView.segments = battery ? @[@"clock", @"cpu", @"gpu", @"memory", @"temp", @"fan", @"network", @"battery"]
                                      : @[@"clock", @"cpu", @"gpu", @"memory", @"temp", @"fan", @"network"];
    for (NSString *key in @[@"cpu", @"gpu", @"memory", @"network"]) [self.statsView setText:@"–" forSegment:key];
    double down, up;
    CPUUsage();  // prime the deltas; first real values arrive with the first tick
    NetworkRates(&down, &up);
    [self present:self.statsBar];
    After(0.6, ^{ [self updateStats]; });
    FanRequestAsync(@"status", ^(NSDictionary *status) { [self tintFanStat:status]; });
    [self.statsTimer invalidate];
    self.statsTimer = [NSTimer scheduledTimerWithTimeInterval:2 repeats:YES block:^(NSTimer *t) { [self updateStats]; }];
    self.statsTimer.tolerance = 0.5;
}

- (void)showStatsFromMenu:(id)sender {
    [self showStats:sender];  // sets statsManual
    self.statsFromMenu = YES;
}

- (void)hideStats {
    self.closingStatsOurselves = YES;
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
    HKStatsView *view = self.statsView;
    NSDate *now = [NSDate date];
    [view setText:[NSString stringWithFormat:@"%@ · %@", [time stringFromDate:now], [date stringFromDate:now]] forSegment:@"clock"];
    static unsigned tick;
    double cpu = CPUUsage(), memory = MemoryUsage(), gpu = GPUUsage(), rpm = FanRPM();
    double temperature = tick++ % 2 == 0 ? SocTemperature() : NAN;  // every other tick is plenty
    [view setText:isfinite(cpu) ? [NSString stringWithFormat:@"%.0f%%", cpu * 100] : @"–" forSegment:@"cpu"];
    [view setText:isfinite(gpu) ? [NSString stringWithFormat:@"%.0f%%", gpu * 100] : @"–" forSegment:@"gpu"];
    double memoryGB = memory * NSProcessInfo.processInfo.physicalMemory / 1073741824.0;
    [view setText:isfinite(memory) ? [NSString stringWithFormat:@"%.1fG | %.0f%%", memoryGB, memory * 100] : @"–" forSegment:@"memory"];
    if (isfinite(temperature)) [view setText:[NSString stringWithFormat:@"%.0f°", temperature] forSegment:@"temp"];
    [view setText:isfinite(rpm) ? [NSString stringWithFormat:@"%.0f", rpm] : @"–" forSegment:@"fan"];
    double down, up;
    NetworkRates(&down, &up);
    [view setText:[NSString stringWithFormat:@"↓%@ ↑%@", RateText(down), RateText(up)] forSegment:@"network"];
    if ([view.segments containsObject:@"battery"]) {
        NSString *symbol = @"battery.100";
        NSString *battery = BatteryText(&symbol);
        [view setText:battery ?: @"–" forSegment:@"battery"];
        static NSString *shownSymbol;
        if (![symbol isEqualToString:shownSymbol]) { shownSymbol = symbol; [view setSymbol:symbol tint:nil forSegment:@"battery"]; }
    }
}

- (void)openActivityMonitor:(id)sender {
    [NSWorkspace.sharedWorkspace openApplicationAtURL:[NSURL fileURLWithPath:@"/System/Applications/Utilities/Activity Monitor.app"]
                                        configuration:[NSWorkspaceOpenConfiguration configuration] completionHandler:nil];
}

- (void)toggleMouseScroll:(id)sender {
    BOOL on = !SettingBool(@"ReverseMouseScroll", NO);
    gSettings[@"ReverseMouseScroll"] = @(on);
    SaveSettingsNow();
    UpdateScrollReversal(YES);
    [self hud:@"computermouse" text:on ? (ScrollReversalActive() ? @"Mouse Scroll Reversed" : @"Grant Accessibility") : @"Mouse Scroll Natural"];
}

- (void)toggleDesktopStats:(id)sender {
    BOOL on = !SettingBool(@"DesktopStats", YES);
    gSettings[@"DesktopStats"] = @(on);
    SaveSettingsNow();
    if (on) [self frontmostChanged:nil];
    else if (self.presentedBar == self.statsBar) [self hideStats];
}

- (void)toggleKeepStats:(id)sender {
    BOOL on = !SettingBool(@"KeepStatsOpen", YES);
    gSettings[@"KeepStatsOpen"] = @(on);
    SaveSettingsNow();
    [self hud:@"pin" text:on ? @"Stats Stay Open" : @"Stats Close When Interrupted"];
}

- (void)toggleLockPanel:(id)sender {
    BOOL on = !SettingBool(@"LockScreenPanel", YES);
    gSettings[@"LockScreenPanel"] = @(on);
    SaveSettingsNow();
    [self hud:@"lock.rectangle" text:on ? @"Lock Screen Panel On" : @"Lock Screen Panel Off"];
}

- (void)previewPanel:(id)sender {
    [HKStatusPanel.shared show];  // hides itself after 15 s
    static uint64_t generation;
    uint64_t mine = ++generation;
    After(15, ^{ if (mine == generation && !gScreenLocked) [HKStatusPanel.shared hide]; });  // locked meanwhile: it stays
}

- (void)showFanPage:(id)sender {
    [self buildFanPages];
    [self watchVisibility:@[self.fanPage, self.fanCustomPage]];
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

// Blue fan icon in the stats bar = Headless is controlling the fans (not Auto).
- (void)tintFanStat:(NSDictionary *)status {
    [self.statsView setSymbol:@"fan.fill" tint:!status || [status[@"mode"] isEqualToString:@"auto"] ? nil : NSColor.systemBlueColor forSegment:@"fan"];
}

- (void)showFanStatus:(NSDictionary *)status {
    self.fanStatus = status;
    [self tintFanStat:status];
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
    static NSHashTable *watched;
    if (!watched) watched = [NSHashTable weakObjectsHashTable];
    for (NSTouchBar *bar in bars) {
        if ([watched containsObject:bar]) continue;
        [watched addObject:bar];
        [bar addObserver:self forKeyPath:@"visible" options:0 context:(__bridge void *)TrayID];
    }
}

// Secondary pages are built the first time they are opened: most sessions never open
// most of them, and each holds a handful of views and symbol images.
- (void)ensureSliderPages {
    if (self.touchBarPage) return;
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
    [self watchVisibility:@[self.touchBarPage, self.keyboardPage, self.monitorPage]];
}

- (void)ensureDisplayPage {
    if (self.displayBar) return;
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

    [self watchVisibility:@[self.displayBar]];
}

- (NSArray<NSTouchBar *> *)builtBars {
    NSMutableArray *bars = [NSMutableArray array];
    for (NSTouchBar *bar in @[self.mainBar ?: NSNull.null, self.statsBar ?: NSNull.null, self.touchBarPage ?: NSNull.null,
                              self.keyboardPage ?: NSNull.null, self.monitorPage ?: NSNull.null, self.displayBar ?: NSNull.null,
                              self.fanPage ?: NSNull.null, self.fanCustomPage ?: NSNull.null])
        if ([bar isKindOfClass:NSTouchBar.class]) [bars addObject:bar];
    return bars;
}

- (void)present:(NSTouchBar *)bar {
    if (!bar || !self.tray) return;  // no tray item = no Touch Bar (or no private API): menu bar only
    [self registerTray];
    if (self.presentedBar == self.statsBar && bar != self.statsBar) self.closingStatsOurselves = YES;  // replaced, not ✕
    self.presentedBar = bar;
    self.presentedAt = [NSDate date];
    [NSTouchBar presentSystemModalTouchBar:bar systemTrayItemIdentifier:TrayID];
}

- (void)showControls:(id)sender { [self refreshControls]; [self present:self.mainBar]; }
- (void)showMainPage:(id)sender { [self showControls:sender]; }
- (void)showTouchBarPage:(id)sender { [self ensureSliderPages]; [self refreshControls]; [self present:self.touchBarPage]; }
- (void)showKeyboardPage:(id)sender { [self ensureSliderPages]; [self refreshControls]; [self present:self.keyboardPage]; }
- (void)showMonitorPage:(id)sender { [self ensureSliderPages]; [self refreshControls]; [self present:self.monitorPage]; }
- (void)showDisplayPage:(id)sender {
    [self ensureDisplayPage];
    [self refreshControls];
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
        for (NSTouchBar *bar in self.builtBars) if (bar != self.statsBar) [NSTouchBar dismissSystemModalTouchBar:bar];
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
        {HKMonitorUp, kVK_ANSI_Equal}, {HKMonitorDown, kVK_ANSI_Minus}, {HKCycleFans, kVK_ANSI_F}, {HKShowStats, kVK_ANSI_I},
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
        case HKShowStats: [self showStats:nil]; break;
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
    NSMenuItem *scroll = [self menuItem:@"Reverse Mouse Scrolling" action:@selector(toggleMouseScroll:) key:nil symbol:@"computermouse"];
    scroll.state = SettingBool(@"ReverseMouseScroll", NO);
    if (scroll.state && !ScrollReversalActive()) scroll.title = @"Reverse Mouse Scrolling (needs Accessibility)";
    [menu addItem:scroll];
    NSMenuItem *stats = [self menuItem:@"System Stats on Desktop Touch Bar" action:@selector(toggleDesktopStats:) key:nil symbol:@"gauge.with.dots.needle.50percent"];
    stats.state = SettingBool(@"DesktopStats", YES);
    [menu addItem:stats];
    NSMenuItem *keepStats = [self menuItem:@"Keep Stats Open Until ✕" action:@selector(toggleKeepStats:) key:nil symbol:@"pin"];
    keepStats.state = SettingBool(@"KeepStatsOpen", YES);
    [menu addItem:keepStats];
    NSMenuItem *panel = [self menuItem:@"Controls Panel on Lock & Login Screen" action:@selector(toggleLockPanel:) key:nil symbol:@"lock.rectangle"];
    panel.state = SettingBool(@"LockScreenPanel", YES);
    [menu addItem:panel];
    [menu addItem:[self menuItem:@"Preview Lock Screen Panel" action:@selector(previewPanel:) key:nil symbol:@"eye"]];

    [menu addItem:NSMenuItem.separatorItem];
    [menu addItem:[self menuItem:@"Lock Screen" action:@selector(lock:) key:@"l" symbol:@"lock"]];
    [menu addItem:[self menuItem:@"Sleep Display" action:@selector(sleepDisplays:) key:@"s" symbol:@"zzz"]];
    [menu addItem:[self menuItem:@"Show Touch Bar Controls" action:@selector(showControls:) key:@"t" symbol:@"slider.horizontal.3"]];
    [menu addItem:[self menuItem:@"Show System Stats" action:@selector(showStats:) key:@"i" symbol:@"gauge.with.dots.needle.50percent"]];
    [menu addItem:[self menuItem:@"Re-apply Display Settings" action:@selector(reapply:) key:@"h" symbol:@"arrow.clockwise"]];
    NSMenuItem *brightnessKeys = [self menuItem:@"Brightness Keys Control Monitor" action:@selector(toggleBrightnessKeys:) key:nil symbol:@"sun.max"];
    brightnessKeys.state = SettingBool(@"BrightnessKeysControlMonitor", YES);
    [menu addItem:brightnessKeys];
    NSMenuItem *brightnessButton = [self menuItem:@"Replace Control Strip Brightness Button" action:@selector(toggleBrightnessButton:) key:nil symbol:@"sun.max"];
    brightnessButton.state = SettingBool(@"ReplaceBrightnessButton", YES);
    [menu addItem:brightnessButton];
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
        "  lockpanel on|off            controls panel on the lock and login screens\n"
        "  mousescroll reverse|natural  wheel-mouse direction (trackpad unchanged)\n"
        "  fan [auto|smart|max|<rpm>]  fan mode (needs the headless-fand daemon)\n"
        "  fan curve <low°C> <high°C>  smart-mode curve (default 60 90)\n"
        "  modes                       list modes for the external display\n"
        "  mode <index>                switch to a mode from `modes`\n"
        "  lock | sleep-display | show [touchbar|keyboard|monitor|display|fans|stats|panel]\n");
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
        printf("mouse scroll  %s\n", !SettingBool(@"ReverseMouseScroll", NO) ? "natural (system setting)"
               : AXIsProcessTrusted() ? "reversed (see 'Reverse Mouse Scrolling' in the menu if it has no effect)"
               : "reversed - needs Accessibility permission for Headless");
        printf("temperature   %.0f°C (SoC, %lu sensors)\n", SocTemperature(), (unsigned long)SocSensorCount());
        printf("fan speed     %.0f rpm\n", FanRPM());
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
    else if ([cmd isEqualToString:@"lockpanel"] && arg && (on = ParseSwitch(arg)) >= 0) { gSettings[@"LockScreenPanel"] = @(on); SaveSettingsNow(); }
    else if ([cmd isEqualToString:@"mousescroll"] && arg && (!strcmp(arg, "reverse") || !strcmp(arg, "natural"))) {
        gSettings[@"ReverseMouseScroll"] = @(!strcmp(arg, "reverse"));
        SaveSettingsNow();
    }
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
