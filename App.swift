// App.swift. Sleepless: a standalone menu-bar toggle that keeps the Mac running
// with the lid closed (on battery, no external display) via `pmset disablesleep`.
//
// Mechanism (verified live on this machine; disablesleep is UNDOCUMENTED in
// pmset(1) but real. It sets IORegistry "SleepDisabled" = Yes and disables
// idle + Apple-menu + lid-close clamshell sleep):
//   ON : sudo pmset -a disablesleep 1
//   OFF: sudo pmset -a disablesleep 0
//   READ (no root): pmset -g | grep -i SleepDisabled  (value 1 = ON; 0/absent = OFF)
// The OFF/ON commands run passwordless via a tightly-scoped /etc/sudoers.d drop-in.
// disablesleep is runtime-only and resets to 0 on reboot, and that reset is a
// deliberate safety feature; the app does NOT auto re-arm.
//
// UI: clicking the menu-bar coffee cup opens a small native popover with an NSSwitch
// toggle (the System-Settings control), a state caption, an auto-off timer, the
// battery-floor slider, a Launch-at-login switch, and Quit. The menu-bar glyph also
// shows state at a glance.
//
// The coffee-cup metaphor is literal: an EMPTY cup means the Mac sleeps normally, a
// FULL cup means it is being kept awake (caffeinated), and a full cup with a small
// dot means it is awake on battery with the auto-off safety net live.
//
// Three small, fail-safe features layer on top, none of which adds a daemon or
// persists OS state (so "reboot resets it" still holds):
//   1. Auto-off timer (1h / 2h) — a one-shot in-memory Timer that flips sleep back
//      on when it fires. Dies on quit; nothing survives a reboot.
//   2. Launch at login (SMAppService.mainApp) — OFF by default. The app always
//      launches reading the TRUE system state, so a login launch can never
//      re-enable disablesleep on its own.
//   3. Low-Power-Mode auto-off — on battery, if Low Power Mode is on, Sleepless
//      turns itself off. Same shape as the battery floor, evaluated on the same tick.
//
// Build (mirrors Nexus.app): Command Line Tools `swiftc`, NO Xcode project.
//   swiftc -O -parse-as-library -target arm64-apple-macos26.0 -framework AppKit \
//          -framework ServiceManagement
//   File MUST be named App.swift and compiled -parse-as-library so the
//   @main enum + @MainActor static main() entry is Swift-6 isolation-safe.
import AppKit
import CoreGraphics
import ServiceManagement
import notify

// MARK: - Tunables
private let pollInterval: TimeInterval = 60
// Keep-awake lease (the dead-man switch). The app does NOT own disablesleep; it holds a
// lease that expires. watchdog.sh clears the flag whenever no live lease says it should be
// set, so a crash here means the Mac goes back to sleeping on its own within one tick
// instead of staying awake until reboot. Format and rationale: docs/LEASE-DESIGN.md.
private let leaseVersion = 1
private let leaseTTL = 120                      // seconds a single renewal is good for
private let leaseRenewInterval: TimeInterval = 30   // must stay well under leaseTTL
private let watchdogLabel = "com.aboudjem.Sleepless.watchdog"
private let leaseRelativePath = "Library/Application Support/Sleepless/lease"

// Battery-floor config (user-adjustable via the popover slider; persisted in UserDefaults).
private let floorKey = "batteryFloorPercent"
private let floorDefault = 15
private let floorMin = 5
private let floorMax = 50

// MARK: - Menu-bar coffee glyph (native SF Symbols, MONOCHROME template — state by SHAPE)
// macOS convention: a menu-bar extra is a template image (no colour) so it adapts to light/dark
// bars and inverts on highlight. State is read from the SILHOUETTE, not colour. The old
// empty-vs-filled cups looked near-identical at 16 px, so we switch the silhouette dramatically
// with steam (a hot cup = awake):
//   OFF   (sleeps normally)        = cup.and.saucer            cup resting on its saucer, NO steam (cold/asleep)
//   ON    (kept awake, on power)   = cup.and.heat.waves.fill   hot cup with rising steam (awake)
//   ARMED (kept awake, on battery) = cup.and.heat.waves.fill + a small dot (awake, safety net live)
// The no-steam → steam change reads instantly even at 16 px; the armed dot is the only extra
// mark. All template (monochrome) — SF Symbols only, no hand-drawn paths.
enum SleepGlyph {
    case off
    case on
    case armed
}

