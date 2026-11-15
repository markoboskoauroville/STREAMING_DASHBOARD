// Dash.swift: the dashboard's state. One poll = one ssh call running collector.py on the VM (a compact JSON snapshot,
// about 2 KB) plus the Mac's own counters. Rates are made here from the difference of two snapshots.
// Every 5 s while the window is visible, every 30 s when it is hidden (SIM data); the site is asked every third poll.
import AppKit
import Foundation

typealias J = [String: Any]
func obj(_ a: Any?) -> J { a as? J ?? [:] }
func list(_ a: Any?) -> [J] { a as? [J] ?? [] }
func num(_ a: Any?) -> Double? { (a as? NSNumber)?.doubleValue }
func str(_ a: Any?) -> String { a as? String ?? "" }

struct StreamRow: Identifiable {
    let id: String
    let relay: String        // SANTOSHI · TEST · STUDIO
    let path: String
    let feeder: String       // which device feeds it
    let ready: Bool
    let inBps: Double?
    let readers: Int
    let since: Date?
    let size: String
    let errors: Int
}

struct ViewerRow: Identifiable {
    let id: String
    let stream: String
    let proto: String        // WHEP · HLS · SRT · STUDIO HLS
    let remote: String
    let device: String
    let bps: Double?
    let note: String         // RTT / loss / nominal
    let since: Date?
}

struct Event: Identifiable {
    let id = UUID()
    let at: Date
    let text: String
    let level: Int           // 0 info, 1 warning, 2 error
}

enum Hop: Int { case off, ok, warn, bad }

final class Dash: ObservableObject {
    // reachability
    @Published var vmOK: Bool? = nil
    @Published var vmError = ""
    @Published var lastPoll: Date? = nil
    @Published var source = ""                               // "service" (VM :8996) or "ssh" (collector.py)
    // the Mac
    @Published var macOutBps: Double? = nil
    @Published var macInBps: Double? = nil
    @Published var tailscaleUp = false
    @Published var simLeftGB: Double? = nil
    @Published var simAt = ""
    @Published var ndi: [String] = []
    // the VM
    @Published var cpu: Double? = nil
    @Published var ramFree: Double? = nil
    @Published var ramTotalGB: Double = 0
    @Published var load: Double? = nil
    @Published var upS: Double = 0
    @Published var diskFree: Double? = nil
    @Published var vmNetIn: Double? = nil
    @Published var vmNetOut: Double? = nil
    @Published var tsIn: Double? = nil
    @Published var services: [(String, String)] = []
    @Published var showNext = ""
    @Published var mixer: J = [:]
    // streams and viewers
    @Published var streams: [StreamRow] = []
    @Published var viewers: [ViewerRow] = []
    @Published var studioIngest: Double? = nil
    @Published var studioViewers = 0
    // the Meditation Room test stream (mrlinux)
    @Published var mrInstalled: Bool? = nil
    @Published var mrRunning = false
    @Published var mrLive = false
    @Published var mrStatus: J = [:]
    // the site
    @Published var siteReachable: Bool? = nil
    @Published var siteLive = false
    @Published var siteVia = ""
    @Published var siteName = ""
    @Published var siteWatching: Int? = nil
    // history for the sparklines (the last 60 polls)
    @Published var hist: [String: [Double]] = [:]
    // what the buttons are doing
    @Published var busy = ""
    @Published var note = ""
    @Published var chain: [(String, Bool?)] = []
    @Published var events: [Event] = []
    var visible = true

    private var prev: [String: (Double, Double)] = [:]      // key -> (time, counter)
    private var timer: Timer?
    private var inflight = false
    private var tick = 0
    private var lastSite = Date.distantPast
    private var lastNdi = Date.distantPast
    private var known: Set<String> = []                      // stream/viewer ids seen, for the events
    private var started = false
    private let collector: Data = {
        if let u = Bundle.main.url(forResource: "collector", withExtension: "py"), let d = try? Data(contentsOf: u) { return d }
        return Data()
    }()

