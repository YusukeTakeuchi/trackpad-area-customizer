import AppKit
import Foundation

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let remapper: ClickRemapper
    private let shouldHighlightStatusItem: Bool
    private var statusItem: NSStatusItem?
    private var indicatorTimer: Timer?
    private var isStatusHighlighted = false
    private let statusLabel = "TP"

    init(remapper: ClickRemapper, shouldHighlightStatusItem: Bool) {
        self.remapper = remapper
        self.shouldHighlightStatusItem = shouldHighlightStatusItem
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard remapper.start() else {
            NSApp.terminate(nil)
            return
        }

        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = statusLabel

        let menu = NSMenu()

        let aboutItem = NSMenuItem(title: "About", action: #selector(showAbout), keyEquivalent: "")
        aboutItem.target = self
        menu.addItem(aboutItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
        self.statusItem = statusItem
        if shouldHighlightStatusItem {
            applyStatusButtonAppearance(isHighlighted: false)
            startIndicatorUpdates()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        indicatorTimer?.invalidate()
        indicatorTimer = nil
        remapper.stop()
    }

    @objc private func showAbout() {
        NSApp.orderFrontStandardAboutPanel([
            NSApplication.AboutPanelOptionKey.applicationName: "trackpad-area-customizer"
        ])
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func startIndicatorUpdates() {
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.refreshStatusButtonHighlight()
        }
        RunLoop.main.add(timer, forMode: .common)
        indicatorTimer = timer
        refreshStatusButtonHighlight()
    }

    private func refreshStatusButtonHighlight() {
        let shouldHighlight = remapper.isTouchInsideAnyRuleArea()
        guard shouldHighlight != isStatusHighlighted else {
            return
        }
        isStatusHighlighted = shouldHighlight
        applyStatusButtonAppearance(isHighlighted: shouldHighlight)
    }

    private func applyStatusButtonAppearance(isHighlighted: Bool) {
        guard let button = statusItem?.button else {
            return
        }

        let textColor = isHighlighted ? NSColor.systemRed : NSColor.labelColor
        let attributedTitle = NSAttributedString(
            string: statusLabel,
            attributes: [
                .foregroundColor: textColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            ]
        )
        button.attributedTitle = attributedTitle
    }
}

let config = Config.parse()
let remapper = ClickRemapper(config: config)

let app = NSApplication.shared
let appDelegate = AppDelegate(
    remapper: remapper,
    shouldHighlightStatusItem: config.highlightStatusItem
)
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
