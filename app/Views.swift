// Views.swift: the window. First screen: the chain lights, 1 START, 2 GO LIVE, five numbers. DETAILS opens the folders.
import AppKit
import SwiftUI

let mono = Font.system(size: 13, weight: .bold, design: .monospaced)
let labelFont = Font.system(size: 10, weight: .semibold, design: .monospaced)

func hopColor(_ h: Hop) -> Color { [Ink.grey, Ink.green, Ink.amber, Ink.red][h.rawValue] }

/// a single-series sparkline: a 2 px line on a hairline baseline, the title of its cell names it; hover gives min/max/now
struct Spark: View {
    let values: [Double]
    var format: (Double) -> String = { String(format: "%.0f", $0) }
    var body: some View {
        let lo = 0.0, hi = max(values.max() ?? 1, 1e-9)
        Canvas { ctx, size in
            var base = Path(); base.move(to: CGPoint(x: 0, y: size.height - 0.5)); base.addLine(to: CGPoint(x: size.width, y: size.height - 0.5))
            ctx.stroke(base, with: .color(Ink.line), lineWidth: 1)
            guard values.count > 1 else { return }
            var p = Path()
            for (i, v) in values.enumerated() {
                let x = size.width * CGFloat(i) / CGFloat(values.count - 1)
                let y = (size.height - 2) * (1 - CGFloat((v - lo) / (hi - lo))) + 1
                if i == 0 { p.move(to: CGPoint(x: x, y: y)) } else { p.addLine(to: CGPoint(x: x, y: y)) }
            }
            ctx.stroke(p, with: .color(Ink.gold), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
        }
        .frame(width: 130, height: 22)
        .help(values.isEmpty ? "no data yet" : "now \(format(values.last!)) · low \(format(values.min()!)) · high \(format(values.max()!)) · last \(values.count) polls")
        .accessibilityLabel(values.isEmpty ? "no data yet" : "now \(format(values.last!)), high \(format(values.max()!))")
    }
}

struct Cell<V: View>: View {
    let label: String
    @ViewBuilder var value: V
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(labelFont).foregroundStyle(Ink.dim).fixedSize()
            value.font(mono).fixedSize()
        }
    }
}

/// the round number is the button (workflow-interface.md): it lights and grows on hover, the word is underlined
struct StepButton: View {
    let n: Int
    let word: String
    let color: Color
    let enabled: Bool
    let action: () -> Void
    @State private var hot = false
    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().stroke(enabled ? color : Ink.grey, lineWidth: hot && enabled ? 2 : 1)
                    .background(Circle().fill((enabled ? color : Ink.grey).opacity(hot && enabled ? 0.18 : 0)))
                Text("\(n)").font(.system(size: 15, weight: .bold, design: .monospaced)).foregroundStyle(enabled ? color : Ink.grey)
            }
            .frame(width: hot && enabled ? 34 : 30, height: hot && enabled ? 34 : 30)
            .frame(width: 34, height: 34)
            Text(word).font(.system(size: 17, weight: .bold, design: .monospaced)).foregroundStyle(enabled ? color : Ink.grey)
                .underline(hot && enabled).fixedSize()
        }
        .animation(.easeOut(duration: 0.12), value: hot)
        .contentShape(Rectangle())
        .onHover { inside in hot = inside; if enabled { if inside { NSCursor.pointingHand.push() } else { NSCursor.pop() } } }
        .onTapGesture { if enabled { action() } }
        .axButton(word.capitalized, id: "step-\(n)", value: enabled ? "enabled" : "disabled") { if enabled { action() } }
    }
}

struct HopLight: View {
    let name: String
    let state: (Hop, String)
    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(hopColor(state.0)).frame(width: 10, height: 10)
                Text(name).font(.system(size: 13, weight: .bold, design: .monospaced)).foregroundStyle(Ink.text)
            }
            Text(state.1).font(labelFont).foregroundStyle(state.0 == .off ? Ink.dim : hopColor(state.0)).fixedSize()
        }
        .fixedSize()
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name): \(state.1)")
    }
}

struct Root: View {
    @ObservedObject var dash: Dash
    @AppStorage("detailsOpen") private var detailsOpen = false
    @AppStorage("folder") private var folder = ""