private func makeCupGlyph(_ glyph: SleepGlyph) -> NSImage {
    let cfg = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular).applying(.init(scale: .medium))
    let name = (glyph == .off) ? "cup.and.saucer" : "cup.and.heat.waves.fill"
    let base = NSImage(systemSymbolName: name, accessibilityDescription: "Sleepless")?
        .withSymbolConfiguration(cfg)
        ?? NSImage(systemSymbolName: "cup.and.saucer.fill", accessibilityDescription: "Sleepless")
        ?? NSImage()

    // Render every state into the same natural-size canvas so the menu-bar slot width
    // never changes when the icon swaps. macOS 26 aggressively re-hides status items whose
    // geometry shifts, and variable-length icons that resize on every toggle are prone to
    // vanishing from the menu bar.
    let symbolSize = base.size
    guard symbolSize.width > 0, symbolSize.height > 0 else {
        base.isTemplate = true
        return base
    }
    let stateNames = ["cup.and.saucer", "cup.and.heat.waves.fill"]
    var canvasSize = symbolSize
    for n in stateNames {
        if let img = NSImage(systemSymbolName: n, accessibilityDescription: "Sleepless")?
            .withSymbolConfiguration(cfg) {
            canvasSize.width = max(canvasSize.width, img.size.width)
            canvasSize.height = max(canvasSize.height, img.size.height)
        }
    }

    let composed = NSImage(size: canvasSize)
    composed.lockFocus()
    base.draw(in: NSRect(x: (canvasSize.width - symbolSize.width) / 2,
                         y: (canvasSize.height - symbolSize.height) / 2,
                         width: symbolSize.width,
                         height: symbolSize.height))
    if glyph == .armed {
        // ARMED: full steaming cup + a small filled dot top-right (the "auto-off safety net is live"
        // mark). Drawn in template black so it tints + inverts with the menu bar exactly like the cup.
        let d = max(symbolSize.height * 0.26, 4)
        let dot = NSBezierPath(ovalIn: NSRect(x: canvasSize.width - d, y: canvasSize.height - d, width: d, height: d))
        NSColor.black.setFill()
        dot.fill()
    }
    composed.unlockFocus()
    composed.alignmentRect = NSRect(origin: .zero, size: canvasSize)
    composed.isTemplate = true
    return composed
}

// Flipped container so popover content lays out top-down with simple frames.
private final class FlippedView: NSView { override var isFlipped: Bool { true } }

// Brand accent (2026 "Liquid Glass" redesign): indigo -> violet -> fuchsia. The
// violet mid-tone is the single accent the popover uses to communicate the
// privileged "awake" state, matching the app icon's gradient mid-stop. These are
// the only hard-coded colours; everything else stays on system semantic colours so
// the panel still reads as a first-party control.
private let brandAccent = NSColor(srgbRed: 139/255.0, green: 92/255.0, blue: 246/255.0, alpha: 1)   // #8B5CF6 violet
private let brandAccentSoft = NSColor(srgbRed: 167/255.0, green: 139/255.0, blue: 250/255.0, alpha: 1) // #A78BFA

// Frosted-glass popover backing: a flipped NSVisualEffectView so content still
// lays out top-down while the panel gets a translucent, blurred material that
// samples the desktop/windows behind it (system light/dark aware). On macOS 26 the
// .popover material renders as the system Liquid Glass automatically; we deliberately
// keep this native (no hand-rolled tint on the surface) so a sudo-touching panel
// stays visually first-party. Colour lives on the controls, never the surface.
private final class GlassView: NSVisualEffectView { override var isFlipped: Bool { true } }

// Inset grouping "card" (System Settings rhythm): a flipped, layer-backed container
// with a subtle, appearance-adaptive fill, a hairline border, and continuous-corner
// rounding. When `active`, the card carries a faint brand-violet wash + a violet
// hairline so the privileged "kept awake" state is unmistakable at a glance in the
// accent colour (Apple's "tint elements, not surfaces" model). Re-resolved on
// light/dark changes and on state changes via updateLayer.
private final class CardView: NSView {
    var active = false { didSet { if active != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if active {
            layer?.backgroundColor = brandAccent.withAlphaComponent(dark ? 0.18 : 0.10).cgColor
            layer?.borderColor = brandAccent.withAlphaComponent(dark ? 0.60 : 0.45).cgColor
            layer?.borderWidth = 1
        } else {
            layer?.backgroundColor = (dark ? NSColor.white.withAlphaComponent(0.06)
                                           : NSColor.black.withAlphaComponent(0.045)).cgColor
            layer?.borderColor = (dark ? NSColor.white.withAlphaComponent(0.08)
                                       : NSColor.black.withAlphaComponent(0.06)).cgColor
            layer?.borderWidth = 1
        }
        layer?.cornerRadius = 11
        layer?.cornerCurve = .continuous
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private let onGlyph = makeCupGlyph(.on)
    private let offGlyph = makeCupGlyph(.off)
    private let armedGlyph = makeCupGlyph(.armed)

    // Popover UI
    private let popover = NSPopover()
    private var toggleSwitch: NSSwitch!
    private var mainCard: CardView!         // group-1 card; gets the brand-violet wash when awake
    private var headerMark: NSImageView!    // header coffee mark; tints violet when awake
    private var captionLabel: NSTextField!
    private var floorValueLabel: NSTextField!
    private var floorSlider: NSSlider!
    private var autoOffControl: NSSegmentedControl!
    private var countdownLabel: NSTextField!
    private var loginSwitch: NSSwitch!
    private var clickMonitor: Any?
    private var batteryFloorPercent = floorDefault
    private var isOn = false
    private var userForcedOn = false   // user deliberately turned it on; honor over the Low Power Mode auto-off (the hard battery floor still wins)

    // Auto-off timer (in-memory; dies on quit, never survives a reboot)
    private var autoOffMinutes = 0           // 0 = none (stay on until off), 60, or 120
    private var leaseTimer: Timer?              // renews the lease while we intend to stay awake
    private var watchdogIsLoaded = false        // cached; launchctl is not free enough for renderText
    private var armedWithoutWatchdog = false    // user's explicit per-session override
    private var clamshellToken: Int32 = NOTIFY_TOKEN_INVALID
    private var lidClosed = false
    private var keepAwakeTimer: Timer?       // one-shot: flips sleep back on when it fires
    private var countdownTicker: Timer?      // 1 Hz label refresh, only while the popover is open
    private var timerEndDate: Date?

    private let popoverWidth: CGFloat = 320
    private let popoverHeight: CGFloat = 432

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        batteryFloorPercent = min(max((UserDefaults.standard.object(forKey: floorKey) as? Int) ?? floorDefault, floorMin), floorMax)
        createStatusItem()
        popover.behavior = .applicationDefined   // app-managed dismissal (no transient close/reopen flicker)
        popover.animates = true
        popover.contentSize = NSSize(width: popoverWidth, height: popoverHeight)
        popover.contentViewController = makeContentController()

        refresh()   // reflect TRUE system state on launch (never a stale assumption)
        startClamshellObserver()
        timer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                     selector: #selector(poll), userInfo: nil, repeats: true)
    }

    // Create (or recreate) the status item. macOS 26 can hide a status item when the menu bar
    // is crowded, and it may also remove the item if the backing button or image becomes invalid.
    // We pin it with a saved autosaveName, force it visible, and re-run this on every poll as a
    // cheap fallback so the icon reliably stays in the menu bar.
    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "Sleepless"
        statusItem.isVisible = true
        if let button = statusItem.button {
            button.image = offGlyph
            button.action = #selector(statusClicked)
            button.target = self
        }
    }

