import AppKit
import Foundation
import IOKit.pwr_mgt
import ServiceManagement
import Darwin.Mach

enum AppMeta {
    static let appName = "Nope-Sleep Mac"
    static let shortName = "N.S.M."
    static let supportFolder = "NopeSleepMac"
    static let launchLabel = "com.nope_sleep_mac.autostart"
    static let diagnosticsPrefix = "NSM-diagnostics"
}

extension Notification.Name {
    static let nsmEventLogUpdated = Notification.Name("NSMEventLogUpdated")
}

final class EventLog {
    static let shared = EventLog()

    private let formatter: ISO8601DateFormatter
    private let maxEntries = 2000
    private let queue = DispatchQueue(label: "com.nope_sleep_mac.eventlog", qos: .utility)
    private var entries: [String] = []
    let fileURL: URL

    private init() {
        formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDirectory = appSupport.appendingPathComponent(AppMeta.supportFolder, isDirectory: true)
        fileURL = logDirectory.appendingPathComponent("events.log", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            // Best effort.
        }

        if let data = try? Data(contentsOf: fileURL),
           let text = String(data: data, encoding: .utf8) {
            entries = Array(text.split(whereSeparator: \.isNewline).map(String.init).suffix(maxEntries))
        }
    }

    func snapshot() -> [String] {
        queue.sync { entries }
    }

    func add(_ message: String) {
        let entry = "[\(formatter.string(from: Date()))] \(message)"

        let writeError: Error? = queue.sync {
            entries.append(entry)
            if entries.count > maxEntries {
                entries.removeFirst(entries.count - maxEntries)
            }
            return syncToDiskLocked()
        }

        if let writeError {
            NSLog("NSM log write error: \(writeError.localizedDescription)")
        }

        postUpdateNotification()
    }

    func clear() {
        let writeError: Error? = queue.sync {
            entries.removeAll()
            return syncToDiskLocked()
        }

        if let writeError {
            add("Failed to clear event history: \(writeError.localizedDescription)")
            return
        }

        postUpdateNotification()
    }

    private func syncToDiskLocked() -> Error? {
        do {
            try entries.joined(separator: "\n").write(to: fileURL, atomically: true, encoding: .utf8)
            return nil
        } catch {
            return error
        }
    }

    private func postUpdateNotification() {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .nsmEventLogUpdated, object: nil)
        }
    }
}

struct AppState {
    var launchAtBoot: Bool
    var serviceEnabled: Bool
    var preventSleep: Bool
    var timerMinutes: Int?
    var timerEndDate: Date?
    var autoReenableAfterWake: Bool
    var serviceWatchdogEnabled: Bool
    var shutdownTimerMinutes: Int?
    var shutdownEndDate: Date?
    var enableAtDate: Date?
    var disableAtDate: Date?
    var wakeScheduleDate: Date?
}

final class AppStateStore {
    private enum Key {
        static let launchAtBoot = "launchAtBoot"
        static let serviceEnabled = "serviceEnabled"
        static let preventSleep = "preventSleep"
        static let timerMinutes = "timerMinutes"
        static let timerEndDate = "timerEndDate"
        static let autoReenableAfterWake = "autoReenableAfterWake"
        static let serviceWatchdogEnabled = "serviceWatchdogEnabled"
        static let shutdownTimerMinutes = "shutdownTimerMinutes"
        static let shutdownEndDate = "shutdownEndDate"
        static let enableAtDate = "enableAtDate"
        static let disableAtDate = "disableAtDate"
        static let wakeScheduleDate = "wakeScheduleDate"
    }

    private let defaults = UserDefaults.standard

    func load() -> AppState {
        AppState(
            launchAtBoot: defaults.object(forKey: Key.launchAtBoot) as? Bool ?? true,
            serviceEnabled: defaults.object(forKey: Key.serviceEnabled) as? Bool ?? true,
            preventSleep: defaults.object(forKey: Key.preventSleep) as? Bool ?? true,
            timerMinutes: defaults.object(forKey: Key.timerMinutes) as? Int,
            timerEndDate: defaults.object(forKey: Key.timerEndDate) as? Date,
            autoReenableAfterWake: defaults.object(forKey: Key.autoReenableAfterWake) as? Bool ?? true,
            serviceWatchdogEnabled: defaults.object(forKey: Key.serviceWatchdogEnabled) as? Bool ?? true,
            shutdownTimerMinutes: defaults.object(forKey: Key.shutdownTimerMinutes) as? Int,
            shutdownEndDate: defaults.object(forKey: Key.shutdownEndDate) as? Date,
            enableAtDate: defaults.object(forKey: Key.enableAtDate) as? Date,
            disableAtDate: defaults.object(forKey: Key.disableAtDate) as? Date,
            wakeScheduleDate: defaults.object(forKey: Key.wakeScheduleDate) as? Date
        )
    }

    func save(_ state: AppState) {
        defaults.set(state.launchAtBoot, forKey: Key.launchAtBoot)
        defaults.set(state.serviceEnabled, forKey: Key.serviceEnabled)
        defaults.set(state.preventSleep, forKey: Key.preventSleep)
        defaults.set(state.autoReenableAfterWake, forKey: Key.autoReenableAfterWake)
        defaults.set(state.serviceWatchdogEnabled, forKey: Key.serviceWatchdogEnabled)

        setOptional(state.timerMinutes, key: Key.timerMinutes)
        setOptional(state.timerEndDate, key: Key.timerEndDate)
        setOptional(state.shutdownTimerMinutes, key: Key.shutdownTimerMinutes)
        setOptional(state.shutdownEndDate, key: Key.shutdownEndDate)
        setOptional(state.enableAtDate, key: Key.enableAtDate)
        setOptional(state.disableAtDate, key: Key.disableAtDate)
        setOptional(state.wakeScheduleDate, key: Key.wakeScheduleDate)
    }

    private func setOptional(_ value: Int?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    private func setOptional(_ value: Date?, key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}

final class SleepBlocker {
    private var noIdleSleepAssertionID: IOPMAssertionID = 0
    private var noDisplaySleepAssertionID: IOPMAssertionID = 0

    private(set) var isActive = false

    @discardableResult
    func activate(reason: String) -> Bool {
        if isActive {
            return true
        }

        let idleResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoIdleSleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &noIdleSleepAssertionID
        )

        let displayResult = IOPMAssertionCreateWithName(
            kIOPMAssertionTypeNoDisplaySleep as CFString,
            IOPMAssertionLevel(kIOPMAssertionLevelOn),
            reason as CFString,
            &noDisplaySleepAssertionID
        )

        if idleResult == kIOReturnSuccess && displayResult == kIOReturnSuccess {
            isActive = true
            EventLog.shared.add("Sleep prevention enabled.")
            return true
        }

        if idleResult == kIOReturnSuccess {
            IOPMAssertionRelease(noIdleSleepAssertionID)
            noIdleSleepAssertionID = 0
        }
        if displayResult == kIOReturnSuccess {
            IOPMAssertionRelease(noDisplaySleepAssertionID)
            noDisplaySleepAssertionID = 0
        }

        EventLog.shared.add("Failed to enable sleep prevention. idle=\(idleResult), display=\(displayResult)")
        return false
    }

    func deactivate() {
        guard isActive else {
            return
        }

        IOPMAssertionRelease(noIdleSleepAssertionID)
        IOPMAssertionRelease(noDisplaySleepAssertionID)
        noIdleSleepAssertionID = 0
        noDisplaySleepAssertionID = 0
        isActive = false
        EventLog.shared.add("Sleep prevention disabled.")
    }

    deinit {
        deactivate()
    }
}

struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

enum CommandRunner {
    static func run(_ executable: String, args: [String]) -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CommandResult(status: -1, stdout: "", stderr: error.localizedDescription)
        }

        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""

        return CommandResult(status: process.terminationStatus, stdout: out, stderr: err)
    }

    static func runPrivilegedShell(_ command: String) -> CommandResult {
        run(
            "/usr/bin/osascript",
            args: [
                "-e", "on run argv",
                "-e", "set theCmd to item 1 of argv",
                "-e", "do shell script theCmd with administrator privileges",
                "-e", "end run",
                command
            ]
        )
    }
}

struct ResourceSnapshot {
    let cpuText: String
    let memoryText: String
    let diskText: String
    let batteryText: String
    let wifiText: String
    let bluetoothText: String
    let uptimeText: String
}

final class ResourceMonitor {
    private let byteFormatter: ByteCountFormatter
    private var previousCpuTicks: [UInt32]?
    private var cachedWiFiInterface: String?

    init() {
        byteFormatter = ByteCountFormatter()
        byteFormatter.countStyle = .binary
        byteFormatter.allowedUnits = [.useGB, .useMB]
        byteFormatter.includesUnit = true
        byteFormatter.isAdaptive = true
    }

    func sample() -> ResourceSnapshot {
        let cpuText = cpuUsageText()
        let memoryText = memoryUsageText()
        let diskText = diskUsageText()
        let batteryText = batteryStatusText()
        let wifiText = wifiStatusText()
        let bluetoothText = bluetoothStatusText()
        let uptimeText = uptimeTextValue()

        return ResourceSnapshot(
            cpuText: cpuText,
            memoryText: memoryText,
            diskText: diskText,
            batteryText: batteryText,
            wifiText: wifiText,
            bluetoothText: bluetoothText,
            uptimeText: uptimeText
        )
    }

    func wifiStatusText() -> String {
        guard let interface = wifiInterface() else {
            return "Unavailable"
        }

        let result = CommandRunner.run("/usr/sbin/networksetup", args: ["-getairportpower", interface])
        if result.status != 0 {
            return "Unknown"
        }

        let lower = result.stdout.lowercased()
        if lower.contains("on") {
            return "On (\(interface))"
        }
        if lower.contains("off") {
            return "Off (\(interface))"
        }
        return "Unknown"
    }

