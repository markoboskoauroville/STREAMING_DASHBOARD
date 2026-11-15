#!/usr/bin/env python3
"""collector.py: ONE snapshot of the streaming machine, as compact JSON on stdout.

Two users, one file: the VM service vm/streaming_dashboard_vm.py imports it (installed beside it by vm/install.sh), and
the Mac app sends it over ssh (`ssh chromium-vm python3 - [site]`) when the service does not answer. Read-only: it only
asks the services that already run there.

  the VM itself        uptime, load, CPU and RAM counters, bytes in/out of every interface (the Mac makes rates from them)
  santoshi relay       MediaMTX API https://127.0.0.1:8443 (127.0.0.1 may read it): paths, WHEP/WHIP sessions, SRT, HLS
  test relay           MediaMTX API http://127.0.0.1:9996 (mrlinux, path vmtest)
  studio ladder        the Mac's RTMP master on :1935 (ss: bytes received), studio-web health (viewers by rendition)
  cloud mixer          http://127.0.0.1:8841 (program, output, frames, late frames, the last events)
  mrlinux              installed? its status.json (speed, fps, bitrate, dropped frames)
  site (arg "site")    santoshi-band.pages.dev/api/live, public; and "status" with the VM Test camera token for the
                       watching count. The token is read here on the VM and never printed: only live/via/source/name/viewers.

Viewer addresses are masked to their first two numbers (a.b.*.*) before they leave the VM.
"""
import json, os, re, ssl, subprocess, sys, time, urllib.request

CTX = ssl.create_default_context()
CTX.check_hostname, CTX.verify_mode = False, ssl.CERT_NONE
UA = {"user-agent": "streaming-dashboard/1"}


def get(url, timeout=4, data=None, headers=None):
    try:
        req = urllib.request.Request(url, data=data, headers={**UA, **(headers or {})}, method="POST" if data else "GET")
        with urllib.request.urlopen(req, timeout=timeout, context=CTX if url.startswith("https") else None) as r:
            return json.load(r)
    except Exception as e:
        return {"_error": type(e).__name__}


def sh(cmd, timeout=6):
    try:
        return subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout).stdout
    except Exception:
        return ""


def mask(addr):
    if not addr:
        return ""
    m = re.match(r"^\[?([0-9.]+|[0-9a-fA-F:]+)\]?(?::(\d+))?$", addr)
    host = m.group(1) if m else addr
    if host.startswith("127.") or host == "::1":
        return "local"
    if host.startswith("100."):
        return "tailnet " + host
    if "." in host:
        p = host.split(".")
        return f"{p[0]}.{p[1]}.*.*"
    return host.split(":")[0] + ":*"


KEEP = ("id", "created", "state", "path", "bytesReceived", "bytesSent", "peerConnectionEstablished", "localCandidate",
        "remoteCandidate", "rtpPacketsLost", "rtpPacketsJitter", "msRTT", "mbpsSendRate", "mbpsReceiveRate",
        "packetsSendLoss", "packetsReceivedLoss", "packetsRetrans", "outboundBytes", "inboundBytes", "userAgent")


def items(base, kind):
    d = get(f"{base}/v3/{kind}/list")
    if "_error" in d:
        return None
    out = []
    for it in d.get("items") or []:
        o = {k: it[k] for k in KEEP if k in it}
        o["remote"] = mask(it.get("remoteAddr", ""))
        if "userAgent" in o:
            ua = o.pop("userAgent") or ""
            o["device"] = "phone" if re.search(r"mobi|android|iphone", ua, re.I) else ("tablet" if re.search(r"ipad|tablet", ua, re.I) else "desktop")
        out.append(o)
    return out


def paths(base):
    d = get(f"{base}/v3/paths/list")
    if "_error" in d:
        return None
    out = []
    for p in d.get("items") or []:
        out.append({"name": p.get("name"), "ready": p.get("ready"), "readyTime": p.get("readyTime"),
                    "source": (p.get("source") or {}).get("type"), "sourceId": (p.get("source") or {}).get("id"),
                    "tracks": p.get("tracks") or [],
                    "size": next(((t.get("codecProps") or {}).get("height") for t in p.get("tracks2") or [] if (t.get("codecProps") or {}).get("height")), None),
                    "readers": [r.get("type") for r in p.get("readers") or []],
                    "bytesReceived": p.get("bytesReceived") or p.get("inboundBytes") or 0,
                    "bytesSent": p.get("bytesSent") or p.get("outboundBytes") or 0,
                    "framesInError": p.get("inboundFramesInError") or 0})
    return out


