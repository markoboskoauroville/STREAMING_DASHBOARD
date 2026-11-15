#!/usr/bin/env python3
"""streaming_dashboard_vm.py: Streaming Dashboard (Mantra) on chromium-vm, the one source of truth for the streams.

Marko, 15.11.2026: "Streaming dashboard Mantra should also be available on the virtual machine Linux as well as on this
machine." So the numbers are gathered HERE, on the VM, every 5 s (collector.py, the same file the Mac app carries), and
served on the tailnet only:

  GET  /                 the web page "Streaming Dashboard" (the VM's desktop Chrome, any browser on the tailnet)
  GET  /api/snapshot     the latest raw snapshot (what collector.py prints) + "served_at": the Mac app reads this
  GET  /api/state        the page's view: hops, numbers, streams, viewers with speeds, machine, events, history
  POST /api/action       {"action": "start"|"stop"|"go-live"|"stop-live", "minutes": 5|15|30}
                         allowed from the VM itself (its own desktop browser) or with the header X-Dash-Token
                         (/home/ubuntu/.config/streaming-dashboard/token, read by the Mac app over ssh, never printed)

Binds 100.102.86.30:8996 (Tailscale) and 127.0.0.1:8996, nothing public. Read-only except the four actions, which run
mrlinux (MANTRA_ROOM/linux) with the same rules as the Mac app: go-live refused 11:50-13:50 Zagreb, while the site is
live, or while another publisher is on the santoshi path; mrlinux checks them again itself.
"""
import datetime as dt
import hmac, json, os, re, subprocess, sys, threading, time
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler
from zoneinfo import ZoneInfo

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import collector  # noqa: E402

PORT = int(os.environ.get("SDASH_PORT", "8996"))
BINDS = os.environ.get("SDASH_BIND", "100.102.86.30,127.0.0.1").split(",")
TOKEN_FILE = os.path.expanduser(os.environ.get("SDASH_TOKEN", "~/.config/streaming-dashboard/token"))
WEB = os.path.join(HERE, "web", "index.html")
LOCAL = {"127.0.0.1", "::1", "100.102.86.30"}
ZAGREB = ZoneInfo("Europe/Zagreb")
VERSION = 1

lock = threading.Lock()
snap = {}                 # the latest raw snapshot
state = {}                # the page's view
prev = {}                 # key -> (t, counter)
hist = {k: [] for k in ("ingest", "viewers", "cpu", "vmOut", "watching")}
events = []               # [(epoch, text, level)]
known = set()
site_cache = {"t": 0, "data": None}
busy = {"what": "", "note": ""}


def log(text, level=0):
    with lock:
        events.insert(0, (time.time(), text, level))
        del events[300:]
    print(time.strftime("%H:%M:%S"), text, flush=True)


def rate(key, value, t):
    p = prev.get(key)
    prev[key] = (t, value)
    if not p or t <= p[0] or value < p[1]:
        return None
    return (value - p[1]) / (t - p[0])


def push(key, v):
    if v is None:
        return
    a = hist[key]
    a.append(round(v, 2))
    del a[:-120]


def in_noon():
    n = dt.datetime.now(ZAGREB)
    m = n.hour * 60 + n.minute
    return 11 * 60 + 50 <= m < 13 * 60 + 50


def date(s):
    if not s:
        return None
    try:
        return dt.datetime.fromisoformat(re.sub(r"(\.\d{6})\d+", r"\1", s).replace("Z", "+00:00")).timestamp()
    except Exception:
        return None


