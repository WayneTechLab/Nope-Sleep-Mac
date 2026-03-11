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
    static let providerName = "WayneTechLab.com"
    static let providerURL = URL(string: "https://WayneTechLab.com")!
    static let repositoryURL = URL(string: "https://github.com/WayneTechLab/Nope-Sleep-Mac")!
    static let wikiURL = URL(string: "https://github.com/WayneTechLab/Nope-Sleep-Mac/wiki")!
    static let latestReleaseAPIURL = URL(string: "https://api.github.com/repos/WayneTechLab/Nope-Sleep-Mac/releases/latest")!
    static let latestReleaseURL = URL(string: "https://github.com/WayneTechLab/Nope-Sleep-Mac/releases/latest")!

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0"
    }

    static var currentBuild: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
    }
    static let riskWarningVersion = "2026-03-09"
    static let riskWarningTitle = "Important Safety, Warranty, and Liability Notice"
    static let riskWarningMenuTitle = "Safety / Warranty Notice"
    static let riskWarningMenuLines = [
        "Long or indefinite use can increase heat, battery wear, and hardware stress.",
        "This software is provided as-is, with no warranties or guarantees.",
        "Use at your own risk and avoid unattended or safety-critical use.",
        "Damage caused by misuse may affect warranty, support, or AppleCare coverage."
    ]
    static let riskWarningMessage = """
    \(appName) can keep a Mac awake for extended or indefinite periods. That can increase heat, battery wear, display wear, and overall component stress.

    This software is provided as-is, without warranties or guarantees of performance, fitness, compatibility, or uninterrupted operation. Use is at your own risk.

    Do not rely on it for safety-critical, regulated, unattended, shared, or public-facing systems unless you have independently determined that use is appropriate. Damage caused by misuse or prolonged operation may affect warranty, support, or AppleCare coverage.
    """
}

extension Notification.Name {
    static let nsmEventLogUpdated = Notification.Name("NSMEventLogUpdated")
}

enum ThermalPressureLevel: Int, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    init(processState: ProcessInfo.ThermalState) {
        switch processState {
        case .nominal:
            self = .nominal
        case .fair:
            self = .fair
        case .serious:
            self = .serious
        case .critical:
            self = .critical
        @unknown default:
            self = .serious
        }
    }

    var title: String {
        switch self {
        case .nominal:
            return "Nominal"
        case .fair:
            return "Fair"
        case .serious:
            return "Serious"
        case .critical:
            return "Critical"
        }
    }
}

enum PowerSourceKind: String {
    case ac = "AC Power"
    case battery = "Battery Power"
    case ups = "UPS Power"
    case noBattery = "No Battery Detected"
    case unknown = "Unknown"

    var title: String {
        rawValue
    }

    var isExternalPower: Bool {
        switch self {
        case .ac, .ups, .noBattery:
            return true
        case .battery, .unknown:
            return false
        }
    }
}

struct PowerSourceSnapshot {
    let source: PowerSourceKind
    let batteryText: String
}

enum AppScopedAwakePolicy: Int, CaseIterable {
    case anySelectedRunning = 0
    case frontmostSelectedApp = 1

    var title: String {
        switch self {
        case .anySelectedRunning:
            return "Any Selected App Running"
        case .frontmostSelectedApp:
            return "Frontmost Selected App Only"
        }
    }
}

struct ScopedAppRecord {
    let bundleIdentifier: String
    let displayName: String
    let isRunning: Bool
    let isFrontmost: Bool
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
    var acPowerOnlyModeEnabled: Bool
    var appScopedAwakeModeEnabled: Bool
    var appScopedAwakePolicyRaw: Int
    var appScopedBundleIdentifiers: [String]
    var thermalGuardEnabled: Bool
    var thermalGuardThresholdRaw: Int
    var thermalGuardCooldownMinutes: Int
    var thermalGuardCooldownUntil: Date?
    var runtimeCapConfiguredMinutes: Int?
    var runtimeCapEndDate: Date?
    var riskWarningAcceptedVersion: String?
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
        static let acPowerOnlyModeEnabled = "acPowerOnlyModeEnabled"
        static let appScopedAwakeModeEnabled = "appScopedAwakeModeEnabled"
        static let appScopedAwakePolicyRaw = "appScopedAwakePolicyRaw"
        static let appScopedBundleIdentifiers = "appScopedBundleIdentifiers"
        static let thermalGuardEnabled = "thermalGuardEnabled"
        static let thermalGuardThresholdRaw = "thermalGuardThresholdRaw"
        static let thermalGuardCooldownMinutes = "thermalGuardCooldownMinutes"
        static let thermalGuardCooldownUntil = "thermalGuardCooldownUntil"
        static let runtimeCapConfiguredMinutes = "runtimeCapConfiguredMinutes"
        static let runtimeCapEndDate = "runtimeCapEndDate"
        static let riskWarningAcceptedVersion = "riskWarningAcceptedVersion"
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
            acPowerOnlyModeEnabled: defaults.object(forKey: Key.acPowerOnlyModeEnabled) as? Bool ?? false,
            appScopedAwakeModeEnabled: defaults.object(forKey: Key.appScopedAwakeModeEnabled) as? Bool ?? false,
            appScopedAwakePolicyRaw: defaults.object(forKey: Key.appScopedAwakePolicyRaw) as? Int ?? AppScopedAwakePolicy.anySelectedRunning.rawValue,
            appScopedBundleIdentifiers: defaults.stringArray(forKey: Key.appScopedBundleIdentifiers) ?? [],
            thermalGuardEnabled: defaults.object(forKey: Key.thermalGuardEnabled) as? Bool ?? true,
            thermalGuardThresholdRaw: defaults.object(forKey: Key.thermalGuardThresholdRaw) as? Int ?? ThermalPressureLevel.serious.rawValue,
            thermalGuardCooldownMinutes: defaults.object(forKey: Key.thermalGuardCooldownMinutes) as? Int ?? 15,
            thermalGuardCooldownUntil: defaults.object(forKey: Key.thermalGuardCooldownUntil) as? Date,
            runtimeCapConfiguredMinutes: defaults.object(forKey: Key.runtimeCapConfiguredMinutes) as? Int,
            runtimeCapEndDate: defaults.object(forKey: Key.runtimeCapEndDate) as? Date,
            riskWarningAcceptedVersion: defaults.string(forKey: Key.riskWarningAcceptedVersion),
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
        defaults.set(state.acPowerOnlyModeEnabled, forKey: Key.acPowerOnlyModeEnabled)
        defaults.set(state.appScopedAwakeModeEnabled, forKey: Key.appScopedAwakeModeEnabled)
        defaults.set(state.appScopedAwakePolicyRaw, forKey: Key.appScopedAwakePolicyRaw)
        defaults.set(state.appScopedBundleIdentifiers, forKey: Key.appScopedBundleIdentifiers)
        defaults.set(state.thermalGuardEnabled, forKey: Key.thermalGuardEnabled)
        defaults.set(state.thermalGuardThresholdRaw, forKey: Key.thermalGuardThresholdRaw)
        defaults.set(state.thermalGuardCooldownMinutes, forKey: Key.thermalGuardCooldownMinutes)
        defaults.set(state.autoReenableAfterWake, forKey: Key.autoReenableAfterWake)
        defaults.set(state.serviceWatchdogEnabled, forKey: Key.serviceWatchdogEnabled)

        setOptional(state.thermalGuardCooldownUntil, key: Key.thermalGuardCooldownUntil)
        setOptional(state.runtimeCapConfiguredMinutes, key: Key.runtimeCapConfiguredMinutes)
        setOptional(state.runtimeCapEndDate, key: Key.runtimeCapEndDate)
        setOptional(state.riskWarningAcceptedVersion, key: Key.riskWarningAcceptedVersion)
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

    private func setOptional(_ value: String?, key: String) {
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

struct UpdateInfo {
    let version: String
    let releaseURL: URL
    let downloadURL: URL?
}

enum UpdateStatus {
    case idle
    case checking
    case upToDate
    case available(UpdateInfo)
    case failed(String)

    var menuTitle: String {
        switch self {
        case .idle:
            return "Check for Updates"
        case .checking:
            return "Checking for Updates..."
        case .upToDate:
            return "You're Up to Date"
        case .available(let info):
            return "Install Update v\(info.version)"
        case .failed:
            return "Update Check Failed"
        }
    }

    var desktopValue: String {
        switch self {
        case .idle:
            return "Ready"
        case .checking:
            return "Checking"
        case .upToDate:
            return "Current"
        case .available(let info):
            return "v\(info.version)"
        case .failed:
            return "Offline"
        }
    }

    var accentColor: NSColor {
        switch self {
        case .idle:
            return NSColor(calibratedRed: 0.80, green: 0.88, blue: 1.00, alpha: 1.0)
        case .checking:
            return NSColor(calibratedRed: 0.47, green: 0.83, blue: 1.00, alpha: 1.0)
        case .upToDate:
            return NSColor(calibratedRed: 0.45, green: 0.93, blue: 0.72, alpha: 1.0)
        case .available:
            return NSColor(calibratedRed: 1.00, green: 0.79, blue: 0.38, alpha: 1.0)
        case .failed:
            return NSColor(calibratedRed: 1.00, green: 0.55, blue: 0.55, alpha: 1.0)
        }
    }

    var buttonTitle: String {
        switch self {
        case .available(let info):
            return "Install v\(info.version)"
        case .checking:
            return "Checking..."
        default:
            return "Check for Updates"
        }
    }

    var isChecking: Bool {
        if case .checking = self {
            return true
        }
        return false
    }
}

final class UpdateChecker {
    private struct ReleaseAsset: Decodable {
        let name: String
        let browser_download_url: String
    }

    private struct ReleasePayload: Decodable {
        let tag_name: String
        let html_url: String
        let assets: [ReleaseAsset]
    }

    enum UpdateError: LocalizedError {
        case invalidResponse
        case invalidReleaseURL

        var errorDescription: String? {
            switch self {
            case .invalidResponse:
                return "The release feed returned an invalid response."
            case .invalidReleaseURL:
                return "The release URL from GitHub is invalid."
            }
        }
    }

    func fetchLatestRelease(completion: @escaping (Result<UpdateInfo, Error>) -> Void) {
        var request = URLRequest(url: AppMeta.latestReleaseAPIURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("\(AppMeta.appName)/\(AppMeta.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { data, _, error in
            let result: Result<UpdateInfo, Error>

            if let error {
                result = .failure(error)
            } else if let data {
                do {
                    let payload = try JSONDecoder().decode(ReleasePayload.self, from: data)
                    guard let releaseURL = URL(string: payload.html_url) else {
                        throw UpdateError.invalidReleaseURL
                    }

                    let version = Self.normalizedVersion(payload.tag_name)
                    let dmgURL = payload.assets.first(where: { $0.name.lowercased().hasSuffix(".dmg") })
                        .flatMap { URL(string: $0.browser_download_url) }

                    result = .success(UpdateInfo(version: version, releaseURL: releaseURL, downloadURL: dmgURL))
                } catch {
                    result = .failure(error)
                }
            } else {
                result = .failure(UpdateError.invalidResponse)
            }

            DispatchQueue.main.async {
                completion(result)
            }
        }.resume()
    }

    static func isNewer(_ remoteVersion: String, than localVersion: String) -> Bool {
        normalizedVersion(remoteVersion).compare(normalizedVersion(localVersion), options: .numeric) == .orderedDescending
    }

    private static func normalizedVersion(_ version: String) -> String {
        let trimmed = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.lowercased().hasPrefix("v") {
            return String(trimmed.dropFirst())
        }
        return trimmed
    }
}

final class GradientBackdropView: NSView {
    private let gradientLayer = CAGradientLayer()
    private let glowLayerA = CALayer()
    private let glowLayerB = CALayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer = CALayer()
        layer?.masksToBounds = true

        gradientLayer.colors = [
            NSColor(calibratedRed: 0.06, green: 0.09, blue: 0.14, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.12, green: 0.18, blue: 0.29, alpha: 1.0).cgColor,
            NSColor(calibratedRed: 0.05, green: 0.07, blue: 0.11, alpha: 1.0).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0.0, y: 1.0)
        gradientLayer.endPoint = CGPoint(x: 1.0, y: 0.0)

        glowLayerA.backgroundColor = NSColor(calibratedRed: 0.50, green: 0.82, blue: 1.00, alpha: 0.18).cgColor
        glowLayerB.backgroundColor = NSColor(calibratedRed: 0.87, green: 0.95, blue: 1.00, alpha: 0.12).cgColor

        for glowLayer in [glowLayerA, glowLayerB] {
            glowLayer.shadowOpacity = 0.35
            glowLayer.shadowRadius = 80
            glowLayer.shadowColor = glowLayer.backgroundColor
            layer?.addSublayer(glowLayer)
        }

        layer?.insertSublayer(gradientLayer, at: 0)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        super.layout()
        gradientLayer.frame = bounds

        let width = bounds.width
        let height = bounds.height

        glowLayerA.frame = NSRect(x: width * 0.64, y: height * 0.54, width: 280, height: 280)
        glowLayerA.cornerRadius = 140

        glowLayerB.frame = NSRect(x: width * 0.05, y: height * 0.10, width: 220, height: 220)
        glowLayerB.cornerRadius = 110
    }
}

class GlassCardView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .behindWindow
        state = .active
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 28
        layer?.borderWidth = 1
        layer?.borderColor = NSColor(calibratedWhite: 1.0, alpha: 0.12).cgColor
        layer?.backgroundColor = NSColor(calibratedWhite: 1.0, alpha: 0.08).cgColor
        layer?.shadowColor = NSColor.black.withAlphaComponent(0.25).cgColor
        layer?.shadowOpacity = 0.35
        layer?.shadowRadius = 18
        layer?.shadowOffset = CGSize(width: 0, height: -4)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

final class MetricCardView: GlassCardView {
    private let titleField: NSTextField
    private let valueField: NSTextField

    init(title: String) {
        titleField = NSTextField(labelWithString: title.uppercased())
        valueField = NSTextField(labelWithString: "--")
        super.init(frame: .zero)

        titleField.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.62)

        valueField.font = NSFont.systemFont(ofSize: 24, weight: .bold)
        valueField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.95)

        let stack = NSStackView(views: [titleField, valueField])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false

        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 16),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -16),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: String, color: NSColor) {
        valueField.stringValue = value
        valueField.textColor = color
    }
}