    var body: some View {
        VStack(spacing: 0) {
            TopRow()
            Hairline()
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    chainRow.padding(.vertical, 14).frame(maxWidth: .infinity)
                    Hairline()
                    steps.padding(.horizontal, 22).padding(.vertical, 16)
                    Hairline()
                    numbers.padding(.horizontal, 22).padding(.vertical, 14)
                    Hairline()
                    details
                }
            }
        }
        .background(Ink.ground)
        .foregroundStyle(Ink.text)
        .ignoresSafeArea(.container, edges: .top)
    }

    // ------------------------------------------------------------ PHONE · MAC · VM · SITE
    var chainRow: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 10)
            HopLight(name: "PHONE", state: dash.hopPhone)
            link
            HopLight(name: "MAC", state: dash.hopMac)
            link
            HopLight(name: "VM", state: dash.hopVM)
            link
            HopLight(name: "SITE", state: dash.hopSite)
            Spacer(minLength: 10)
        }
    }
    var link: some View { Rectangle().fill(Ink.line).frame(height: 1).frame(minWidth: 24, maxWidth: 90).padding(.horizontal, 10).padding(.bottom, 16) }

    // ------------------------------------------------------------ 1 START  2 GO LIVE
    var steps: some View {
        VStack(alignment: .leading, spacing: 14) {
            let busy = !dash.busy.isEmpty
            VStack(alignment: .leading, spacing: 4) {
                StepButton(n: 1, word: dash.busy == "START STREAM" ? "STARTING…" : dash.busy == "STOP STREAM" ? "STOPPING…" :
                            (dash.mrRunning ? "STOP MEDITATION ROOM STREAM" : "START MEDITATION ROOM STREAM"),
                           color: dash.mrRunning ? Ink.amber : Ink.green, enabled: !busy && dash.mrInstalled == true) {
                    if dash.mrRunning { dash.stopStream() } else { dash.startStream() }
                }
                Text(streamLine).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim).padding(.leading, 46)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 4) {
                let refusal = dash.goLiveRefusal
                StepButton(n: 2, word: dash.busy == "GO LIVE" ? "GOING LIVE…" : dash.busy == "STOP LIVE" ? "STOPPING LIVE…" :
                            (dash.mrLive ? "STOP LIVE ON THE SITE" : "GO LIVE ON THE SITE"),
                           color: dash.mrLive ? Ink.red : Ink.green, enabled: !busy && (dash.mrLive || refusal == nil)) {
                    if dash.mrLive { dash.stopLive() } else { dash.goLive() }
                }
                Text(dash.mrLive ? "VM Test is live on santoshi-band.pages.dev/live · \(dash.siteWatching.map { "\($0) watching" } ?? "watching —")"
                     : (refusal.map { "not now: " + $0 } ?? "as camera \"VM Test\", 5 · 15 · 30 min, asks first"))
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(refusal == nil || dash.mrLive ? Ink.dim : Ink.amber)
                    .padding(.leading, 46).fixedSize(horizontal: false, vertical: true)
            }
            if !dash.note.isEmpty || busy {
                Text(busy ? dash.busy.lowercased() + "…" : dash.note).font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(dash.note.hasPrefix("refused") || dash.note.hasPrefix("not now") ? Ink.amber : Ink.dim)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
    var streamLine: String {
        if dash.mrInstalled == false { return "not installed on the VM (MANTRA_ROOM/linux, mrlinux)" }
        if dash.mrInstalled == nil { return "asking the VM…" }
        if !dash.mrRunning { return "the Meditation Room (Linux) test stream on the VM, private (Tailscale only)" }
        let s = dash.mrStatus
        let parts = [str(s["track"]), str(s["speed"]).isEmpty ? "" : "speed " + str(s["speed"]), str(s["fps"]).isEmpty ? "" : str(s["fps"]) + " fps",
                     str(s["bitrate"]), str(s["drop_frames"]).isEmpty ? "" : "dropped " + str(s["drop_frames"])]
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    // ------------------------------------------------------------ five numbers
    var numbers: some View {
        Flow(spacing: 30, rowSpacing: 14) {
            Cell(label: "MAC → VM (TAILSCALE OUT)") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.bits(dash.macOutBps.map { $0 * 8 }))
                    Spark(values: dash.hist["macOut"] ?? [], format: { Fmt.bits($0) })
                }
            }
            Cell(label: "INGEST ON THE VM") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.bits((dash.hist["ingest"] ?? []).last))
                    Spark(values: dash.hist["ingest"] ?? [], format: { Fmt.bits($0) })
                }
            }
            Cell(label: "VIEWERS ON OUR STREAMS") {
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(dash.audience)" + (dash.siteWatching.map { " · SITE \($0) WATCHING" } ?? ""))
                    Spark(values: dash.hist["viewers"] ?? [], format: { String(format: "%.0f", $0) })
                }
            }
            Cell(label: "VM CPU") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Fmt.pct(dash.cpu)).foregroundStyle(load(dash.cpu))
                    Spark(values: dash.hist["cpu"] ?? [], format: { Fmt.pct($0) })
                }
            }
            Cell(label: "SIM DATA LEFT") {
                VStack(alignment: .leading, spacing: 4) {
                    Text(dash.simLeftGB.map { String(format: "%.1f GB", $0) } ?? "—").foregroundStyle(simColor)
                    Text(simLine)
                        .font(.system(size: 10, design: .monospaced)).foregroundStyle(Ink.dim)
                }
            }
        }
    }
    func load(_ v: Double?) -> Color { guard let v else { return Ink.text }; return v > 90 ? Ink.red : v > 70 ? Ink.amber : Ink.green }
    var simLine: String {
        guard let g = dash.simLeftGB else { return "no SIM check yet" }
        return (g < 10 ? "WARNING: low · " : "") + "checked " + dash.simAt
    }
    var mixerOn: Bool { if let o = dash.mixer["output"], !(o is NSNull) { return true }; return false }
    func serviceColor(_ s: String) -> Color { s == "active" ? Ink.green : (s == "failed" ? Ink.red : Ink.grey) }
    var simColor: Color { guard let g = dash.simLeftGB else { return Ink.text }; return g < 3 ? Ink.red : g < 10 ? Ink.amber : Ink.text }

    // ------------------------------------------------------------ DETAILS: the folders
    struct Folder { let id, name, line: String }
    var folders: [Folder] {[
        Folder(id: "streams", name: "STREAMS", line: "\(dash.streams.filter { $0.ready }.count) on · every path, who feeds it, speed in, readers"),
        Folder(id: "viewers", name: "VIEWERS", line: "\(dash.viewers.count) connected · protocol, where, speed for each"),
        Folder(id: "machine", name: "THE MACHINE", line: "chromium-vm · CPU, RAM, network, uptime, services, cloud mixer"),
        Folder(id: "devices", name: "DEVICES", line: "which device feeds which path · NDI sources on this Mac (\(dash.ndi.count))"),
        Folder(id: "tools", name: "TOOLS", line: "test the whole chain · copy the viewer link"),
        Folder(id: "events", name: "EVENTS", line: "\(dash.events.count) lines · what happened, newest first"),
    ]}

    var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text((detailsOpen ? "▾ " : "▸ ") + "DETAILS").font(.system(size: 14, weight: .bold, design: .monospaced))
                    .word("Details", id: "details", value: detailsOpen ? "open" : "closed") { detailsOpen.toggle() }
                if !detailsOpen {
                    Text("streams · viewers · the machine · devices · tools · events").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                }
                Spacer()
                Text(dash.lastPoll.map { "updated " + Fmt.hm.string(from: $0) + (dash.source.isEmpty ? "" : " · via " + dash.source) } ?? "").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            if detailsOpen {
                ForEach(folders, id: \.id) { f in
                    Hairline()
                    HStack(spacing: 12) {
                        Text((folder == f.id ? "▾ " : "▸ ") + f.name).font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundStyle(folder == f.id ? Ink.gold : Ink.text).fixedSize()
                        Text(f.line).font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 22).padding(.vertical, 8)
                    .word(f.name.capitalized, id: "folder-" + f.id, value: folder == f.id ? "open" : "closed") { folder = folder == f.id ? "" : f.id }
                    if folder == f.id { content(f.id).padding(.horizontal, 30).padding(.bottom, 14).padding(.top, 4) }
                }
            }
        }
    }

    @ViewBuilder func content(_ id: String) -> some View {
        switch id {
        case "streams": streamsTable
        case "viewers": viewersTable
        case "machine": machine
        case "devices": devices
        case "tools": tools
        default: eventsList
        }
    }

    func head(_ s: String) -> some View { Text(s).font(labelFont).foregroundStyle(Ink.dim).fixedSize() }
    func val(_ s: String, _ c: Color = Ink.text) -> some View { Text(s).font(.system(size: 12, weight: .semibold, design: .monospaced)).foregroundStyle(c).fixedSize() }

    var streamsTable: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
            GridRow { head("RELAY"); head("PATH"); head("FED BY"); head("STATE"); head("IN"); head("READERS"); head("ON FOR"); head("PICTURE"); head("ERRORS") }
            ForEach(dash.streams) { s in
                GridRow {
                    val(s.relay, Ink.dim); val(s.path); val(s.feeder)
                    val(s.ready ? "ON" : "OFF", s.ready ? Ink.green : Ink.grey)
                    val(Fmt.bits(s.inBps.map { $0 * 8 })); val("\(s.readers)"); val(Fmt.since(s.since)); val(s.size.isEmpty ? "—" : s.size)
                    val("\(s.errors)", s.errors > 0 ? Ink.amber : Ink.text)
                }
            }
        }
    }

    var viewersTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            if dash.viewers.isEmpty {
                Text("nobody is connected now").font(.system(size: 12, design: .monospaced)).foregroundStyle(Ink.dim)
            } else {
                Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                    GridRow { head("STREAM"); head("PROTOCOL"); head("WHERE"); head("DEVICE"); head("SPEED"); head("LINK"); head("FOR") }
                    ForEach(dash.viewers) { v in
                        GridRow {
                            val(v.stream); val(v.proto); val(v.remote.isEmpty ? "—" : v.remote, Ink.dim); val(v.device.isEmpty ? "—" : v.device)
                            val(Fmt.bits(v.bps.map { $0 * 8 })); val(v.note.isEmpty ? "—" : v.note, Ink.dim); val(Fmt.since(v.since))
                        }
                    }
                }
            }
            Text("SITE WATCHING (the live room): \(dash.siteWatching.map(String.init) ?? "— (counted only while the site is live)")")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
            Text("addresses are cut to their first two numbers on the VM · studio viewers are counted by rendition, speed nominal")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
        }
    }

    var machine: some View {
        VStack(alignment: .leading, spacing: 12) {
            Flow(spacing: 26, rowSpacing: 12) {
                Cell(label: "CPU") { Text(Fmt.pct(dash.cpu)).foregroundStyle(load(dash.cpu)) }
                Cell(label: "RAM FREE") { Text(Fmt.pct(dash.ramFree) + String(format: " of %.0f GB", dash.ramTotalGB)).foregroundStyle(load(dash.ramFree.map { 100 - $0 })) }
                Cell(label: "LOAD") { Text(dash.load.map { String(format: "%.2f", $0) } ?? "—") }
                Cell(label: "UP FOR") { Text(Fmt.dur(dash.upS)) }
                Cell(label: "DISK FREE") { Text(dash.diskFree.map { String(format: "%.0f GB", $0) } ?? "—") }
                Cell(label: "NET IN") { Text(Fmt.bits(dash.vmNetIn.map { $0 * 8 })) }
                Cell(label: "NET OUT") {
                    VStack(alignment: .leading, spacing: 4) { Text(Fmt.bits(dash.vmNetOut.map { $0 * 8 })); Spark(values: dash.hist["vmOut"] ?? [], format: { Fmt.bits($0) }) }
                }
                Cell(label: "TAILSCALE IN") { Text(Fmt.bits(dash.tsIn.map { $0 * 8 })) }
            }
            Hairline()
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
                GridRow { head("SERVICE"); head("STATE") }
                ForEach(Array(dash.services.enumerated()), id: \.offset) { s in
                    GridRow { val(s.element.0); val(s.element.1.uppercased(), serviceColor(s.element.1)) }
                }
            }
            Hairline()
            Flow(spacing: 26, rowSpacing: 12) {
                Cell(label: "CLOUD MIXER PROGRAM") { Text(str(dash.mixer["program"]).isEmpty ? "—" : str(dash.mixer["program"])) }
                Cell(label: "MIXER OUTPUT") { Text(mixerOn ? "ON" : "OFF").foregroundStyle(mixerOn ? Ink.green : Ink.grey) }
                Cell(label: "LATE FRAMES") { Text(num(dash.mixer["late_frames"]).map { String(Int($0)) } ?? "—") }
                Cell(label: "NEXT SHOW (TIMER)") { Text(dash.showNext.isEmpty ? "—" : dash.showNext) }
            }
            ForEach(Array((dash.mixer["events"] as? [String] ?? []).reversed().enumerated()), id: \.offset) { e in
                Text(e.element).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    var devices: some View {
        VStack(alignment: .leading, spacing: 10) {
            Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 6) {
                GridRow { head("DEVICE"); head("FEEDS"); head("STATE") }
                GridRow { val("Pixel / Sony (phone camera app)"); val("relay santoshi, or pixel → Cloud Mixer (WHIP)"); stateOf { $0.relay == "SANTOSHI" && $0.feeder.contains("WHIP") || $0.path == "pixel" } }
                GridRow { val("MacBook Pro studio"); val("studio/master (RTMP over Tailscale) → ladder"); stateOf { $0.relay == "STUDIO" } }
                GridRow { val("Cloud Mixer (VM)"); val("reads pixel, publishes santoshi (SRT)"); stateOf { $0.relay == "SANTOSHI" && $0.feeder == "Cloud Mixer" } }
                GridRow { val("VM Test (Meditation Room Linux)"); val("vmtest (private); santoshi while live"); stateOf { $0.relay == "TEST" } }
            }
            Hairline()
            head("NDI SOURCES ON THIS MAC")
            if dash.ndi.isEmpty { val("none seen (or not asked yet)", Ink.dim) }
            ForEach(dash.ndi, id: \.self) { n in val(n) }
        }
    }
    func stateOf(_ match: @escaping (StreamRow) -> Bool) -> some View {
        let on = dash.streams.contains { $0.ready && match($0) }
        return val(on ? "SENDING" : "—", on ? Ink.green : Ink.grey)
    }

    var tools: some View {
        VStack(alignment: .leading, spacing: 10) {
            Flow(spacing: 22, rowSpacing: 10) {
                Text(dash.busy == "TEST THE WHOLE CHAIN" ? "TESTING…" : "TEST THE WHOLE CHAIN").font(mono).foregroundStyle(dash.busy.isEmpty ? Ink.green : Ink.grey)
                    .word("Test the whole chain", id: "test-chain") { dash.testChain() }
                Text("COPY VIEWER LINK").font(mono)
                    .word("Copy viewer link", id: "copy-viewer") { dash.copy("https://santoshi-band.pages.dev/live/", what: "the viewer link") }
                Text("COPY TEST LINK").font(mono)
                    .word("Copy test link", id: "copy-test") { dash.copy("http://\(VM.tailscale):8987/vmtest/index.m3u8", what: "the private test stream (Tailscale)") }
                Text("COPY STUDIO LINK").font(mono)
                    .word("Copy studio link", id: "copy-studio") { dash.copy("https://relay.ples-duse.org:2053/studio/master.m3u8", what: "the studio ladder") }
            }
            Text("the test uses the VM test stream: it never goes live and sends only playlists over the SIM")
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).fixedSize(horizontal: false, vertical: true)
            ForEach(Array(dash.chain.enumerated()), id: \.offset) { c in
                HStack(spacing: 8) {
                    Text(c.element.1 == true ? "OK" : c.element.1 == false ? "FAIL" : "NOTE").font(mono)
                        .foregroundStyle(c.element.1 == true ? Ink.green : c.element.1 == false ? Ink.red : Ink.amber).frame(width: 44, alignment: .leading)
                    Text(c.element.0).font(.system(size: 12, design: .monospaced)).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    var eventsList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(dash.events.prefix(80)) { e in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Text(Fmt.hm.string(from: e.at)).font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim).fixedSize()
                    Text(e.text).font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(e.level == 2 ? Ink.red : e.level == 1 ? Ink.amber : Ink.text)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("the whole log: ~/Library/Logs/StreamingDashboard.log").font(.system(size: 11, design: .monospaced)).foregroundStyle(Ink.dim)
        }
    }
}