    func bluetoothStatusText() -> String {
        let result = CommandRunner.run(
            "/usr/bin/defaults",
            args: ["read", "/Library/Preferences/com.apple.Bluetooth", "ControllerPowerState"]
        )

        if result.status == 0 {
            let value = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if value == "1" {
                return "On"
            }
            if value == "0" {
                return "Off"
            }
        }

        return "Unknown"
    }

    @discardableResult
    func setWiFiEnabled(_ enabled: Bool) -> Bool {
        guard let interface = wifiInterface() else {
            EventLog.shared.add("Wi-Fi interface not found.")
            return false
        }

        let stateText = enabled ? "on" : "off"
        let command = "/usr/sbin/networksetup -setairportpower \(interface) \(stateText)"
        let result = CommandRunner.runPrivilegedShell(command)

        if result.status == 0 {
            EventLog.shared.add("Wi-Fi turned \(enabled ? "on" : "off").")
            return true
        }

        let errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.add("Failed to change Wi-Fi power: \(errorText.isEmpty ? "unknown error" : errorText)")
        return false
    }

    @discardableResult
    func setBluetoothEnabled(_ enabled: Bool) -> Bool {
        let value = enabled ? "1" : "0"
        let command = "/usr/bin/defaults write /Library/Preferences/com.apple.Bluetooth ControllerPowerState -int \(value); /usr/bin/killall -HUP blued >/dev/null 2>&1 || true"
        let result = CommandRunner.runPrivilegedShell(command)

        if result.status == 0 {
            EventLog.shared.add("Bluetooth set to \(enabled ? "on" : "off") (best effort).")
            return true
        }

        let errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.add("Failed to change Bluetooth state: \(errorText.isEmpty ? "unknown error" : errorText)")
        return false
    }

    private func cpuUsageText() -> String {
        guard let ticks = readCPUTicks() else {
            return "CPU: N/A"
        }

        defer { previousCpuTicks = ticks }

        guard let previous = previousCpuTicks else {
            return "CPU: measuring..."
        }

        func delta(_ index: Int) -> Double {
            Double(Int64(ticks[index]) - Int64(previous[index]))
        }

        let user = max(0, delta(Int(CPU_STATE_USER)))
        let system = max(0, delta(Int(CPU_STATE_SYSTEM)))
        let nice = max(0, delta(Int(CPU_STATE_NICE)))
        let idle = max(0, delta(Int(CPU_STATE_IDLE)))

        let total = user + system + nice + idle
        guard total > 0 else {
            return "CPU: N/A"
        }

        let usage = ((user + system + nice) / total) * 100.0
        return String(format: "CPU: %.1f%%", usage)
    }

    private func readCPUTicks() -> [UInt32]? {
        var cpuInfo = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result = withUnsafeMutablePointer(to: &cpuInfo) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        return [cpuInfo.cpu_ticks.0, cpuInfo.cpu_ticks.1, cpuInfo.cpu_ticks.2, cpuInfo.cpu_ticks.3]
    }

    private func memoryUsageText() -> String {
        guard let memory = memoryUsage() else {
            return "Memory: N/A"
        }

        let usedText = byteFormatter.string(fromByteCount: Int64(memory.used))
        let totalText = byteFormatter.string(fromByteCount: Int64(memory.total))

        return "Memory: \(usedText) / \(totalText)"
    }

    private func memoryUsage() -> (used: Double, total: Double)? {
        let total = Double(ProcessInfo.processInfo.physicalMemory)

        var vmStat = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let host = mach_host_self()

        let result = withUnsafeMutablePointer(to: &vmStat) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(host, HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else {
            return nil
        }

        var pageSize: vm_size_t = 0
        host_page_size(host, &pageSize)

        let freePages = Double(vmStat.free_count + vmStat.speculative_count)
        let free = freePages * Double(pageSize)
        let used = max(0, total - free)

        return (used, total)
    }

    private func diskUsageText() -> String {
        do {
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: NSHomeDirectory())
            let total = (attrs[.systemSize] as? NSNumber)?.doubleValue ?? 0
            let free = (attrs[.systemFreeSize] as? NSNumber)?.doubleValue ?? 0
            let used = max(0, total - free)

            let usedText = byteFormatter.string(fromByteCount: Int64(used))
            let totalText = byteFormatter.string(fromByteCount: Int64(total))

            return "Disk: \(usedText) / \(totalText)"
        } catch {
            return "Disk: N/A"
        }
    }

    private func batteryStatusText() -> String {
        let result = CommandRunner.run("/usr/bin/pmset", args: ["-g", "batt"])
        guard result.status == 0 else {
            return "Battery: N/A"
        }

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        if let detail = lines.dropFirst().first(where: { $0.contains("%") }) {
            return "Battery: \(detail)"
        }

        return "Battery: N/A"
    }

    private func uptimeTextValue() -> String {
        let uptime = Int(ProcessInfo.processInfo.systemUptime)
        let hours = uptime / 3600
        let minutes = (uptime % 3600) / 60
        return "Uptime: \(hours)h \(minutes)m"
    }

    private func wifiInterface() -> String? {
        if let cachedWiFiInterface {
            return cachedWiFiInterface
        }

        let result = CommandRunner.run("/usr/sbin/networksetup", args: ["-listallhardwareports"])
        guard result.status == 0 else {
            return nil
        }

        let lines = result.stdout.split(whereSeparator: \.isNewline).map(String.init)
        var foundWiFi = false

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let lower = line.lowercased()

            if lower.hasPrefix("hardware port:") {
                foundWiFi = lower.contains("wi-fi") || lower.contains("wifi")
                continue
            }

            if foundWiFi, lower.hasPrefix("device:") {
                let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2 else {
                    continue
                }

                let device = parts[1].trimmingCharacters(in: .whitespaces)
                if !device.isEmpty {
                    cachedWiFiInterface = device
                    return device
                }
            }
        }

        return nil
    }
}

final class PowerScheduler {
    private let pmsetDateFormatter: DateFormatter

    init() {
        pmsetDateFormatter = DateFormatter()
        pmsetDateFormatter.dateFormat = "MM/dd/yy HH:mm:ss"
        pmsetDateFormatter.locale = Locale(identifier: "en_US_POSIX")
        pmsetDateFormatter.timeZone = .current
    }

    @discardableResult
    func scheduleWakeOrPowerOn(at date: Date) -> Bool {
        let dateText = pmsetDateFormatter.string(from: date)
        let command = "/usr/bin/pmset schedule wakeorpoweron \"\(dateText)\""
        let result = CommandRunner.runPrivilegedShell(command)

        if result.status == 0 {
            EventLog.shared.add("Wake/Power On scheduled for \(Self.userFacingDate(date)).")
            return true
        }

        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.add("Failed to schedule Wake/Power On: \(msg.isEmpty ? "unknown error" : msg)")
        return false
    }

    @discardableResult
    func cancelWakeOrPowerOn() -> Bool {
        let result = CommandRunner.runPrivilegedShell("/usr/bin/pmset schedule cancel wakeorpoweron")

        if result.status == 0 {
            EventLog.shared.add("Wake/Power On schedule canceled.")
            return true
        }

        let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.add("Failed to cancel Wake/Power On schedule: \(msg.isEmpty ? "unknown error" : msg)")
        return false
    }

    func readScheduleText() -> String {
        let result = CommandRunner.run("/usr/bin/pmset", args: ["-g", "sched"])
        if result.status != 0 {
            return "pmset -g sched failed: \(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "(no schedule output)" : output
    }

    static func userFacingDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .medium
        formatter.timeZone = .current
        return formatter.string(from: date)
    }
}

final class LaunchAtBootManager {
    private let fileManager = FileManager.default

    private var appBundlePath: String {
        Bundle.main.bundlePath
    }

