// Polling Rate Tester
// Copyright (c) 2026 Taha Hatipoğlu
// Licensed under the MIT License — see the LICENSE file for details.

import SwiftUI
import AppKit
import IOKit.hid

// MARK: - Model types

struct PointerDevice: Identifiable, Hashable {
    let id: UInt64
    let name: String
    let detail: String
    let autoEligible: Bool
    var isMultitouch = false
}

struct Snapshot {
    var medianHz = 0.0      // headline number: 1 / median report interval
    var meanHz = 0.0        // mean of "clean" intervals
    var fastestHz = 0.0     // 1st-percentile interval
    var jitterUs = 0.0      // std-dev of clean intervals
    var skippedPct = 0.0    // intervals much longer than the median (sensor sent nothing)
    var reports = 0
    var samples = 0
    var duplicates = 0      // reports delivered with an identical timestamp
    var source = "—"
}

enum AccessState { case granted, denied, unknown }

// MARK: - HID engine
//
// All measurement state is owned by `hidQueue` (a serial queue), so the report
// callback needs no locks and does almost no work per report.

final class HIDEngine: ObservableObject {
    @Published var access: AccessState = .unknown
    @Published var devices: [PointerDevice] = []
    @Published var selectedID: UInt64? = nil      // nil = auto-detect
    @Published var snapshot = Snapshot()

    private let hidQueue = DispatchQueue(label: "pollingrate.hid", qos: .userInteractive)
    private var manager: IOHIDManager?
    private var mtList: CFArray?
    private var mtStarted = false
    static weak var shared: HIDEngine?
    private var tbNumer = 1.0
    private var tbDenom = 1.0
    private var tickCount = 0

    // Owned by hidQueue
    private var known: [UInt64: PointerDevice] = [:]
    private var filterID: UInt64? = nil
    private var lockedID: UInt64? = nil
    private var sourceName = "—"
    private var lastNs: Double? = nil
    private var intervals: [Double] = []          // nanoseconds, ring buffer
    private var head = 0
    private var totalReports = 0
    private var duplicateStamps = 0
    private let capacity = 4096
    private let gapNs = 50_000_000.0              // >50 ms = pause between movements

