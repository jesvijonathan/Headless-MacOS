// headless-fand — root fan daemon for Headless.
//
// Modes:  auto    macOS controls the fans (default)
//         smart   temperature curve (Curve.swift): minimum RPM below `low` °C (60), easing up
//                 to maximum at `high` °C (90), from the mean of the 4 hottest SoC sensors
//         custom  fixed RPM
//         max     full blast
//
// Starts at boot (LaunchDaemon), so the mode applies before anyone logs in. Any mode other
// than auto jumps to maximum if macOS reports a serious/critical thermal state, and fans are
// handed back to macOS when the daemon stops.
//
// Talks over /var/run/dev.jesvi.headless.fand.sock, one line per request:
//   status                       → JSON
//   set auto|smart|max           → JSON   (root or admin group only)
//   set custom <rpm>             → JSON
//   curve <low°C> <high°C>       → JSON

import Foundation
import IOKit
import IOKit.pwr_mgt
import os

let log = Logger(subsystem: "dev.jesvi.headless", category: "fand")
let socketPath = ProcessInfo.processInfo.environment["HEADLESS_FAND_SOCKET"] ?? "/var/run/dev.jesvi.headless.fand.sock"
let statePath = "/Library/Application Support/Headless/fan.plist"
let queue = DispatchQueue(label: "fand")
let smc = SMC.shared

// MARK: - Hardware

struct Fan { let id: Int; let min: Double; let max: Double }

let fans: [Fan] = (0..<Int(smc.getValue("FNum") ?? 0)).compactMap { id in
    guard let lo = smc.getValue("F\(id)Mn"), let hi = smc.getValue("F\(id)Mx"), hi > lo else { return nil }
    return Fan(id: id, min: lo, max: hi)
}

// SoC sensors: CPU clusters/cores (Tc, Te, Tp) and GPU (Tg). Chosen once, at start.
let sensorKeys: [String] = smc.getAllKeys().filter { key in
    ["Tc", "Te", "Tp", "Tg"].contains(String(key.prefix(2))) &&
        (smc.getValue(key).map { $0 > 15 && $0 < 125 } ?? false)
}

// Temperature of the busy part of the chip: mean of the 4 hottest SoC sensors (same measure
// as the agent's stats). Only the 8 sensors that were hottest at the last full scan are read
// each tick; every 20th read rescans all of them.
var hotSensors: [String] = []
var readsSinceScan = 0

func hottest() -> Double? {
    var readings: [Double]
    readsSinceScan += 1
    if hotSensors.isEmpty || readsSinceScan >= 20 {
        readsSinceScan = 0
        let all = sensorKeys.compactMap { key in smc.getValue(key).map { (key, $0) } }
            .filter { $0.1 > 15 && $0.1 < 125 }.sorted { $0.1 > $1.1 }.prefix(8)
        hotSensors = all.map { $0.0 }
        readings = all.map { $0.1 }
    } else {
        readings = hotSensors.compactMap { smc.getValue($0) }.filter { $0 > 15 && $0 < 125 }.sorted(by: >)
    }
    guard !readings.isEmpty else { return nil }
    let top = readings.prefix(4)
    return top.reduce(0, +) / Double(top.count)
}

// MARK: - State

struct State: Codable {
    var mode = "auto"
    var custom = 3000.0
    var low = 60.0
    var high = 90.0
}

var state: State = {
    guard let data = FileManager.default.contents(atPath: statePath),
          let saved = try? PropertyListDecoder().decode(State.self, from: data) else { return State() }
    return saved
}()