    private var launchAgentURL: URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(AppMeta.launchLabel).plist", isDirectory: false)
    }

    private var logOutPath: String {
        "\(NSHomeDirectory())/Library/Logs/NopeSleepMac.launchd.out.log"
    }

    private var logErrPath: String {
        "\(NSHomeDirectory())/Library/Logs/NopeSleepMac.launchd.err.log"
    }

    func isEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            if SMAppService.mainApp.status == .enabled {
                return true
            }
        }

        return fileManager.fileExists(atPath: launchAgentURL.path)
    }

    @discardableResult
    func setEnabled(_ enabled: Bool) -> Bool {
        if enabled && !isInstallPathValid() {
            EventLog.shared.add("Launch at boot requires app in /Applications or ~/Applications.")
            return false
        }

        if #available(macOS 13.0, *) {
            do {
                if enabled {
                    try SMAppService.mainApp.register()
                    removeLaunchAgentFileOnly()
                    EventLog.shared.add("Launch at boot enabled.")
                } else {
                    try SMAppService.mainApp.unregister()
                    _ = disableWithLaunchAgent(logChange: false)
                    EventLog.shared.add("Launch at boot disabled.")
                }
                return true
            } catch {
                EventLog.shared.add("SMAppService update failed: \(error.localizedDescription). Using LaunchAgent fallback.")
            }
        }

        return enabled ? enableWithLaunchAgent(logChange: true) : disableWithLaunchAgent(logChange: true)
    }

    private func isInstallPathValid() -> Bool {
        if appBundlePath.hasPrefix("/Applications/") {
            return true
        }

        let userApps = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Applications", isDirectory: true)
            .path

        return appBundlePath.hasPrefix("\(userApps)/")
    }

    private func enableWithLaunchAgent(logChange: Bool) -> Bool {
        let launchAgentsDir = launchAgentURL.deletingLastPathComponent()
        let logsDir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Logs", isDirectory: true)

        do {
            try fileManager.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: logsDir, withIntermediateDirectories: true)
        } catch {
            EventLog.shared.add("Failed to create LaunchAgent directories: \(error.localizedDescription)")
            return false
        }

        let plist: [String: Any] = [
            "Label": AppMeta.launchLabel,
            "ProgramArguments": ["/usr/bin/open", appBundlePath],
            "RunAtLoad": true,
            "KeepAlive": false,
            "LimitLoadToSessionType": ["Aqua"],
            "StandardOutPath": logOutPath,
            "StandardErrorPath": logErrPath
        ]

        do {
            let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: launchAgentURL, options: .atomic)
        } catch {
            EventLog.shared.add("Failed to write LaunchAgent plist: \(error.localizedDescription)")
            return false
        }

        let uid = getuid()
        let bootstrapStatus = runLaunchctl(["bootstrap", "gui/\(uid)", launchAgentURL.path], quietOnFailure: true)
        _ = runLaunchctl(["kickstart", "-k", "gui/\(uid)/\(AppMeta.launchLabel)"], quietOnFailure: true)

        if bootstrapStatus != 0 {
            let printStatus = runLaunchctl(["print", "gui/\(uid)/\(AppMeta.launchLabel)"], quietOnFailure: true)
            if printStatus != 0 {
                EventLog.shared.add("Failed to load LaunchAgent (status \(bootstrapStatus)).")
                return false
            }
        }

        if logChange {
            EventLog.shared.add("Launch at boot enabled.")
        }

        return true
    }

    private func disableWithLaunchAgent(logChange: Bool) -> Bool {
        let uid = getuid()
        _ = runLaunchctl(["bootout", "gui/\(uid)/\(AppMeta.launchLabel)"], quietOnFailure: true)
        removeLaunchAgentFileOnly()

        if logChange {
            EventLog.shared.add("Launch at boot disabled.")
        }

        return true
    }

    private func removeLaunchAgentFileOnly() {
        if fileManager.fileExists(atPath: launchAgentURL.path) {
            try? fileManager.removeItem(at: launchAgentURL)
        }
    }

    @discardableResult
    private func runLaunchctl(_ args: [String], quietOnFailure: Bool) -> Int32 {
        let result = CommandRunner.run("/bin/launchctl", args: args)

        if result.status != 0 && !quietOnFailure {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            if !msg.isEmpty {
                EventLog.shared.add("launchctl failed (\(args.joined(separator: " "))): \(msg)")
            }
        }

        return result.status
    }
}

final class BackgroundServiceController {
    let serviceLogURL: URL
    private var process: Process?
    private var suppressedTerminationPIDs: Set<pid_t> = []

    var onUnexpectedTermination: ((Int32, String) -> Void)?

    init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let logDirectory = appSupport.appendingPathComponent(AppMeta.supportFolder, isDirectory: true)
        serviceLogURL = logDirectory.appendingPathComponent("service.log", isDirectory: false)

        do {
            try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        } catch {
            // Best effort.
        }
    }

    var isRunning: Bool {
        process?.isRunning ?? false
    }

    @discardableResult
    func start() -> Bool {
        if isRunning {
            return true
        }

        guard let scriptPath = Bundle.main.path(forResource: "service-worker", ofType: "sh") else {
            EventLog.shared.add("Background service script missing from app bundle.")
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [
            scriptPath,
            serviceLogURL.path,
            String(ProcessInfo.processInfo.processIdentifier)
        ]

        let stderrPipe = Pipe()
        process.standardError = stderrPipe

        process.terminationHandler = { [weak self] proc in
            DispatchQueue.main.async {
                guard let self else {
                    return
                }

                let pid = proc.processIdentifier
                let suppressed = self.suppressedTerminationPIDs.remove(pid) != nil

                if self.process === proc {
                    self.process = nil
                }

                if suppressed {
                    return
                }

                let details = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let trimmed = details.trimmingCharacters(in: .whitespacesAndNewlines)

                if proc.terminationReason == .exit && proc.terminationStatus == 0 {
                    EventLog.shared.add("Background service exited cleanly.")
                } else if trimmed.isEmpty {
                    EventLog.shared.add("Background service exited with code \(proc.terminationStatus).")
                } else {
                    EventLog.shared.add("Background service exited with code \(proc.terminationStatus): \(trimmed)")
                }

                self.onUnexpectedTermination?(proc.terminationStatus, trimmed)
            }
        }

        do {
            try process.run()
            self.process = process
            EventLog.shared.add("Background service enabled.")
            return true
        } catch {
            EventLog.shared.add("Failed to start background service: \(error.localizedDescription)")
            return false
        }
    }

    func stop() {
        guard let process else {
            return
        }

        if process.isRunning {
            suppressedTerminationPIDs.insert(process.processIdentifier)
            process.terminate()
        }

        self.process = nil
        EventLog.shared.add("Background service disabled.")
    }

    @discardableResult
    func restart() -> Bool {
        stop()
        return start()
    }
}