struct ResourceSnapshot {
    let cpuText: String
    let memoryText: String
    let diskText: String
    let powerSource: PowerSourceKind
    let powerSourceText: String
    let batteryText: String
    let wifiText: String
    let bluetoothText: String
    let thermalLevel: ThermalPressureLevel
    let thermalText: String
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
        let powerSnapshot = powerSourceSnapshot()
        let powerSource = powerSnapshot.source
        let powerSourceText = "Power Source: \(powerSource.title)"
        let batteryText = powerSnapshot.batteryText
        let wifiText = wifiStatusText()
        let bluetoothText = bluetoothStatusText()
        let thermalLevel = thermalPressureLevel()
        let thermalText = "Thermal Pressure: \(thermalLevel.title)"
        let uptimeText = uptimeTextValue()

        return ResourceSnapshot(
            cpuText: cpuText,
            memoryText: memoryText,
            diskText: diskText,
            powerSource: powerSource,
            powerSourceText: powerSourceText,
            batteryText: batteryText,
            wifiText: wifiText,
            bluetoothText: bluetoothText,
            thermalLevel: thermalLevel,
            thermalText: thermalText,
            uptimeText: uptimeText
        )
    }

    func thermalPressureLevel() -> ThermalPressureLevel {
        ThermalPressureLevel(processState: ProcessInfo.processInfo.thermalState)
    }

    func powerSourceKind() -> PowerSourceKind {
        powerSourceSnapshot().source
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

    private func powerSourceSnapshot() -> PowerSourceSnapshot {
        let result = CommandRunner.run("/usr/bin/pmset", args: ["-g", "batt"])
        guard result.status == 0 else {
            return PowerSourceSnapshot(source: .unknown, batteryText: "Battery: N/A")
        }

        let lines = result.stdout
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }

        let source = parsePowerSourceKind(lines: lines)

        if lines.contains(where: { $0.lowercased().contains("no batteries") }) {
            return PowerSourceSnapshot(source: source == .unknown ? .noBattery : source, batteryText: "Battery: Not Present")
        }

        if let detail = lines.dropFirst().first(where: { $0.contains("%") }) {
            return PowerSourceSnapshot(source: source, batteryText: "Battery: \(detail)")
        }

        switch source {
        case .ac, .ups:
            return PowerSourceSnapshot(source: source, batteryText: "Battery: External Power")
        case .battery:
            return PowerSourceSnapshot(source: source, batteryText: "Battery: Battery Power")
        case .noBattery:
            return PowerSourceSnapshot(source: source, batteryText: "Battery: Not Present")
        case .unknown:
            return PowerSourceSnapshot(source: source, batteryText: "Battery: N/A")
        }
    }

    private func parsePowerSourceKind(lines: [String]) -> PowerSourceKind {
        let firstLine = lines.first?.lowercased() ?? ""

        if firstLine.contains("ac power") {
            return .ac
        }

        if firstLine.contains("battery power") {
            return .battery
        }

        if firstLine.contains("ups power") {
            return .ups
        }

        if firstLine.contains("no batteries") || lines.contains(where: { $0.lowercased().contains("no batteries") }) {
            return .noBattery
        }

        return .unknown
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
        lines.append("- acPowerOnlyModeEnabled: \(state.acPowerOnlyModeEnabled)")
        lines.append("- appScopedAwakeModeEnabled: \(state.appScopedAwakeModeEnabled)")
        lines.append("- appScopedAwakePolicy: \(AppScopedAwakePolicy(rawValue: state.appScopedAwakePolicyRaw)?.title ?? AppScopedAwakePolicy.anySelectedRunning.title)")
        lines.append("- appScopedBundleIdentifiers: \(state.appScopedBundleIdentifiers.isEmpty ? "none" : state.appScopedBundleIdentifiers.joined(separator: ", "))")
        lines.append("- thermalGuardEnabled: \(state.thermalGuardEnabled)")
        lines.append("- thermalGuardThreshold: \(ThermalPressureLevel(rawValue: state.thermalGuardThresholdRaw)?.title ?? ThermalPressureLevel.serious.title)")
        lines.append("- thermalGuardCooldownMinutes: \(state.thermalGuardCooldownMinutes)")
        lines.append("- thermalGuardCooldownUntil: \(state.thermalGuardCooldownUntil.map(PowerScheduler.userFacingDate) ?? "none")")
        lines.append("- runtimeCapConfiguredMinutes: \(state.runtimeCapConfiguredMinutes.map(String.init) ?? "none")")
        lines.append("- runtimeCapEndDate: \(state.runtimeCapEndDate.map(PowerScheduler.userFacingDate) ?? "none")")
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
    private let updateChecker = UpdateChecker()

    private var state: AppState

    private var sleepTimer: Timer?
    private var runtimeCapTimer: Timer?
    private var shutdownTimer: Timer?
    private var enableProtectionTimer: Timer?
    private var disableProtectionTimer: Timer?
    private var monitorTimer: Timer?
    private var updateTimer: Timer?

    private var restartTimestamps: [Date] = []
    private var isTerminating = false
    private var updateStatus: UpdateStatus = .idle

    private var statusItem: NSStatusItem?
    private var desktopWindow: NSWindow?
    private var desktopSummaryTextView: NSTextView?
    private var desktopEventLogTextView: NSTextView?
    private var desktopServiceButton: NSButton?
    private var desktopSleepButton: NSButton?
    private var desktopUpdateButton: NSButton?
    private var desktopACPowerOnlyButton: NSButton?
    private var desktopAppScopedButton: NSButton?
    private var desktopThermalGuardButton: NSButton?
    private var desktopServiceCard: MetricCardView?
    private var desktopProtectionCard: MetricCardView?
    private var desktopVersionCard: MetricCardView?
    private var desktopUpdateCard: MetricCardView?

    private let titleItem = NSMenuItem(title: AppMeta.shortName, action: nil, keyEquivalent: "")
    private let openDesktopModeItem = NSMenuItem(title: "Open N.S.M. Desktop Experience", action: #selector(openDesktopExperience), keyEquivalent: "")
    private let checkUpdatesItem = NSMenuItem(title: "Check for Updates", action: #selector(checkForUpdatesOrInstall), keyEquivalent: "")
    private let openWikiItem = NSMenuItem(title: "Open GitHub Wiki", action: #selector(openWiki), keyEquivalent: "")
    private let warningItem = NSMenuItem(title: AppMeta.riskWarningMenuTitle, action: nil, keyEquivalent: "")
    private let warningMenu = NSMenu(title: AppMeta.riskWarningMenuTitle)
    private let warningLineOneItem = NSMenuItem(title: AppMeta.riskWarningMenuLines[0], action: nil, keyEquivalent: "")
    private let warningLineTwoItem = NSMenuItem(title: AppMeta.riskWarningMenuLines[1], action: nil, keyEquivalent: "")
    private let warningLineThreeItem = NSMenuItem(title: AppMeta.riskWarningMenuLines[2], action: nil, keyEquivalent: "")
    private let warningLineFourItem = NSMenuItem(title: AppMeta.riskWarningMenuLines[3], action: nil, keyEquivalent: "")
    private let warningReviewItem = NSMenuItem(title: "Review Full Notice...", action: #selector(showUsageWarningFromMenu), keyEquivalent: "")

    private let resourceItem = NSMenuItem(title: "Mini Resource Monitor", action: nil, keyEquivalent: "")
    private let resourceMenu = NSMenu(title: "Mini Resource Monitor")
    private let resourceCPUItem = NSMenuItem(title: "CPU: --", action: nil, keyEquivalent: "")
    private let resourceMemoryItem = NSMenuItem(title: "Memory: --", action: nil, keyEquivalent: "")
    private let resourceDiskItem = NSMenuItem(title: "Disk: --", action: nil, keyEquivalent: "")
    private let resourceBatteryItem = NSMenuItem(title: "Battery: --", action: nil, keyEquivalent: "")
    private let resourceWiFiItem = NSMenuItem(title: "Wi-Fi: --", action: nil, keyEquivalent: "")
    private let resourceBluetoothItem = NSMenuItem(title: "Bluetooth: --", action: nil, keyEquivalent: "")
    private let resourceThermalItem = NSMenuItem(title: "Thermal Pressure: --", action: nil, keyEquivalent: "")
    private let resourceUptimeItem = NSMenuItem(title: "Uptime: --", action: nil, keyEquivalent: "")

    private let serviceToggleItem = NSMenuItem(title: "Enable Service", action: #selector(toggleService), keyEquivalent: "")
    private let sleepToggleItem = NSMenuItem(title: "Prevent Sleep", action: #selector(toggleSleepPrevention), keyEquivalent: "")
    private let autoWakeToggleItem = NSMenuItem(title: "Auto-Reenable After Wake", action: #selector(toggleAutoReenableAfterWake), keyEquivalent: "")
    private let watchdogToggleItem = NSMenuItem(title: "Service Watchdog", action: #selector(toggleServiceWatchdog), keyEquivalent: "")
    private let acPowerOnlyItem = NSMenuItem(title: "AC Power Only Mode", action: nil, keyEquivalent: "")
    private let acPowerOnlyMenu = NSMenu(title: "AC Power Only Mode")
    private let acPowerOnlyStatusItem = NSMenuItem(title: "Status: --", action: nil, keyEquivalent: "")
    private let acPowerOnlyToggleItem = NSMenuItem(title: "Enable AC Power Only Mode", action: #selector(toggleACPowerOnlyMode), keyEquivalent: "")
    private let acPowerOnlyReviewItem = NSMenuItem(title: "Review Power Source Status...", action: #selector(showACPowerOnlyStatus), keyEquivalent: "")
    private let appScopedItem = NSMenuItem(title: "App-Scoped Awake Mode", action: nil, keyEquivalent: "")
    private let appScopedMenu = NSMenu(title: "App-Scoped Awake Mode")
    private let appScopedStatusItem = NSMenuItem(title: "Status: --", action: nil, keyEquivalent: "")
    private let appScopedToggleItem = NSMenuItem(title: "Enable App-Scoped Awake Mode", action: #selector(toggleAppScopedAwakeMode), keyEquivalent: "")
    private let appScopedPolicyItem = NSMenuItem(title: "Match Policy", action: nil, keyEquivalent: "")
    private let appScopedPolicyMenu = NSMenu(title: "Match Policy")
    private let appScopedAddFrontmostItem = NSMenuItem(title: "Add Current Frontmost App", action: #selector(addFrontmostAppToScopedAwakeList), keyEquivalent: "")
    private let appScopedAddRunningItem = NSMenuItem(title: "Add Running App", action: nil, keyEquivalent: "")
    private let appScopedAddRunningMenu = NSMenu(title: "Add Running App")
    private let appScopedRemoveItem = NSMenuItem(title: "Remove Selected App", action: nil, keyEquivalent: "")
    private let appScopedRemoveMenu = NSMenu(title: "Remove Selected App")
    private let appScopedClearItem = NSMenuItem(title: "Clear Selected Apps", action: #selector(clearScopedAwakeApps), keyEquivalent: "")
    private let appScopedReviewItem = NSMenuItem(title: "Review Scoped App Status...", action: #selector(showAppScopedAwakeStatus), keyEquivalent: "")
    private var appScopedPolicyOptionItems: [AppScopedAwakePolicy: NSMenuItem] = [:]
    private let thermalGuardItem = NSMenuItem(title: "Thermal Guard", action: nil, keyEquivalent: "")
    private let thermalGuardMenu = NSMenu(title: "Thermal Guard")
    private let thermalGuardStatusItem = NSMenuItem(title: "Status: --", action: nil, keyEquivalent: "")
    private let thermalGuardToggleItem = NSMenuItem(title: "Enable Thermal Guard", action: #selector(toggleThermalGuard), keyEquivalent: "")
    private let thermalGuardThresholdItem = NSMenuItem(title: "Trip Threshold", action: nil, keyEquivalent: "")
    private let thermalGuardThresholdMenu = NSMenu(title: "Trip Threshold")
    private let thermalGuardCooldownItem = NSMenuItem(title: "Cooldown", action: nil, keyEquivalent: "")
    private let thermalGuardCooldownMenu = NSMenu(title: "Cooldown")
    private let thermalGuardClearCooldownItem = NSMenuItem(title: "Clear Cooldown Now", action: #selector(clearThermalGuardCooldownManually), keyEquivalent: "")
    private let thermalGuardReviewItem = NSMenuItem(title: "Review Thermal Guard Status...", action: #selector(showThermalGuardStatus), keyEquivalent: "")
    private var thermalGuardThresholdOptionItems: [ThermalPressureLevel: NSMenuItem] = [:]
    private var thermalGuardCooldownOptionItems: [Int: NSMenuItem] = [:]
    private let runtimeCapItem = NSMenuItem(title: "Max Runtime Cap", action: nil, keyEquivalent: "")
    private let runtimeCapMenu = NSMenu(title: "Max Runtime Cap")
    private let runtimeCapStatusItem = NSMenuItem(title: "Status: Off", action: nil, keyEquivalent: "")
    private let runtimeCapOffItem = NSMenuItem(title: "Off", action: #selector(disableRuntimeCap), keyEquivalent: "")
    private let runtimeCapSetUntilItem = NSMenuItem(title: "Set Until Date/Time...", action: #selector(promptRuntimeCapUntilDate), keyEquivalent: "")
    private var runtimeCapOptionItems: [Int: NSMenuItem] = [:]

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
    private let providedByItem = NSMenuItem(title: "Provided BY: WayneTechLab.com", action: #selector(openProviderWebsite), keyEquivalent: "")

    private let sleepTimerOptions: [Int] = [30, 60, 120, 240]
    private let runtimeCapOptions: [Int] = [120, 240, 480]
    private let shutdownTimerOptions: [Int] = [15, 30, 60, 120]
    private let appScopedPolicyOptions: [AppScopedAwakePolicy] = [.anySelectedRunning, .frontmostSelectedApp]
    private let thermalGuardThresholdOptions: [ThermalPressureLevel] = [.fair, .serious, .critical]
    private let thermalGuardCooldownOptions: [Int] = [5, 15, 30, 60]

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
        startUpdateTimer()

        serviceController.onUnexpectedTermination = { [weak self] status, details in
            self?.handleUnexpectedServiceTermination(status: status, details: details)
        }

        synchronizeLaunchAtBootState()
        guard presentFirstLaunchWarningIfNeeded() else {
            return
        }
        applyStateOnLaunch()
        refreshMenuState()

        EventLog.shared.add("\(AppMeta.shortName) launched.")
    }

    func applicationWillTerminate(_ notification: Notification) {
        isTerminating = true
        EventLog.shared.add("\(AppMeta.shortName) is terminating.")

        sleepTimer?.invalidate()
        runtimeCapTimer?.invalidate()
        shutdownTimer?.invalidate()
        enableProtectionTimer?.invalidate()
        disableProtectionTimer?.invalidate()
        monitorTimer?.invalidate()
        updateTimer?.invalidate()

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
            button.toolTip = "\(AppMeta.appName) v\(AppMeta.currentVersion) • Provided BY: \(AppMeta.providerName)"
        }

        titleItem.isEnabled = false
        wakeScheduleInfoItem.isEnabled = false
        enableScheduleInfoItem.isEnabled = false
        disableScheduleInfoItem.isEnabled = false

        buildWarningMenu()
        buildResourceMenu()
        buildACPowerOnlyMenu()
        buildAppScopedMenu()
        buildThermalGuardMenu()
        buildRuntimeCapMenu()

        openDesktopModeItem.target = self
        checkUpdatesItem.target = self
        openWikiItem.target = self
        warningReviewItem.target = self
        serviceToggleItem.target = self
        sleepToggleItem.target = self
        autoWakeToggleItem.target = self
        watchdogToggleItem.target = self
        acPowerOnlyToggleItem.target = self
        acPowerOnlyReviewItem.target = self
        appScopedToggleItem.target = self
        appScopedAddFrontmostItem.target = self
        appScopedClearItem.target = self
        appScopedReviewItem.target = self
        thermalGuardToggleItem.target = self
        thermalGuardClearCooldownItem.target = self
        thermalGuardReviewItem.target = self
        runtimeCapOffItem.target = self
        runtimeCapSetUntilItem.target = self
        launchAtBootItem.target = self
        restartServiceItem.target = self
        runSelfTestItem.target = self
        copyStatusItem.target = self
        exportDiagnosticsItem.target = self
        providedByItem.target = self

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
        menu.addItem(checkUpdatesItem)
        menu.addItem(openWikiItem)
        menu.addItem(warningItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(resourceItem)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(serviceToggleItem)
        menu.addItem(sleepToggleItem)
        menu.addItem(autoWakeToggleItem)
        menu.addItem(watchdogToggleItem)
        menu.addItem(acPowerOnlyItem)
        menu.addItem(appScopedItem)
        menu.addItem(thermalGuardItem)
        menu.addItem(runtimeCapItem)
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
        menu.addItem(providedByItem)
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
    }

    private func buildWarningMenu() {
        warningMenu.removeAllItems()

        for item in [warningLineOneItem, warningLineTwoItem, warningLineThreeItem, warningLineFourItem] {
            item.isEnabled = false
            warningMenu.addItem(item)
        }

        warningMenu.addItem(NSMenuItem.separator())
        warningMenu.addItem(warningReviewItem)
        warningItem.submenu = warningMenu
    }

    private func buildResourceMenu() {
        for item in [resourceCPUItem, resourceMemoryItem, resourceDiskItem, resourceBatteryItem, resourceWiFiItem, resourceBluetoothItem, resourceThermalItem, resourceUptimeItem] {
            item.isEnabled = false
            resourceMenu.addItem(item)
        }

        resourceItem.submenu = resourceMenu
    }

    private func buildACPowerOnlyMenu() {
        acPowerOnlyMenu.removeAllItems()

        acPowerOnlyStatusItem.isEnabled = false
        acPowerOnlyMenu.addItem(acPowerOnlyStatusItem)
        acPowerOnlyMenu.addItem(NSMenuItem.separator())
        acPowerOnlyMenu.addItem(acPowerOnlyToggleItem)
        acPowerOnlyMenu.addItem(NSMenuItem.separator())
        acPowerOnlyMenu.addItem(acPowerOnlyReviewItem)
        acPowerOnlyItem.submenu = acPowerOnlyMenu
    }

    private func buildAppScopedMenu() {
        appScopedMenu.removeAllItems()
        appScopedPolicyMenu.removeAllItems()
        appScopedAddRunningMenu.removeAllItems()
        appScopedRemoveMenu.removeAllItems()
        appScopedPolicyOptionItems.removeAll()

        appScopedStatusItem.isEnabled = false
        appScopedMenu.addItem(appScopedStatusItem)
        appScopedMenu.addItem(NSMenuItem.separator())
        appScopedMenu.addItem(appScopedToggleItem)

        for policy in appScopedPolicyOptions {
            let item = NSMenuItem(title: policy.title, action: #selector(selectAppScopedAwakePolicy(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: policy.rawValue)
            appScopedPolicyMenu.addItem(item)
            appScopedPolicyOptionItems[policy] = item
        }

        appScopedPolicyItem.submenu = appScopedPolicyMenu
        appScopedMenu.addItem(appScopedPolicyItem)
        appScopedMenu.addItem(NSMenuItem.separator())
        appScopedMenu.addItem(appScopedAddFrontmostItem)
        appScopedAddRunningItem.submenu = appScopedAddRunningMenu
        appScopedMenu.addItem(appScopedAddRunningItem)
        appScopedRemoveItem.submenu = appScopedRemoveMenu
        appScopedMenu.addItem(appScopedRemoveItem)
        appScopedMenu.addItem(appScopedClearItem)
        appScopedMenu.addItem(NSMenuItem.separator())
        appScopedMenu.addItem(appScopedReviewItem)
        appScopedItem.submenu = appScopedMenu
    }

    private func buildThermalGuardMenu() {
        thermalGuardMenu.removeAllItems()
        thermalGuardThresholdMenu.removeAllItems()
        thermalGuardCooldownMenu.removeAllItems()
        thermalGuardThresholdOptionItems.removeAll()
        thermalGuardCooldownOptionItems.removeAll()

        thermalGuardStatusItem.isEnabled = false
        thermalGuardMenu.addItem(thermalGuardStatusItem)
        thermalGuardMenu.addItem(NSMenuItem.separator())
        thermalGuardMenu.addItem(thermalGuardToggleItem)

        for level in thermalGuardThresholdOptions {
            let item = NSMenuItem(title: level.title, action: #selector(selectThermalGuardThreshold(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: level.rawValue)
            thermalGuardThresholdMenu.addItem(item)
            thermalGuardThresholdOptionItems[level] = item
        }

        thermalGuardThresholdItem.submenu = thermalGuardThresholdMenu
        thermalGuardMenu.addItem(thermalGuardThresholdItem)

        for minutes in thermalGuardCooldownOptions {
            let item = NSMenuItem(title: "\(minutes) Minutes", action: #selector(selectThermalGuardCooldown(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: minutes)
            thermalGuardCooldownMenu.addItem(item)
            thermalGuardCooldownOptionItems[minutes] = item
        }

        thermalGuardCooldownItem.submenu = thermalGuardCooldownMenu
        thermalGuardMenu.addItem(thermalGuardCooldownItem)
        thermalGuardMenu.addItem(thermalGuardClearCooldownItem)
        thermalGuardMenu.addItem(NSMenuItem.separator())
        thermalGuardMenu.addItem(thermalGuardReviewItem)
        thermalGuardItem.submenu = thermalGuardMenu
    }

    private func buildRuntimeCapMenu() {
        runtimeCapMenu.removeAllItems()
        runtimeCapOptionItems.removeAll()

        runtimeCapStatusItem.isEnabled = false
        runtimeCapMenu.addItem(runtimeCapStatusItem)
        runtimeCapMenu.addItem(NSMenuItem.separator())
        runtimeCapMenu.addItem(runtimeCapOffItem)

        for minutes in runtimeCapOptions {
            let item = NSMenuItem(title: displayTitle(forMinutes: minutes), action: #selector(selectRuntimeCapOption(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = NSNumber(value: minutes)
            runtimeCapMenu.addItem(item)
            runtimeCapOptionItems[minutes] = item
        }

        runtimeCapMenu.addItem(NSMenuItem.separator())
        runtimeCapMenu.addItem(runtimeCapSetUntilItem)
        runtimeCapItem.submenu = runtimeCapMenu
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
        button.controlSize = .large
        button.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        button.contentTintColor = .white
        button.bezelColor = NSColor(calibratedRed: 0.28, green: 0.62, blue: 0.95, alpha: 0.92)
        return button
    }

    private func makeDesktopLinkButton(title: String, action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.isBordered = false
        button.font = NSFont.systemFont(ofSize: 13, weight: .medium)
        button.contentTintColor = NSColor(calibratedRed: 0.76, green: 0.88, blue: 1.0, alpha: 1.0)
        return button
    }

    private func makeDesktopTextView(initialText: String) -> NSTextView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.88)
        textView.textContainerInset = NSSize(width: 10, height: 12)
        textView.string = initialText

        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        }

        return textView
    }

    private func wrapScrollContent(title: String, textView: NSTextView, minHeight: CGFloat) -> GlassCardView {
        let card = GlassCardView()

        let titleField = NSTextField(labelWithString: title)
        titleField.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        titleField.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.96)

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.documentView = textView

        let stack = NSStackView(views: [titleField, scrollView])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -18),
            stack.widthAnchor.constraint(equalTo: card.widthAnchor, constant: -36),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: minHeight)
        ])

        return card
    }

    private func ensureDesktopWindow() -> NSWindow {
        if let desktopWindow {
            return desktopWindow
        }

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 860),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = AppMeta.appName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 980, height: 680)
        window.collectionBehavior.insert(.fullScreenPrimary)
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()

        if #available(macOS 11.0, *) {
            window.toolbarStyle = .unifiedCompact
        }

        let backdropView = GradientBackdropView()
        backdropView.translatesAutoresizingMaskIntoConstraints = false
        window.contentView = backdropView

        let shellCard = GlassCardView()
        backdropView.addSubview(shellCard)

        let eyebrowLabel = NSTextField(labelWithString: "PROVIDED BY \(AppMeta.providerName.uppercased())")
        eyebrowLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        eyebrowLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.58)

        let titleLabel = NSTextField(labelWithString: AppMeta.appName)
        titleLabel.font = NSFont.systemFont(ofSize: 36, weight: .black)
        titleLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.98)

        let subtitleLabel = NSTextField(labelWithString: "2026 glass control surface for uptime, sleep protection, and power orchestration.")
        subtitleLabel.font = NSFont.systemFont(ofSize: 14, weight: .medium)
        subtitleLabel.textColor = NSColor(calibratedWhite: 1.0, alpha: 0.72)

        let providerButton = makeDesktopLinkButton(title: "WayneTechLab.com", action: #selector(openProviderWebsite))
        let wikiButton = makeDesktopLinkButton(title: "GitHub Wiki", action: #selector(openWiki))

        let linkStack = NSStackView(views: [providerButton, wikiButton])
        linkStack.orientation = .horizontal
        linkStack.alignment = .centerY
        linkStack.spacing = 16

        let headerStack = NSStackView(views: [eyebrowLabel, titleLabel, subtitleLabel, linkStack])
        headerStack.orientation = .vertical
        headerStack.alignment = .leading
        headerStack.spacing = 6

        let desktopServiceButton = makeDesktopActionButton(title: "Enable Service", action: #selector(desktopToggleService))
        let desktopSleepButton = makeDesktopActionButton(title: "Enable Sleep Prevention", action: #selector(desktopToggleSleep))
        let desktopUpdateButton = makeDesktopActionButton(title: "Check for Updates", action: #selector(checkForUpdatesOrInstall))
        let desktopACPowerOnlyButton = makeDesktopActionButton(title: "Enable AC Power Only", action: #selector(desktopToggleACPowerOnlyMode))
        let desktopAppScopedButton = makeDesktopActionButton(title: "Enable App-Scoped Mode", action: #selector(desktopToggleAppScopedAwakeMode))
        let desktopThermalGuardButton = makeDesktopActionButton(title: "Disable Thermal Guard", action: #selector(desktopToggleThermalGuard))
        let openEventLogButton = makeDesktopActionButton(title: "Open Event Log", action: #selector(openEventLog))
        let openServiceLogButton = makeDesktopActionButton(title: "Open Service Log", action: #selector(openServiceLog))
        let exportDiagnosticsButton = makeDesktopActionButton(title: "Export Diagnostics", action: #selector(exportDiagnostics))
        let closeDesktopButton = makeDesktopActionButton(title: "Close Desktop Mode", action: #selector(closeDesktopExperience))
        closeDesktopButton.bezelColor = NSColor(calibratedWhite: 1.0, alpha: 0.16)

        let actionStack = NSStackView(views: [
            desktopServiceButton,
            desktopSleepButton,
            desktopUpdateButton,
            desktopUpdateButton,
            desktopACPowerOnlyButton,
            desktopAppScopedButton,
            desktopThermalGuardButton,
            openEventLogButton,
            openServiceLogButton,
            exportDiagnosticsButton,
            closeDesktopButton
        ])
        actionStack.orientation = .horizontal
        actionStack.alignment = .centerY
        actionStack.spacing = 10
        actionStack.distribution = .fillProportionally

        let desktopServiceCard = MetricCardView(title: "Service")
        let desktopProtectionCard = MetricCardView(title: "Sleep Shield")
        let desktopVersionCard = MetricCardView(title: "Version")
        let desktopUpdateCard = MetricCardView(title: "Update")

        let metricStack = NSStackView(views: [
            desktopServiceCard,
            desktopProtectionCard,
            desktopVersionCard,
            desktopUpdateCard
        ])
        metricStack.orientation = .horizontal
        metricStack.alignment = .top
        metricStack.spacing = 12
        metricStack.distribution = .fillEqually

        let summaryTextView = makeDesktopTextView(initialText: "Preparing control-plane summary...")
        let eventLogTextView = makeDesktopTextView(initialText: "Waiting for event history...")

        let summaryCard = wrapScrollContent(title: "Control Plane + Telemetry", textView: summaryTextView, minHeight: 220)
        let eventLogCard = wrapScrollContent(title: "Event History", textView: eventLogTextView, minHeight: 280)

        let contentStack = NSStackView(views: [summaryCard, eventLogCard])
        contentStack.orientation = .vertical
        contentStack.alignment = .leading
        contentStack.spacing = 14
        contentStack.translatesAutoresizingMaskIntoConstraints = false

        let rootStack = NSStackView(views: [headerStack, actionStack, metricStack, contentStack])
        rootStack.orientation = .vertical
        rootStack.alignment = .leading
        rootStack.spacing = 16
        rootStack.translatesAutoresizingMaskIntoConstraints = false

        shellCard.addSubview(rootStack)

        NSLayoutConstraint.activate([
            shellCard.leadingAnchor.constraint(equalTo: backdropView.leadingAnchor, constant: 18),
            shellCard.trailingAnchor.constraint(equalTo: backdropView.trailingAnchor, constant: -18),
            shellCard.topAnchor.constraint(equalTo: backdropView.topAnchor, constant: 18),
            shellCard.bottomAnchor.constraint(equalTo: backdropView.bottomAnchor, constant: -18),

            rootStack.leadingAnchor.constraint(equalTo: shellCard.leadingAnchor, constant: 22),
            rootStack.trailingAnchor.constraint(equalTo: shellCard.trailingAnchor, constant: -22),
            rootStack.topAnchor.constraint(equalTo: shellCard.topAnchor, constant: 22),
            rootStack.bottomAnchor.constraint(equalTo: shellCard.bottomAnchor, constant: -22),

            headerStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            actionStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            metricStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            contentStack.widthAnchor.constraint(equalTo: rootStack.widthAnchor),
            metricStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 96)
        ])

        self.desktopWindow = window
        self.desktopSummaryTextView = summaryTextView
        self.desktopEventLogTextView = eventLogTextView
        self.desktopServiceButton = desktopServiceButton
        self.desktopSleepButton = desktopSleepButton
        self.desktopUpdateButton = desktopUpdateButton
        self.desktopACPowerOnlyButton = desktopACPowerOnlyButton
        self.desktopAppScopedButton = desktopAppScopedButton
        self.desktopThermalGuardButton = desktopThermalGuardButton
        self.desktopServiceCard = desktopServiceCard
        self.desktopProtectionCard = desktopProtectionCard
        self.desktopVersionCard = desktopVersionCard
        self.desktopUpdateCard = desktopUpdateCard

        return window
    }

    private func refreshDesktopWindowState(resourceSnapshot: ResourceSnapshot? = nil) {
        guard let desktopSummaryTextView, let desktopEventLogTextView else {
            return
        }

        desktopServiceButton?.title = serviceController.isRunning ? "Disable Service" : "Enable Service"
        desktopACPowerOnlyButton?.title = state.acPowerOnlyModeEnabled ? "Disable AC Power Only" : "Enable AC Power Only"
        desktopAppScopedButton?.title = state.appScopedAwakeModeEnabled ? "Disable App-Scoped Mode" : "Enable App-Scoped Mode"
        desktopThermalGuardButton?.title = state.thermalGuardEnabled ? "Disable Thermal Guard" : "Enable Thermal Guard"
        desktopUpdateButton?.title = updateStatus.buttonTitle
        desktopUpdateButton?.isEnabled = !updateStatus.isChecking

        let snapshot = resourceSnapshot ?? resourceMonitor.sample()
        let thermalGuardCooldownText = thermalGuardCooldownRemainingText()
        let acPowerOnlyBlocked = state.acPowerOnlyModeEnabled && !snapshot.powerSource.isExternalPower
        let appScopedBlocked = appScopedAwakeBlocksManualEnable()

        desktopSleepButton?.title = blocker.isActive
            ? "Disable Sleep Prevention"
            : (
                thermalGuardCooldownText.map { "Cooling Down (\($0) left)" }
                ?? (acPowerOnlyBlocked ? "AC Power Required" : (appScopedBlocked ? "Waiting for App Match" : "Enable Sleep Prevention"))
            )
        desktopSleepButton?.isEnabled = blocker.isActive || (thermalGuardCooldownText == nil && !acPowerOnlyBlocked && !appScopedBlocked)

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

        desktopServiceCard?.update(
            value: serviceController.isRunning ? "Running" : "Standby",
            color: serviceController.isRunning
                ? NSColor(calibratedRed: 0.55, green: 0.93, blue: 0.73, alpha: 1.0)
                : NSColor(calibratedWhite: 1.0, alpha: 0.78)
        )
        desktopProtectionCard?.update(
            value: blocker.isActive ? "Armed" : "Idle",
            color: blocker.isActive
                ? NSColor(calibratedRed: 0.55, green: 0.93, blue: 0.73, alpha: 1.0)
                : NSColor(calibratedWhite: 1.0, alpha: 0.78)
        )
        desktopVersionCard?.update(
            value: "v\(AppMeta.currentVersion)",
            color: NSColor(calibratedRed: 0.83, green: 0.91, blue: 1.0, alpha: 1.0)
        )
        desktopUpdateCard?.update(value: updateStatus.desktopValue, color: updateStatus.accentColor)

        var lines: [String] = []
        lines.append("Version: v\(AppMeta.currentVersion) (build \(AppMeta.currentBuild))")
        lines.append("Provided BY: \(AppMeta.providerName)")
        lines.append("")
        lines.append("Control Plane")
        lines.append("- Service: \(serviceController.isRunning ? "Running" : "Stopped")")
        lines.append("- Sleep Prevention: \(blocker.isActive ? "On" : "Off")")
        lines.append("- Power Source: \(snapshot.powerSource.title)")
        lines.append("- Launch at Boot: \(state.launchAtBoot ? "Enabled" : "Disabled")")
        lines.append("- Auto-Reenable After Wake: \(state.autoReenableAfterWake ? "Enabled" : "Disabled")")
        lines.append("- Service Watchdog: \(state.serviceWatchdogEnabled ? "Enabled" : "Disabled")")
        lines.append("- Update Status: \(updateStatus.menuTitle)")
        lines.append("- AC Power Only Mode: \(state.acPowerOnlyModeEnabled ? (snapshot.powerSource.isExternalPower ? "Enabled (ready)" : "Enabled (blocking on \(snapshot.powerSource.title))") : "Disabled")")
        lines.append("- App-Scoped Awake Mode: \(appScopedAwakeStatusText())")
        lines.append("- App-Scoped Policy: \(appScopedAwakePolicy().title)")
        lines.append("- App-Scoped Apps: \(state.appScopedBundleIdentifiers.isEmpty ? "None" : state.appScopedBundleIdentifiers.map(scopedAwakeDisplayName(forBundleIdentifier:)).joined(separator: ", "))")
        lines.append("- Thermal Guard: \(state.thermalGuardEnabled ? "Enabled" : "Disabled")")
        lines.append("- Thermal Guard Threshold: \(thermalGuardThreshold().title)")
        lines.append("- Thermal Guard Cooldown: \(thermalGuardCooldownText.map { "\($0) left" } ?? "Ready")")
        lines.append("- Max Runtime Cap: \(runtimeCapStatusText())")
        lines.append("")
        lines.append("Timers + Scheduling")
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
        lines.append("- \(snapshot.powerSourceText)")
        lines.append("- \(snapshot.batteryText)")
        lines.append("- Wi-Fi: \(snapshot.wifiText)")
        lines.append("- Bluetooth: \(snapshot.bluetoothText)")
        lines.append("- \(snapshot.thermalText)")
        lines.append("- \(snapshot.uptimeText)")
        desktopSummaryTextView.string = lines.joined(separator: "\n")

        let recentEvents = EventLog.shared.snapshot().suffix(140)
        desktopEventLogTextView.string = recentEvents.isEmpty
            ? "No event history yet."
            : recentEvents.joined(separator: "\n")
    }

    private func startUpdateTimer() {
        updateTimer?.invalidate()
        updateTimer = Timer.scheduledTimer(withTimeInterval: 21600, repeats: true) { [weak self] _ in
            self?.performUpdateCheck(userInitiated: false)
        }

        if let updateTimer {
            RunLoop.main.add(updateTimer, forMode: .common)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            self?.performUpdateCheck(userInitiated: false)
        }
    }

    private func showMessageAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()
    }

    private func showUpdateAvailableAlert(_ info: UpdateInfo) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        alert.informativeText = "Nope-Sleep Mac v\(info.version) is available. Open the release now?"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Update")
        alert.addButton(withTitle: "Not Now")
        NSApplication.shared.activate(ignoringOtherApps: true)

        if alert.runModal() == .alertFirstButtonReturn {
            openUpdateDestination(info)
        }
    }

    private func performUpdateCheck(userInitiated: Bool) {
        guard !updateStatus.isChecking else {
            return
        }

        updateStatus = .checking
        refreshMenuState()

        updateChecker.fetchLatestRelease { [weak self] result in
            guard let self else {
                return
            }

            switch result {
            case .success(let info):
                if UpdateChecker.isNewer(info.version, than: AppMeta.currentVersion) {
                    updateStatus = .available(info)
                    EventLog.shared.add("Update available: v\(info.version).")
                    if userInitiated {
                        showUpdateAvailableAlert(info)
                    }
                } else {
                    updateStatus = .upToDate
                    if userInitiated {
                        showMessageAlert(
                            title: "You're Up to Date",
                            message: "\(AppMeta.appName) is already on the latest version installed here: v\(AppMeta.currentVersion)."
                        )
                    }
                }
            case .failure(let error):
                updateStatus = .failed(error.localizedDescription)
                EventLog.shared.add("Update check failed: \(error.localizedDescription)")
                if userInitiated {
                    showMessageAlert(
                        title: "Update Check Failed",
                        message: error.localizedDescription
                    )
                }
            }

            refreshMenuState()
        }
    }

    private func openUpdateDestination(_ info: UpdateInfo?) {
        let destination = info?.downloadURL ?? info?.releaseURL ?? AppMeta.latestReleaseURL
        NSWorkspace.shared.open(destination)
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

        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didActivateApplicationNotification
        ] {
            let token = workspaceCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.refreshMenuState()
            }
            workspaceObservers.append(token)
        }

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

    private func thermalGuardThreshold() -> ThermalPressureLevel {
        ThermalPressureLevel(rawValue: state.thermalGuardThresholdRaw) ?? .serious
    }

    private func presentACPowerRequiredAlert(currentSource: PowerSourceKind) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "External Power Required"
        alert.informativeText = """
        AC Power Only Mode is enabled, so sleep prevention can only run while the Mac is on external power.

        Current power source: \(currentSource.title). Reconnect the charger or disable AC Power Only Mode to continue.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func evaluateACPowerOnlyMode(using snapshot: ResourceSnapshot) {
        guard state.acPowerOnlyModeEnabled else {
            return
        }

        guard blocker.isActive else {
            return
        }

        guard !snapshot.powerSource.isExternalPower else {
            return
        }

        blocker.deactivate()
        state.preventSleep = false
        clearSleepTimer(logChange: false)
        handleProtectionDisabledForRuntimeCap()
        stateStore.save(state)

        EventLog.shared.add(
            "AC Power Only Mode disabled sleep prevention because current power source is \(snapshot.powerSource.title)."
        )
    }

    private func appScopedAwakePolicy() -> AppScopedAwakePolicy {
        AppScopedAwakePolicy(rawValue: state.appScopedAwakePolicyRaw) ?? .anySelectedRunning
    }

    private func normalizedScopedAwakeBundleIdentifiers(_ bundleIdentifiers: [String]) -> [String] {
        var seen: Set<String> = []
        var ordered: [String] = []

        for bundleIdentifier in bundleIdentifiers {
            let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed) else {
                continue
            }

            seen.insert(trimmed)
            ordered.append(trimmed)
        }

        return ordered
    }

    private func scopedAwakeCandidateApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications
            .filter { app in
                guard let bundleIdentifier = app.bundleIdentifier, !bundleIdentifier.isEmpty else {
                    return false
                }

                return bundleIdentifier != Bundle.main.bundleIdentifier && app.activationPolicy != .prohibited
            }
            .sorted { lhs, rhs in
                let left = (lhs.localizedName ?? lhs.bundleIdentifier ?? "").localizedCaseInsensitiveCompare(rhs.localizedName ?? rhs.bundleIdentifier ?? "")
                return left == .orderedAscending
            }
    }

    private func scopedAwakeDisplayName(for application: NSRunningApplication) -> String {
        if let localizedName = application.localizedName, !localizedName.isEmpty {
            return localizedName
        }

        if let bundleIdentifier = application.bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }

        return application.bundleURL?.deletingPathExtension().lastPathComponent ?? "Unknown App"
    }

    private func scopedAwakeDisplayName(forBundleIdentifier bundleIdentifier: String) -> String {
        if let runningApplication = scopedAwakeCandidateApplications().first(where: { $0.bundleIdentifier == bundleIdentifier }) {
            return scopedAwakeDisplayName(for: runningApplication)
        }

        return bundleIdentifier
    }

    private func selectedScopedAppRecords() -> [ScopedAppRecord] {
        let selectedBundleIdentifiers = normalizedScopedAwakeBundleIdentifiers(state.appScopedBundleIdentifiers)
        let runningApplications = scopedAwakeCandidateApplications()
        let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        return selectedBundleIdentifiers.map { bundleIdentifier in
            let runningMatches = runningApplications.filter { $0.bundleIdentifier == bundleIdentifier }
            let displayName = runningMatches.first.map(scopedAwakeDisplayName(for:)) ?? scopedAwakeDisplayName(forBundleIdentifier: bundleIdentifier)

            return ScopedAppRecord(
                bundleIdentifier: bundleIdentifier,
                displayName: displayName,
                isRunning: !runningMatches.isEmpty,
                isFrontmost: frontmostBundleIdentifier == bundleIdentifier
            )
        }
    }

    private func matchedScopedAppRecords(from records: [ScopedAppRecord]) -> [ScopedAppRecord] {
        switch appScopedAwakePolicy() {
        case .anySelectedRunning:
            return records.filter(\.isRunning)
        case .frontmostSelectedApp:
            return records.filter(\.isFrontmost)
        }
    }

    private func appScopedAwakeStatusText(records: [ScopedAppRecord]? = nil) -> String {
        let currentRecords = records ?? selectedScopedAppRecords()

        guard state.appScopedAwakeModeEnabled else {
            return "Disabled"
        }

        guard !currentRecords.isEmpty else {
            return "Enabled • No apps selected"
        }

        let matchedRecords = matchedScopedAppRecords(from: currentRecords)
        if !matchedRecords.isEmpty {
            let names = matchedRecords.map(\.displayName).joined(separator: ", ")
            return "Active • \(names)"
        }

        return "Armed • Waiting for \(appScopedAwakePolicy() == .frontmostSelectedApp ? "frontmost selected app" : "selected app")"
    }

    private func appScopedAwakeBlocksManualEnable(records: [ScopedAppRecord]? = nil) -> Bool {
        let currentRecords = records ?? selectedScopedAppRecords()

        guard state.appScopedAwakeModeEnabled, !currentRecords.isEmpty else {
            return false
        }

        return matchedScopedAppRecords(from: currentRecords).isEmpty
    }

    private func evaluateAppScopedAwakeMode() {
        guard state.appScopedAwakeModeEnabled else {
            return
        }

        let records = selectedScopedAppRecords()
        guard !records.isEmpty else {
            return
        }

        let matchedRecords = matchedScopedAppRecords(from: records)
        if matchedRecords.isEmpty {
            guard blocker.isActive else {
                return
            }

            blocker.deactivate()
            state.preventSleep = false
            clearSleepTimer(logChange: false)
            handleProtectionDisabledForRuntimeCap()
            stateStore.save(state)

            EventLog.shared.add("App-Scoped Awake Mode disabled sleep prevention because no selected app matches.")
            return
        }

        guard !blocker.isActive else {
            return
        }

        guard ensureProtectionEnabled(showThermalAlert: false, logBlockedReason: false) else {
            return
        }

        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode enabled sleep prevention for \(matchedRecords.map(\.displayName).joined(separator: ", ")).")
    }

    private func thermalGuardCooldownMinutes() -> Int {
        max(1, state.thermalGuardCooldownMinutes)
    }

    private func thermalGuardCooldownRemainingInterval(now: Date = Date()) -> TimeInterval? {
        guard let cooldownUntil = state.thermalGuardCooldownUntil else {
            return nil
        }

        let remaining = cooldownUntil.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    private func thermalGuardCooldownRemainingText(now: Date = Date()) -> String? {
        guard let remaining = thermalGuardCooldownRemainingInterval(now: now) else {
            return nil
        }

        let minutes = Int(ceil(remaining / 60.0))
        if minutes >= 60 {
            let hours = Int(ceil(Double(minutes) / 60.0))
            return "\(hours)h"
        }

        return "\(max(1, minutes))m"
    }

    private func clearExpiredThermalGuardCooldownIfNeeded(now: Date = Date()) {
        guard let cooldownUntil = state.thermalGuardCooldownUntil, cooldownUntil <= now else {
            return
        }

        state.thermalGuardCooldownUntil = nil
        stateStore.save(state)
        EventLog.shared.add("Thermal Guard cooldown ended.")
    }

    private func presentThermalGuardCooldownAlert(until: Date, currentLevel: ThermalPressureLevel) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "Thermal Guard Active"
        alert.informativeText = """
        Sleep prevention is temporarily blocked because macOS reports thermal pressure at \(currentLevel.title).

        Cooling down until \(PowerScheduler.userFacingDate(until)). You can re-enable protection after cooldown ends, or disable Thermal Guard if you accept the risk.
        """
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
    }

    private func canEnableProtection(showThermalAlert: Bool, logBlockedReason: Bool = true) -> Bool {
        clearExpiredThermalGuardCooldownIfNeeded()

        let powerSource = resourceMonitor.powerSourceKind()
        if state.acPowerOnlyModeEnabled, !powerSource.isExternalPower {
            if logBlockedReason {
                EventLog.shared.add("AC Power Only Mode blocked sleep prevention because current power source is \(powerSource.title).")
            }

            if showThermalAlert {
                presentACPowerRequiredAlert(currentSource: powerSource)
            }

            return false
        }

        guard state.thermalGuardEnabled, let cooldownUntil = state.thermalGuardCooldownUntil, cooldownUntil > Date() else {
            return true
        }

        let currentLevel = resourceMonitor.thermalPressureLevel()
        if logBlockedReason {
            EventLog.shared.add("Thermal Guard blocked sleep prevention until \(PowerScheduler.userFacingDate(cooldownUntil)).")
        }

        if showThermalAlert {
            presentThermalGuardCooldownAlert(until: cooldownUntil, currentLevel: currentLevel)
        }

        return false
    }

    private func evaluateThermalGuard(using snapshot: ResourceSnapshot, now: Date = Date()) {
        clearExpiredThermalGuardCooldownIfNeeded(now: now)

        guard state.thermalGuardEnabled else {
            return
        }

        guard blocker.isActive else {
            return
        }

        guard snapshot.thermalLevel.rawValue >= thermalGuardThreshold().rawValue else {
            return
        }

        let cooldownUntil = now.addingTimeInterval(TimeInterval(thermalGuardCooldownMinutes() * 60))
        blocker.deactivate()
        state.preventSleep = false
        clearSleepTimer(logChange: false)
        handleProtectionDisabledForRuntimeCap()
        state.thermalGuardCooldownUntil = cooldownUntil
        stateStore.save(state)

        EventLog.shared.add(
            "Thermal Guard triggered at \(snapshot.thermalLevel.title). Sleep prevention disabled until \(PowerScheduler.userFacingDate(cooldownUntil))."
        )
    }

    private func runtimeCapRemainingInterval(now: Date = Date()) -> TimeInterval? {
        guard let endDate = state.runtimeCapEndDate else {
            return nil
        }

        let remaining = endDate.timeIntervalSince(now)
        return remaining > 0 ? remaining : nil
    }

    private func runtimeCapRemainingText(now: Date = Date()) -> String? {
        guard let remaining = runtimeCapRemainingInterval(now: now) else {
            return nil
        }

        let totalMinutes = Int(ceil(remaining / 60.0))
        if totalMinutes >= 60 {
            let hours = totalMinutes / 60
            let minutes = totalMinutes % 60
            return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m"
        }

        return "\(max(1, totalMinutes))m"
    }

    private func runtimeCapStatusText(now: Date = Date()) -> String {
        if blocker.isActive, let remaining = runtimeCapRemainingText(now: now) {
            return "Active • \(remaining) left"
        }

        if blocker.isActive, let endDate = state.runtimeCapEndDate, endDate > now {
            return "Active • until \(PowerScheduler.userFacingDate(endDate))"
        }

        if blocker.isActive, let minutes = state.runtimeCapConfiguredMinutes {
            return "Active • \(displayTitle(forMinutes: minutes)) cap"
        }

        if let minutes = state.runtimeCapConfiguredMinutes {
            return "Armed for next enable • \(displayTitle(forMinutes: minutes))"
        }

        if let endDate = state.runtimeCapEndDate, endDate > now {
            return "Deadline set • \(PowerScheduler.userFacingDate(endDate))"
        }

        return "Off"
    }

    private func clearRuntimeCap(logChange: Bool) {
        runtimeCapTimer?.invalidate()
        runtimeCapTimer = nil
        state.runtimeCapConfiguredMinutes = nil
        state.runtimeCapEndDate = nil
        stateStore.save(state)

        if logChange {
            EventLog.shared.add("Max Runtime Cap turned off.")
        }
    }

    private func handleProtectionDisabledForRuntimeCap() {
        runtimeCapTimer?.invalidate()
        runtimeCapTimer = nil
        var didChangeState = false

        if state.runtimeCapConfiguredMinutes != nil, state.runtimeCapEndDate != nil {
            state.runtimeCapEndDate = nil
            didChangeState = true
        }

        if didChangeState {
            stateStore.save(state)
        }
    }

    private func scheduleRuntimeCapTimer(endDate: Date, logMessage: String?) {
        runtimeCapTimer?.invalidate()

        let interval = endDate.timeIntervalSinceNow
        if interval <= 0 {
            handleRuntimeCapFired()
            return
        }

        if state.runtimeCapEndDate != endDate {
            state.runtimeCapEndDate = endDate
            stateStore.save(state)
        }

        if let logMessage {
            EventLog.shared.add(logMessage)
        }

        runtimeCapTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            self?.handleRuntimeCapFired()
        }

        if let runtimeCapTimer {
            RunLoop.main.add(runtimeCapTimer, forMode: .common)
        }
    }

    private func armRuntimeCapIfNeeded(reason: String) {
        if let minutes = state.runtimeCapConfiguredMinutes {
            if state.runtimeCapEndDate == nil {
                let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
                scheduleRuntimeCapTimer(
                    endDate: endDate,
                    logMessage: "Max Runtime Cap armed for \(displayTitle(forMinutes: minutes)) (\(reason))."
                )
            } else if let endDate = state.runtimeCapEndDate {
                if endDate <= Date() {
                    handleRuntimeCapFired()
                } else if runtimeCapTimer == nil {
                    scheduleRuntimeCapTimer(endDate: endDate, logMessage: nil)
                }
            }
            return
        }

        guard let endDate = state.runtimeCapEndDate else {
            return
        }

        if endDate <= Date() {
            if blocker.isActive {
                handleRuntimeCapFired()
            } else {
                state.runtimeCapEndDate = nil
                stateStore.save(state)
                EventLog.shared.add("Max Runtime Cap deadline expired and was cleared.")
            }
            return
        }

        if runtimeCapTimer == nil {
            scheduleRuntimeCapTimer(endDate: endDate, logMessage: nil)
        }
    }

    private func normalizeRuntimeCapState() {
        if !blocker.isActive, state.runtimeCapConfiguredMinutes != nil, state.runtimeCapEndDate != nil {
            runtimeCapTimer?.invalidate()
            runtimeCapTimer = nil
            state.runtimeCapEndDate = nil
            stateStore.save(state)
            return
        }

        guard let endDate = state.runtimeCapEndDate else {
            return
        }

        if endDate <= Date() {
            if blocker.isActive {
                handleRuntimeCapFired()
                return
            }

            runtimeCapTimer?.invalidate()
            runtimeCapTimer = nil
            state.runtimeCapEndDate = nil
            stateStore.save(state)
            EventLog.shared.add("Max Runtime Cap deadline expired while protection was off.")
            return
        }

        if blocker.isActive, runtimeCapTimer == nil {
            scheduleRuntimeCapTimer(endDate: endDate, logMessage: nil)
        }
    }

    private func handleRuntimeCapFired() {
        runtimeCapTimer?.invalidate()
        runtimeCapTimer = nil

        blocker.deactivate()
        state.preventSleep = false
        clearSleepTimer(logChange: false)
        state.runtimeCapEndDate = nil
        stateStore.save(state)

        EventLog.shared.add("Max Runtime Cap reached. Sleep prevention disabled.")
        refreshMenuState()
    }

    private func refreshMenuState() {
        let snapshot = resourceMonitor.sample()
        evaluateACPowerOnlyMode(using: snapshot)
        evaluateThermalGuard(using: snapshot)
        normalizeRuntimeCapState()
        evaluateAppScopedAwakeMode()

        titleItem.title = "\(AppMeta.appName) • v\(AppMeta.currentVersion)"
        openDesktopModeItem.title = desktopWindow == nil
            ? "Open \(AppMeta.shortName) Desktop Experience"
            : "Open \(AppMeta.shortName) Desktop Experience (Active)"
        checkUpdatesItem.title = updateStatus.menuTitle
        checkUpdatesItem.isEnabled = !updateStatus.isChecking
        providedByItem.title = "Provided BY: \(AppMeta.providerName)"

        serviceToggleItem.state = serviceController.isRunning ? .on : .off
        sleepToggleItem.state = blocker.isActive ? .on : .off
        autoWakeToggleItem.state = state.autoReenableAfterWake ? .on : .off
        watchdogToggleItem.state = state.serviceWatchdogEnabled ? .on : .off
        launchAtBootItem.state = state.launchAtBoot ? .on : .off

        let thermalGuardCooldownText = thermalGuardCooldownRemainingText()
        let acPowerOnlyBlocked = state.acPowerOnlyModeEnabled && !snapshot.powerSource.isExternalPower
        let appScopedBlocked = appScopedAwakeBlocksManualEnable()
        sleepToggleItem.title = thermalGuardCooldownText != nil
            ? "Prevent Sleep (Cooling Down)"
            : (acPowerOnlyBlocked ? "Prevent Sleep (AC Power Required)" : (appScopedBlocked ? "Prevent Sleep (Waiting for App)" : "Prevent Sleep"))
        sleepToggleItem.isEnabled = blocker.isActive || (thermalGuardCooldownText == nil && !acPowerOnlyBlocked && !appScopedBlocked)

        updateResourceItems(snapshot)
        updateACPowerOnlyMenuState(snapshot)
        updateAppScopedMenuState()
        updateThermalGuardMenuState(snapshot)
        updateRuntimeCapMenuState()
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
        resourceBatteryItem.title = "\(snap.powerSourceText) • \(snap.batteryText.replacingOccurrences(of: "Battery: ", with: ""))"
        resourceWiFiItem.title = "Wi-Fi: \(snap.wifiText)"
        resourceBluetoothItem.title = "Bluetooth: \(snap.bluetoothText)"
        resourceThermalItem.title = snap.thermalText
        resourceUptimeItem.title = snap.uptimeText
    }

    private func updateACPowerOnlyMenuState(_ snapshot: ResourceSnapshot) {
        let blocked = state.acPowerOnlyModeEnabled && !snapshot.powerSource.isExternalPower

        acPowerOnlyItem.title = blocked ? "AC Power Only Mode (\(snapshot.powerSource.title))" : "AC Power Only Mode"
        acPowerOnlyStatusItem.title = state.acPowerOnlyModeEnabled
            ? "Status: Enabled • Current \(snapshot.powerSource.title) • \(snapshot.powerSource.isExternalPower ? "Protection allowed" : "Protection blocked")"
            : "Status: Disabled • Current \(snapshot.powerSource.title)"
        acPowerOnlyToggleItem.state = state.acPowerOnlyModeEnabled ? .on : .off
    }

    private func updateAppScopedMenuState() {
        let records = selectedScopedAppRecords()
        let matchedRecords = matchedScopedAppRecords(from: records)

        appScopedItem.title = matchedRecords.isEmpty
            ? "App-Scoped Awake Mode"
            : "App-Scoped Awake Mode (\(matchedRecords.map(\.displayName).joined(separator: ", ")))"
        appScopedStatusItem.title = "Status: \(appScopedAwakeStatusText(records: records))"
        appScopedToggleItem.state = state.appScopedAwakeModeEnabled ? .on : .off
        appScopedPolicyItem.title = "Match Policy (\(appScopedAwakePolicy().title))"

        for (policy, item) in appScopedPolicyOptionItems {
            item.state = policy == appScopedAwakePolicy() ? .on : .off
        }

        if let frontmostApplication = NSWorkspace.shared.frontmostApplication,
           let bundleIdentifier = frontmostApplication.bundleIdentifier,
           bundleIdentifier != Bundle.main.bundleIdentifier,
           !state.appScopedBundleIdentifiers.contains(bundleIdentifier) {
            appScopedAddFrontmostItem.title = "Add Current Frontmost App (\(scopedAwakeDisplayName(for: frontmostApplication)))"
            appScopedAddFrontmostItem.isEnabled = true
        } else {
            appScopedAddFrontmostItem.title = "Add Current Frontmost App"
            appScopedAddFrontmostItem.isEnabled = false
        }

        appScopedAddRunningMenu.removeAllItems()
        let selectedBundleIdentifiers = Set(state.appScopedBundleIdentifiers)
        let addCandidates = scopedAwakeCandidateApplications().filter { application in
            guard let bundleIdentifier = application.bundleIdentifier else {
                return false
            }

            return !selectedBundleIdentifiers.contains(bundleIdentifier)
        }

        if addCandidates.isEmpty {
            let emptyItem = NSMenuItem(title: "No running apps available", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            appScopedAddRunningMenu.addItem(emptyItem)
            appScopedAddRunningItem.isEnabled = false
        } else {
            for application in addCandidates {
                guard let bundleIdentifier = application.bundleIdentifier else {
                    continue
                }

                let item = NSMenuItem(title: scopedAwakeDisplayName(for: application), action: #selector(addRunningAppToScopedAwakeList(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = bundleIdentifier
                appScopedAddRunningMenu.addItem(item)
            }
            appScopedAddRunningItem.isEnabled = true
        }

        appScopedRemoveMenu.removeAllItems()
        if records.isEmpty {
            let emptyItem = NSMenuItem(title: "No selected apps", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            appScopedRemoveMenu.addItem(emptyItem)
            appScopedRemoveItem.isEnabled = false
            appScopedClearItem.isEnabled = false
        } else {
            for record in records {
                let item = NSMenuItem(title: "\(record.displayName) (\(record.bundleIdentifier))", action: #selector(removeScopedAwakeApp(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = record.bundleIdentifier
                appScopedRemoveMenu.addItem(item)
            }
            appScopedRemoveItem.isEnabled = true
            appScopedClearItem.isEnabled = true
        }
    }

    private func addScopedAwakeBundleIdentifier(_ bundleIdentifier: String, displayName: String) {
        state.appScopedBundleIdentifiers.append(bundleIdentifier)
        state.appScopedBundleIdentifiers = normalizedScopedAwakeBundleIdentifiers(state.appScopedBundleIdentifiers)
        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode added \(displayName).")
        refreshMenuState()
    }

    private func updateThermalGuardMenuState(_ snapshot: ResourceSnapshot) {
        let threshold = thermalGuardThreshold()
        let cooldownText = thermalGuardCooldownRemainingText()

        thermalGuardItem.title = cooldownText.map { "Thermal Guard (\($0) left)" } ?? "Thermal Guard"
        thermalGuardStatusItem.title = state.thermalGuardEnabled
            ? "Status: \(snapshot.thermalLevel.title) • Threshold \(threshold.title) • \(cooldownText.map { "Cooldown \($0) left" } ?? "Ready")"
            : "Status: Disabled • Current \(snapshot.thermalLevel.title)"
        thermalGuardToggleItem.state = state.thermalGuardEnabled ? .on : .off
        thermalGuardCooldownItem.title = "Cooldown (\(thermalGuardCooldownMinutes())m)"
        thermalGuardClearCooldownItem.isEnabled = cooldownText != nil

        for (level, item) in thermalGuardThresholdOptionItems {
            item.state = level == threshold ? .on : .off
        }

        for (minutes, item) in thermalGuardCooldownOptionItems {
            item.state = minutes == thermalGuardCooldownMinutes() ? .on : .off
        }
    }

    private func updateRuntimeCapMenuState() {
        let remainingText = blocker.isActive ? runtimeCapRemainingText() : nil
        runtimeCapItem.title = remainingText.map { "Max Runtime Cap (\($0) left)" } ?? "Max Runtime Cap"
        runtimeCapStatusItem.title = "Status: \(runtimeCapStatusText())"
        runtimeCapOffItem.state = (state.runtimeCapConfiguredMinutes == nil && state.runtimeCapEndDate == nil) ? .on : .off

        for (minutes, item) in runtimeCapOptionItems {
            item.state = minutes == state.runtimeCapConfiguredMinutes ? .on : .off
        }

        if let endDate = state.runtimeCapEndDate, state.runtimeCapConfiguredMinutes == nil {
            runtimeCapSetUntilItem.title = "Set Until Date/Time... (Ends \(PowerScheduler.userFacingDate(endDate)))"
            runtimeCapSetUntilItem.state = .on
        } else {
            runtimeCapSetUntilItem.title = "Set Until Date/Time..."
            runtimeCapSetUntilItem.state = .off
        }
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
    private func ensureProtectionEnabled(showThermalAlert: Bool = false, logBlockedReason: Bool = true) -> Bool {
        guard canEnableProtection(showThermalAlert: showThermalAlert, logBlockedReason: logBlockedReason) else {
            state.preventSleep = false
            return false
        }

        guard ensureServiceRunning() else {
            return false
        }

        let enabled = blocker.activate(reason: "\(AppMeta.shortName) protection enabled")
        state.preventSleep = enabled
        if enabled {
            armRuntimeCapIfNeeded(reason: "protection enabled")
        }
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
        handleProtectionDisabledForRuntimeCap()
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
        handleProtectionDisabledForRuntimeCap()
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

    private func presentFirstLaunchWarningIfNeeded() -> Bool {
        guard state.riskWarningAcceptedVersion != AppMeta.riskWarningVersion else {
            return true
        }

        return presentUsageWarning(requireAcknowledgement: true)
    }

    @discardableResult
    private func presentUsageWarning(requireAcknowledgement: Bool) -> Bool {
        NSApplication.shared.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = AppMeta.riskWarningTitle
        alert.informativeText = AppMeta.riskWarningMessage
        alert.alertStyle = .warning

        if requireAcknowledgement {
            alert.addButton(withTitle: "I Accept the Risk")
            alert.addButton(withTitle: "Quit")

            if alert.runModal() == .alertFirstButtonReturn {
                state.riskWarningAcceptedVersion = AppMeta.riskWarningVersion
                stateStore.save(state)
                EventLog.shared.add("Safety/warranty notice accepted: version \(AppMeta.riskWarningVersion).")
                return true
            }

            EventLog.shared.add("Safety/warranty notice declined on first launch.")
            NSApplication.shared.terminate(nil)
            return false
        }

        alert.addButton(withTitle: "OK")
        _ = alert.runModal()
        EventLog.shared.add("Safety/warranty notice reviewed from the menu.")
        return true
    }

    private func displayTitle(forMinutes minutes: Int) -> String {
        if minutes == 60 {
            return "1 Hour"
        }

        if minutes > 60, minutes % 60 == 0 {
            return "\(minutes / 60) Hours"
        }

        return "\(minutes) Minutes"
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
            handleProtectionDisabledForRuntimeCap()

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
            handleProtectionDisabledForRuntimeCap()

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

    @objc private func checkForUpdatesOrInstall() {
        switch updateStatus {
        case .available(let info):
            openUpdateDestination(info)
        case .checking:
            return
        default:
            performUpdateCheck(userInitiated: true)
        }
    }

    @objc private func openProviderWebsite() {
        NSWorkspace.shared.open(AppMeta.providerURL)
    }

    @objc private func openWiki() {
        NSWorkspace.shared.open(AppMeta.wikiURL)
    }

    @objc private func desktopToggleACPowerOnlyMode() {
        toggleACPowerOnlyMode()
    }

    @objc private func desktopToggleAppScopedAwakeMode() {
        toggleAppScopedAwakeMode()
    }

    @objc private func desktopToggleThermalGuard() {
        toggleThermalGuard()
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
                handleProtectionDisabledForRuntimeCap()
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
            handleProtectionDisabledForRuntimeCap()
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
            handleProtectionDisabledForRuntimeCap()
        } else {
            guard ensureProtectionEnabled(showThermalAlert: true) else {
                EventLog.shared.add("Cannot enable sleep prevention because service is not running or Thermal Guard is cooling down.")
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

    @objc private func toggleACPowerOnlyMode() {
        state.acPowerOnlyModeEnabled.toggle()
        stateStore.save(state)
        EventLog.shared.add("AC Power Only Mode \(state.acPowerOnlyModeEnabled ? "enabled" : "disabled").")
        refreshMenuState()
    }

    @objc private func toggleAppScopedAwakeMode() {
        state.appScopedAwakeModeEnabled.toggle()
        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode \(state.appScopedAwakeModeEnabled ? "enabled" : "disabled").")
        refreshMenuState()
    }

    @objc private func selectAppScopedAwakePolicy(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber,
              let policy = AppScopedAwakePolicy(rawValue: wrapped.intValue) else {
            return
        }

        state.appScopedAwakePolicyRaw = policy.rawValue
        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode policy set to \(policy.title).")
        refreshMenuState()
    }

    @objc private func addFrontmostAppToScopedAwakeList() {
        guard let application = NSWorkspace.shared.frontmostApplication,
              let bundleIdentifier = application.bundleIdentifier,
              bundleIdentifier != Bundle.main.bundleIdentifier else {
            EventLog.shared.add("App-Scoped Awake Mode could not add the current frontmost app.")
            refreshMenuState()
            return
        }

        addScopedAwakeBundleIdentifier(bundleIdentifier, displayName: scopedAwakeDisplayName(for: application))
    }

    @objc private func addRunningAppToScopedAwakeList(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else {
            return
        }

        addScopedAwakeBundleIdentifier(bundleIdentifier, displayName: scopedAwakeDisplayName(forBundleIdentifier: bundleIdentifier))
    }

    @objc private func removeScopedAwakeApp(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else {
            return
        }

        state.appScopedBundleIdentifiers.removeAll { $0 == bundleIdentifier }
        state.appScopedBundleIdentifiers = normalizedScopedAwakeBundleIdentifiers(state.appScopedBundleIdentifiers)
        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode removed \(scopedAwakeDisplayName(forBundleIdentifier: bundleIdentifier)).")
        refreshMenuState()
    }

    @objc private func clearScopedAwakeApps() {
        guard !state.appScopedBundleIdentifiers.isEmpty else {
            return
        }

        state.appScopedBundleIdentifiers = []
        stateStore.save(state)
        EventLog.shared.add("App-Scoped Awake Mode cleared all selected apps.")
        refreshMenuState()
    }

    @objc private func toggleThermalGuard() {
        state.thermalGuardEnabled.toggle()

        if !state.thermalGuardEnabled {
            state.thermalGuardCooldownUntil = nil
        }

        stateStore.save(state)
        EventLog.shared.add("Thermal Guard \(state.thermalGuardEnabled ? "enabled" : "disabled").")
        refreshMenuState()
    }

    @objc private func selectThermalGuardThreshold(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber,
              let level = ThermalPressureLevel(rawValue: wrapped.intValue) else {
            return
        }

        state.thermalGuardThresholdRaw = level.rawValue
        stateStore.save(state)
        EventLog.shared.add("Thermal Guard threshold set to \(level.title).")
        refreshMenuState()
    }

    @objc private func selectThermalGuardCooldown(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber else {
            return
        }

        let minutes = max(1, wrapped.intValue)
        state.thermalGuardCooldownMinutes = minutes
        stateStore.save(state)
        EventLog.shared.add("Thermal Guard cooldown set to \(minutes) minutes.")
        refreshMenuState()
    }

    @objc private func clearThermalGuardCooldownManually() {
        guard state.thermalGuardCooldownUntil != nil else {
            return
        }

        state.thermalGuardCooldownUntil = nil
        stateStore.save(state)
        EventLog.shared.add("Thermal Guard cooldown cleared by user.")
        refreshMenuState()
    }

    @objc private func disableRuntimeCap() {
        clearRuntimeCap(logChange: true)
        refreshMenuState()
    }

    @objc private func selectRuntimeCapOption(_ sender: NSMenuItem) {
        guard let wrapped = sender.representedObject as? NSNumber else {
            return
        }

        let minutes = max(1, wrapped.intValue)
        state.runtimeCapConfiguredMinutes = minutes
        stateStore.save(state)

        if blocker.isActive {
            let endDate = Date().addingTimeInterval(TimeInterval(minutes * 60))
            scheduleRuntimeCapTimer(
                endDate: endDate,
                logMessage: "Max Runtime Cap set for \(displayTitle(forMinutes: minutes))."
            )
        } else {
            runtimeCapTimer?.invalidate()
            runtimeCapTimer = nil
            state.runtimeCapEndDate = nil
            stateStore.save(state)
            EventLog.shared.add("Max Runtime Cap armed for next enable: \(displayTitle(forMinutes: minutes)).")
        }

        refreshMenuState()
    }

    @objc private func promptRuntimeCapUntilDate() {
        guard let date = promptForDateTime(
            title: "Max Runtime Cap",
            message: "Pick the latest date and time that sleep prevention is allowed to remain active.",
            defaultDate: Date().addingTimeInterval(4 * 3600)
        ) else {
            return
        }

        state.runtimeCapConfiguredMinutes = nil
        stateStore.save(state)

        if blocker.isActive {
            scheduleRuntimeCapTimer(
                endDate: date,
                logMessage: "Max Runtime Cap deadline set for \(PowerScheduler.userFacingDate(date))."
            )
        } else {
            runtimeCapTimer?.invalidate()
            runtimeCapTimer = nil
            state.runtimeCapEndDate = date
            stateStore.save(state)
            EventLog.shared.add("Max Runtime Cap deadline armed for \(PowerScheduler.userFacingDate(date)).")
        }

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

        guard ensureProtectionEnabled(showThermalAlert: true) else {
            EventLog.shared.add("Cannot set sleep timer because service/protection could not be enabled or Thermal Guard is cooling down.")
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
        checks.append("AC Power Only Mode: \(state.acPowerOnlyModeEnabled ? "Enabled" : "Disabled")")
        checks.append("Power source: \(resourceMonitor.powerSourceKind().title)")
        checks.append("App-Scoped Awake Mode: \(state.appScopedAwakeModeEnabled ? "Enabled" : "Disabled")")
        checks.append("App-Scoped Policy: \(appScopedAwakePolicy().title)")
        checks.append("App-Scoped Apps: \(state.appScopedBundleIdentifiers.isEmpty ? "None" : state.appScopedBundleIdentifiers.map(scopedAwakeDisplayName(forBundleIdentifier:)).joined(separator: ", "))")
        checks.append("Thermal Guard: \(state.thermalGuardEnabled ? "Enabled" : "Disabled")")
        checks.append("Thermal pressure: \(resourceMonitor.thermalPressureLevel().title)")
        checks.append("Max Runtime Cap: \(runtimeCapStatusText())")
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
            "Version: \(AppMeta.currentVersion) (\(AppMeta.currentBuild))",
            "Provided BY: \(AppMeta.providerName)",
            "Service running: \(serviceController.isRunning)",
            "Sleep prevention active: \(blocker.isActive)",
            "AC Power Only Mode: \(state.acPowerOnlyModeEnabled ? "enabled" : "disabled")",
            "Power Source: \(resourceMonitor.powerSourceKind().title)",
            "App-Scoped Awake Mode: \(state.appScopedAwakeModeEnabled ? "enabled" : "disabled")",
            "App-Scoped Policy: \(appScopedAwakePolicy().title)",
            "App-Scoped Apps: \(state.appScopedBundleIdentifiers.isEmpty ? "none" : state.appScopedBundleIdentifiers.map(scopedAwakeDisplayName(forBundleIdentifier:)).joined(separator: ", "))",
            "Thermal Guard: \(state.thermalGuardEnabled ? "enabled" : "disabled")",
            "Thermal Guard threshold: \(thermalGuardThreshold().title)",
            "Thermal Guard cooldown: \(thermalGuardCooldownRemainingText() ?? "ready")",
            "Max Runtime Cap: \(runtimeCapStatusText())",
            "Launch at boot: \(state.launchAtBoot)",
            "Auto-reenable after wake: \(state.autoReenableAfterWake)",
            "Service watchdog: \(state.serviceWatchdogEnabled)",
            "Update status: \(updateStatus.menuTitle)",
            "Sleep timer: \(state.timerEndDate.map(PowerScheduler.userFacingDate) ?? "off")",
            "Shutdown timer: \(state.shutdownEndDate.map(PowerScheduler.userFacingDate) ?? "off")",
            "Wake/Power On: \(state.wakeScheduleDate.map(PowerScheduler.userFacingDate) ?? "none")",
            "Wi-Fi: \(resourceMonitor.wifiStatusText())",
            "Bluetooth: \(resourceMonitor.bluetoothStatusText())",
            "Thermal Pressure: \(resourceMonitor.thermalPressureLevel().title)"
        ].joined(separator: "\n")

        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(statusText, forType: .string)

        EventLog.shared.add("Status copied to clipboard.")
    }

    @objc private func showUsageWarningFromMenu() {
        _ = presentUsageWarning(requireAcknowledgement: false)
    }

    @objc private func showACPowerOnlyStatus() {
        let snapshot = resourceMonitor.sample()
        let alert = NSAlert()
        alert.messageText = "AC Power Only Mode"
        alert.informativeText = [
            "AC Power Only Mode: \(state.acPowerOnlyModeEnabled ? "Enabled" : "Disabled")",
            "Current Power Source: \(snapshot.powerSource.title)",
            "Protection Allowed Right Now: \(snapshot.powerSource.isExternalPower ? "Yes" : "No")",
            snapshot.batteryText
        ].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()

        EventLog.shared.add("AC Power Only Mode status reviewed.")
    }

    @objc private func showAppScopedAwakeStatus() {
        let records = selectedScopedAppRecords()
        let matchedRecords = matchedScopedAppRecords(from: records)
        let selectedSummary = records.isEmpty
            ? "None"
            : records.map { record in
                let stateText = record.isFrontmost ? "frontmost" : (record.isRunning ? "running" : "not running")
                return "\(record.displayName) (\(record.bundleIdentifier)) - \(stateText)"
            }.joined(separator: "\n")

        let alert = NSAlert()
        alert.messageText = "App-Scoped Awake Mode"
        alert.informativeText = [
            "Mode: \(state.appScopedAwakeModeEnabled ? "Enabled" : "Disabled")",
            "Policy: \(appScopedAwakePolicy().title)",
            "Current Status: \(appScopedAwakeStatusText(records: records))",
            "Matched Apps: \(matchedRecords.isEmpty ? "None" : matchedRecords.map(\.displayName).joined(separator: ", "))",
            "Selected Apps:",
            selectedSummary
        ].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()

        EventLog.shared.add("App-Scoped Awake Mode status reviewed.")
    }

    @objc private func showThermalGuardStatus() {
        clearExpiredThermalGuardCooldownIfNeeded()

        let currentLevel = resourceMonitor.thermalPressureLevel()
        let alert = NSAlert()
        alert.messageText = "Thermal Guard Status"
        alert.informativeText = [
            "Thermal Guard: \(state.thermalGuardEnabled ? "Enabled" : "Disabled")",
            "Current Thermal Pressure: \(currentLevel.title)",
            "Trip Threshold: \(thermalGuardThreshold().title)",
            "Cooldown: \(thermalGuardCooldownRemainingText() ?? "Ready")",
            "Configured Cooldown Length: \(thermalGuardCooldownMinutes()) minutes"
        ].joined(separator: "\n")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")

        NSApplication.shared.activate(ignoringOtherApps: true)
        _ = alert.runModal()

        EventLog.shared.add("Thermal Guard status reviewed.")
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
        desktopSummaryTextView = nil
        desktopEventLogTextView = nil
        desktopServiceButton = nil
        desktopSleepButton = nil
        desktopUpdateButton = nil
        desktopACPowerOnlyButton = nil
        desktopAppScopedButton = nil
        desktopThermalGuardButton = nil
        desktopServiceCard = nil
        desktopProtectionCard = nil
        desktopVersionCard = nil
        desktopUpdateCard = nil

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