    // Ensure the status item stays attached to the menu bar. macOS 26 can drop or hide an item
    // when its button becomes nil or when the system trims crowded extras. Re-create if needed
    // and force visibility on every refresh/poll cycle.
    private func ensureStatusItemVisible() {
        let needsRecreate = statusItem == nil || statusItem.button == nil
        if needsRecreate { createStatusItem() }
        statusItem.isVisible = true
    }

    // MARK: - Popover content (native NSSwitch toggle, macOS-aligned)
    private func makeContentController() -> NSViewController {
        let W = popoverWidth, pad: CGFloat = 16
        let contentW = W - pad * 2
        let ci: CGFloat = 12                 // card inner padding
        let cw = contentW - ci * 2           // card inner content width

        // Standard system popover material: untinted, no forced emphasis, so it reads
        // as a first-party control (like the Wi-Fi / Sound / Battery popovers), not a
        // themed panel. NSPopover supplies its own corner, shadow, and arrow.
        let root = GlassView(frame: NSRect(x: 0, y: 0, width: W, height: popoverHeight))
        root.material = .popover
        root.blendingMode = .behindWindow
        root.state = .followsWindowActiveState

        // Header: small coffee mark + "Sleepless" (quiet system glyph, not a branded logo).
        // The mark tints to the brand violet while the Mac is kept awake.
        let mark = NSImageView(frame: NSRect(x: pad, y: 14, width: 18, height: 18))
        let headerCup = makeCupGlyph(.on); headerCup.isTemplate = true
        mark.image = headerCup
        mark.contentTintColor = .labelColor
        root.addSubview(mark)
        headerMark = mark
        let title = makeLabel("Sleepless", font: .systemFont(ofSize: 14, weight: .semibold), color: .labelColor)
        title.frame = NSRect(x: pad + 24, y: 14, width: contentW - 24, height: 20)
        root.addSubview(title)

        // Grouped inset cards (System Settings rhythm) replace per-row hairline separators.
        func makeCard(_ rect: NSRect) -> CardView {
            let c = CardView(frame: rect)
            c.wantsLayer = true
            root.addSubview(c)
            return c
        }
        let swProto = NSSwitch().intrinsicContentSize
        let swW = swProto.width > 0 ? swProto.width : 38
        let swH = swProto.height > 0 ? swProto.height : 21

        // GROUP 1 — main switch + state caption
        let g1y: CGFloat = 46, g1h: CGFloat = 84
        let g1 = makeCard(NSRect(x: pad, y: g1y, width: contentW, height: g1h))
        mainCard = g1
        let rowLabel = makeLabel("Keep awake with lid closed", font: .systemFont(ofSize: 13), color: .labelColor)
        rowLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g1.addSubview(rowLabel)
        toggleSwitch = NSSwitch()
        toggleSwitch.target = self
        toggleSwitch.action = #selector(switchToggled(_:))
        toggleSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g1.addSubview(toggleSwitch)
        captionLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        captionLabel.frame = NSRect(x: ci, y: ci + 30, width: cw, height: 32)
        captionLabel.usesSingleLineMode = false
        captionLabel.lineBreakMode = .byWordWrapping
        captionLabel.maximumNumberOfLines = 2
        captionLabel.cell?.wraps = true
        g1.addSubview(captionLabel)

        // GROUP 2 — auto-off timer (label + segmented [Off | 1h | 2h] + countdown)
        let g2y = g1y + g1h + 12, g2h: CGFloat = 78
        let g2 = makeCard(NSRect(x: pad, y: g2y, width: contentW, height: g2h))
        let timerLabel = makeLabel("Auto-off timer", font: .systemFont(ofSize: 13), color: .labelColor)
        timerLabel.frame = NSRect(x: ci, y: ci + 3, width: 110, height: 22)
        g2.addSubview(timerLabel)
        autoOffControl = NSSegmentedControl(labels: ["Off", "1h", "2h"],
                                            trackingMode: .selectOne,
                                            target: self, action: #selector(autoOffChanged(_:)))
        autoOffControl.selectedSegment = 0
        autoOffControl.controlSize = .regular
        autoOffControl.segmentStyle = .automatic
        autoOffControl.sizeToFit()
        let segSize = autoOffControl.frame.size
        let segW = segSize.width > 0 ? segSize.width : 150
        autoOffControl.frame = NSRect(x: contentW - ci - segW, y: ci, width: segW, height: max(segSize.height, 24))
        g2.addSubview(autoOffControl)
        countdownLabel = makeLabel("", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        countdownLabel.frame = NSRect(x: ci, y: ci + 36, width: cw, height: 16)
        g2.addSubview(countdownLabel)

        // GROUP 3 — battery-floor (label + value + slider + min/max hints)
        let g3y = g2y + g2h + 12, g3h: CGFloat = 92
        let g3 = makeCard(NSRect(x: pad, y: g3y, width: contentW, height: g3h))
        let floorLabel = makeLabel("Auto-off at low battery", font: .systemFont(ofSize: 13), color: .labelColor)
        floorLabel.frame = NSRect(x: ci, y: ci, width: cw - 54, height: 18)
        g3.addSubview(floorLabel)
        floorValueLabel = makeLabel("\(batteryFloorPercent)%", font: .systemFont(ofSize: 13, weight: .semibold), color: .secondaryLabelColor)
        floorValueLabel.alignment = .right
        floorValueLabel.frame = NSRect(x: contentW - ci - 54, y: ci, width: 54, height: 18)
        g3.addSubview(floorValueLabel)
        floorSlider = NSSlider(value: Double(batteryFloorPercent), minValue: Double(floorMin), maxValue: Double(floorMax),
                               target: self, action: #selector(floorSliderChanged(_:)))
        floorSlider.isContinuous = true          // live update while dragging
        floorSlider.controlSize = .regular
        floorSlider.frame = NSRect(x: ci, y: ci + 26, width: cw, height: 20)
        g3.addSubview(floorSlider)
        let minHint = makeLabel("\(floorMin)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        minHint.frame = NSRect(x: ci, y: ci + 50, width: 34, height: 13)
        g3.addSubview(minHint)
        let maxHint = makeLabel("\(floorMax)%", font: .systemFont(ofSize: 10), color: .tertiaryLabelColor)
        maxHint.alignment = .right
        maxHint.frame = NSRect(x: contentW - ci - 34, y: ci + 50, width: 34, height: 13)
        g3.addSubview(maxHint)

        // GROUP 4 — launch at login (off by default; never auto-enables sleep prevention)
        let g4y = g3y + g3h + 12, g4h: CGFloat = 46
        let g4 = makeCard(NSRect(x: pad, y: g4y, width: contentW, height: g4h))
        let loginLabel = makeLabel("Launch at login", font: .systemFont(ofSize: 13), color: .labelColor)
        loginLabel.frame = NSRect(x: ci, y: ci, width: cw - swW - 8, height: 22)
        g4.addSubview(loginLabel)
        loginSwitch = NSSwitch()
        loginSwitch.target = self
        loginSwitch.action = #selector(loginToggled(_:))
        loginSwitch.state = loginItemEnabled() ? .on : .off
        loginSwitch.frame = NSRect(x: contentW - ci - swW, y: ci + (22 - swH) / 2, width: swW, height: swH)
        g4.addSubview(loginSwitch)

        // Footer — Quit (separated by space, not a hairline)
        let quit = NSButton(title: "Quit Sleepless", target: self, action: #selector(quit))
        quit.controlSize = .regular
        quit.bezelStyle = .rounded
        quit.sizeToFit()
        let qs = quit.frame.size
        quit.frame = NSRect(x: W - pad - qs.width, y: g4y + g4h + 12, width: qs.width, height: qs.height)
        root.addSubview(quit)

        let vc = NSViewController()
        vc.view = root
        return vc
    }

    private func makeLabel(_ s: String, font: NSFont, color: NSColor) -> NSTextField {
        let t = NSTextField(labelWithString: s)
        t.font = font
        t.textColor = color
        t.isEditable = false
        t.isBordered = false
        t.drawsBackground = false
        return t
    }

    // MARK: - Click the menu-bar cup to open/close the popover
    @objc private func statusClicked() {
        if popover.isShown { closePopover() } else { openPopover() }
    }

    private func openPopover() {
        refresh()                              // sync switch/caption to TRUE state before showing
        loginSwitch?.state = loginItemEnabled() ? .on : .off
        guard let button = statusItem.button else { return }
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
        if keepAwakeTimer != nil { startCountdownTicker() }
        updateCountdownLabel()
        // Close when the user clicks anywhere outside the app (status bar, another app, desktop).
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.closePopover()
        }
    }

    private func closePopover() {
        popover.performClose(nil)
        countdownTicker?.invalidate(); countdownTicker = nil   // stop the 1 Hz label refresh (keep-awake timer keeps running)
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor); clickMonitor = nil }
    }

    @objc private func switchToggled(_ sender: NSSwitch) {
        if performToggle(wantOn: sender.state == .on) {
            // The transition failed. Show the state the SYSTEM is actually in — forcing .off here
            // made a failed turn-OFF read as "asleep" while the Mac was still being kept awake.
            sender.state = isOn ? .on : .off
        }
    }

    // Core keep-awake toggle, decoupled from the UI sender. Returns true when the requested
    // transition FAILED, so the caller can resync the switch to reality. The decision is made on
    // the REAL sudo result (see setDisableSleep),
    // never by re-reading SleepDisabled: a successful sudo means the command ran, even if a
    // safety net (Low Power Mode / battery floor) legitimately turns sleep back on afterwards —
    // which must NOT be mistaken for "permission missing" and trigger a password prompt. This
    // unobservable, state-proxy decision is what made earlier releases re-prompt spuriously.
    @discardableResult
    private func performToggle(wantOn: Bool) -> Bool {
        if wantOn {
            // The safety net is the point of this build, so arming without it is an explicit,
            // per-session choice rather than a silent downgrade.
            refreshWatchdogState()
            if !watchdogIsLoaded, !armedWithoutWatchdog {
                guard confirmArmingWithoutWatchdog() else { refresh(); return true }
                armedWithoutWatchdog = true
            }
            // Lease FIRST, flag second: never leave a window where disablesleep is set with no
            // lease behind it, which the watchdog would (correctly) undo on its next tick.
            extendLease()
        }
        let result = setDisableSleep(wantOn)
        switch result {
        case .ok:
            break
        case .grantMissing:
            if wantOn { releaseLease() }
            showGrantInstructions()
            refresh()
            return true
        case .failed(let detail):
            if wantOn { releaseLease() }
            // Surface BOTH directions. A failed turn-off is the dangerous one: the Mac stays awake.
            NSLog("Sleepless: pmset toggle failed: %@", detail)
            notify(wantOn
                ? "Couldn't keep awake. See Console for the pmset error."
                : "Couldn't restore normal sleep. See Console for the pmset error.")
            refresh()
            return true
        }
        if wantOn { startLeaseRenewal() } else { stopLeaseRenewal() }
        // A deliberate, successful turn-on wins over the Low Power Mode auto-off (hard floor still wins).
        userForcedOn = wantOn
        refresh()                              // applies UI + safety nets; switch reflects reality
        if isOn, autoOffMinutes > 0 { startKeepAwakeTimer(minutes: autoOffMinutes) }
        return false
    }

    // Privilege setup is deliberately NOT launched from the GUI.
    //
    // Upstream installs the sudoers grant by running the bundled grant.sh as root through
    // osascript's "with administrator privileges". A .app bundle is user-writable, so that is an
    // avoidable substitution/TOCTOU surface: anything that can write into Contents/Resources
    // between the check and the exec gets root. Upstream's version also built the AppleScript by
    // string interpolation, escaping only backslash and double quote — a bundle path containing an
    // apostrophe broke out of the single-quoted shell string.
    //
    // This is a personal build, so the fix is to delete the code path rather than harden it:
    // installing the grant is a one-time, reviewed Terminal step. See docs/FORK.md.
    private func showGrantInstructions() {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "One-time permission needed"
        alert.informativeText = """
            Sleepless flips a protected macOS setting (pmset disablesleep), which needs a one-time \
            passwordless sudo grant for exactly two commands.

            It is never installed from inside the app. Run this once, from the source folder you \
            reviewed:

                ./grant.sh

            Then flip the switch again.
            """
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    // A brief, subtle pulse on the menu-bar glyph whenever the state (and thus the cup
    // shape) changes, so the change is noticeable. Uses AppKit animator proxy only:
    // no CALayer mutation on NSStatusBarButton, which is fragile on macOS 26 and has
    // been observed to make status items disappear.
    private func pulseStatusItem() {
        guard let b = statusItem.button else { return }
        b.alphaValue = 0.3
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.34
            ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
            b.animator().alphaValue = 1.0
        }, completionHandler: nil)
    }

    @objc private func poll() { refresh() }

    // MARK: - Auto-off timer (Feature 1)
    @objc private func autoOffChanged(_ sender: NSSegmentedControl) {
        switch sender.selectedSegment {
        case 1: autoOffMinutes = 60
        case 2: autoOffMinutes = 120
        default: autoOffMinutes = 0
        }
        if isOn, autoOffMinutes > 0 {
            startKeepAwakeTimer(minutes: autoOffMinutes)
        } else {
            cancelKeepAwakeTimer()
            updateCountdownLabel()
        }
    }

    private func startKeepAwakeTimer(minutes: Int) {
        cancelKeepAwakeTimer()
        guard minutes > 0, isOn else { updateCountdownLabel(); return }
        let seconds = TimeInterval(minutes * 60)
        timerEndDate = Date().addingTimeInterval(seconds)
        keepAwakeTimer = Timer.scheduledTimer(timeInterval: seconds, target: self,
                                              selector: #selector(keepAwakeTimerFired), userInfo: nil, repeats: false)
        if popover.isShown { startCountdownTicker() }
        updateCountdownLabel()
    }

    private func cancelKeepAwakeTimer() {
        keepAwakeTimer?.invalidate(); keepAwakeTimer = nil
        countdownTicker?.invalidate(); countdownTicker = nil
        timerEndDate = nil
    }

    @objc private func keepAwakeTimerFired() {
        if turnOffForSafety("Auto-off timer ended",
                            success: "Auto-off timer ended. Sleepless turned off.") {
            cancelKeepAwakeTimer()
            autoOffMinutes = 0
            autoOffControl?.selectedSegment = 0
        } else {
            // This timer is one-shot. Without an explicit retry a single transient sudo/pmset
            // failure silently defeats the auto-off and the Mac stays awake indefinitely.
            timerEndDate = Date().addingTimeInterval(pollInterval)
            keepAwakeTimer = Timer.scheduledTimer(timeInterval: pollInterval, target: self,
                                                  selector: #selector(keepAwakeTimerFired),
                                                  userInfo: nil, repeats: false)
            updateCountdownLabel()
        }
    }

    // Every safety net turns Sleepless off through here. A failed privileged call must never be
    // treated as success: the Mac is still awake, so say so and stay armed. Returns true only when
    // normal sleep was really restored. The battery-floor and Low-Power-Mode nets re-evaluate on
    // the next poll by themselves; one-shot callers must reschedule.
    @discardableResult
    private func turnOffForSafety(_ reason: String, success: String) -> Bool {
        let result = setDisableSleep(false)
        if result == .ok { stopLeaseRenewal() }
        applyUI(on: readSleepDisabled())
        if result == .ok {
            notify(success)
            return true
        }
        NSLog("Sleepless: safety turn-off (%@) failed: %@", reason, String(describing: result))
        notify("\(reason), but normal sleep could NOT be restored. Still trying.")
        return false
    }

    private func startCountdownTicker() {
        countdownTicker?.invalidate()
        countdownTicker = Timer.scheduledTimer(timeInterval: 1, target: self,
                                               selector: #selector(countdownTick), userInfo: nil, repeats: true)
    }

    @objc private func countdownTick() { updateCountdownLabel() }

    private func updateCountdownLabel() {
        guard let end = timerEndDate, isOn else { countdownLabel?.stringValue = ""; return }
        let remaining = Int(end.timeIntervalSinceNow.rounded())
        guard remaining > 0 else { countdownLabel?.stringValue = ""; return }
        let h = remaining / 3600, m = (remaining % 3600) / 60, s = remaining % 60
        let t = h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
        countdownLabel?.stringValue = "Auto-off in \(t)"
    }

    // MARK: - Launch at login (Feature 2) — OFF by default; never re-enables sleep prevention
    @objc private func loginToggled(_ sender: NSSwitch) {
        do {
            if sender.state == .on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Sleepless: login item update failed: %@", error.localizedDescription)
            notify("Couldn't update Launch at login.")
        }
        sender.state = loginItemEnabled() ? .on : .off
    }

    private func loginItemEnabled() -> Bool { SMAppService.mainApp.status == .enabled }

    // MARK: - Core state sync
    @objc private func refresh() {
        ensureStatusItemVisible()
        refreshWatchdogState()
        let on = readSleepDisabled()
        applyUI(on: on)
        if on { enforceSafetyNets() }
    }

    private func applyUI(on: Bool) {
        isOn = on
        if !on {
            cancelKeepAwakeTimer()      // going OFF clears any countdown/timer
            stopLeaseRenewal()          // ...and drops the lease, however we got here —
        }                               // including the watchdog clearing the flag under us
        // ARMED = kept awake while actively discharging on battery, so the
        // auto-off safety net is live. Distinct menu-bar glyph (cup + dot).
        var armed = false
        if on {
            let (onBattery, discharging, _) = batteryStatus()
            armed = onBattery && discharging
        }
        if let button = statusItem.button {
            let newImage = on ? (armed ? armedGlyph : onGlyph) : offGlyph
            if button.image !== newImage {   // state (cup shape) changed -> swap + pulse
                button.image = newImage
                pulseStatusItem()
            }
            button.toolTip = on
                ? (armed
                    ? "Sleepless: on (battery). Auto-off at \(batteryFloorPercent)% or in Low Power Mode."
                    : "Sleepless: on. Stays awake with the lid closed.")
                : "Sleepless: off. Sleeps normally."
        }
        toggleSwitch?.state = on ? .on : .off
        // Brand-violet accent communicates the privileged "awake" state at a glance.
        mainCard?.active = on
        headerMark?.contentTintColor = on ? brandAccentSoft : .labelColor
        renderText()
        updateCountdownLabel()
    }

    // Update text labels only (no pmset subprocess; safe to call on every slider tick).
    private func renderText() {
        floorValueLabel?.stringValue = "\(batteryFloorPercent)%"
        if !watchdogIsLoaded {
            captionLabel?.stringValue = isOn
                ? "⚠️ No watchdog: if Sleepless quits, your Mac stays awake until you reboot."
                : "⚠️ Watchdog not running. Install it: ./watchdog-agent.sh install"
        } else {
            captionLabel?.stringValue = isOn
                ? "Stays awake when the lid is closed. Turns off at \(batteryFloorPercent)% battery or in Low Power Mode."
                : "Sleeps normally when you close the lid."
        }
    }

    @objc private func floorSliderChanged(_ sender: NSSlider) {
        let v = min(max(Int(sender.doubleValue.rounded()), floorMin), floorMax)
        if v != batteryFloorPercent {
            batteryFloorPercent = v
            UserDefaults.standard.set(v, forKey: floorKey)
        }
        renderText()
    }

    // Result of the privileged keep-awake toggle, based on sudo's REAL exit status — not on a
    // second, independent state read. `.ok` = the command ran; `.grantMissing` = the passwordless
    // sudoers grant isn't installed (sudo -n refused), the one case that warrants setup; `.failed`
    // = any other error. Using sudo's own result (instead of re-reading SleepDisabled) is the fix:
    // a safety net flipping sleep back on must never look like "permission missing" and re-prompt.
    private enum ToggleResult: Equatable { case ok, grantMissing, failed(String) }

    @discardableResult
    private func setDisableSleep(_ on: Bool) -> ToggleResult {
        // sudo -n: never prompt (GUI app has no TTY). The exact argument vector matches the
        // NOPASSWD sudoers grant, so this runs without a password.
        let (exit, _, err) = runPrivileged(["-n", "/usr/bin/pmset", "-a", "disablesleep", on ? "1" : "0"])
        let result: ToggleResult
        if exit == 0 {
            result = .ok
        } else if err.range(of: "a password is required", options: .caseInsensitive) != nil
               || err.range(of: "not allowed", options: .caseInsensitive) != nil
               || err.range(of: "may not run", options: .caseInsensitive) != nil {
            result = .grantMissing   // grant absent/removed -> sudo -n refused to run passwordless
        } else {
            result = .failed(err.isEmpty ? "exit \(exit)" : err.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return result
    }

    // Run a privileged command via sudo, capturing exit status + stderr (which the generic
    // runCapture discards). stdin is /dev/null so a GUI process with no controlling TTY can
    // never block on a prompt. This is what lets the app KNOW whether its own toggle worked.
    private func runPrivileged(_ args: [String]) -> (exit: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sudo")
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() }
        catch {
            NSLog("Sleepless: failed to launch sudo: %@", error.localizedDescription)
            return (-1, "", "launch failed: \(error.localizedDescription)")
        }
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus,
                String(data: outData, encoding: .utf8) ?? "",
                String(data: errData, encoding: .utf8) ?? "")
    }

    // MARK: - Keep-awake lease — the dead-man switch (Feature 5)
    //
    // Mirrors the `sleepless` CLI exactly; that script is the reference writer and the two must agree
    // byte for byte on the format, or the watchdog silently stops trusting our leases.
    private var leaseURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(leaseRelativePath)
    }

    // Seconds since the epoch at which the running kernel booted. A lease cannot outlive its
    // boot: disablesleep resets to 0 on reboot, so a lease from before it is stale by
    // construction. Read through sysctl rather than a subprocess — this runs every 30s.
    private func bootTimeSeconds() -> Int? {
        var tv = timeval()
        var size = MemoryLayout<timeval>.stride
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0 else { return nil }
        return Int(tv.tv_sec)
    }

    // Current expiry, but only from a lease this boot can trust. Digits-only fields, same as
    // the shell reader: anything unparseable reads as "no live lease", which lets the flag go.
    private func liveLeaseExpiry() -> Int? {
        guard let text = try? String(contentsOf: leaseURL, encoding: .utf8) else { return nil }
        var fields: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, !parts[1].isEmpty,
                  parts[1].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(parts[1]) else { continue }
            fields[String(parts[0])] = value
        }
        guard fields["version"] == leaseVersion,
              let boot = bootTimeSeconds(), fields["boot"] == boot,
              let expires = fields["expires"] else { return nil }
        return expires
    }

    // Extend is a FLOOR, never an assignment: our 30s renewal must not truncate a longer
    // lease someone else (the CLI, later) is holding.
    @discardableResult
    private func extendLease() -> Bool {
        guard let boot = bootTimeSeconds() else {
            NSLog("Sleepless: no boot time; refusing to write a lease")
            return false
        }
        let now = Int(Date().timeIntervalSince1970)
        var target = now + leaseTTL
        if let current = liveLeaseExpiry(), current > target { target = current }
        do {
            try FileManager.default.createDirectory(at: leaseURL.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            // atomically: true is write-then-rename, so the watchdog never sees a partial lease.
            try "version=\(leaseVersion)\nexpires=\(target)\nboot=\(boot)\n"
                .write(to: leaseURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                  ofItemAtPath: leaseURL.path)
            return true
        } catch {
            NSLog("Sleepless: couldn't write lease: %@", error.localizedDescription)
            return false
        }
    }

    private func releaseLease() { try? FileManager.default.removeItem(at: leaseURL) }

    private func startLeaseRenewal() {
        leaseTimer?.invalidate()
        leaseTimer = Timer.scheduledTimer(timeInterval: leaseRenewInterval, target: self,
                                          selector: #selector(renewLease), userInfo: nil, repeats: true)
    }

    // Stops renewing AND drops the lease: intent has ended, so the watchdog is free to act.
    private func stopLeaseRenewal() {
        leaseTimer?.invalidate(); leaseTimer = nil
        releaseLease()
    }

    @objc private func renewLease() {
        guard isOn else { stopLeaseRenewal(); return }
        extendLease()
    }

    // Is the dead-man switch actually running? Cheap enough per poll, too expensive for
    // renderText (which fires on every slider tick), hence the cached flag.
    private func refreshWatchdogState() {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        proc.arguments = ["list", watchdogLabel]
        proc.standardOutput = Pipe(); proc.standardError = Pipe()
        do { try proc.run(); proc.waitUntilExit() } catch { watchdogIsLoaded = false; return }
        watchdogIsLoaded = proc.terminationStatus == 0
    }

    // Arming without the watchdog is a real choice with a real cost, so it is presented as
    // one. Refusing outright would be brittle; arming silently would recreate exactly the
    // failure this fork exists to fix — the user believing they have a safety net they
    // don't. Cancel is the default button; the override lasts for this app session only.
    private func confirmArmingWithoutWatchdog() -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "The safety net isn't running"
        alert.informativeText = """
            Sleepless keeps your Mac awake by setting a system-wide flag that no app owns. A \
            watchdog normally clears it if Sleepless quits or crashes — without it, the flag \
            stays set until you reboot.

            Install it from the source folder:

                ./watchdog-agent.sh install
            """
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Keep Awake Anyway")
        NSApp.activate(ignoringOtherApps: true)
        return alert.runModal() == .alertSecondButtonReturn
    }

    // MARK: - Lid-close display power-off — Feature 4
    //
    // With SleepDisabled set, closing the lid no longer takes the normal sleep path, so the
    // built-in panel can stay powered: a lit screen inside a closed bag, burning battery and
    // making heat. (It also means the Mac never locks on lid close, because the password prompt
    // hangs off sleep / display-off.) Asking for display sleep explicitly restores both.
    //
    // `pmset displaysleepnow` is an ACTION, not a setting — per pmset(1) only settings need root —
    // so this runs unprivileged and needs NO extra entry in the sudoers grant.
    //
    // Event-driven via the clamshell darwin notification: no polling, and it fires even while
    // another process holds a NoDisplaySleep assertion.
    private func startClamshellObserver() {
        let name = "com.apple.system.powermanagement.clamshellstate"
        let status = notify_register_dispatch(name, &clamshellToken, DispatchQueue.main) { [weak self] token in
            var state: UInt64 = 0
            guard notify_get_state(token, &state) == UInt32(NOTIFY_STATUS_OK) else {
                NSLog("Sleepless: couldn't read clamshell state")
                return
            }
            MainActor.assumeIsolated { self?.clamshellChanged(closed: state != 0) }
        }
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            NSLog("Sleepless: clamshell observer unavailable (status %d); lid-close display-off disabled", status)
            clamshellToken = NOTIFY_TOKEN_INVALID
            return
        }
        var state: UInt64 = 0
        if notify_get_state(clamshellToken, &state) == UInt32(NOTIFY_STATUS_OK) { lidClosed = state != 0 }
    }

    private func clamshellChanged(closed: Bool) {
        defer { lidClosed = closed }
        guard closed, !lidClosed else { return }          // only the open -> closed edge
        guard isOn else { return }                        // not keeping awake: macOS handles the lid
        guard !externalDisplayPresent() else { return }   // clamshell mode: the external stays on
        let out = runCapture("/usr/bin/pmset", ["displaysleepnow"])
        if !out.isEmpty { NSLog("Sleepless: displaysleepnow said: %@", out) }
    }

    private func externalDisplayPresent() -> Bool {
        for screen in NSScreen.screens {
            guard let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
            else { continue }
            if CGDisplayIsBuiltin(id) == 0 { return true }
        }
        return false
    }

    // MARK: - Battery + Low-Power-Mode safety nets (silent; no extra UI) — Feature 3
    private func enforceSafetyNets() {
        let (onBattery, discharging, percent) = batteryStatus()
        guard onBattery, discharging else { return }
        // Hard battery floor ALWAYS wins, even over a deliberate turn-on: never drain to empty.
        if percent <= batteryFloorPercent {
            userForcedOn = false
            turnOffForSafety("Battery low (\(percent)%)",
                             success: "Battery low (\(percent)%). Sleepless turned off.")
            return
        }
        // Low Power Mode auto-off, UNLESS the user deliberately chose to keep awake this session.
        if ProcessInfo.processInfo.isLowPowerModeEnabled && !userForcedOn {
            turnOffForSafety("Low Power Mode on",
                             success: "Low Power Mode on. Sleepless turned off.")
        }
    }

    // MARK: - Readers (no root needed)
    private func readSleepDisabled() -> Bool {
        let out = runCapture("/usr/bin/pmset", ["-g"])
        for line in out.split(whereSeparator: { $0 == "\n" }) {
            if line.range(of: "SleepDisabled", options: .caseInsensitive) != nil {
                let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
                if let last = toks.last { return last == "1" }
            }
        }
        return false   // line absent -> OFF
    }

    private func batteryStatus() -> (onBattery: Bool, discharging: Bool, percent: Int) {
        let out = runCapture("/usr/bin/pmset", ["-g", "batt"])
        let onBattery = out.contains("Battery Power")
        let discharging = out.range(of: "discharging", options: .caseInsensitive) != nil
        var percent = 100
        for tok in out.split(whereSeparator: { " \t\n;".contains($0) }) {
            if tok.hasSuffix("%"), let v = Int(tok.dropLast()) { percent = v; break }
        }
        return (onBattery, discharging, percent)
    }

    // MARK: - Notification (mirrors Nexus' osascript approach)
    private func notify(_ message: String) {
        let script = "display notification \"\(message)\" with title \"Sleepless\" sound name \"Tink\""
        _ = runCapture("/usr/bin/osascript", ["-e", script])
    }

    // MARK: - Process runner (explicit PATH/HOME; captures stdout)
    @discardableResult
    private func runCapture(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        process.environment = env
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do { try process.run() }
        catch { NSLog("Sleepless: failed to launch %@: %@", launchPath, error.localizedDescription); return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    @objc private func quit() { NSApp.terminate(nil) }

    // A deliberate quit ends the intent, so it ends the state: drop the lease and restore
    // normal sleep directly rather than leaving the Mac awake for up to one watchdog tick.
    // The watchdog remains the backstop for the case this cannot cover — a crash.
    func applicationWillTerminate(_ notification: Notification) {
        releaseLease()
        leaseTimer?.invalidate(); leaseTimer = nil
        if readSleepDisabled() { setDisableSleep(false) }
    }
}

@main
enum SleeplessApp {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        objc_setAssociatedObject(app, &delegateKey, delegate, .OBJC_ASSOCIATION_RETAIN)
        app.run()
    }
}

nonisolated(unsafe) private var delegateKey = 0
