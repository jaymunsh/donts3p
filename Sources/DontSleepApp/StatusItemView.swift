import SwiftUI
import AppKit
import IOKit.ps
import DontSleepShared
import Foundation

enum Donts3pStatusIconState: Equatable {
    case active
    case inactive

    init(observation: AssertionObservation, now: Date = Date()) {
        self = observation.isFreshActive(now: now) ? .active : .inactive
    }

    var accessibilityLabel: String {
        switch self {
        case .active: "donts3p: sleep prevention active"
        case .inactive: "donts3p: sleep prevention inactive"
        }
    }

    var badgeSymbolName: String {
        switch self {
        case .active: "checkmark.circle.fill"
        case .inactive: "xmark.circle.fill"
        }
    }
}

struct Donts3pStatusIcon: View {
    let observation: AssertionObservation

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let state = Donts3pStatusIconState(observation: observation, now: context.date)

            Text(state == .active ? "Z³✓⃝" : "Z³×⃝")
                .font(.system(size: 15, weight: .semibold, design: .rounded))
                .accessibilityLabel(state.accessibilityLabel)
        }
    }
}

private struct PowerDashboardSnapshot {
    let source: String
    let batteryPercentage: Int?
}

private func currentPowerDashboardSnapshot() -> PowerDashboardSnapshot {
    guard let snapshot = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
          let sources = IOPSCopyPowerSourcesList(snapshot)?.takeRetainedValue() as? [CFTypeRef] else {
        return PowerDashboardSnapshot(source: "Unknown", batteryPercentage: nil)
    }

    for source in sources {
        guard let details = IOPSGetPowerSourceDescription(snapshot, source)?.takeUnretainedValue() as? [String: Any] else {
            continue
        }
        let powerState = details[kIOPSPowerSourceStateKey] as? String
        let currentCapacity = details[kIOPSCurrentCapacityKey] as? Int
        let maximumCapacity = details[kIOPSMaxCapacityKey] as? Int
        let percentage = currentCapacity.flatMap { current in
            maximumCapacity.flatMap { maximum in maximum > 0 ? Int((Double(current) / Double(maximum) * 100).rounded()) : nil }
        }
        let sourceName = powerState == kIOPSACPowerValue ? "Power Adapter" : "Battery"
        return PowerDashboardSnapshot(source: sourceName, batteryPercentage: percentage)
    }

    return PowerDashboardSnapshot(source: "Unknown", batteryPercentage: nil)
}