def relay(base):
    return {"paths": paths(base), "webrtc": items(base, "webrtcsessions"), "srt": items(base, "srtconns"),
            "hls": items(base, "hlssessions")}


def machine():
    m = {}
    try:
        m["up_s"] = float(open("/proc/uptime").read().split()[0])
        m["load"] = [float(x) for x in open("/proc/loadavg").read().split()[:3]]
        cpu = [int(x) for x in open("/proc/stat").readline().split()[1:]]
        m["cpu"] = [sum(cpu), cpu[3] + (cpu[4] if len(cpu) > 4 else 0)]
        m["ncpu"] = os.cpu_count()
        mem = dict((l.split(":")[0], int(l.split()[1])) for l in open("/proc/meminfo") if l.split()[0][:-1] in ("MemTotal", "MemAvailable"))
        m["mem_kb"] = [mem.get("MemTotal", 0), mem.get("MemAvailable", 0)]
        net = {}
        for l in open("/proc/net/dev").readlines()[2:]:
            n, rest = l.split(":", 1)
            f = rest.split()
            if n.strip() in ("tailscale0", "enp0s6", "eth0", "ens3"):
                net[n.strip()] = [int(f[0]), int(f[8])]
        m["net"] = net
        st = os.statvfs("/")
        m["disk_free_gb"] = round(st.f_bavail * st.f_frsize / 1e9, 1)
    except Exception as e:
        m["_error"] = type(e).__name__
    return m


UNITS = ["santoshi-relay", "studio-ladder", "studio-web", "cloud-mixer", "santoshi-rec-upload", "mrlinux-relay",
         "meditation-room-linux", "mrlinux-live"]


def services():
    out = sh("systemctl is-active " + " ".join(UNITS) + " cloud-mixer-show.timer").split()
    names = UNITS + ["cloud-mixer-show.timer"]
    s = {n: (out[i] if i < len(out) else "unknown") for i, n in enumerate(names)}
    nxt = sh("systemctl show cloud-mixer-show.timer -p NextElapseUSecRealtime --value").strip()
    return s, nxt


def studio():
    ss = sh("ss -tinH state established '( sport = :1935 )'")
    conns = []
    peer, rx = None, None
    for l in ss.splitlines():
        if not l.startswith(("\t", " ")):
            p = l.split()
            peer = p[-1] if p else None
        m = re.search(r"bytes_received:(\d+)", l)
        if m and peer:
            conns.append({"remote": mask(peer.rsplit(":", 1)[0]), "bytesReceived": int(m.group(1))})
            peer = None
    return {"ingest": conns, "health": get("https://127.0.0.1:2053/studio/health")}


def mixer():
    d = get("http://127.0.0.1:8841/", timeout=3)
    if "_error" in d:
        return d
    prog = d.get("program") or {}
    return {"program": prog.get("label") or prog.get("id"), "output": d.get("output"), "frames": d.get("frames"),
            "late_frames": d.get("late_frames"), "holds": d.get("holds"), "inputs": [i.get("label") or i.get("id") for i in d.get("inputs") or []],
            "events": (d.get("events") or [])[-6:]}


def mrlinux():
    inst = bool(sh("command -v mrlinux").strip())
    st = {}
    try:
        st = json.load(open("/home/ubuntu/.cache/mrlinux/status.json"))
        st.pop("pid", None)
    except Exception:
        pass
    return {"installed": inst, "status": st}


def site():
    pub = get("https://santoshi-band.pages.dev/api/live", timeout=8)
    out = {"live": pub.get("live"), "via": pub.get("via"), "since": pub.get("since"), "_error": pub.get("_error")}
    tok = sh("sudo -n cat /etc/meditation-room-linux/site-token 2>/dev/null").strip()
    if tok:
        d = get("https://santoshi-band.pages.dev/api/live", timeout=8, data=json.dumps({"action": "status"}).encode(),
                headers={"Authorization": "Bearer " + tok, "content-type": "application/json"})
        out.update({"viewers": d.get("viewers"), "source": d.get("source"), "name": d.get("name")})
        tok = None
    return out


def main():
    snap = {"t": time.time(), "machine": machine()}
    snap["services"], snap["show_next"] = services()
    snap["relay"] = relay("https://127.0.0.1:8443")
    snap["test"] = relay("http://127.0.0.1:9996")
    snap["studio"] = studio()
    snap["mixer"] = mixer()
    snap["mrlinux"] = mrlinux()
    if "site" in sys.argv[1:]:
        snap["site"] = site()
    sys.stdout.write(json.dumps(snap, separators=(",", ":")))


if __name__ == "__main__":
    main()
