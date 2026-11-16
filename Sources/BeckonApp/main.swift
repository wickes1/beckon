import AppKit
import ServiceManagement
import SwiftUI

// The panel must never take keystrokes the user is typing elsewhere, yet SwiftUI only recognises a click in a
// key window (seen live: in a panel that refuses key status no tap gesture fires at all). So it becomes key for
// the length of a click and hands the keyboard straight back afterwards, unless that click put the cursor in
// one of its text fields; then it keeps the keyboard until the field is gone.
final class KeyPanel: NSPanel {
    private var wantsKey = false
    override var canBecomeKey: Bool { wantsKey }

    func takeKey() {
        wantsKey = true
        makeKey()
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, !isKeyWindow { takeKey() }
        super.sendEvent(event)
        // Not at once: SwiftUI delivers the tap after the mouse-up returns, and a panel taken off screen before
        // that drops it (seen live). By then a card has also had time to focus its field.
        if event.type == .leftMouseUp { DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { self.yieldKeyIfIdle() } }
    }

    override func resignKey() {
        super.resignKey()
        wantsKey = false
    }

    /// Gives the keyboard back unless a text field is being edited. Called after every click and every change
    /// to the cards (answer sent, card answered in the terminal). Taking a key window off screen is what makes
    /// macOS hand key status to the active app's window; it comes straight back on, in the same pass.
    func yieldKeyIfIdle() {
        guard isKeyWindow, !(firstResponder is NSTextView) else { return }
        orderOut(nil)
        orderFrontRegardless()
    }
}

/// The one panel, for cards that focus their text field from a click elsewhere on the card.
weak var keyPanel: KeyPanel?

/// The menu bar icon: a card with a picked option and an open one, the panel's cards in miniature. Drawn here
/// rather than shipped as a file, as a template image so macOS tints it for a light or dark menu bar.
/// Geometry on an 18 pt grid.
func menuBarIcon() -> NSImage {
    let image = NSImage(size: NSSize(width: 18, height: 18), flipped: true) { _ in
        func stroke(_ path: NSBezierPath, width: CGFloat = 1.5, alpha: CGFloat = 1) {
            NSColor.black.withAlphaComponent(alpha).setStroke()
            path.lineWidth = width
            path.lineCapStyle = .round
            path.stroke()
        }
        func line(_ x0: CGFloat, _ x1: CGFloat, _ y: CGFloat) -> NSBezierPath {
            let path = NSBezierPath()
            path.move(to: NSPoint(x: x0, y: y))
            path.line(to: NSPoint(x: x1, y: y))
            return path
        }
        stroke(NSBezierPath(roundedRect: NSRect(x: 2, y: 2.25, width: 14, height: 13.5), xRadius: 3, yRadius: 3))
        // First option: picked (filled dot), full-strength label.
        NSColor.black.setFill()
        NSBezierPath(ovalIn: NSRect(x: 4.25, y: 5, width: 3, height: 3)).fill()
        stroke(line(8.75, 13, 6.5))
        // Second option: open circle, label at partial alpha (template images keep alpha).
        stroke(NSBezierPath(ovalIn: NSRect(x: 4.65, y: 10.15, width: 2.2, height: 2.2)), width: 1.1)
        stroke(line(8.75, 12, 11.25), alpha: 0.55)
        return true
    }
    image.isTemplate = true
    image.accessibilityDescription = "beckon"
    return image
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var panel: KeyPanel!
    var statusItem: NSStatusItem!
    var server: Server!
    var cardFrames: [CGRect] = []

    // A tall fixed transparent column, so cards animate without window resizes.
    // Clicks pass through everywhere except over a card.
    func updateClickThrough() {
        guard let content = panel.contentView else { return }
        let p = panel.mouseLocationOutsideOfEventStream
        let flipped = CGPoint(x: p.x, y: content.bounds.height - p.y)
        let over = cardFrames.contains { $0.insetBy(dx: -10, dy: -10).contains(flipped) }
        if panel.ignoresMouseEvents == over { panel.ignoresMouseEvents = !over }
        if store.pointerInside != over {
            store.pointerInside = over
            store.pointerEnteredAt = over ? Date() : nil
        }
    }

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width: CGFloat = 424
        panel = KeyPanel(contentRect: NSRect(x: screen.maxX - width, y: screen.minY, width: width, height: screen.height),
                         styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.contentView = NSHostingView(rootView: StackView { [weak self] frames in
            self?.cardFrames = frames
            self?.updateClickThrough()
        })
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.ignoresMouseEvents = true
        panel.orderFrontRegardless()
        keyPanel = panel
        NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] _ in self?.updateClickThrough() }
        NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] e in self?.updateClickThrough(); return e }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = menuBarIcon()
        statusItem.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        store.onChange = { [weak self] in
            let n = store.pending.count
            self?.statusItem.button?.title = n > 0 ? "\(n)" : ""
            // After SwiftUI has dropped the answered card's text field.
            DispatchQueue.main.async { self?.panel.yieldKeyIfIdle() }
        }
        server = Server(onRequest: Intake.handle)
        do {
            try server.start()
        } catch {
            // Loud: without the socket every hook silently falls back to the terminal.
            let alert = NSAlert(error: error)
            alert.messageText = "beckon couldn't open its socket"
            alert.runModal()
            NSApp.terminate(nil)
        }
        // After the server: it creates the directory the presence file lives in, which a first launch lacks.
        Presence.start()
    }
}