enum DiagnosticsBuilder {
    static func build(
        state: AppState,
        serviceRunning: Bool,
        sleepActive: Bool,
        launchAtBootEnabled: Bool,
        eventLogURL: URL,
        serviceLogURL: URL,
        wakeScheduleText: String
    ) -> String {
        var lines: [String] = []

        let now = ISO8601DateFormatter().string(from: Date())
        let bundle = Bundle.main

        lines.append("\(AppMeta.shortName) Diagnostics")
        lines.append("Generated: \(now)")
        lines.append("Bundle ID: \(bundle.bundleIdentifier ?? "unknown")")
        lines.append("Version: \(bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown")")
        lines.append("Build: \(bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown")")
        lines.append("")

        lines.append("State")
        lines.append("- launchAtBoot: \(state.launchAtBoot)")
        lines.append("- launchAtBootEffective: \(launchAtBootEnabled)")
        lines.append("- serviceEnabled: \(state.serviceEnabled)")
        lines.append("- serviceRunning: \(serviceRunning)")
        lines.append("- preventSleep: \(state.preventSleep)")
        lines.append("- sleepAssertionActive: \(sleepActive)")
        lines.append("- autoReenableAfterWake: \(state.autoReenableAfterWake)")
        lines.append("- serviceWatchdogEnabled: \(state.serviceWatchdogEnabled)")
        lines.append("- sleepTimerEnd: \(state.timerEndDate.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("- shutdownTimerEnd: \(state.shutdownEndDate.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("- enableAtDate: \(state.enableAtDate.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("- disableAtDate: \(state.disableAtDate.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("- wakeScheduleDate: \(state.wakeScheduleDate.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("")

        lines.append("pmset -g assertions")
        lines.append(runCommand("/usr/bin/pmset", ["-g", "assertions"]))
        lines.append("")

        lines.append("pmset -g sched")
        lines.append(wakeScheduleText)
        lines.append("")

        lines.append("Recent Event Log")
        lines.append(tailFile(eventLogURL, maxLines: 60))
        lines.append("")

        lines.append("Recent Service Log")
        lines.append(tailFile(serviceLogURL, maxLines: 60))

        return lines.joined(separator: "\n")
    }

    private static func runCommand(_ executable: String, _ args: [String]) -> String {
        let result = CommandRunner.run(executable, args: args)
        if result.status != 0 {
            let err = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Command failed (status \(result.status)): \(err)"
        }

        let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return output.isEmpty ? "(no output)" : output
    }

    private static func tailFile(_ url: URL, maxLines: Int) -> String {
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            return "(no log file)"
        }

        let lines = text.split(whereSeparator: \.isNewline).map(String.init)
        if lines.isEmpty {
            return "(log empty)"
        }

        return lines.suffix(maxLines).joined(separator: "\n")
    }
}

enum PowerProfile: String {
    case diamond
    case powerPlus
    case batteryPlus
    case offGrid
    case restoreConnectivity
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let stateStore = AppStateStore()
    private let launchAtBootManager = LaunchAtBootManager()
    private let powerScheduler = PowerScheduler()
    private let serviceController = BackgroundServiceController()
    private let blocker = SleepBlocker()
    private let resourceMonitor = ResourceMonitor()

    private var state: AppState

    private var sleepTimer: Timer?
    private var shutdownTimer: Timer?
    private var enableProtectionTimer: Timer?
    private var disableProtectionTimer: Timer?
    private var monitorTimer: Timer?

    private var restartTimestamps: [Date] = []
    private var isTerminating = false

    private var statusItem: NSStatusItem?
    private var desktopWindow: NSWindow?
    private var desktopStatusTextView: NSTextView?
    private var desktopServiceButton: NSButton?
    private var desktopSleepButton: NSButton?

    private let titleItem = NSMenuItem(title: AppMeta.shortName, action: nil, keyEquivalent: "")
    private let openDesktopModeItem = NSMenuItem(title: "Open N.S.M. Desktop Experience", action: #selector(openDesktopExperience), keyEquivalent: "")

    private let resourceItem = NSMenuItem(title: "Mini Resource Monitor", action: nil, keyEquivalent: "")
    private let resourceMenu = NSMenu(title: "Mini Resource Monitor")
    private let resourceCPUItem = NSMenuItem(title: "CPU: --", action: nil, keyEquivalent: "")
    private let resourceMemoryItem = NSMenuItem(title: "Memory: --", action: nil, keyEquivalent: "")
    private let resourceDiskItem = NSMenuItem(title: "Disk: --", action: nil, keyEquivalent: "")
    private let resourceBatteryItem = NSMenuItem(title: "Battery: --", action: nil, keyEquivalent: "")
    private let resourceWiFiItem = NSMenuItem(title: "Wi-Fi: --", action: nil, keyEquivalent: "")
    private let resourceBluetoothItem = NSMenuItem(title: "Bluetooth: --", action: nil, keyEquivalent: "")
    private let resourceUptimeItem = NSMenuItem(title: "Uptime: --", action: nil, keyEquivalent: "")

    private let serviceToggleItem = NSMenuItem(title: "Enable Service", action: #selector(toggleService), keyEquivalent: "")
    private let sleepToggleItem = NSMenuItem(title: "Prevent Sleep", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    private let autoWakeToggleItem = NSMenuItem(title: "Auto-Reenable After Wake", action: #selector(toggleAutoReenableAfterWake), keyEquivalent: "")
    private let watchdogToggleItem = NSMenuItem(title: "Service Watchdog", action: #selector(toggleServiceWatchdog), keyEquivalent: "")

    private let sleepTimerItem = NSMenuItem(title: "Sleep Timer", action: nil, keyEquivalent: "")
    private let sleepTimerMenu = NSMenu(title: "Sleep Timer")
    private var sleepTimerOptionItems: [Int: NSMenuItem] = [:]

    private let scheduledActionsItem = NSMenuItem(title: "Scheduled Actions", action: nil, keyEquivalent: "")
    private let scheduledActionsMenu = NSMenu(title: "Scheduled Actions")

    private let shutdownTimerItem = NSMenuItem(title: "Shutdown Timer", action: nil, keyEquivalent: "")
    private let shutdownTimerMenu = NSMenu(title: "Shutdown Timer")
    private var shutdownTimerOptionItems: [Int: NSMenuItem] = [:]

    private let wakeScheduleInfoItem = NSMenuItem(title: "Wake/Power On: Not Scheduled", action: nil, keyEquivalent: "")
    private let enableScheduleInfoItem = NSMenuItem(title: "Enable Protection: Not Scheduled", action: nil, keyEquivalent: "")
    private let disableScheduleInfoItem = NSMenuItem(title: "Disable Protection: Not Scheduled", action: nil, keyEquivalent: "")

    private let launchAtBootItem = NSMenuItem(title: "Launch at Boot", action: #selector(toggleLaunchAtBoot), keyEquivalent: "")
    private let restartServiceItem = NSMenuItem(title: "Restart Service", action: #selector(restartService), keyEquivalent: "")

    private let profileItem = NSMenuItem(title: "Power Profiles", action: nil, keyEquivalent: "")
    private let profileMenu = NSMenu(title: "Power Profiles")

    private let runSelfTestItem = NSMenuItem(title: "Run Self-Test", action: #selector(runSelfTest), keyEquivalent: "")
    private let copyStatusItem = NSMenuItem(title: "Copy Status", action: #selector(copyStatusToClipboard), keyEquivalent: "")
    private let exportDiagnosticsItem = NSMenuItem(title: "Export Diagnostics", action: #selector(exportDiagnostics), keyEquivalent: "")

    private let recentEventsItem = NSMenuItem(title: "Recent Events", action: nil, keyEquivalent: "")
    private let recentEventsMenu = NSMenu(title: "Recent Events")

    private let sleepTimerOptions: [Int] = [30, 60, 120, 240]
    private let shutdownTimerOptions: [Int] = [15, 30, 60, 120]

    private var workspaceObservers: [NSObjectProtocol] = []
    private var distributedObservers: [NSObjectProtocol] = []
    private var logObserver: NSObjectProtocol?

    override init() {
        self.state = stateStore.load()
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.setActivationPolicy(.accessory)

        buildStatusItem()
        registerSystemObservers()
        registerLogObserver()
        startMonitorTimer()

        serviceController.onUnexpectedTermination = { [weak self] status, details in
            self?.handleUnexpectedServiceTermination(status: status, details: details)
        }

        synchronizeLaunchAtBootState()
        applyStateOnLaunch()
        refreshMenuState()

        EventLog.shared.add("\(AppMeta.shortName) launched.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        EventLog.shared.add("\(AppMeta.shortName) is terminating.")

        sleepTimer?.invalidate()
        shutdownTimer?.invalidate()
        enableProtectionTimer?.invalidate()
        disableProtectionTimer?.invalidate()
        monitorTimer?.invalidate()

        serviceController.stop()
        blocker.deactivate()
    }

    private func buildStatusItem() {
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem.button {
            if #available(macOS 11.0, *) {
                button.image = NSImage(systemSymbolName: "moon.zzz.fill", accessibilityDescription: AppMeta.shortName)
            }
            button.title = ""
            button.imagePosition = .imageOnly
            button.toolTip = AppMeta.appName
        }

        titleItem.isEnabled = false
        wakeScheduleInfoItem.isEnabled = false
        enableScheduleInfoItem.isEnabled = false
        disableScheduleInfoItem.isEnabled = false

        buildResourceMenu()

        openDesktopModeItem.target = self
        serviceToggleItem.target = self
        sleepToggleItem.target = self
        autoWakeToggleItem.target = self
        watchdogToggleItem.target = self
        launchAtBootItem.target = self
        restartServiceItem.target = self
        runSelfTestItem.target = self
        copyStatusItem.target = self
        exportDiagnosticsItem.target = self

        buildSleepTimerMenu()
        buildShutdownTimerMenu()
        buildScheduledActionsMenu()
        buildProfileMenu()

        let openEventLogItem = NSMenuItem(title: "Open Event Log", action: #selector(openEventLog), keyEquivalent: "")
        openEventLogItem.target = self

        let openServiceLogItem = NSMenuItem(title: "Open Service Log", action: #selector(openServiceLog), keyEquivalent: "")
        openServiceLogItem.target = self

        let clearHistoryItem = NSMenuItem(title: "Clear Event History", action: #selector(clearHistory), keyEquivalent: "")
        clearHistoryItem.target = self

        let quitItem = NSMenuItem(title: "Quit \(AppMeta.shortName)", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self

        recentEventsItem.submenu = recentEventsMenu

        let menu = NSMenu()
        menu.addItem(titleItem)
        menu.addItem(openDesktopModeItem)
        menu.addItem(resourceItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(serviceToggleItem)
        menu.addItem(sleepToggleItem)
        menu.addItem(autoWakeToggleItem)
        menu.addItem(watchdogToggleItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(sleepTimerItem)
        menu.addItem(scheduledActionsItem)
        menu.addItem(profileItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(launchAtBootItem)
        menu.addItem(restartServiceItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(runSelfTestItem)
        menu.addItem(copyStatusItem)
        menu.addItem(exportDiagnosticsItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(recentEventsItem)
        menu.addItem(openEventLogItem)
        menu.addItem(openServiceLogItem)
        menu.addItem(clearHistoryItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func buildResourceMenu() {
        for item in [resourceCPUItem, resourceMemoryItem, resourceDiskItem, resourceBatteryItem, resourceWiFiItem, resourceBluetoothItem, resourceUptimeItem] {
            item.isEnabled = false
            resourceMenu.addItem(item)
        }

        resourceItem.submenu = resourceMenu
    }

    private func buildSleepTimerMenu() {
        sleepTimerMenu.removeAllItems()

        let off = NSMenuItem(title: "Off", action: #selector(selectSleepTimerOption(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = NSNumber(value: 0)
        sleepTimerMenu.addItem(off)

        for minutes in sleepTimerOptions {
            let item = NSMenuItem(title: displayTitle(forMinutes: minutes), action: #selector(selectSleepTimerOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: minutes)
            sleepTimerMenu.addItem(item)
            sleepTimerOptionItems[minutes] = item
        }

        sleepTimerItem.submenu = sleepTimerMenu
    }

    private func buildShutdownTimerMenu() {
        shutdownTimerMenu.removeAllItems()

        let off = NSMenuItem(title: "Off", action: #selector(selectShutdownTimerOption(_:)), keyEquivalent: "")
        off.target = self
        off.representedObject = NSNumber(value: 0)
        shutdownTimerMenu.addItem(off)

        for minutes in shutdownTimerOptions {
            let item = NSMenuItem(title: displayTitle(forMinutes: minutes), action: #selector(selectShutdownTimerOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: minutes)
            shutdownTimerMenu.addItem(item)
            shutdownTimerOptionItems[minutes] = item
        }

        shutdownTimerItem.submenu = shutdownTimerMenu
    }

    private func buildScheduledActionsMenu() {
        scheduledActionsMenu.removeAllItems()

        let scheduleShutdownAtDateItem = NSMenuItem(title: "Schedule Shutdown At Date/Time...", action: #selector(promptScheduleShutdownAtDate), keyEquivalent: "")
        scheduleShutdownAtDateItem.target = self

        let scheduleWakeAtDateItem = NSMenuItem(title: "Schedule Wake/Power On At Date/Time...", action: #selector(promptScheduleWakePowerOnAtDate), keyEquivalent: "")
        scheduleWakeAtDateItem.target = self

        let scheduleEnableAtDateItem = NSMenuItem(title: "Schedule Enable Protection At Date/Time...", action: #selector(promptScheduleEnableProtectionAtDate), keyEquivalent: "")
        scheduleEnableAtDateItem.target = self

        let scheduleDisableAtDateItem = NSMenuItem(title: "Schedule Disable Protection At Date/Time...", action: #selector(promptScheduleDisableProtectionAtDate), keyEquivalent: "")
        scheduleDisableAtDateItem.target = self

        let cancelSchedulesItem = NSMenuItem(title: "Cancel All Scheduled Actions", action: #selector(cancelAllScheduledActions), keyEquivalent: "")
        cancelSchedulesItem.target = self

        scheduledActionsMenu.addItem(shutdownTimerItem)
        scheduledActionsMenu.addItem(scheduleShutdownAtDateItem)
        scheduledActionsMenu.addItem(scheduleWakeAtDateItem)
        scheduledActionsMenu.addItem(scheduleEnableAtDateItem)
        scheduledActionsMenu.addItem(scheduleDisableAtDateItem)
        scheduledActionsMenu.addItem(NSMenuItem.separator())
        scheduledActionsMenu.addItem(wakeScheduleInfoItem)
        scheduledActionsMenu.addItem(enableScheduleInfoItem)
        scheduledActionsMenu.addItem(disableScheduleInfoItem)
        scheduledActionsMenu.addItem(NSMenuItem.separator())
        scheduledActionsMenu.addItem(cancelSchedulesItem)

        scheduledActionsItem.submenu = scheduledActionsMenu
    }

    private func buildProfileMenu() {
        profileMenu.removeAllItems()

        let diamond = NSMenuItem(title: "Diamond - Full Power (GOD-MODE)", action: #selector(applyPowerProfileMenuAction(_:)), keyEquivalent: "")
        diamond.target = self
        diamond.representedObject = PowerProfile.diamond.rawValue

        let powerPlus = NSMenuItem(title: "Power + (Server / Always-On)", action: #selector(applyPowerProfileMenuAction(_:)), keyEquivalent: "")
        powerPlus.target = self
        powerPlus.representedObject = PowerProfile.powerPlus.rawValue

        let batteryPlus = NSMenuItem(title: "Battery + (Efficiency)", action: #selector(applyPowerProfileMenuAction(_:)), keyEquivalent: "")
        batteryPlus.target = self
        batteryPlus.representedObject = PowerProfile.batteryPlus.rawValue

        let offGrid = NSMenuItem(title: "Off-Grid Mode (Wireless Off)", action: #selector(applyPowerProfileMenuAction(_:)), keyEquivalent: "")
        offGrid.target = self
        offGrid.representedObject = PowerProfile.offGrid.rawValue

        let restore = NSMenuItem(title: "Restore Connectivity", action: #selector(applyPowerProfileMenuAction(_:)), keyEquivalent: "")
        restore.target = self
        restore.representedObject = PowerProfile.restoreConnectivity.rawValue

        profileMenu.addItem(diamond)
        profileMenu.addItem(powerPlus)
        profileMenu.addItem(batteryPlus)
        profileMenu.addItem(offGrid)
        profileMenu.addItem(NSMenuItem.separator())
        profileMenu.addItem(restore)

        profileItem.submenu = profileMenu
    }

    private func makeDesktopActionButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        return button
    }

    private func ensureDesktopWindow() -> NSWindow {
        if let desktopWindow {
            return desktopWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1160, height: 760),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "\(AppMeta.shortName) Desktop Experience"
        window.minSize = NSSize(width: 900, height: 580)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unified
        }

        let contentView = NSView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = contentView

        let titleLabel = NSTextField(labelWithString: "\(AppMeta.shortName) Desktop Experience")
        titleLabel.font = NSFont.systemFont(ofSize: 28, weight: .bold)

        let subtitleLabel = NSTextField(labelWithString: "\(AppMeta.appName) command center")
        subtitleLabel.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        subtitleLabel.textColor = .secondaryLabelColor

        let headerStack = NSStackView(views: [titleLabel, subtitleLabel])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 4

        let desktopServiceButton = makeDesktopActionButton(title: "Enable Service", action: #selector(desktopToggleService))
        let desktopSleepButton = makeDesktopActionButton(title: "Enable Sleep Prevention", action: #selector(desktopToggleSleep))
        let openEventLogButton = makeDesktopActionButton(title: "Open Event Log", action: #selector(openEventLog))
        let openServiceLogButton = makeDesktopActionButton(title: "Open Service Log", action: #selector(openServiceLog))
        let exportDiagnosticsButton = makeDesktopActionButton(title: "Export Diagnostics", action: #selector(exportDiagnostics))
        let closeDesktopButton = makeDesktopActionButton(title: "Close Desktop Mode", action: #selector(closeDesktopExperience))

        let actionStack = NSStackView(views: [
            desktopServiceButton,
            desktopSleepButton,
            openEventLogButton,
            openServiceLogButton,
            exportDiagnosticsButton,
            closeDesktopButton
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.distribution = .fillProportionally
        actionStack.spacing = 8

        let statusScrollView = NSScrollView()
        statusScrollView.translatesAutoresizingMaskIntoConstraints = false
        statusScrollView.hasVerticalScroller = true
        statusScrollView.borderType = .bezelBorder
        statusScrollView.drawsBackground = true

        let statusTextView = NSTextView()
        statusTextView.isEditable = false
        statusTextView.isSelectable = true
        statusTextView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        statusTextView.textContainerInset = NSSize(width: 10, height: 12)
        statusTextView.string = "Loading \(AppMeta.shortName) desktop data..."

        if let textContainer = statusTextView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        statusScrollView.documentView = statusTextView

        let rootStack = NSStackView(views: [headerStack, actionStack, statusScrollView])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 12
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(rootStack)

        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18),
            rootStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18),
            rootStack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            rootStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),

            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            actionStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            statusScrollView.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            statusScrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 420)
        ])

        self.desktopWindow = window
        self.desktopStatusTextView = statusTextView
        self.desktopServiceButton = desktopServiceButton
        self.desktopSleepButton = desktopSleepButton

        return window
    }

    private func refreshDesktopWindowState(resourceSnapshot: ResourceSnapshot? = nil) {
        guard let desktopStatusTextView else {
            return
        }

        desktopServiceButton?.title = serviceController.isRunning ? "Disable Service" : "Enable Service"
        desktopSleepButton?.title = blocker.isActive ? "Disable Sleep Prevention" : "Enable Sleep Prevention"

        let snapshot = resourceSnapshot ?? resourceMonitor.sample()

        let sleepTimerText: String
        if let endDate = state.timerEndDate, let minutes = state.timerMinutes {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow / 60.0))
            sleepTimerText = "\(minutes)m (\(remaining)m left)"
        } else {
            sleepTimerText = "Off"
        }

        let shutdownTimerText: String
        if let endDate = state.shutdownEndDate, let minutes = state.shutdownTimerMinutes {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow / 60.0))
            shutdownTimerText = "\(minutes)m (\(remaining)m left)"
        } else {
            shutdownTimerText = "Off"
        }

        var lines: [String] = []
        lines.append("\(AppMeta.shortName) Desktop Snapshot")
        lines.append("Generated: \(PowerScheduler.userFacingDate(Date()))")
        lines.append("")
        lines.append("Control Plane")
        lines.append("- Service: \(serviceController.isRunning ? "Running" : "Stopped")")
        lines.append("- Sleep Prevention: \(blocker.isActive ? "On" : "Off")")
        lines.append("- Launch at Boot: \(state.launchAtBoot ? "Enabled" : "Disabled")")
        lines.append("- Auto-Reenable After Wake: \(state.autoReenableAfterWake ? "Enabled" : "Disabled")")
        lines.append("- Service Watchdog: \(state.serviceWatchdogEnabled ? "Enabled" : "Disabled")")
        lines.append("- Sleep Timer: \(sleepTimerText)")
        lines.append("- Shutdown Timer: \(shutdownTimerText)")
        lines.append("- Wake/Power On: \(state.wakeScheduleDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")")
        lines.append("- Enable Protection At: \(state.enableAtDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")")
        lines.append("- Disable Protection At: \(state.disableAtDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")")
        lines.append("")
        lines.append("Mini Resource Monitor")
        lines.append("- \(snapshot.cpuText)")
        lines.append("- \(snapshot.memoryText)")
        lines.append("- \(snapshot.diskText)")
        lines.append("- \(snapshot.batteryText)")
        lines.append("- Wi-Fi: \(snapshot.wifiText)")
        lines.append("- Bluetooth: \(snapshot.bluetoothText)")
        lines.append("- \(snapshot.uptimeText)")
        lines.append("")
        lines.append("Recent Events")

        let recentEvents = EventLog.shared.snapshot().suffix(120)
        if recentEvents.isEmpty {
            lines.append("(No events yet)")
        } else {
            lines.append(contentsOf: recentEvents)
        }

        let text = lines.joined(separator: "\n")
        if desktopStatusTextView.string != text {
            desktopStatusTextView.string = text
        }
    }

    private func startMonitorTimer() {
        monitorTimer?.invalidate()
        monitorTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            self?.refreshMenuState()
        }
        if let monitorTimer {
            RunLoop.main.add(monitorTimer, forMode: .common)
        }
    }

    private func registerLogObserver() {
        logObserver = NotificationCenter.default.addObserver(
            forName: .nsmEventLogUpdated,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshMenuState()
        }
    }

    private func registerSystemObservers() {
        let workspaceCenter = NSWorkspace.shared.notificationCenter

        func watchWorkspace(_ name: NSNotification.Name, message: String, handler: (() -> Void)? = nil) {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { _ in
                EventLog.shared.add(message)
                handler?()
            }
            workspaceObservers.append(token)
        }

        watchWorkspace(NSWorkspace.willSleepNotification, message: "System sleep notification received.")
        watchWorkspace(NSWorkspace.didWakeNotification, message: "System wake notification received.") { [weak self] in
            self?.handleWakeEvent()
        }
        watchWorkspace(NSWorkspace.willPowerOffNotification, message: "System power-off notification received.")
        watchWorkspace(NSWorkspace.screensDidSleepNotification, message: "Display sleep notification received.")
        watchWorkspace(NSWorkspace.screensDidWakeNotification, message: "Display wake notification received.")
        watchWorkspace(NSWorkspace.sessionDidBecomeActiveNotification, message: "User session became active.")
        watchWorkspace(NSWorkspace.sessionDidResignActiveNotification, message: "User session resigned activity.")

        let distributedCenter = DistributedNotificationCenter.default()

        func watchDistributed(_ rawName: String, _ message: String) {
            let token = distributedCenter.addObserver(forName: Notification.Name(rawName), object: nil, queue: .main) { _ in
                EventLog.shared.add(message)
            }
            distributedObservers.append(token)
        }

        watchDistributed("com.apple.loginwindow.shutdownInitiated", "Loginwindow initiated shutdown.")
        watchDistributed("com.apple.loginwindow.shutdowninitiated", "Loginwindow initiated shutdown.")
        watchDistributed("com.apple.loginwindow.restartInitiated", "Loginwindow initiated restart.")
        watchDistributed("com.apple.loginwindow.restartinitiated", "Loginwindow initiated restart.")
        watchDistributed("com.apple.loginwindow.logoutInitiated", "Loginwindow initiated logout.")
        watchDistributed("com.apple.loginwindow.logoutinitiated", "Loginwindow initiated logout.")
    }

    private func applyStateOnLaunch() {
        if state.serviceEnabled {
            _ = serviceController.start()
        }

        if state.preventSleep {
            _ = ensureProtectionEnabled()
        }

        restoreScheduledTimers()
        stateStore.save(state)
    }

    private func restoreScheduledTimers() {
        if let minutes = state.timerMinutes, let end = state.timerEndDate, end > Date() {
            scheduleSleepTimer(endDate: end, minutes: minutes, logSelection: false)
        } else {
            clearSleepTimer(logChange: false)
        }

        if let minutes = state.shutdownTimerMinutes, let end = state.shutdownEndDate, end > Date() {
            scheduleShutdownTimer(endDate: end, minutes: minutes, logSelection: false)
        } else {
            clearShutdownTimer(logChange: false)
        }

        if let enableAt = state.enableAtDate, enableAt > Date() {
            scheduleEnableProtection(at: enableAt, logSelection: false)
        } else {
            clearEnableSchedule(logChange: false)
        }

        if let disableAt = state.disableAtDate, disableAt > Date() {
            scheduleDisableProtection(at: disableAt, logSelection: false)
        } else {
            clearDisableSchedule(logChange: false)
        }
    }

    private func synchronizeLaunchAtBootState() {
        let effective = launchAtBootManager.isEnabled()
        if effective != state.launchAtBoot {
            _ = launchAtBootManager.setEnabled(state.launchAtBoot)
        }

        state.launchAtBoot = launchAtBootManager.isEnabled()
        stateStore.save(state)
    }

    private func refreshMenuState() {
        titleItem.title = "\(AppMeta.shortName) • Service \(serviceController.isRunning ? "Running" : "Stopped") • Sleep \(blocker.isActive ? "On" : "Off")"
        openDesktopModeItem.title = desktopWindow == nil
            ? "Open \(AppMeta.shortName) Desktop Experience"
            : "Open \(AppMeta.shortName) Desktop Experience (Active)"

        serviceToggleItem.state = serviceController.isRunning ? .on : .off
        sleepToggleItem.state = blocker.isActive ? .on : .off
        autoWakeToggleItem.state = state.autoReenableAfterWake ? .on : .off
        watchdogToggleItem.state = state.serviceWatchdogEnabled ? .on : .off
        launchAtBootItem.state = state.launchAtBoot ? .on : .off

        sleepToggleItem.isEnabled = serviceController.isRunning || !blocker.isActive

        let snapshot = resourceMonitor.sample()
        updateResourceItems(snapshot)
        refreshDesktopWindowState(resourceSnapshot: snapshot)
        updateSleepTimerMenuState()
        updateShutdownTimerMenuState()
        updateScheduleInfoItems()
        rebuildRecentEventsMenu()
    }

    private func updateResourceItems(_ snap: ResourceSnapshot) {
        resourceCPUItem.title = snap.cpuText
        resourceMemoryItem.title = snap.memoryText
        resourceDiskItem.title = snap.diskText
        resourceBatteryItem.title = snap.batteryText
        resourceWiFiItem.title = "Wi-Fi: \(snap.wifiText)"
        resourceBluetoothItem.title = "Bluetooth: \(snap.bluetoothText)"
        resourceUptimeItem.title = snap.uptimeText
    }

    private func updateSleepTimerMenuState() {
        let active = state.timerMinutes

        if let offItem = sleepTimerMenu.item(at: 0) {
            offItem.state = active == nil ? .on : .off
        }

        for (minutes, item) in sleepTimerOptionItems {
            item.state = minutes == active ? .on : .off
        }

        if let endDate = state.timerEndDate, let minutes = state.timerMinutes {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow / 60.0))
            sleepTimerItem.title = "Sleep Timer (\(minutes)m, \(remaining)m left)"
        } else {
            sleepTimerItem.title = "Sleep Timer"
        }
    }

    private func updateShutdownTimerMenuState() {
        let active = state.shutdownTimerMinutes

        if let offItem = shutdownTimerMenu.item(at: 0) {
            offItem.state = active == nil ? .on : .off
        }

        for (minutes, item) in shutdownTimerOptionItems {
            item.state = minutes == active ? .on : .off
        }

        if let endDate = state.shutdownEndDate, let minutes = state.shutdownTimerMinutes {
            let remaining = max(0, Int(endDate.timeIntervalSinceNow / 60.0))
            shutdownTimerItem.title = "Shutdown Timer (\(minutes)m, \(remaining)m left)"
        } else {
            shutdownTimerItem.title = "Shutdown Timer"
        }
    }

    private func updateScheduleInfoItems() {
        wakeScheduleInfoItem.title = "Wake/Power On: \(state.wakeScheduleDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")"
        enableScheduleInfoItem.title = "Enable Protection: \(state.enableAtDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")"
        disableScheduleInfoItem.title = "Disable Protection: \(state.disableAtDate.map(PowerScheduler.userFacingDate) ?? "Not Scheduled")"
    }

    private func rebuildRecentEventsMenu() {
        recentEventsMenu.removeAllItems()

        let recent = EventLog.shared.snapshot().suffix(14)
        if recent.isEmpty {
            let empty = NSMenuItem(title: "No events yet.", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            recentEventsMenu.addItem(empty)
            return
        }

        for line in recent.reversed() {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            recentEventsMenu.addItem(item)
        }
    }

    private func ensureServiceRunning() -> Bool {
        if serviceController.isRunning {
            state.serviceEnabled = true
            return true
        }

        let started = serviceController.start()
        state.serviceEnabled = started
        if started {
            EventLog.shared.add("Service auto-enabled for requested action.")
        }
        return started
    }

    @discardableResult
    private func ensureProtectionEnabled() -> Bool {
        guard ensureServiceRunning() else {
            return false
        }

        let enabled = blocker.activate(reason: "\(AppMeta.shortName) protection enabled")
        state.preventSleep = enabled
        return enabled
    }

    private func handleWakeEvent() {
        guard state.autoReenableAfterWake else {
            return
        }

        guard state.preventSleep || state.serviceEnabled else {
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else {
                return
            }

            if self.state.serviceEnabled {
                _ = self.serviceController.start()
            }

            if self.state.preventSleep {
                _ = self.ensureProtectionEnabled()
            }

            self.stateStore.save(self.state)
            self.refreshMenuState()
            EventLog.shared.add("Auto-reenable after wake applied.")
        }
    }

    private func handleUnexpectedServiceTermination(status: Int32, details: String) {
        guard !isTerminating else {
            return
        }

        guard state.serviceEnabled, state.serviceWatchdogEnabled else {
            return
        }

        let now = Date()
        restartTimestamps = restartTimestamps.filter { now.timeIntervalSince($0) <= 120 }

        if restartTimestamps.count >= 5 {
            EventLog.shared.add("Service watchdog paused after repeated failures.")
            return
        }

        restartTimestamps.append(now)

        let detailText = details.isEmpty ? "" : " (\(details))"
        EventLog.shared.add("Service watchdog restarting service in 2 seconds after exit \(status)\(detailText).")

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            guard let self else {
                return
            }

            guard !self.isTerminating else {
                return
            }

            guard self.state.serviceEnabled, self.state.serviceWatchdogEnabled else {
                return
            }

            guard !self.serviceController.isRunning else {
                return
            }

            let restarted = self.serviceController.start()
            EventLog.shared.add(restarted ? "Service watchdog restart succeeded." : "Service watchdog restart failed.")

            if restarted, self.state.preventSleep {
                _ = self.ensureProtectionEnabled()
            }

            self.stateStore.save(self.state)
            self.refreshMenuState()
        }
    }

    private func scheduleSleepTimer(endDate: Date, minutes: Int, logSelection: Bool) {
        sleepTimer?.invalidate()

        let interval = endDate.timeIntervalSinceNow
        if interval <= 0 {
            handleSleepTimerFired()
            return
        }

        state.timerMinutes = minutes
        state.timerEndDate = endDate
        stateStore.save(state)

        if logSelection {
            EventLog.shared.add("Sleep timer set for \(minutes) minutes.")
        }

        sleepTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleSleepTimerFired()
        }

        if let sleepTimer {
            RunLoop.main.add(sleepTimer, forMode: .common)
        }
    }

    private func clearSleepTimer(logChange: Bool) {
        sleepTimer?.invalidate()
        sleepTimer = nil

        state.timerMinutes = nil
        state.timerEndDate = nil
        stateStore.save(state)

        if logChange {
            EventLog.shared.add("Sleep timer turned off.")
        }
    }

    private func handleSleepTimerFired() {
        sleepTimer?.invalidate()
        sleepTimer = nil

        blocker.deactivate()
        state.preventSleep = false
        state.timerMinutes = nil
        state.timerEndDate = nil
        stateStore.save(state)

        EventLog.shared.add("Sleep timer elapsed. Sleep prevention disabled.")
        refreshMenuState()
    }

    private func scheduleShutdownTimer(endDate: Date, minutes: Int, logSelection: Bool) {
        shutdownTimer?.invalidate()

        let interval = endDate.timeIntervalSinceNow
        if interval <= 0 {
            handleShutdownTimerFired()
            return
        }

        state.shutdownTimerMinutes = minutes
        state.shutdownEndDate = endDate
        stateStore.save(state)

        if logSelection {
            EventLog.shared.add("Shutdown timer set for \(minutes) minutes.")
        }

        shutdownTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleShutdownTimerFired()
        }

        if let shutdownTimer {
            RunLoop.main.add(shutdownTimer, forMode: .common)
        }
    }

    private func clearShutdownTimer(logChange: Bool) {
        shutdownTimer?.invalidate()
        shutdownTimer = nil

        state.shutdownTimerMinutes = nil
        state.shutdownEndDate = nil
        stateStore.save(state)

        if logChange {
            EventLog.shared.add("Shutdown timer turned off.")
        }
    }

    private func handleShutdownTimerFired() {
        shutdownTimer?.invalidate()
        shutdownTimer = nil

        state.shutdownTimerMinutes = nil
        state.shutdownEndDate = nil
        stateStore.save(state)

        EventLog.shared.add("Shutdown timer elapsed.")
        refreshMenuState()
        performShutdown(reason: "timer")
    }

    private func scheduleEnableProtection(at date: Date, logSelection: Bool) {
        enableProtectionTimer?.invalidate()

        let interval = date.timeIntervalSinceNow
        if interval <= 0 {
            handleEnableProtectionFired()
            return
        }

        state.enableAtDate = date
        stateStore.save(state)

        if logSelection {
            EventLog.shared.add("Enable protection scheduled for \(PowerScheduler.userFacingDate(date)).")
        }

        enableProtectionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleEnableProtectionFired()
        }

        if let enableProtectionTimer {
            RunLoop.main.add(enableProtectionTimer, forMode: .common)
        }
    }

    private func clearEnableSchedule(logChange: Bool) {
        enableProtectionTimer?.invalidate()
        enableProtectionTimer = nil

        state.enableAtDate = nil
        stateStore.save(state)

        if logChange {
            EventLog.shared.add("Enable protection schedule cleared.")
        }
    }

    private func handleEnableProtectionFired() {
        enableProtectionTimer?.invalidate()
        enableProtectionTimer = nil

        state.enableAtDate = nil

        let success = ensureProtectionEnabled()
        state.serviceEnabled = serviceController.isRunning
        state.preventSleep = blocker.isActive
        stateStore.save(state)

        EventLog.shared.add(success ? "Scheduled enable protection executed." : "Scheduled enable protection failed.")
        refreshMenuState()
    }

    private func scheduleDisableProtection(at date: Date, logSelection: Bool) {
        disableProtectionTimer?.invalidate()

        let interval = date.timeIntervalSinceNow
        if interval <= 0 {
            handleDisableProtectionFired()
            return
        }

        state.disableAtDate = date
        stateStore.save(state)

        if logSelection {
            EventLog.shared.add("Disable protection scheduled for \(PowerScheduler.userFacingDate(date)).")
        }

        disableProtectionTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleDisableProtectionFired()
        }

        if let disableProtectionTimer {
            RunLoop.main.add(disableProtectionTimer, forMode: .common)
        }
    }

    private func clearDisableSchedule(logChange: Bool) {
        disableProtectionTimer?.invalidate()
        disableProtectionTimer = nil

        state.disableAtDate = nil
        stateStore.save(state)

        if logChange {
            EventLog.shared.add("Disable protection schedule cleared.")
        }
    }

    private func handleDisableProtectionFired() {
        disableProtectionTimer?.invalidate()
        disableProtectionTimer = nil

        state.disableAtDate = nil

        blocker.deactivate()
        state.preventSleep = false
        clearSleepTimer(logChange: false)
        stateStore.save(state)

        EventLog.shared.add("Scheduled disable protection executed.")
        refreshMenuState()
    }

    private func performShutdown(reason: String) {
        EventLog.shared.add("Shutdown requested (\(reason)).")

        let result = CommandRunner.run(
            "/usr/bin/osascript",
            args: ["-e", "tell application \"System Events\" to shut down"]
        )

        if result.status == 0 {
            EventLog.shared.add("Shutdown command sent.")
        } else {
            let msg = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            EventLog.shared.add("Shutdown command failed: \(msg.isEmpty ? "unknown error" : msg)")
        }
    }

    private func promptForDateTime(title: String, message: String, defaultDate: Date) -> Date? {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set")
        alert.addButton(withTitle: "Cancel")

        let picker = NSDatePicker(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        picker.datePickerStyle = .textFieldAndStepper
        picker.datePickerElements = [.yearMonthDay, .hourMinuteSecond]
        picker.dateValue = defaultDate
        picker.minDate = Date()
        alert.accessoryView = picker

        return alert.runModal() == .alertFirstButtonReturn ? picker.dateValue : nil
    }

    private func displayTitle(forMinutes minutes: Int) -> String {
        switch minutes {
        case 60:
            return "1 Hour"
        case 120:
            return "2 Hours"
        case 240:
            return "4 Hours"
        default:
            return "\(minutes) Minutes"
        }
    }

    @discardableResult
    private func runPrivilegedPowerCommand(_ command: String, successMessage: String, failureLabel: String) -> Bool {
        let result = CommandRunner.runPrivilegedShell(command)
        if result.status == 0 {
            EventLog.shared.add(successMessage)
            return true
        }

        let errorText = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        EventLog.shared.add("\(failureLabel): \(errorText.isEmpty ? "unknown error" : errorText)")
        return false
    }

    private func applyPowerProfile(_ profile: PowerProfile) {
        switch profile {
        case .diamond:
            state.autoReenableAfterWake = true
            state.serviceWatchdogEnabled = true
            state.launchAtBoot = true
            _ = launchAtBootManager.setEnabled(true)

            _ = serviceController.start()
            _ = ensureProtectionEnabled()
            state.serviceEnabled = serviceController.isRunning
            state.preventSleep = blocker.isActive

            _ = runPrivilegedPowerCommand(
                "/usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 autopoweroff 0 powernap 0 lowpowermode 0",
                successMessage: "Diamond profile: full power pmset settings applied.",
                failureLabel: "Diamond profile pmset failed"
            )

            _ = resourceMonitor.setWiFiEnabled(true)
            _ = resourceMonitor.setBluetoothEnabled(true)

            EventLog.shared.add("Power profile applied: Diamond - Full Power (GOD-MODE).")

        case .powerPlus:
            state.autoReenableAfterWake = true
            state.serviceWatchdogEnabled = true
            state.launchAtBoot = true
            _ = launchAtBootManager.setEnabled(true)

            _ = serviceController.start()
            _ = ensureProtectionEnabled()
            state.serviceEnabled = serviceController.isRunning
            state.preventSleep = blocker.isActive

            _ = runPrivilegedPowerCommand(
                "/usr/bin/pmset -a sleep 0 displaysleep 0 disksleep 0 standby 0 autopoweroff 0 powernap 0 lowpowermode 0",
                successMessage: "Power+ profile: always-on pmset settings applied.",
                failureLabel: "Power+ pmset failed"
            )

            _ = runPrivilegedPowerCommand(
                "/usr/sbin/systemsetup -setrestartpowerfailure on; /usr/sbin/systemsetup -setrestartfreeze on",
                successMessage: "Power+ profile: auto-restart on power failure/freeze enabled.",
                failureLabel: "Power+ systemsetup failed"
            )

            clearShutdownTimer(logChange: false)
            EventLog.shared.add("Power profile applied: Power+ (Server / Always-On).")

        case .batteryPlus:
            blocker.deactivate()
            state.preventSleep = false
            clearSleepTimer(logChange: false)

            state.autoReenableAfterWake = false
            state.serviceWatchdogEnabled = false
            state.serviceEnabled = false
            serviceController.stop()

            _ = runPrivilegedPowerCommand(
                "/usr/bin/pmset -b sleep 10 displaysleep 3 disksleep 10 powernap 0 lowpowermode 1 standby 1 autopoweroff 1; /usr/bin/pmset -c lowpowermode 0",
                successMessage: "Battery+ profile: battery-saving power settings applied.",
                failureLabel: "Battery+ pmset failed"
            )

            EventLog.shared.add("Power profile applied: Battery+ (Efficiency).")

        case .offGrid:
            blocker.deactivate()
            state.preventSleep = false
            clearSleepTimer(logChange: false)

            state.serviceEnabled = false
            serviceController.stop()
            state.autoReenableAfterWake = false

            _ = resourceMonitor.setWiFiEnabled(false)
            _ = resourceMonitor.setBluetoothEnabled(false)

            _ = runPrivilegedPowerCommand(
                "/usr/bin/pmset -a womp 0 powernap 0 lowpowermode 1",
                successMessage: "Off-Grid profile: wireless-related power settings restricted.",
                failureLabel: "Off-Grid pmset failed"
            )

            EventLog.shared.add("Power profile applied: Off-Grid Mode (wireless off).")

        case .restoreConnectivity:
            _ = resourceMonitor.setWiFiEnabled(true)
            _ = resourceMonitor.setBluetoothEnabled(true)

            _ = runPrivilegedPowerCommand(
                "/usr/bin/pmset -a womp 1 powernap 1",
                successMessage: "Connectivity restored: WOMP and Power Nap enabled.",
                failureLabel: "Restore connectivity pmset failed"
            )

            EventLog.shared.add("Power profile applied: Restore Connectivity.")
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func openDesktopExperience() {
        let window = ensureDesktopWindow()

        _ = NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        refreshDesktopWindowState()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let activeWindow = self.desktopWindow else {
                return
            }

            guard activeWindow.isVisible, !activeWindow.styleMask.contains(.fullScreen) else {
                return
            }

            activeWindow.toggleFullScreen(nil)
        }

        EventLog.shared.add("Desktop experience opened.")
        refreshMenuState()
    }

    @objc private func closeDesktopExperience() {
        desktopWindow?.performClose(nil)
    }

    @objc private func desktopToggleService() {
        toggleService()
    }

    @objc private func desktopToggleSleep() {
        toggleSleepPrevention()
    }

    @objc private func toggleLaunchAtBoot() {
        let desired = !state.launchAtBoot
        if launchAtBootManager.setEnabled(desired) {
            state.launchAtBoot = desired
        } else {
            state.launchAtBoot = launchAtBootManager.isEnabled()
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func toggleService() {
        if serviceController.isRunning {
            serviceController.stop()
            state.serviceEnabled = false

            if blocker.isActive {
                blocker.deactivate()
                state.preventSleep = false
            }

            clearSleepTimer(logChange: true)
        } else {
            let started = serviceController.start()
            state.serviceEnabled = started
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func restartService() {
        let restarted = serviceController.restart()
        state.serviceEnabled = restarted

        if !restarted {
            blocker.deactivate()
            state.preventSleep = false
            clearSleepTimer(logChange: false)
        }

        if restarted, state.preventSleep {
            _ = ensureProtectionEnabled()
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func toggleSleepPrevention() {
        if blocker.isActive {
            blocker.deactivate()
            state.preventSleep = false
            clearSleepTimer(logChange: true)
        } else {
            guard ensureProtectionEnabled() else {
                EventLog.shared.add("Cannot enable sleep prevention because service is not running.")
                refreshMenuState()
                return
            }
            state.preventSleep = true
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func toggleAutoReenableAfterWake() {
        state.autoReenableAfterWake.toggle()
        stateStore.save(state)
        EventLog.shared.add("Auto-reenable after wake \(state.autoReenableAfterWake ? "enabled" : "disabled").")
        refreshMenuState()
    }

    @objc private func toggleServiceWatchdog() {
        state.serviceWatchdogEnabled.toggle()
        stateStore.save(state)
        EventLog.shared.add("Service watchdog \(state.serviceWatchdogEnabled ? "enabled" : "disabled").")
        refreshMenuState()
    }

    @objc private func selectSleepTimerOption(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber else {
            return
        }

        let minutes = wrapped.intValue

        if minutes == 0 {
            clearSleepTimer(logChange: true)
            refreshMenuState()
            return
        }

        guard ensureProtectionEnabled() else {
            EventLog.shared.add("Cannot set sleep timer because service/protection could not be enabled.")
            refreshMenuState()
            return
        }

        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        scheduleSleepTimer(endDate: endDate, minutes: minutes, logSelection: true)

        state.preventSleep = true
        state.serviceEnabled = true
        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func selectShutdownTimerOption(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber else {
            return
        }

        let minutes = wrapped.intValue

        if minutes == 0 {
            clearShutdownTimer(logChange: true)
            refreshMenuState()
            return
        }

        let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
        scheduleShutdownTimer(endDate: endDate, minutes: minutes, logSelection: true)
        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func promptScheduleShutdownAtDate() {
        guard let date = promptForDateTime(
            title: "Schedule Shutdown",
            message: "Pick a date and time to shut down this Mac.",
            defaultDate: Date().addingTimeInterval(3600)
        ) else {
            return
        }

        let minutes = max(1, Int(date.timeIntervalSinceNow / 60.0))
        scheduleShutdownTimer(endDate: date, minutes: minutes, logSelection: true)
        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func promptScheduleWakePowerOnAtDate() {
        guard let date = promptForDateTime(
            title: "Schedule Wake/Power On",
            message: "Pick a date/time. macOS may ask for your admin password.",
            defaultDate: Date().addingTimeInterval(3600)
        ) else {
            return
        }

        if powerScheduler.scheduleWakeOrPowerOn(at: date) {
            state.wakeScheduleDate = date
            stateStore.save(state)
        }

        refreshMenuState()
    }

    @objc private func promptScheduleEnableProtectionAtDate() {
        guard let date = promptForDateTime(
            title: "Schedule Enable Protection",
            message: "Pick a date/time to auto-enable service and sleep prevention.",
            defaultDate: Date().addingTimeInterval(1800)
        ) else {
            return
        }

        scheduleEnableProtection(at: date, logSelection: true)
        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func promptScheduleDisableProtectionAtDate() {
        guard let date = promptForDateTime(
            title: "Schedule Disable Protection",
            message: "Pick a date/time to auto-disable sleep prevention.",
            defaultDate: Date().addingTimeInterval(3600)
        ) else {
            return
        }

        scheduleDisableProtection(at: date, logSelection: true)
        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func cancelAllScheduledActions() {
        clearSleepTimer(logChange: true)
        clearShutdownTimer(logChange: true)
        clearEnableSchedule(logChange: true)
        clearDisableSchedule(logChange: true)

        if state.wakeScheduleDate != nil {
            if powerScheduler.cancelWakeOrPowerOn() {
                state.wakeScheduleDate = nil
            }
        }

        stateStore.save(state)
        refreshMenuState()
    }

    @objc private func applyPowerProfileMenuAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let profile = PowerProfile(rawValue: raw) else {
            return
        }

        applyPowerProfile(profile)
    }

    @objc private func runSelfTest() {
        var checks: [String] = []
        var ok = true

        if Bundle.main.path(forResource: "service-worker", ofType: "sh") != nil {
            checks.append("Service script: OK")
        } else {
            checks.append("Service script: MISSING")
            ok = false
        }

        if FileManager.default.isWritableFile(atPath: EventLog.shared.fileURL.deletingLastPathComponent().path) {
            checks.append("Log directory writable: OK")
        } else {
            checks.append("Log directory writable: FAILED")
            ok = false
        }

        let pmset = CommandRunner.run("/usr/bin/pmset", args: ["-g", "assertions"])
        checks.append("pmset access: \(pmset.status == 0 ? "OK" : "FAILED")")
        if pmset.status != 0 {
            ok = false
        }

        checks.append("Launch at boot effective: \(launchAtBootManager.isEnabled())")
        checks.append("Service running: \(serviceController.isRunning)")
        checks.append("Sleep prevention active: \(blocker.isActive)")
        checks.append("Wi-Fi: \(resourceMonitor.wifiStatusText())")
        checks.append("Bluetooth: \(resourceMonitor.bluetoothStatusText())")

        let alert = NSAlert()
        alert.messageText = ok ? "Self-Test Passed" : "Self-Test Found Issues"
        alert.informativeText = checks.joined(separator: "\n")
        alert.addButton(withTitle: "OK")
        alert.alertStyle = ok ? .informational : .warning

        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()

        EventLog.shared.add("Self-test completed: \(ok ? "pass" : "issues found").")
    }

    @objc private func copyStatusToClipboard() {
        let statusText = [
            "\(AppMeta.shortName) Status",
            "Service running: \(serviceController.isRunning)",
            "Sleep prevention active: \(blocker.isActive)",
            "Launch at boot: \(state.launchAtBoot)",
            "Auto-reenable after wake: \(state.autoReenableAfterWake)",
            "Service watchdog: \(state.serviceWatchdogEnabled)",
            "Sleep timer: \(state.timerEndDate.map(PowerScheduler.userFacingDate) ?? "off")",
            "Shutdown timer: \(state.shutdownEndDate.map(PowerScheduler.userFacingDate) ?? "off")",
            "Wake/Power On: \(state.wakeScheduleDate.map(PowerScheduler.userFacingDate) ?? "none")",
            "Wi-Fi: \(resourceMonitor.wifiStatusText())",
            "Bluetooth: \(resourceMonitor.bluetoothStatusText())"
        ].joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusText, forType: .string)

        EventLog.shared.add("Status copied to clipboard.")
    }

    @objc private func exportDiagnostics() {
        let report = DiagnosticsBuilder.build(
            state: state,
            serviceRunning: serviceController.isRunning,
            sleepActive: blocker.isActive,
            launchAtBootEnabled: launchAtBootManager.isEnabled(),
            eventLogURL: EventLog.shared.fileURL,
            serviceLogURL: serviceController.serviceLogURL,
            wakeScheduleText: powerScheduler.readScheduleText()
        )

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let timestamp = formatter.string(from: Date())

        let desktop = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Desktop", isDirectory: true)
        let outputURL = desktop.appendingPathComponent("\(AppMeta.diagnosticsPrefix)-\(timestamp).txt", isDirectory: false)

        do {
            try report.write(to: outputURL, atomically: true, encoding: .utf8)
            NSWorkspace.shared.open(outputURL)
            EventLog.shared.add("Diagnostics exported to \(outputURL.path).")
        } catch {
            EventLog.shared.add("Failed to export diagnostics: \(error.localizedDescription)")
        }
    }

    @objc private func openEventLog() {
        NSWorkspace.shared.open(EventLog.shared.fileURL)
    }

    @objc private func openServiceLog() {
        NSWorkspace.shared.open(serviceController.serviceLogURL)
    }

    @objc private func clearHistory() {
        EventLog.shared.clear()
        EventLog.shared.add("Event history cleared by user.")
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === desktopWindow else {
            return
        }

        desktopWindow = nil
        desktopStatusTextView = nil
        desktopServiceButton = nil
        desktopSleepButton = nil

        if !isTerminating {
            _ = NSApplication.shared.setActivationPolicy(.accessory)
            EventLog.shared.add("Desktop experience closed. Returned to menu bar mode.")
            refreshMenuState()
        }
    }

    deinit {
        if let logObserver {
            NotificationCenter.default.removeObserver(logObserver)
        }

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            workspaceCenter.removeObserver(observer)
        }

        let distributedCenter = DistributedNotificationCenter.default()
        for observer in distributedObservers {
            distributedCenter.removeObserver(observer)
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