def build(s):
    """the raw snapshot -> the page's view (the same rules as the Mac app's Dash.swift)"""
    t = s.get("t", time.time())
    m = s.get("machine") or {}
    view = {"t": t, "version": VERSION}
    cpu = None
    c = m.get("cpu")
    if c:
        p1, p2 = prev.get("cpu.total"), prev.get("cpu.idle")
        if p1 and p2 and c[0] > p1[1]:
            cpu = max(0.0, min(100.0, 100 * (1 - (c[1] - p2[1]) / (c[0] - p1[1]))))
        prev["cpu.total"], prev["cpu.idle"] = (t, c[0]), (t, c[1])
    mk = m.get("mem_kb") or [0, 0]
    net = m.get("net") or {}
    pub = net.get("enp0s6") or net.get("eth0") or net.get("ens3") or [0, 0]
    ts = net.get("tailscale0") or [0, 0]
    vm_in, vm_out, ts_in = rate("vm.in", pub[0], t), rate("vm.out", pub[1], t), rate("ts.in", ts[0], t)
    view["machine"] = {"cpu": cpu, "ram_free": 100 * mk[1] / mk[0] if mk[0] else None, "ram_gb": mk[0] / 1048576,
                       "load": (m.get("load") or [None])[0], "up_s": m.get("up_s"), "disk_free_gb": m.get("disk_free_gb"),
                       "net_in": vm_in, "net_out": vm_out, "ts_in": ts_in}
    sv = s.get("services") or {}
    view["services"] = sv
    view["show_next"] = s.get("show_next")
    mixer = s.get("mixer") or {}
    view["mixer"] = mixer
    mr = s.get("mrlinux") or {}
    site = s.get("site") or {}
    view["mr"] = {"installed": mr.get("installed"), "status": mr.get("status") or {},
                  "running": sv.get("meditation-room-linux") == "active", "live": sv.get("mrlinux-live") == "active"}
    view["site"] = site
    site_name = site.get("name") or ""

    streams, viewers = [], []
    mixer_out = bool(mixer.get("output"))
    for relay, r in (("SANTOSHI", s.get("relay") or {}), ("TEST", s.get("test") or {})):
        for p in r.get("paths") or []:
            name, ready, src = p.get("name"), bool(p.get("ready")), p.get("source") or ""
            key = f"{relay}.{name}"
            inb = rate(key + ".in", p.get("bytesReceived") or 0, t)
            feeder = "—"
            if ready:
                if relay == "TEST":
                    feeder = "VM Test (Meditation Room Linux)"
                elif name == "pixel":
                    feeder = (site_name or "Phone camera") + " → Cloud Mixer"
                elif name == "santoshi" and src == "srtConn":
                    feeder = "Cloud Mixer" if mixer_out else "SRT encoder"
                elif name == "santoshi" and src == "webRTCSession":
                    feeder = (site_name or "Phone camera") + " (WHIP)"
                else:
                    feeder = src or "publisher"
            streams.append({"id": key, "relay": relay, "path": name, "feeder": feeder, "ready": ready,
                            "in_bps": inb * 8 if (ready and inb is not None) else None, "readers": len(p.get("readers") or []),
                            "since": date(p.get("readyTime")),
                            "picture": " ".join(x for x in [f"{p['size']}p" if p.get("size") else "", "+".join(p.get("tracks") or [])] if x),
                            "errors": p.get("framesInError") or 0})
        for w in r.get("webrtc") or []:
            if w.get("state") != "read":
                continue
            k = f"{relay}.w.{w.get('id')}"
            b = rate(k, w.get("bytesSent") or 0, t)
            viewers.append({"id": k, "stream": w.get("path"), "proto": "WHEP", "remote": w.get("remote"), "device": w.get("device", ""),
                            "bps": b * 8 if b is not None else None, "note": f"lost {w['rtpPacketsLost']}" if "rtpPacketsLost" in w else "",
                            "since": date(w.get("created"))})
        for x in r.get("srt") or []:
            if x.get("state") != "read":
                continue
            k = f"{relay}.s.{x.get('id')}"
            b = rate(k, x.get("bytesSent") or 0, t)
            local = x.get("remote") == "local"
            viewers.append({"id": k, "stream": x.get("path"), "proto": "SRT (Cloud Mixer)" if local else "SRT", "remote": x.get("remote"),
                            "device": "", "bps": b * 8 if b is not None else None,
                            "note": f"rtt {x['msRTT']:.0f} ms" if isinstance(x.get("msRTT"), (int, float)) else "", "since": date(x.get("created"))})
        for h in r.get("hls") or []:
            k = f"{relay}.h.{h.get('id')}"
            b = rate(k, h.get("bytesSent") or h.get("outboundBytes") or 0, t)
            viewers.append({"id": k, "stream": h.get("path"), "proto": "HLS", "remote": h.get("remote"), "device": h.get("device", ""),
                            "bps": b * 8 if b is not None else None, "note": "", "since": date(h.get("created"))})
    st = s.get("studio") or {}
    ingest = st.get("ingest") or []
    tot = sum(i.get("bytesReceived") or 0 for i in ingest)
    sin = rate("studio.in", tot, t) if ingest else None
    if not ingest:
        prev.pop("studio.in", None)
    health = st.get("health") or {}
    streams.append({"id": "STUDIO.master", "relay": "STUDIO", "path": "studio/master", "feeder": "MacBook Pro studio (RTMP)" if ingest else "—",
                    "ready": bool(ingest), "in_bps": sin * 8 if sin is not None else None, "readers": health.get("viewers") or 0,
                    "since": None, "picture": "1080 ladder" if health.get("live") else "", "errors": 0})
    nominal = {"1080": 5160000, "720": 2660000, "480": 1260000, "360": 760000}
    for rend, n in (health.get("by") or {}).items():
        for i in range(int(n)):
            viewers.append({"id": f"STUDIO.{rend}.{i}", "stream": "studio", "proto": f"STUDIO HLS {rend}", "remote": "", "device": "",
                            "bps": nominal.get(rend), "note": "nominal", "since": None})
    viewers.sort(key=lambda v: -(v["bps"] or 0))
    audience = len([v for v in viewers if "Cloud Mixer" not in v["proto"] and v["remote"] != "local"])
    ingest_bps = sin * 8 if sin is not None else sum(x["in_bps"] or 0 for x in streams)
    view.update({"streams": streams, "viewers": viewers, "audience": audience, "ingest_bps": ingest_bps})

    # events: streams on/off, viewers in/out, services changing
    global known
    ready_now = {"s:" + x["id"] for x in streams if x["ready"]}
    v_now = {"v:" + v["id"] for v in viewers}
    if state:
        for k in sorted(ready_now - known):
            x = next(x for x in streams if "s:" + x["id"] == k)
            log(f"stream {x['relay'].lower()}/{x['path']} is ON ({x['feeder']})")
        for k in sorted({k for k in known if k.startswith("s:")} - ready_now):
            log(f"stream {k[2:]} is OFF")
        j, l = len(v_now - known), len({k for k in known if k.startswith("v:")} - v_now)
        if j:
            log(f"{j} viewer{'s' if j > 1 else ''} joined, {len(viewers)} watching")
        if l:
            log(f"{l} viewer{'s' if l > 1 else ''} left, {len(viewers)} watching")
        for k, v in sv.items():
            old = (state.get("services") or {}).get(k)
            if old and old != v:
                log(f"{k}: {old} → {v}", 2 if v == "failed" else 0)
        os_ = state.get("site") or {}
        if site and bool(site.get("live")) != bool(os_.get("live")):
            log("the site is LIVE" + (f" ({site_name})" if site_name else "") if site.get("live") else "the site is not live")
    known = ready_now | v_now

    # hops (seen from the VM: the Mac hop is the studio master arriving over Tailscale)
    phone = next((x for x in streams if x["relay"] == "SANTOSHI" and x["ready"] and ("WHIP" in x["feeder"] or x["path"] == "pixel")), None)
    failed = [k for k, v in sv.items() if v == "failed"]
    view["hops"] = [
        ["PHONE", "ok" if phone else "off", f"SENDING {fmt_bits(phone['in_bps'])}" if phone else "IDLE"],
        ["MAC", "ok" if ingest else "off", "STUDIO SENDING" if ingest else "NO STUDIO STREAM"],
        ["VM", "warn" if failed or sv.get("santoshi-relay") != "active" else "ok",
         "A SERVICE FAILED" if failed else ("RELAY DOWN" if sv.get("santoshi-relay") != "active" else "RELAY OK")],
        ["SITE", "bad" if site.get("_error") else ("ok" if site.get("live") else "off"),
         "NO ANSWER" if site.get("_error") else ("LIVE" + (" · " + site_name.upper() if site_name else "") if site.get("live") else "READY · NOT LIVE")],
    ]
    view["refusal"] = refusal(view)
    push("ingest", ingest_bps)
    push("viewers", audience)
    push("cpu", cpu)
    push("vmOut", vm_out * 8 if vm_out is not None else None)
    push("watching", site.get("viewers") or 0)
    return view