    func start() {
        log("dashboard started, asking the VM")
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.second() }
    }

    private func second() {
        tick += 1
        let every = visible ? 5 : 30
        if tick % every == 0 { poll() }
    }

    func log(_ s: String, _ level: Int = 0) {
        let e = Event(at: Date(), text: s, level: level)
        events.insert(e, at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
        let line = "\(Dash.stamp.string(from: e.at)) \(s)\n"
        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/StreamingDashboard.log")
        if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close() }
        else { try? Data(line.utf8).write(to: url) }
    }
    static let stamp: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f }()
    static let iso: ISO8601DateFormatter = { let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f }()
    static func date(_ s: String) -> Date? {
        if s.isEmpty { return nil }
        // MediaMTX writes nanoseconds; the formatter takes up to milliseconds
        let trimmed = s.replacingOccurrences(of: #"(\.\d{3})\d+"#, with: "$1", options: .regularExpression)
        return iso.date(from: trimmed) ?? ISO8601DateFormatter().date(from: s)
    }

    /// bytes/s of a counter since the last poll (nil the first time or after a reset)
    private func rate(_ key: String, _ value: Double, _ t: Double) -> Double? {
        defer { prev[key] = (t, value) }
        guard let p = prev[key], t > p.0, value >= p.1 else { return nil }
        return (value - p.1) / (t - p.0)
    }

    private func push(_ key: String, _ v: Double?) {
        guard let v else { return }
        var a = hist[key] ?? []
        a.append(v)
        if a.count > 60 { a.removeFirst(a.count - 60) }
        hist[key] = a
    }

    // ------------------------------------------------------------ the poll
    func poll() {
        guard !inflight else { return }
        inflight = true
        let wantSite = Date().timeIntervalSince(lastSite) > 14
        let wantNdi = Date().timeIntervalSince(lastNdi) > 30
        DispatchQueue.global(qos: .utility).async {
            // the VM's own service first (one source of truth, over Tailscale); ssh + collector.py only when it does not answer
            var snap = Service.snapshot()
            var s: Int32 = 0, err = ""
            let via = snap != nil ? "service" : "ssh"
            if snap == nil {
                let r = VM.run("python3 - " + (wantSite ? "site" : ""), input: self.collector, timeout: 25)
                s = r.0; err = r.2
                snap = s == 0 ? (try? JSONSerialization.jsonObject(with: Data(r.1.utf8))) as? J : nil
            }
            let mac = Mac.tailscaleCounters()
            let sim = Mac.sim()
            let ndi = wantNdi ? Mac.ndiSources() : nil
            let snapshot = snap, status = s, error = err
            DispatchQueue.main.async {
                let snap = snapshot, s = status, err = error
                self.inflight = false
                if wantSite { self.lastSite = Date() }
                if let ndi { self.lastNdi = Date(); self.ndi = ndi }
                self.applyMac(mac, sim)
                if via != self.source && snap != nil { self.log(via == "service" ? "reading the VM's dashboard service (:8996)" : "the dashboard service does not answer: reading by ssh", via == "service" ? 0 : 1) }
                if snap != nil { self.source = via }
                if let snap { self.apply(snap) }
                else {
                    if self.vmOK != false { self.log("the VM does not answer: " + (err.split(separator: "\n").last.map(String.init) ?? "ssh \(s)"), 2) }
                    self.vmOK = false
                    self.vmError = s == -2 ? "no answer in 25 s" : (err.split(separator: "\n").last.map(String.init) ?? "ssh failed")
                }
                self.lastPoll = Date()
            }
        }
    }

    private func applyMac(_ c: (Double, Double, Double)?, _ sim: (Double, String)?) {
        tailscaleUp = c != nil
        if let c {
            macOutBps = rate("mac.out", c.2, c.0)
            macInBps = rate("mac.in", c.1, c.0)
            push("macOut", macOutBps.map { $0 * 8 })
        } else { macOutBps = nil; macInBps = nil }
        if let sim {
            if simLeftGB == nil && sim.0 < 10 { log(String(format: "SIM data left %.1f GB", sim.0), 1) }
            simLeftGB = sim.0; simAt = sim.1
        }
    }

    private func apply(_ j: J) {
        if vmOK != true { log("the VM answers") }
        vmOK = true; vmError = ""
        let t = num(j["t"]) ?? Date().timeIntervalSince1970

        // the machine
        let m = obj(j["machine"])
        if let c = m["cpu"] as? [NSNumber], c.count == 2 {
            let total = c[0].doubleValue, idle = c[1].doubleValue
            if let pt = prev["cpu.total"]?.1, let pi = prev["cpu.idle"]?.1, total > pt {
                cpu = max(0, min(100, 100 * (1 - (idle - pi) / (total - pt))))
            }
            prev["cpu.total"] = (t, total); prev["cpu.idle"] = (t, idle)
            push("cpu", cpu)
        }
        if let mk = m["mem_kb"] as? [NSNumber], mk.count == 2, mk[0].doubleValue > 0 {
            ramTotalGB = mk[0].doubleValue / 1_048_576
            ramFree = 100 * mk[1].doubleValue / mk[0].doubleValue
        }
        load = (m["load"] as? [NSNumber])?.first?.doubleValue
        upS = num(m["up_s"]) ?? 0
        diskFree = num(m["disk_free_gb"])
        let net = obj(m["net"])
        if let pub = (net["enp0s6"] ?? net["eth0"] ?? net["ens3"]) as? [NSNumber], pub.count == 2 {
            vmNetIn = rate("vm.in", pub[0].doubleValue, t); vmNetOut = rate("vm.out", pub[1].doubleValue, t)
            push("vmOut", vmNetOut.map { $0 * 8 })
        }
        if let ts = net["tailscale0"] as? [NSNumber], ts.count == 2 { tsIn = rate("ts.in", ts[0].doubleValue, t) }

        // services
        let sv = obj(j["services"])
        let order = ["santoshi-relay", "studio-ladder", "studio-web", "cloud-mixer", "cloud-mixer-show.timer", "santoshi-rec-upload",
                     "mrlinux-relay", "meditation-room-linux", "mrlinux-live"]
        let newServices = order.compactMap { k in sv[k].map { (k, str($0)) } }
        for (k, v) in newServices {
            if let old = services.first(where: { $0.0 == k })?.1, old != v { log("\(k): \(old) → \(v)", v == "failed" ? 2 : 0) }
        }
        services = newServices
        showNext = str(j["show_next"])
        mixer = obj(j["mixer"])

        // the test stream
        let mr = obj(j["mrlinux"])
        mrInstalled = (mr["installed"] as? Bool) ?? false
        mrStatus = obj(mr["status"])
        let running = sv["meditation-room-linux"].map { str($0) == "active" } ?? false
        let live = sv["mrlinux-live"].map { str($0) == "active" } ?? false
        if running != mrRunning && started { log(running ? "Meditation Room test stream is running" : "Meditation Room test stream stopped") }
        if live != mrLive && started { log(live ? "VM Test is LIVE on the site" : "VM Test live ended") }
        mrRunning = running; mrLive = live

        // the site
        if let site = j["site"] as? J {
            let ok = site["_error"] == nil || site["_error"] is NSNull
            if ok != siteReachable && started { log(ok ? "the site answers" : "the site does not answer", ok ? 0 : 2) }
            siteReachable = ok
            let l = (site["live"] as? Bool) ?? false
            if l != siteLive && started { log(l ? "the site is LIVE" + (str(site["name"]).isEmpty ? "" : " (\(str(site["name"])))") : "the site is not live") }
            siteLive = l
            siteVia = str(site["via"]); siteName = str(site["name"])
            siteWatching = num(site["viewers"]).map { Int($0) }
            push("watching", Double(siteWatching ?? 0))
        }

        // streams and viewers
        var rows: [StreamRow] = [], vs: [ViewerRow] = []
        let mixerOut = !(mixer["output"] == nil || mixer["output"] is NSNull)
        func relayRows(_ r: J, relay: String) {
            let webrtc = list(r["webrtc"]), srt = list(r["srt"]), hls = list(r["hls"])
            for p in list(r["paths"]) {
                let name = str(p["name"]), ready = (p["ready"] as? Bool) ?? false
                let key = "\(relay).\(name)"
                let inB = rate(key + ".in", num(p["bytesReceived"]) ?? 0, t)
                let src = str(p["source"])
                var feeder = "—"
                if ready {
                    switch (relay, name, src) {
                    case ("TEST", _, _): feeder = "VM Test (Meditation Room Linux)"
                    case (_, "pixel", _): feeder = (siteName.isEmpty ? "Phone camera" : siteName) + " → Cloud Mixer"
                    case (_, "santoshi", "srtConn"): feeder = mixerOut ? "Cloud Mixer" : "SRT encoder"
                    case (_, "santoshi", "webRTCSession"): feeder = siteName.isEmpty ? "Phone camera (WHIP)" : siteName + " (WHIP)"
                    default: feeder = src.isEmpty ? "publisher" : src
                    }
                }
                let size = num(p["size"]).map { "\(Int($0))p" } ?? ""
                rows.append(StreamRow(id: key, relay: relay, path: name, feeder: feeder, ready: ready, inBps: ready ? inB : nil,
                                      readers: (p["readers"] as? [Any])?.count ?? 0, since: Dash.date(str(p["readyTime"])),
                                      size: size + (size.isEmpty ? "" : " ") + ((p["tracks"] as? [String]) ?? []).joined(separator: "+"),
                                      errors: Int(num(p["framesInError"]) ?? 0)))
            }
            for w in webrtc where str(w["state"]) == "read" {
                let id = "\(relay).w.\(str(w["id"]))"
                vs.append(ViewerRow(id: id, stream: str(w["path"]), proto: "WHEP", remote: str(w["remote"]), device: str(w["device"]),
                                    bps: rate(id, num(w["bytesSent"]) ?? 0, t),
                                    note: num(w["rtpPacketsLost"]).map { "lost \(Int($0))" } ?? "",
                                    since: Dash.date(str(w["created"]))))
            }
            for s in srt where str(s["state"]) == "read" {
                let id = "\(relay).s.\(str(s["id"]))"
                let local = str(s["remote"]) == "local"
                vs.append(ViewerRow(id: id, stream: str(s["path"]), proto: local ? "SRT (Cloud Mixer)" : "SRT", remote: str(s["remote"]), device: "",
                                    bps: rate(id, num(s["bytesSent"]) ?? 0, t),
                                    note: num(s["msRTT"]).map { String(format: "rtt %.0f ms", $0) } ?? "",
                                    since: Dash.date(str(s["created"]))))
            }
            for h in hls {
                let id = "\(relay).h.\(str(h["id"]))"
                vs.append(ViewerRow(id: id, stream: str(h["path"]), proto: "HLS", remote: str(h["remote"]), device: str(h["device"]),
                                    bps: rate(id, num(h["bytesSent"]) ?? num(h["outboundBytes"]) ?? 0, t), note: "",
                                    since: Dash.date(str(h["created"]))))
            }
        }
        relayRows(obj(j["relay"]), relay: "SANTOSHI")
        relayRows(obj(j["test"]), relay: "TEST")

        // the studio ladder: the Mac's RTMP master and its HLS viewers (by rendition; studio-web counts, no bytes)
        let st = obj(j["studio"])
        let ingest = list(st["ingest"])
        let total = ingest.reduce(0.0) { $0 + (num($1["bytesReceived"]) ?? 0) }
        studioIngest = ingest.isEmpty ? nil : rate("studio.in", total, t)
        if ingest.isEmpty { prev["studio.in"] = nil }
        push("ingest", (studioIngest ?? rows.compactMap { $0.inBps }.reduce(0, +)) * 8)
        let h = obj(st["health"])
        studioViewers = Int(num(h["viewers"]) ?? 0)
        rows.append(StreamRow(id: "STUDIO.master", relay: "STUDIO", path: "studio/master", feeder: ingest.isEmpty ? "—" : "MacBook Pro studio (RTMP)",
                              ready: !ingest.isEmpty, inBps: studioIngest, readers: studioViewers, since: nil, size: (h["live"] as? Bool) == true ? "1080 ladder" : "",
                              errors: 0))
        let nominal: [String: Double] = ["1080": 5_160_000, "720": 2_660_000, "480": 1_260_000, "360": 760_000]
        for (rend, n) in obj(h["by"]) {
            let c = Int(num(n) ?? 0)
            for i in 0..<c {
                vs.append(ViewerRow(id: "STUDIO.\(rend).\(i)", stream: "studio", proto: "STUDIO HLS \(rend)", remote: "", device: "",
                                    bps: nominal[rend].map { $0 / 8 }, note: "nominal", since: nil))
            }
        }

        // events: streams that came and went, viewers joining and leaving
        let readyNow = Set(rows.filter { $0.ready }.map { "s:" + $0.id })
        let viewersNow = Set(vs.map { "v:" + $0.id })
        if started {
            for k in readyNow.subtracting(known) { if let r = rows.first(where: { "s:" + $0.id == k }) { log("stream \(r.relay.lowercased())/\(r.path) is ON (\(r.feeder))") } }
            for k in known.filter({ $0.hasPrefix("s:") }).subtracting(readyNow) { log("stream \(k.dropFirst(2)) is OFF") }
            let joined = viewersNow.subtracting(known).count, left = known.filter { $0.hasPrefix("v:") }.subtracting(viewersNow).count
            if joined > 0 { log("\(joined) viewer\(joined == 1 ? "" : "s") joined, \(vs.count) watching") }
            if left > 0 { log("\(left) viewer\(left == 1 ? "" : "s") left, \(vs.count) watching") }
        }
        known = readyNow.union(viewersNow)
        streams = rows
        viewers = vs.sorted { ($0.bps ?? 0) > ($1.bps ?? 0) }
        push("viewers", Double(audience))
        started = true
    }

    /// people watching our streams (not the mixer reading its own camera)
    var audience: Int { viewers.filter { !$0.proto.contains("Cloud Mixer") && $0.remote != "local" }.count }

    // ------------------------------------------------------------ the hops: PHONE · MAC · VM · SITE
    var hopPhone: (Hop, String) {
        if let p = streams.first(where: { $0.relay == "SANTOSHI" && $0.ready && ($0.feeder.contains("WHIP") || $0.path == "pixel") }) {
            return (.ok, p.inBps.map { "SENDING " + Fmt.bits($0 * 8) } ?? "SENDING")
        }
        return (.off, "IDLE")
    }
    var hopMac: (Hop, String) {
        if !tailscaleUp { return (.bad, "NO TAILSCALE") }
        if studioIngest != nil { return (.ok, "STUDIO SENDING") }
        return (.ok, "TAILSCALE UP")
    }
    var hopVM: (Hop, String) {
        guard let ok = vmOK else { return (.off, "ASKING") }
        if !ok { return (.bad, "NO ANSWER") }
        if services.contains(where: { $0.1 == "failed" }) { return (.warn, "A SERVICE FAILED") }
        if services.first(where: { $0.0 == "santoshi-relay" })?.1 != "active" { return (.warn, "RELAY DOWN") }
        return (.ok, "RELAY OK")
    }
    var hopSite: (Hop, String) {
        guard let ok = siteReachable else { return (.off, "ASKING") }
        if !ok { return (.bad, "NO ANSWER") }
        return siteLive ? (.ok, "LIVE" + (siteName.isEmpty ? "" : " · " + siteName.uppercased())) : (.off, "READY · NOT LIVE")
    }

    // ------------------------------------------------------------ the rules before GO LIVE
    static let zagreb = TimeZone(identifier: "Europe/Zagreb") ?? .current
    var inNoon: Bool {
        var c = Calendar(identifier: .gregorian); c.timeZone = Dash.zagreb
        let d = c.dateComponents([.hour, .minute], from: Date())
        let m = (d.hour ?? 0) * 60 + (d.minute ?? 0)
        return m >= 11 * 60 + 50 && m < 13 * 60 + 50
    }
    /// nil = allowed; else why not
    var goLiveRefusal: String? {
        if mrLive { return nil }
        if mrInstalled != true { return "the Meditation Room test stream is not installed on the VM" }
        if !mrRunning { return "start the stream first (1)" }
        if inNoon { return "11:50–13:50 Zagreb: the noon replay owns the site" }
        if siteLive { return "the site is already live" + (siteName.isEmpty ? "" : " (\(siteName))") }
        if streams.contains(where: { $0.relay == "SANTOSHI" && $0.path == "santoshi" && $0.ready }) { return "another publisher is on the santoshi path" }
        return nil
    }

    // ------------------------------------------------------------ the buttons
    /// through the VM's service (same rules there), by ssh + mrlinux only when the service does not answer
    private func action(_ title: String, _ cmd: String, timeout: Double = 40, then: ((Int32, String) -> Void)? = nil) {
        guard busy.isEmpty else { return }
        busy = title; note = ""
        log(title.lowercased() + "…")
        DispatchQueue.global(qos: .userInitiated).async {
            let parts = cmd.split(separator: " ").map(String.init)      // "mrlinux go-live 15"
            let s: Int32, text: String
            if parts.count >= 2, let r = Service.action(parts[1], minutes: parts.count > 2 ? Int(parts[2]) ?? 5 : 5) {
                s = r.0 ? 0 : 1; text = r.1
            } else {
                let r = VM.run(cmd, timeout: timeout)
                s = r.0; text = (r.1 + r.2).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            DispatchQueue.main.async {
                self.busy = ""
                let last = text.split(separator: "\n").last.map(String.init) ?? ""
                self.note = s == 0 ? last : "refused: " + (last.isEmpty ? "exit \(s)" : last)
                self.log((s == 0 ? "" : "FAILED ") + title.lowercased() + ": " + (last.isEmpty ? "exit \(s)" : last), s == 0 ? 0 : 2)
                then?(s, text)
                self.lastSite = .distantPast
                self.poll()
            }
        }
    }

    func startStream() {
        guard mrInstalled == true else { note = "mrlinux is not installed on the VM"; return }
        action("START STREAM", "mrlinux start")
    }
    func stopStream() {
        confirm("Stop the Meditation Room test stream?", mrLive ? "VM Test is live on the site: stopping ends that too." : "The test stream on the VM stops.", ["Stop"]) { i in
            if i == 0 { self.action("STOP STREAM", "mrlinux stop") }
        }
    }
    func goLive() {
        if let why = goLiveRefusal { note = "not now: " + why; log("go live refused: " + why, 1); return }
        confirm("Go live on santoshi-band.pages.dev as camera \"VM Test\"?",
                "Everyone on the live page sees the Meditation Room test stream. It ends by itself after the minutes you choose (STOP LIVE ends it sooner).",
                ["Go live 5 min", "Go live 15 min", "Go live 30 min"]) { i in
            let m = [5, 15, 30]
            if i >= 0 && i < 3 { self.action("GO LIVE", "mrlinux go-live \(m[i])", timeout: 60) }
        }
    }
    func stopLive() { action("STOP LIVE", "mrlinux stop-live") }

    /// buttons in order; the handler gets the index of the pressed one, or -1 for Cancel
    func confirm(_ title: String, _ text: String, _ buttons: [String], _ done: @escaping (Int) -> Void) {
        let a = NSAlert()
        a.messageText = title; a.informativeText = text
        for b in buttons { a.addButton(withTitle: b) }
        a.addButton(withTitle: "Cancel")
        let handle: (NSApplication.ModalResponse) -> Void = { r in
            let i = r.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            done(i < buttons.count ? i : -1)
        }
        if let w = App.shared.window, w.isVisible { a.beginSheetModal(for: w, completionHandler: handle) } else { handle(a.runModal()) }
    }

    /// TEST THE WHOLE CHAIN with the VM test stream: nothing over the SIM but a few hundred bytes of playlists; never goes live
    func testChain() {
        guard busy.isEmpty else { return }
        busy = "TEST THE WHOLE CHAIN"; chain = []
        log("test of the whole chain started")
        DispatchQueue.global(qos: .userInitiated).async {
            func step(_ name: String, _ ok: Bool?) { DispatchQueue.main.async { self.chain.append((name, ok)); self.log("chain: \(name) \(ok == true ? "OK" : ok == false ? "FAIL" : "—")", ok == false ? 2 : 0) } }
            let (s0, o0, _) = VM.run("command -v mrlinux >/dev/null && echo yes; systemctl is-active meditation-room-linux", timeout: 20)
            step("the VM answers (ssh)", s0 == 0 || !o0.isEmpty)
            let installed = o0.contains("yes")
            step("Meditation Room test stream installed", installed)
            var startedHere = false
            if installed {
                if !o0.contains("\nactive") {
                    let (s1, _, _) = VM.run("mrlinux start", timeout: 40); startedHere = s1 == 0
                    step("test stream started for the test", s1 == 0)
                } else { step("test stream already running", true) }
                // the encoder reaches the private relay: path vmtest ready and bytes growing
                var ready = false
                for _ in 0..<12 {
                    let (_, o, _) = VM.run("curl -s -m4 http://127.0.0.1:9996/v3/paths/get/vmtest", timeout: 10)
                    if let d = (try? JSONSerialization.jsonObject(with: Data(o.utf8))) as? J, (d["ready"] as? Bool) == true { ready = true; break }
                    Thread.sleep(forTimeInterval: 2.5)
                }
                step("encoder → test relay (vmtest ready)", ready)
                // the Mac reaches the test HLS over Tailscale (the playlist only)
                step("VM → Mac over Tailscale (test HLS playlist)", Net.ok("http://\(VM.tailscale):8987/vmtest/index.m3u8", wantBody: "#EXTM3U"))
            }
            step("public relay answers (relay.ples-duse.org)", Net.reachable("https://relay.ples-duse.org:8889/santoshi/whep"))
            step("studio ladder web answers (:2053)", Net.ok("https://relay.ples-duse.org:2053/studio/health", wantBody: "live"))
            step("cloud mixer API answers (Tailscale :8841)", Net.ok("http://\(VM.tailscale):8841/", wantBody: "program"))
            step("site answers (/api/live)", Net.ok("https://santoshi-band.pages.dev/api/live", wantBody: "live"))
            if installed {
                let (_, o, _) = VM.run("mrlinux checks", timeout: 30)
                let free = o.contains("free to go live")
                step(free ? "go live would be allowed now" : "go live would be refused: " + o.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: "; "), free ? true : nil)
                if startedHere { let (s, _, _) = VM.run("mrlinux stop", timeout: 30); step("test stream stopped again", s == 0) }
            }
            DispatchQueue.main.async {
                self.busy = ""
                let bad = self.chain.filter { $0.1 == false }.count
                self.note = bad == 0 ? "the whole chain is OK" : "\(bad) step\(bad == 1 ? "" : "s") failed (DETAILS · TOOLS)"
                self.log("test of the whole chain: " + self.note, bad == 0 ? 0 : 2)
                self.poll()
            }
        }
    }

    func copy(_ s: String, what: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        note = "copied: \(what)"
    }
}