private func formattedDuration(since startDate: Date?, now: Date = Date()) -> String {
    guard let startDate else { return "—" }
    let totalMinutes = max(0, Int(now.timeIntervalSince(startDate)) / 60)
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
}
private func compactStatusIcon(state: Donts3pStatusIconState) -> NSImage {
    let image = NSImage(size: NSSize(width: 22, height: 18))
    image.lockFocus()
    NSColor.black.setStroke()

    let z = NSBezierPath()
    z.move(to: NSPoint(x: 3.2, y: 14))
    z.line(to: NSPoint(x: 12.2, y: 14))
    z.line(to: NSPoint(x: 3.2, y: 4.5))
    z.line(to: NSPoint(x: 12.2, y: 4.5))
    z.lineWidth = 1.45
    z.lineCapStyle = .round
    z.lineJoinStyle = .miter
    z.stroke()

    let superscript = NSAttributedString(
        string: "3",
        attributes: [
            .font: NSFont.monospacedSystemFont(ofSize: 6.8, weight: .semibold),
            .foregroundColor: NSColor.black,
        ]
    )
    superscript.draw(at: NSPoint(x: 14.1, y: 9.5))

    let badgeFrame = NSRect(x: 11.8, y: 0, width: 10, height: 10)
    let badgeKnockout = NSBezierPath(ovalIn: badgeFrame.insetBy(dx: -0.7, dy: -0.7))
    NSGraphicsContext.current?.saveGraphicsState()
    NSGraphicsContext.current?.compositingOperation = .copy
    NSColor.clear.setFill()
    badgeKnockout.fill()
    NSGraphicsContext.current?.restoreGraphicsState()

    NSColor.black.setStroke()
    let circle = NSBezierPath(ovalIn: badgeFrame)
    circle.lineWidth = 1.2
    circle.stroke()

    let badge = NSBezierPath()
    if state == .active {
        badge.move(to: NSPoint(x: 13.9, y: 5))
        badge.line(to: NSPoint(x: 16.1, y: 3))
        badge.line(to: NSPoint(x: 19.9, y: 7))
    } else {
        badge.move(to: NSPoint(x: 14.2, y: 3))
        badge.line(to: NSPoint(x: 19.4, y: 7))
        badge.move(to: NSPoint(x: 19.4, y: 3))
        badge.line(to: NSPoint(x: 14.2, y: 7))
    }
    badge.lineWidth = 1.35
    badge.lineCapStyle = .round
    badge.lineJoinStyle = .round
    badge.stroke()

    image.unlockFocus()
    image.isTemplate = true
    return image
}
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    private let model: AppModel
    private var statusItem: NSStatusItem?
    private let menu = NSMenu()
    private var timer: Timer?
    private var protectedSince: Date?

    init(model: AppModel) {
        self.model = model
        super.init()
        DispatchQueue.main.async { [weak self] in
            self?.installStatusItem()
        }
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: 24)
        statusItem = item
        item.isVisible = true
        menu.delegate = self
        item.menu = menu
        updateButton()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateButton() }
        }
    }

    deinit {
        timer?.invalidate()
    }

    private func updateButton() {
        let state = Donts3pStatusIconState(observation: model.observation)
        if state == .active {
            protectedSince = protectedSince ?? Date()
        } else {
            protectedSince = nil
        }
        statusItem?.button?.title = ""
        statusItem?.button?.image = compactStatusIcon(state: state)
        statusItem?.button?.imagePosition = .imageOnly
        statusItem?.button?.toolTip = state.accessibilityLabel
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()

        let title = NSMenuItem(title: "donts3p", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let isProtected = model.isProtected
        let power = currentPowerDashboardSnapshot()
        let dashboardLines = [
            isProtected ? "● Sleep prevention active" : "● Sleep prevention inactive",
            "  Active for: \(isProtected ? formattedDuration(since: protectedSince) : "—")",
            "  Power: \(power.source)",
            "  Battery: \(power.batteryPercentage.map { "\($0)%" } ?? "Unknown")",
            "  Assertion: \(isProtected ? "Healthy" : "Inactive")",
            "  Login recovery: \(model.desiredActive ? "Enabled" : "Off")",
        ]
        for line in dashboardLines {
            let item = NSMenuItem(title: line, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }

        let lid = NSMenuItem(title: "  Closed-lid prevention: Unavailable", action: nil, keyEquivalent: "")
        lid.isEnabled = false
        menu.addItem(lid)

        if model.isBatteryWarningVisible {
            let battery = NSMenuItem(title: "Running on battery", action: nil, keyEquivalent: "")
            battery.isEnabled = false
            menu.addItem(battery)
        }
        if let diagnostic = model.terminalOffDiagnostic {
            let diagnosticItem = NSMenuItem(title: diagnostic, action: nil, keyEquivalent: "")
            diagnosticItem.isEnabled = false
            menu.addItem(diagnosticItem)
        }

        menu.addItem(.separator())

        let toggle = NSMenuItem(
            title: model.desiredActive ? "Turn Off" : "Turn On",
            action: #selector(toggleProtection),
            keyEquivalent: ""
        )
        toggle.target = self
        menu.addItem(toggle)

        let quit = NSMenuItem(title: "Quit", action: #selector(quitApplication), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    @objc private func toggleProtection() {
        model.desiredActive ? model.disable() : model.enableAndActivate()
        updateButton()
    }

    @objc private func quitApplication() {
        model.quit()
    }
}

struct StatusItemView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Text("donts3p")
        Text(model.isProtected ? "Sleep prevention active" : "Sleep prevention inactive")
        Text("Closed-lid sleep prevention is unavailable.")
        if model.isBatteryWarningVisible {
            Text("Running on battery")
        }
        if let diagnostic = model.terminalOffDiagnostic {
            Text(diagnostic)
        }
        Divider()
        Button(model.desiredActive ? "Turn Off" : "Turn On") {
            model.desiredActive ? model.disable() : model.enableAndActivate()
        }
        Button("Quit") { model.quit() }
    }
}