func save() {
    try? FileManager.default.createDirectory(atPath: (statePath as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    if let data = try? PropertyListEncoder().encode(state) { FileManager.default.createFile(atPath: statePath, contents: data) }
}

var temperature = TemperatureFilter()
var smartTargets: [Int: SmartFanTarget] = [:]   // per fan id; see Curve.swift
var timer: DispatchSourceTimer?
var interval = 3.0
var stableTicks = 0

var thermalEmergency: Bool {
    let t = ProcessInfo.processInfo.thermalState
    return t == .serious || t == .critical
}

// MARK: - Control

// On M1 the fan keeps following F0Tg after the mode flag is cleared, and F0Tg can no longer be
// written once it is. So drop the target to the minimum while still forced, then clear the
// flag: macOS raises the target from there when it needs cooling.
func handBack() {
    for fan in fans {
        if smc.getValue(smc.fanModeKey(fan.id)) == 1 { _ = smc.applyFanTarget(fan.id, Int(fan.min)) }
        smc.setFanMode(fan.id, mode: .automatic)
    }
    _ = smc.resetFanControl()
    smartTargets.removeAll()
}

func tick() {
    if state.mode == "auto" && !thermalEmergency { return }
    let curve = SmartCurve(low: state.low, high: state.high)
    let previous = temperature.value
    let current = state.mode == "smart" ? temperature.add(hottest()) : nil
    var settled = true
    for fan in fans {
        let rpm: Double
        if thermalEmergency || state.mode == "max" {
            rpm = fan.max
        } else if state.mode == "custom" {
            rpm = Swift.min(fan.max, Swift.max(fan.min, state.custom))
        } else {
            var smart = smartTargets[fan.id] ?? SmartFanTarget(minRPM: fan.min, maxRPM: fan.max)
            rpm = smart.next(temperature: current, curve: curve)   // nil temperature → maximum
            if let current { settled = settled && smart.settled(temperature: current, curve: curve) }
            smartTargets[fan.id] = smart
        }
        let target = smc.getValue(smc.fanModeKey(fan.id)) == 1 ? smc.getValue("F\(fan.id)Tg") : nil
        if target == rpm { continue }
        if !smc.applyFanTarget(fan.id, Int(rpm)) {
            smartTargets[fan.id]?.reset()  // retry from scratch next tick
            log.error("Fan \(fan.id): could not apply \(Int(rpm)) RPM")
        }
    }
    // Smart: check every 3 s while the temperature moves or a ramp is in progress; every 6 s
    // once both have settled.
    guard state.mode == "smart" else { return }
    let steady = settled && previous != nil && current != nil && abs(previous! - current!) < 0.5
    stableTicks = steady ? stableTicks + 1 : 0
    let wanted: Double = stableTicks >= 5 ? 6 : 3
    if wanted != interval {
        interval = wanted
        timer?.schedule(deadline: .now() + wanted, repeating: wanted, leeway: .seconds(1))
    }
}

// Smart mode follows temperature every 3–6 s; fixed modes only re-assert every 30 s
// (wake is handled separately). Auto does nothing at all.
func reschedule() {
    timer?.cancel()
    timer = nil
    if state.mode == "auto" && !thermalEmergency {
        handBack()
        return
    }
    interval = state.mode == "smart" ? 3 : 30
    stableTicks = 0
    let source = DispatchSource.makeTimerSource(queue: queue)
    source.schedule(deadline: .now(), repeating: interval, leeway: .seconds(state.mode == "smart" ? 1 : 5))
    source.setEventHandler(handler: tick)
    source.resume()
    timer = source
}

func status() -> String {
    var fanInfo: [[String: Any]] = []
    for fan in fans {
        fanInfo.append(["id": fan.id, "rpm": (smc.getValue("F\(fan.id)Ac") ?? 0).rounded(),
                        "min": fan.min, "max": fan.max])
    }
    let info: [String: Any] = [
        "mode": state.mode, "custom": state.custom, "low": state.low, "high": state.high,
        "temp": ((hottest() ?? 0) * 10).rounded() / 10, "emergency": thermalEmergency, "fans": fanInfo,
    ]
    let data = (try? JSONSerialization.data(withJSONObject: info, options: [.sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self)
}

// MARK: - Requests

func authorized(_ uid: uid_t) -> Bool {
    if uid == 0 { return true }
    guard let pw = getpwuid(uid) else { return false }
    var groups = [gid_t](repeating: 0, count: 64)
    var count = Int32(groups.count)
    getgrouplist(pw.pointee.pw_name, Int32(bitPattern: pw.pointee.pw_gid), &groups, &count)
    let admin = getgrnam("admin")?.pointee.gr_gid
    return groups.prefix(Int(Swift.max(0, count))).contains { $0 == admin }
}

func handle(_ line: String, uid: uid_t) -> String {
    let parts = line.split(separator: " ").map(String.init)
    guard let command = parts.first else { return #"{"error":"empty request"}"# }
    if command == "status" { return status() }
    guard authorized(uid) else { return #"{"error":"only administrators can change fan settings"}"# }
    switch (command, parts.count) {
    case ("set", 2) where ["auto", "smart", "max"].contains(parts[1]):
        state.mode = parts[1]
    case ("set", 3) where parts[1] == "custom":
        guard let rpm = Double(parts[2]), let fan = fans.first, rpm >= fan.min, rpm <= fan.max else {
            return #"{"error":"rpm out of range"}"#
        }
        state.mode = "custom"
        state.custom = rpm.rounded()
    case ("curve", 3):
        guard let lo = Double(parts[1]), let hi = Double(parts[2]), lo >= 30, hi <= 100, hi - lo >= 10 else {
            return #"{"error":"curve must satisfy 30 <= low, high <= 100, high - low >= 10"}"#
        }
        state.low = lo
        state.high = hi
    default:
        return #"{"error":"unknown request"}"#
    }
    save()
    smartTargets.removeAll()
    log.info("Fan mode \(state.mode, privacy: .public) (uid \(uid))")
    reschedule()
    return status()
}

func serve() {
    unlink(socketPath)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let pathCapacity = MemoryLayout.size(ofValue: addr.sun_path)
    withUnsafeMutablePointer(to: &addr.sun_path) {
        $0.withMemoryRebound(to: CChar.self, capacity: pathCapacity) { _ = strlcpy($0, socketPath, pathCapacity) }
    }
    let bound = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0, listen(fd, 8) == 0 else { log.fault("Cannot listen on \(socketPath)"); exit(1) }
    chmod(socketPath, 0o666)  // anyone may ask for status; changes are checked per peer uid
    let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
    source.setEventHandler {
        let client = accept(fd, nil, nil)
        guard client >= 0 else { return }
        var uid: uid_t = 0, gid: gid_t = 0
        getpeereid(client, &uid, &gid)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var buffer = [UInt8](repeating: 0, count: 256)
        let n = read(client, &buffer, buffer.count)
        let line = n > 0 ? String(decoding: buffer[0..<n], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let reply = handle(line, uid: uid) + "\n"
        _ = reply.withCString { write(client, $0, strlen($0)) }
        close(client)
    }
    source.resume()
    sources.append(source)
}
var sources: [DispatchSourceProtocol] = []

// MARK: - Main

// Unprivileged: just report, unless serving a test socket for UI development
// (fan writes then fail harmlessly).
guard geteuid() == 0 || CommandLine.arguments.contains("--serve") else {
    print(status())
    exit(0)
}
guard !fans.isEmpty else { log.info("No controllable fans; exiting"); exit(0) }

for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: sig, queue: queue)
    source.setEventHandler { handBack(); unlink(socketPath); exit(0) }
    source.resume()
    sources.append(source)
}

NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: nil) { _ in
    queue.async { log.info("Thermal state \(ProcessInfo.processInfo.thermalState.rawValue)"); reschedule() }
}

// Re-apply after wake: the SMC may have reset the fan mode while asleep.
// (IOKit's iokit_common_msg() macros are not imported into Swift.)
let kIOMessageCanSystemSleep: UInt32 = 0xE000_0270
let kIOMessageSystemWillSleep: UInt32 = 0xE000_0280
let kIOMessageSystemHasPoweredOn: UInt32 = 0xE000_0300
var powerPort: io_connect_t = 0
var notifyPort: IONotificationPortRef?
var notifier: io_object_t = 0
powerPort = IORegisterForSystemPower(nil, &notifyPort, { _, _, type, argument in
    if type == kIOMessageCanSystemSleep || type == kIOMessageSystemWillSleep {
        IOAllowPowerChange(powerPort, Int(bitPattern: argument))
    } else if type == kIOMessageSystemHasPoweredOn {
        queue.asyncAfter(deadline: .now() + 2) { smartTargets.removeAll(); reschedule() }
    }
}, &notifier)
if let notifyPort { IONotificationPortSetDispatchQueue(notifyPort, queue) }

queue.async {
    log.info("Started: \(fans.count) fan(s), \(sensorKeys.count) sensors, mode \(state.mode, privacy: .public)")
    serve()
    reschedule()
}
dispatchMain()