    init() {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        tbNumer = Double(tb.numer)
        tbDenom = Double(tb.denom)
        intervals.reserveCapacity(capacity)

        Self.shared = self
        access = Self.currentAccess()
        if access == .unknown { _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent) }
        start()

        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
    }

    // MARK: Permission

    static func currentAccess() -> AccessState {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return .granted
        case kIOHIDAccessTypeDenied:  return .denied
        default:                      return .unknown
        }
    }

    func requestAccess() {
        if Self.currentAccess() == .unknown {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)   // shows the system prompt
        } else {
            openSettings()                                         // prompt only ever appears once
        }
    }

    func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }

    func relaunch() {
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: Manager lifecycle

    private func start() {
        stop()

        let mgr = IOHIDManagerCreate(kCFAllocatorDefault, 0)
        let matching: [[String: Any]] = [
            ["DeviceUsagePage": 0x01, "DeviceUsage": 0x02],          // Generic Desktop · Mouse
            ["DeviceUsagePage": 0x01, "DeviceUsage": 0x01],          // Generic Desktop · Pointer
            ["DeviceUsagePage": 0x0D, "DeviceUsage": 0x05]           // Digitizer · Touch Pad
        ]
        IOHIDManagerSetDeviceMatchingMultiple(mgr, matching as CFArray)

        let ctx = Unmanaged.passUnretained(self).toOpaque()

        IOHIDManagerRegisterDeviceMatchingCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDEngine>.fromOpaque(ctx).takeUnretainedValue().deviceAdded(device)
        }, ctx)

        IOHIDManagerRegisterDeviceRemovalCallback(mgr, { ctx, _, _, device in
            guard let ctx else { return }
            Unmanaged<HIDEngine>.fromOpaque(ctx).takeUnretainedValue().deviceRemoved(device)
        }, ctx)

        // One call per raw input report, with the driver's mach_absolute_time timestamp.
        IOHIDManagerRegisterInputReportWithTimeStampCallback(mgr, { ctx, _, sender, _, _, _, _, ts in
            guard let ctx, let sender else { return }
            Unmanaged<HIDEngine>.fromOpaque(ctx).takeUnretainedValue().handleReport(sender: sender, ts: ts)
        }, ctx)

        IOHIDManagerSetDispatchQueue(mgr, hidQueue)
        IOHIDManagerOpen(mgr, 0)            // listen only — never seizes the device
        IOHIDManagerActivate(mgr)
        manager = mgr
        startMultitouch()
    }

    private func stop() {
        hidQueue.async { [weak self] in
            guard let self else { return }
            self.known = self.known.filter { $0.value.isMultitouch }
            self.resetLocked()
            self.publishDevices()
        }
        guard let mgr = manager else { return }
        manager = nil
        IOHIDManagerSetCancelHandler(mgr) { withExtendedLifetime(mgr) {} }
        IOHIDManagerCancel(mgr)
    }

    // MARK: Device callbacks (hidQueue)

    private static func id(of pointer: UnsafeMutableRawPointer) -> UInt64 {
        UInt64(UInt(bitPattern: pointer))
    }

    private func deviceAdded(_ device: IOHIDDevice) {
        func str(_ k: String) -> String? { IOHIDDeviceGetProperty(device, k as CFString) as? String }
        func int(_ k: String) -> Int?    { IOHIDDeviceGetProperty(device, k as CFString) as? Int }

        let name = str("Product") ?? "Unknown device"
        let transport = str("Transport") ?? "?"
        let vid = int("VendorID") ?? 0
        let pid = int("ProductID") ?? 0
        let detail = String(format: "%@ · %04X:%04X", transport, vid, pid)

        let id = Self.id(of: Unmanaged.passUnretained(device).toOpaque())
        known[id] = PointerDevice(id: id, name: name, detail: detail, autoEligible: true)
        publishDevices()
    }

    private func deviceRemoved(_ device: IOHIDDevice) {
        let id = Self.id(of: Unmanaged.passUnretained(device).toOpaque())
        known.removeValue(forKey: id)
        if filterID == id {
            filterID = nil
            resetLocked()
            DispatchQueue.main.async { self.selectedID = nil }
        } else if lockedID == id {
            resetLocked()
        }
        publishDevices()
    }

    private func publishDevices() {
        let list = known.values.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
        DispatchQueue.main.async { self.devices = list }
    }

    // MARK: Report callbacks — keep these tiny

    private func handleReport(sender: UnsafeMutableRawPointer, ts: UInt64) {
        handleSample(id: Self.id(of: sender), ns: Double(ts) * tbNumer / tbDenom)
    }

    // Runs on hidQueue. `ns` is a monotonic timestamp in nanoseconds.
    fileprivate func handleSample(id: UInt64, ns: Double) {
        if let f = filterID {
            if id != f { return }
        } else if let l = lockedID {
            if id != l { return }
        } else {
            guard let info = known[id], info.autoEligible else { return }
            lockedID = id
            sourceName = info.name
        }

        totalReports += 1
        let previous = lastNs
        lastNs = ns
        guard let last = previous else { return }

        if ns <= last {
            if ns == last { duplicateStamps += 1 }
            return
        }
        let dt = ns - last
        if dt > gapNs { return }                            // pointer was idle, not a polling interval

        if intervals.count < capacity {
            intervals.append(dt)
        } else {
            intervals[head] = dt
            head = (head + 1) % capacity
        }
    }

    fileprivate func enqueueSample(id: UInt64, ns: Double) {
        hidQueue.async { [self] in handleSample(id: id, ns: ns) }
    }

    // MARK: Built-in / Magic trackpads
    //
    // Apple's trackpads don't expose normal HID mouse reports. Their raw sensor frames
    // come from the private MultitouchSupport framework, which we load at runtime.
    // This API is undocumented and could change between macOS versions; if it can't be
    // loaded, the app simply carries on without trackpad support.

    private func startMultitouch() {
        guard !mtStarted else { return }
        guard let lib = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW),
              let createSym = dlsym(lib, "MTDeviceCreateList"),
              let registerSym = dlsym(lib, "MTRegisterContactFrameCallback"),
              let startSym = dlsym(lib, "MTDeviceStart") else { return }

        typealias CreateList = @convention(c) () -> Unmanaged<CFArray>?
        typealias Register = @convention(c) (UnsafeMutableRawPointer, MTCallback) -> Void
        typealias Start = @convention(c) (UnsafeMutableRawPointer, Int32) -> Void
        typealias IsBuiltIn = @convention(c) (UnsafeMutableRawPointer) -> Bool

        let create = unsafeBitCast(createSym, to: CreateList.self)
        let register = unsafeBitCast(registerSym, to: Register.self)
        let start = unsafeBitCast(startSym, to: Start.self)
        let isBuiltIn = dlsym(lib, "MTDeviceIsBuiltIn").map { unsafeBitCast($0, to: IsBuiltIn.self) }

        guard let list = create()?.takeRetainedValue(), CFArrayGetCount(list) > 0 else { return }
        mtList = list                                       // keep the device objects alive

        var found: [PointerDevice] = []
        for i in 0..<CFArrayGetCount(list) {
            guard let raw = CFArrayGetValueAtIndex(list, i) else { continue }
            let dev = UnsafeMutableRawPointer(mutating: raw)
            let builtIn = isBuiltIn?(dev) ?? false
            found.append(PointerDevice(id: Self.id(of: dev),
                                       name: builtIn ? "Built-in Trackpad" : "Trackpad \(i + 1)",
                                       detail: "MultitouchSupport · sensor frame rate",
                                       autoEligible: false,
                                       isMultitouch: true))
            register(dev, mtCallback)
            start(dev, 0)
        }
        mtStarted = true
        hidQueue.async { [self] in
            for d in found { known[d.id] = d }
            publishDevices()
        }
    }

    // MARK: Control

    func select(_ id: UInt64?) {
        selectedID = id
        hidQueue.async { [self] in
            filterID = id
            sourceName = id.flatMap { known[$0]?.name } ?? "—"
            resetLocked()
        }
    }

    func reset() {
        hidQueue.async { [self] in resetLocked() }
    }

    private func resetLocked() {
        lastNs = nil
        intervals.removeAll(keepingCapacity: true)
        head = 0
        totalReports = 0
        duplicateStamps = 0
        if filterID == nil {
            lockedID = nil
            sourceName = "—"
        }
    }

    // MARK: UI refresh (main thread, 10 Hz)

    private func tick() {
        tickCount += 1
        if tickCount % 10 == 0 {
            let now = Self.currentAccess()
            if now != access {
                let was = access
                access = now
                if now == .granted && was != .granted { start() }
            }
        }
        hidQueue.async { [weak self] in
            guard let self else { return }
            let snap = self.makeSnapshot()
            DispatchQueue.main.async { self.snapshot = snap }
        }
    }

    private func makeSnapshot() -> Snapshot {
        var s = Snapshot()
        s.reports = totalReports
        s.duplicates = duplicateStamps
        s.samples = intervals.count
        s.source = sourceName
        guard intervals.count >= 30 else { return s }

        let sorted = intervals.sorted()
        let median = sorted[sorted.count / 2]
        s.medianHz = 1e9 / median
        s.fastestHz = 1e9 / sorted[Int(Double(sorted.count) * 0.01)]

        // "Clean" = not a multiple of the true interval caused by the sensor skipping a report.
        let clean = sorted.filter { $0 <= median * 1.5 }
        let mean = clean.reduce(0, +) / Double(clean.count)
        let variance = clean.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(clean.count)
        s.meanHz = 1e9 / mean
        s.jitterUs = variance.squareRoot() / 1000
        s.skippedPct = 100 * Double(sorted.count - clean.count) / Double(sorted.count)
        return s
    }
}