extension AppDelegate {
    // Built when opened: everything still waiting on the user, including cards closed with × and prompts held
    // back because their session is in front. Picking one puts it on the panel, open.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let waiting = store.pending
        if waiting.isEmpty {
            menu.addItem(NSMenuItem(title: "Nothing waiting", action: nil, keyEquivalent: ""))
        }
        for item in waiting {
            let entry = NSMenuItem(title: Words.clip("\(item.kind.label): \(item.summary) — \(item.title)", 80), action: #selector(showItem(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = item.id
            entry.image = NSImage(systemSymbolName: item.kind.symbol, accessibilityDescription: item.kind.label)
            menu.addItem(entry)
        }
        menu.addItem(.separator())
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(soundsItem())
        menu.addItem(NSMenuItem(title: "Quit beckon", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    @objc func showItem(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { store.reveal(id, open: true) }
    }

    @objc func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() }
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "beckon couldn't change its login item"
            alert.runModal()
        }
    }

    // Sounds ▸  Mute · When Claude Waits for You ▸ · When a Turn Ends ▸ (None, then every system sound).
    func soundsItem() -> NSMenuItem {
        let sub = NSMenu()
        let mute = NSMenuItem(title: "Mute", action: #selector(toggleMute), keyEquivalent: "")
        mute.target = self
        mute.state = Chime.muted ? .on : .off
        sub.addItem(mute)
        sub.addItem(.separator())
        for slot in Chime.Slot.allCases {
            let picks = NSMenu()
            let current = Chime.sound(slot)
            for name in [""] + Chime.available {
                let entry = NSMenuItem(title: name.isEmpty ? "None" : name, action: #selector(pickSound(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = [slot.rawValue, name]
                entry.state = name == current ? .on : .off
                picks.addItem(entry)
                if name.isEmpty { picks.addItem(.separator()) }
            }
            let item = NSMenuItem(title: slot.title, action: nil, keyEquivalent: "")
            item.submenu = picks
            sub.addItem(item)
        }
        let item = NSMenuItem(title: Chime.muted ? "Sounds: Muted" : "Sounds", action: nil, keyEquivalent: "")
        item.submenu = sub
        return item
    }

    @objc func toggleMute() { Chime.muted.toggle() }

    /// Choosing a sound plays it, so the user hears what they picked; it also unmutes, since picking one means
    /// they want to hear it.
    @objc func pickSound(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [String], pair.count == 2, let slot = Chime.Slot(rawValue: pair[0]) else { return }
        Chime.set(slot, to: pair[1])
        Chime.muted = false
        Chime.preview(pair[1])
    }

    func applicationWillTerminate(_ n: Notification) { Presence.stop() }
}

// A hook that already hung up must never take the app down with it: writing to its closed socket raises
// SIGPIPE, which killed the app (exit 141) even with SO_NOSIGPIPE set on the accepted socket.
signal(SIGPIPE, SIG_IGN)

// `pkill` and logout end the app with SIGTERM, which skips applicationWillTerminate: go through terminate()
// so the presence file never outlives the app (it would mute phone pushes for good).
signal(SIGTERM, SIG_IGN)
let sigterm = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
sigterm.setEventHandler { NSApp.terminate(nil) }
sigterm.resume()

// A second copy (an upgrade opened over the running one, a dev build beside the installed app) would take over
// the socket and leave the first one's panel up with cards nothing ever clears. The newcomer leaves at once,
// before it touches the socket or the presence file the running copy keeps.
if let me = Bundle.main.bundleIdentifier,
   let other = NSRunningApplication.runningApplications(withBundleIdentifier: me).first(where: { $0.processIdentifier != getpid() }) {
    FileHandle.standardError.write(Data("beckon is already running (pid \(other.processIdentifier)); quit it first\n".utf8))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
