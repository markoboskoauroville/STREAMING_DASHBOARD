// Streaming Dashboard (Mantra): one window for the streams on the cloud machine chromium-vm.
// Marko, 15.11.2026: "I want to have one window, one pane, like any other application, which we can call a streaming
// dashboard. From the streaming dashboard, I can start this meditation room to be streamed. I can see the statistics:
// what is the speed coming from my computer to the virtual machine? How many users are attached to our streams? What is
// the speed for each user? And any other useful settings and features you find for this panel."
//
// The first screen: the chain PHONE · MAC · VM · SITE as four lights, 1 START the Meditation Room test stream on the VM,
// 2 GO LIVE on the site as camera "VM Test", and five numbers with their sparklines. Everything else sits behind DETAILS,
// as folders (name + one line), one open at a time. All data comes from the VM by ssh (Collector.swift); the app never
// streams video itself.
import AppKit
import SwiftUI

let VERSION = 5
let APP_NAME = "Streaming Dashboard (Mantra)"

enum Ink {
    static func hex(_ v: UInt32) -> Color {
        Color(red: Double((v >> 16) & 255) / 255, green: Double((v >> 8) & 255) / 255, blue: Double(v & 255) / 255)
    }
    static let ground = hex(0x0B0B0D)
    static let line = hex(0x2E2E33)
    static let text = hex(0xECECEC)
    static let dim = hex(0x8E8E96)
    static let green = hex(0x33D17A)
    static let grey = hex(0x7A8087)
    static let amber = hex(0xF0A030)
    static let red = hex(0xE5484D)
    static let gold = hex(0xD4AF37)
}

struct PressHover: ViewModifier {
    @Environment(\.isEnabled) private var enabled
    @State private var hot = false
    func body(content: Content) -> some View {
        let on = hot && enabled
        content
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color.white.opacity(on ? 0.12 : 0)))
            .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.white.opacity(on ? 0.55 : 0), lineWidth: 1))
            .animation(.easeOut(duration: 0.12), value: on)
            .onHover { inside in hot = inside
                if enabled { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
    }
}

extension View {
    func pressHover() -> some View { modifier(PressHover()) }
    func axButton(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        accessibilityElement(children: .ignore)
            .accessibilityLabel(label)
            .accessibilityIdentifier(id)
            .accessibilityValue(value ?? "")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction(.default, action)
    }
    /// a word that is a button: tap, hover highlight, Accessibility button
    func word(_ label: String, id: String, value: String? = nil, _ action: @escaping () -> Void) -> some View {
        self.pressHover().contentShape(Rectangle()).onTapGesture(perform: action).axButton(label, id: id, value: value, action)
    }
}

/// cells laid out in rows that wrap: nothing is cut at the minimum width
struct Flow: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 10
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 800
        var x: CGFloat = 0, y: CGFloat = 0, row: CGFloat = 0, maxW: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > 0 && x + s.width > w { y += row + rowSpacing; x = 0; row = 0 }
            x += s.width + spacing; row = max(row, s.height); maxW = max(maxW, x - spacing)
        }
        return CGSize(width: min(w, maxW), height: y + row)
    }
    func placeSubviews(in b: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = b.minX, y = b.minY, row: CGFloat = 0
        for v in subviews {
            let s = v.sizeThatFits(.unspecified)
            if x > b.minX && x + s.width > b.maxX { y += row + rowSpacing; x = b.minX; row = 0 }
            v.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(s))
            x += s.width + spacing; row = max(row, s.height)
        }
    }
}

struct Hairline: View { var body: some View { Rectangle().fill(Ink.line).frame(height: 1) } }

// ---------------------------------------------------------------- the top row (house rule: name · ON · OFF · version · TOP · ✕)
struct TopRow: View {
    @AppStorage("onTop") private var onTop = false
    var body: some View {
        ZStack {
            (Text("Streaming Dashboard").fontWeight(.bold) + Text(" (Mantra)").fontWeight(.regular))
                .font(.system(size: 15)).foregroundStyle(Ink.text)
            HStack(spacing: 10) {
                Spacer().frame(width: 64)
                Text("ON").foregroundStyle(Ink.green)
                Text("OFF").foregroundStyle(Ink.grey).word("Off", id: "off") { DispatchQueue.main.async { NSApp.terminate(nil) } }
                Spacer()
                Text("v\(VERSION)").foregroundStyle(Ink.dim)
                Text("TOP").foregroundStyle(onTop ? Ink.green : Ink.grey)
                    .word("Top", id: "top", value: onTop ? "on" : "off") { onTop.toggle(); TopRow.float(onTop) }
                Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Ink.grey)
                    .frame(width: 28, height: 28)
                    .word("Close window", id: "close") { App.shared.window?.performClose(nil) }
            }
            .font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .frame(height: 34)
        .onAppear { DispatchQueue.main.async { TopRow.float(onTop) } }
    }
    static func float(_ on: Bool) { App.shared.window?.level = on ? .floating : .normal; App.shared.enforceOneTitle() }
}

