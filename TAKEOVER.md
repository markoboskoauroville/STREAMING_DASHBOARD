# TAKEOVER: Streaming Dashboard (Mantra)

A Mac app (Swift, built only by GitHub Actions) with one window for the streams on the cloud machine chromium-vm.
Started 15.11.2026 at Marko's word (momentaryupdates.md, request 1). This repository is public and unpromoted, so it has
no README: what it is lives here (MANTRA_MANIFEST modules/repo-privacy.md).

## What the window shows

- **The chain**: four lights PHONE · MAC · VM · SITE, each with one word (SENDING, TAILSCALE UP, RELAY OK, LIVE / READY).
- **① START MEDITATION ROOM STREAM** (STOP while it runs): `mrlinux start|stop` on the VM, the Meditation Room (Linux)
  test stream of MANTRA_ROOM/linux, private (relay vmtest, HLS on Tailscale :8987).
- **② GO LIVE ON THE SITE** (STOP LIVE while live): `mrlinux go-live 5|15|30` / `mrlinux stop-live`, as camera "VM Test",
  asked first (sheet with the minutes). Grey with the reason when not allowed: stream not running, 11:50–13:50 Zagreb,
  the site already live, another publisher on the santoshi path. mrlinux checks the same rules again on the VM.
- **Five numbers** with sparklines (last 60 polls): MAC → VM (the Mac's Tailscale interface out), INGEST ON THE VM (the
  studio RTMP master, else the sum of the publishers), VIEWERS ON OUR STREAMS (+ SITE N WATCHING), VM CPU, SIM DATA LEFT.
- **DETAILS** (one named entry), folders with a one-line "what is inside", one open at a time:
  STREAMS (every MediaMTX path of the santoshi relay and the test relay + the studio ladder: fed by, state, speed in,
  readers, on for, picture, errors) · VIEWERS (each WHEP / HLS / SRT reader: where (a.b.*.*), device, speed, RTT/loss;
  studio viewers per rendition with nominal speed) · THE MACHINE (CPU, RAM, load, uptime, disk, net, Tailscale in, the
  services, cloud mixer program/output/late frames/next show) · DEVICES (which device feeds which path; NDI sources on
  this Mac by `~/.local/bin/ndimon list`) · TOOLS (TEST THE WHOLE CHAIN, copy the viewer / test / studio links) · EVENTS
  (what happened, newest first; also ~/Library/Logs/StreamingDashboard.log).

## How the data comes

- One poll = `ssh chromium-vm python3 - [site]` with app/collector.py on stdin (nothing installed on the VM), about 2 KB of
  JSON back. Every 5 s while the window is visible, every 30 s when hidden; the site every 15 s. One shared ssh connection
  (ControlMaster /tmp/sdash-<uid>-%C, 10 min).
- The collector asks: MediaMTX santoshi relay API https://127.0.0.1:8443/v3 (127.0.0.1 has the api right), test relay
  http://127.0.0.1:9996/v3, `ss` on :1935 (studio ladder ingest bytes), studio-web /studio/health (viewers by rendition),
  cloud mixer http://127.0.0.1:8841/, systemctl states, /proc counters, mrlinux status.json, the site /api/live (public)
  and `status` with the VM Test camera token for the watching count (token read on the VM with sudo, never printed or sent
  to the Mac; only live/via/source/name/viewers leave).
- The Mac: `netstat -ibn` for the utun with the 100.64/10 address; SIM from ~/Library/Application Support/connection-keeper/
  sim-balances.json (written by the hub's SIM DATA LEFT check; no SMS is sent by the app).
- TEST THE WHOLE CHAIN: VM answers → mrlinux installed → test stream (started for the test if it was off, stopped again)
  → vmtest ready → test HLS playlist over Tailscale → public relay → studio-web → cloud mixer API → site → `mrlinux checks`.
  Only playlists and JSON cross the SIM; it never goes live.

## Known limits (v1)

- ssh goes through the alias `chromium-vm` (the VM's public sshd): the Tailscale address answers port 22 with Tailscale SSH,
  which asks for a browser check. The HTTP checks (test HLS, cloud mixer) go over Tailscale.
- MAC → VM is the whole Tailscale interface out, not only the studio stream; the exact studio ingest is INGEST ON THE VM.
- The site's watching count comes only while the site is live (the API gives it on `status` of a live stream).
- Studio viewers have no per-viewer bytes (studio-web counts them by rendition): their speed is the rendition's nominal rate.

## Build, release, install

Push to main → .github/workflows/build.yml (guard check_one_title.sh, build.sh, release vN marked Latest). The app updates
itself at start (app/Updater.swift, kits/mac-updater). First install on the Mac:

    gh release download --repo markoboskoauroville/STREAMING_DASHBOARD --pattern app.zip -D /tmp/sd --clobber
    ditto -x -k /tmp/sd/app.zip /Applications && codesign --force -s "Mantra Apps" "/Applications/Streaming Dashboard (Mantra).app"
    open -g -a "Streaming Dashboard (Mantra)" --args --background

Never swiftc / build.sh on the Mac (MANTRA_MANIFEST compile-on-github.md). Bundle id community.auroville.streamingdashboard.