// ---------------------------------------------------------------- the Mac's own numbers
enum Mac {
    /// (time, bytes in, bytes out) of the Tailscale interface (the one with a 100.64/10 address), 64-bit counters from netstat
    static func tailscaleCounters() -> (Double, Double, Double)? {
        let (_, out, _) = Shell.run("/usr/sbin/netstat", ["-ibn"], timeout: 5)
        for l in out.split(separator: "\n") {
            let f = l.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            // Name Mtu Network Address Ipkts Ierrs Ibytes Opkts Oerrs Obytes Coll
            guard f.count >= 10, f[0].hasPrefix("utun"), f[3].hasPrefix("100.") else { continue }
            let parts = f[3].split(separator: ".").compactMap { Int($0) }
            guard parts.count == 4, parts[1] >= 64, parts[1] <= 127 else { continue }
            if let i = Double(f[6]), let o = Double(f[9]) { return (Date().timeIntervalSince1970, i, o) }
        }
        return nil
    }

    /// the data left on the SIM (the hub's SIM DATA LEFT check writes it; read here, no SMS is sent)
    static func sim() -> (Double, String)? {
        let p = Shell.home + "/Library/Application Support/connection-keeper/sim-balances.json"
        guard let d = FileManager.default.contents(atPath: p), let j = (try? JSONSerialization.jsonObject(with: d)) as? J else { return nil }
        let lines = list(j["lines"]).compactMap { l -> (Double, String)? in num(l["left_gb"]).map { ($0, str(l["at"])) } }
        return lines.min { $0.0 < $1.0 }
    }