// ---------------------------------------------------------------- the app
final class App: NSObject, NSApplicationDelegate, NSWindowDelegate {
    static let shared = App()
    let dash = Dash()
    var window: NSWindow?

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.appearance = NSAppearance(named: .darkAqua)
        menu()
        makeWindow()
        dash.start()
        Updater.checkAtStart()
    }

    func makeWindow() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 940, height: 680),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = APP_NAME
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        w.tabbingMode = .disallowed
        w.isReleasedWhenClosed = false
        w.backgroundColor = NSColor(red: 0.043, green: 0.043, blue: 0.051, alpha: 1)
        w.contentMinSize = NSSize(width: 780, height: 560)
        w.contentView = NSHostingView(rootView: Root(dash: dash))
        w.delegate = self
        w.center()
        w.setFrameAutosaveName("StreamingDashboardMain")
        // the first time: on the MacBook Pro's own screen, never the BenQ (the BenQ is Marko's); later where he left it.
        // After the autosave name, which restores a saved frame: v1/v2 had saved one on the BenQ.
        if !UserDefaults.standard.bool(forKey: "placedOnBuiltIn"),
           let built = NSScreen.screens.first(where: { $0.localizedName.localizedCaseInsensitiveContains("built-in") }) {
            let f = built.visibleFrame
            w.setFrameOrigin(NSPoint(x: f.midX - w.frame.width / 2, y: max(f.minY, f.maxY - w.frame.height - 40)))
            UserDefaults.standard.set(true, forKey: "placedOnBuiltIn")
        }
        window = w
        enforceOneTitle(w)
        // opened in the background: never takes the focus from what Marko is doing
        if CommandLine.arguments.contains("--background") { w.orderBack(nil) } else { w.makeKeyAndOrderFront(nil) }
        DispatchQueue.main.async { self.enforceOneTitle(w) }
    }

    /// ONE TITLE ONLY (Marko 15.11.2026: "don't repeat this bug"). The app draws its own title (TopRow); the system title
    /// stays hidden in every state: creation, key, resize, full screen, TOP. MANTRA_MANIFEST modules/one-title-only.md.
    func enforceOneTitle(_ w: NSWindow? = nil) {
        guard let w = w ?? window else { return }
        w.title = APP_NAME                      // kept for Mission Control and Accessibility, never drawn
        w.titleVisibility = .hidden
        w.titlebarAppearsTransparent = true
        func walk(_ v: NSView) {
            if v === w.contentView { return }
            if let t = v as? NSTextField, t.stringValue == APP_NAME { t.isHidden = true; t.alphaValue = 0 }
            v.subviews.forEach(walk)
        }
        if let frame = w.contentView?.superview { walk(frame) }
    }
    func windowDidBecomeKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResignKey(_ n: Notification) { enforceOneTitle() }
    func windowDidResize(_ n: Notification) { enforceOneTitle() }
    func windowDidEnterFullScreen(_ n: Notification) { enforceOneTitle() }
    func windowDidExitFullScreen(_ n: Notification) { enforceOneTitle() }
    func windowDidChangeOcclusionState(_ n: Notification) { dash.visible = window?.occlusionState.contains(.visible) ?? false }

    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }   // ✕ closes the window only
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        window?.makeKeyAndOrderFront(nil); return true
    }

    private func menu() {
        let m = NSMenu()
        let appItem = NSMenuItem(), appMenu = NSMenu()
        appMenu.addItem(withTitle: "Check for Updates…", action: #selector(checkUpdates), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(APP_NAME)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu; m.addItem(appItem)
        let editItem = NSMenuItem(), edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit; m.addItem(editItem)
        NSApp.mainMenu = m
    }
    @objc func checkUpdates() { Updater.checkAtStart(delay: 0, manual: true) }
}

@main
enum Main {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = App.shared
        app.run()
    }
}