// MARK: - Multitouch callback (C function pointer, so it can't capture anything)

private typealias MTCallback = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?, Int32, Double, Int32) -> Int32

private func mtCallback(_ device: UnsafeMutableRawPointer?, _ fingers: UnsafeMutableRawPointer?,
                        _ count: Int32, _ timestamp: Double, _ frame: Int32) -> Int32 {
    if let device {
        HIDEngine.shared?.enqueueSample(id: UInt64(UInt(bitPattern: device)), ns: timestamp * 1e9)
    }
    return 0
}

// MARK: - UI

struct ContentView: View {
    @EnvironmentObject var engine: HIDEngine
    private var s: Snapshot { engine.snapshot }

    var body: some View {
        VStack(spacing: 18) {
            if engine.access != .granted { PermissionBanner() }

            devicePicker
            readout
            statsGrid

            Text("Move the pointer quickly and continuously (fast circles work well). Devices only send reports while they are moving or being touched. For a trackpad, pick it in the list and keep a finger moving on it.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            Button("Reset") { engine.reset() }
                .keyboardShortcut("r", modifiers: .command)

            Divider()

            Text("© 2026 Taha Hatipoğlu · MIT License")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 460)
    }

    private var devicePicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Device").font(.caption).foregroundStyle(.secondary)
            Picker("", selection: Binding(get: { engine.selectedID }, set: { engine.select($0) })) {
                Text("Auto-detect (first device that moves)").tag(UInt64?.none)
                ForEach(engine.devices) { d in
                    Text("\(d.name) — \(d.detail)").tag(Optional(d.id))
                }
            }
            .labelsHidden()
            if engine.devices.isEmpty {
                Text(engine.access == .granted
                     ? "No pointing devices found."
                     : "Devices will appear once permission is granted.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if engine.selectedID == nil {
                Text("Measuring: \(s.source)").font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var readout: some View {
        VStack(spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(s.medianHz > 0 ? String(format: "%.0f", s.medianHz) : "—")
                    .font(.system(size: 76, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                Text("Hz").font(.title2).foregroundStyle(.secondary)
            }
            Text(nominalLabel(s.medianHz) ?? (s.samples < 30 ? "Waiting for movement…" : " "))
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            stat("Mean rate", s.meanHz > 0 ? String(format: "%.1f Hz", s.meanHz) : "—")
            stat("Fastest 1%", s.fastestHz > 0 ? String(format: "%.0f Hz", s.fastestHz) : "—")
            stat("Jitter (σ)", s.medianHz > 0 ? String(format: "%.1f µs", s.jitterUs) : "—")
            stat("Skipped intervals", s.medianHz > 0 ? String(format: "%.1f %%", s.skippedPct) : "—")
            stat("Reports", "\(s.reports)")
            stat("Same-timestamp reports", "\(s.duplicates)")
        }
    }

    private func stat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.system(.title3, design: .rounded)).monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }

    private func nominalLabel(_ hz: Double) -> String? {
        guard hz > 0 else { return nil }
        let classes: [Double] = [125, 250, 500, 1000, 2000, 4000, 8000]
        guard let best = classes.min(by: { abs($0 - hz) < abs($1 - hz) }),
              abs(best - hz) / best < 0.10 else { return nil }
        return String(format: "≈ %.0f Hz class", best)
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var engine: HIDEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Input Monitoring permission needed", systemImage: "lock.shield")
                .font(.headline)
            Text(engine.access == .denied
                 ? "Access is currently denied. Enable “Polling Rate Tester” under Privacy & Security → Input Monitoring, then relaunch the app."
                 : "macOS only lets apps read raw device reports after you allow Input Monitoring. Click Request Access and approve the prompt.")
                .font(.callout)
            HStack {
                Button("Request Access") { engine.requestAccess() }
                Button("Open System Settings") { engine.openSettings() }
                Button("Relaunch") { engine.relaunch() }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct PollingRateTesterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var engine = HIDEngine()

    var body: some Scene {
        WindowGroup("Polling Rate Tester") {
            ContentView().environmentObject(engine)
        }
        .windowResizability(.contentSize)
    }
}