    static func ndiSources() -> [String] {
        let nd = Shell.home + "/.local/bin/ndimon"
        guard FileManager.default.isExecutableFile(atPath: nd) else { return ["ndimon is not installed (~/.local/bin/ndimon)"] }
        let (_, out, _) = Shell.run(nd, ["list"], timeout: 12)
        return out.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }
}

enum Net {
    /// a small GET; true when the status is 2xx/3xx and the body has the word
    static func ok(_ url: String, wantBody: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        req.setValue("streaming-dashboard/\(VERSION)", forHTTPHeaderField: "User-Agent")
        var good = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            let code = (r as? HTTPURLResponse)?.statusCode ?? 0
            good = code >= 200 && code < 400 && String(decoding: (d ?? Data()).prefix(4000), as: UTF8.self).contains(wantBody)
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return good
    }
    /// any HTTP answer at all (a WHEP door says 4xx to a plain GET, which still proves it is there)
    static func reachable(_ url: String) -> Bool {
        guard let u = URL(string: url) else { return false }
        var got = false
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)) { _, r, _ in got = r is HTTPURLResponse; sem.signal() }.resume()
        _ = sem.wait(timeout: .now() + 12)
        return got
    }
}

enum Fmt {
    static func bits(_ b: Double?) -> String {
        guard let b else { return "—" }
        if b >= 1_000_000 { return String(format: "%.2f Mbit/s", b / 1_000_000) }
        if b >= 1_000 { return String(format: "%.0f kbit/s", b / 1_000) }
        return String(format: "%.0f bit/s", b)
    }
    static func pct(_ v: Double?) -> String { v.map { String(format: "%.0f %%", $0) } ?? "—" }
    static func dur(_ s: Double) -> String {
        let t = Int(max(0, s))
        if t >= 86400 { return "\(t / 86400) d \(t % 86400 / 3600) h" }
        if t >= 3600 { return "\(t / 3600) h \(t % 3600 / 60) min" }
        if t >= 60 { return "\(t / 60) min \(t % 60) s" }
        return "\(t) s"
    }
    static func since(_ d: Date?) -> String { d.map { dur(Date().timeIntervalSince($0)) } ?? "—" }
    static let hm: DateFormatter = { let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f }()
}