def refusal(view):
    mr = view["mr"]
    if mr["live"]:
        return None
    if not mr["installed"]:
        return "the Meditation Room test stream is not installed on the VM"
    if not mr["running"]:
        return "start the stream first (1)"
    if in_noon():
        return "11:50–13:50 Zagreb: the noon replay owns the site"
    if (view.get("site") or {}).get("live"):
        return "the site is already live"
    if any(x["relay"] == "SANTOSHI" and x["path"] == "santoshi" and x["ready"] for x in view["streams"]):
        return "another publisher is on the santoshi path"
    return None


def fmt_bits(b):
    if b is None:
        return "—"
    if b >= 1e6:
        return f"{b / 1e6:.2f} Mbit/s"
    if b >= 1e3:
        return f"{b / 1e3:.0f} kbit/s"
    return f"{b:.0f} bit/s"


def loop():
    global snap, state
    log("streaming dashboard service started")
    while True:
        t0 = time.time()
        try:
            s = {"t": time.time(), "machine": collector.machine()}
            s["services"], s["show_next"] = collector.services()
            s["relay"] = collector.relay("https://127.0.0.1:8443")
            s["test"] = collector.relay("http://127.0.0.1:9996")
            s["studio"] = collector.studio()
            s["mixer"] = collector.mixer()
            s["mrlinux"] = collector.mrlinux()
            if time.time() - site_cache["t"] > 15:
                site_cache["data"], site_cache["t"] = collector.site(), time.time()
            s["site"] = site_cache["data"]
            v = build(s)
            with lock:
                snap, state = s, v
        except Exception as e:
            log(f"collect failed: {type(e).__name__}: {e}", 2)
        time.sleep(max(1.0, 5 - (time.time() - t0)))