// ---------------------------------------------------------------- the VM's dashboard service (vm/, Tailscale :8996)
enum Service {
    static var base: String { "http://\(VM.tailscale):8996" }
    private static var token: String?                       // read once over ssh, kept only in memory, never shown

    static func snapshot() -> J? {
        guard let r = http("GET", "/api/snapshot", nil, timeout: 6), r.0 == 200,
              let j = (try? JSONSerialization.jsonObject(with: r.1)) as? J, j["machine"] != nil,
              let served = num(j["served_at"]), let t = num(j["t"]), served - t < 30 else { return nil }   // stale = not trusted
        return j
    }

    /// (ok, note) or nil when the service does not answer (then the caller uses ssh)
    static func action(_ action: String, minutes: Int) -> (Bool, String)? {
        if token == nil {
            let (s, out, _) = VM.run("cat ~/.config/streaming-dashboard/token 2>/dev/null", timeout: 15)
            let t = out.trimmingCharacters(in: .whitespacesAndNewlines)
            if s == 0 && !t.isEmpty { token = t }
        }
        let body = try? JSONSerialization.data(withJSONObject: ["action": action, "minutes": minutes])
        guard let r = http("POST", "/api/action", body, timeout: 95) else { return nil }
        let code = r.0, data = r.1
        if code == 403 { token = nil; return (false, "the service refused the token") }
        let j = (try? JSONSerialization.jsonObject(with: data)) as? J ?? [:]
        let note = str(j["note"]).isEmpty ? str(j["error"]) : str(j["note"])
        return ((j["ok"] as? Bool) == true, note.isEmpty ? "HTTP \(code)" : note)
    }

    private static func http(_ method: String, _ path: String, _ body: Data?, timeout: Double) -> (Int, Data)? {
        guard let u = URL(string: base + path) else { return nil }
        var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        req.httpMethod = method
        if let body { req.httpBody = body; req.setValue("application/json", forHTTPHeaderField: "content-type") }
        if let token { req.setValue(token, forHTTPHeaderField: "x-dash-token") }
        var result: (Int, Data)?
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: req) { d, r, _ in
            if let h = r as? HTTPURLResponse { result = (h.statusCode, d ?? Data()) }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + timeout + 2)
        return result
    }
}