def run_action(action, minutes):
    cmd = {"start": ["mrlinux", "start"], "stop": ["mrlinux", "stop"], "stop-live": ["mrlinux", "stop-live"],
           "go-live": ["mrlinux", "go-live", str(minutes)]}[action]
    busy["what"] = action
    log(f"{action} …")
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=90)
        out = (r.stdout + r.stderr).strip().splitlines()
        last = out[-1] if out else f"exit {r.returncode}"
        busy["note"] = last if r.returncode == 0 else "refused: " + last
        log(f"{'' if r.returncode == 0 else 'FAILED '}{action}: {last}", 0 if r.returncode == 0 else 2)
        site_cache["t"] = 0
        return r.returncode == 0, last
    finally:
        busy["what"] = ""


def token():
    try:
        return open(TOKEN_FILE).read().strip()
    except OSError:
        return ""


class H(BaseHTTPRequestHandler):
    server_version = "streaming-dashboard"

    def log_message(self, *a):
        pass

    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body, separators=(",", ":")).encode()
        self.send_response(code)
        self.send_header("content-type", ctype)
        self.send_header("cache-control", "no-store")
        self.send_header("content-length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        path = self.path.split("?")[0]
        if path in ("/", "/index.html"):
            try:
                return self.send(200, open(WEB, "rb").read(), "text/html; charset=utf-8")
            except OSError:
                return self.send(500, {"error": "page missing"})
        with lock:
            if path == "/api/snapshot":
                return self.send(200, {**snap, "served_at": time.time()})
            if path == "/api/state":
                return self.send(200, {**state, "hist": hist, "busy": busy,
                                       "events": [[time.strftime("%H:%M:%S", time.localtime(e[0])), e[1], e[2]] for e in events[:80]]})
        if path == "/health":
            return self.send(200, {"ok": True, "version": VERSION})
        self.send(404, {"error": "not found"})

    def do_POST(self):
        if self.path.split("?")[0] != "/api/action":
            return self.send(404, {"error": "not found"})
        local = self.client_address[0] in LOCAL
        tok = token()
        given = self.headers.get("x-dash-token", "")
        if not local and not (tok and hmac.compare_digest(given, tok)):
            return self.send(403, {"error": "token"})
        try:
            body = json.loads(self.rfile.read(min(int(self.headers.get("content-length", "0") or 0), 4096)) or b"{}")
        except Exception:
            body = {}
        action = body.get("action", "")
        if action not in ("start", "stop", "go-live", "stop-live"):
            return self.send(400, {"error": "action"})
        if busy["what"]:
            return self.send(409, {"ok": False, "note": f"busy: {busy['what']}"})
        minutes = body.get("minutes", 5)
        if action == "go-live":
            if minutes not in (5, 15, 30):
                return self.send(400, {"error": "minutes must be 5, 15 or 30"})
            with lock:
                why = refusal(state) if state else "not ready yet"
            if why:
                log(f"go live refused: {why}", 1)
                return self.send(409, {"ok": False, "note": "not now: " + why})
        ok, note = run_action(action, minutes)
        self.send(200 if ok else 409, {"ok": ok, "note": note})


def main():
    threading.Thread(target=loop, daemon=True).start()
    servers = []
    for b in BINDS:
        for _ in range(30):          # Tailscale may come up after us at boot
            try:
                servers.append(ThreadingHTTPServer((b.strip(), PORT), H))
                break
            except OSError:
                time.sleep(2)
    if not servers:
        sys.exit("could not bind")
    for s in servers[1:]:
        threading.Thread(target=s.serve_forever, daemon=True).start()
    servers[0].serve_forever()


if __name__ == "__main__":
    main()
