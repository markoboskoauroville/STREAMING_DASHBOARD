#!/bin/bash
# install.sh: Streaming Dashboard (Mantra) on chromium-vm (Marko, 15.11.2026: "should also be available on the virtual
# machine Linux as well as on this machine"). Run on the VM from a clone of this repository:
#   git clone https://github.com/markoboskoauroville/STREAMING_DASHBOARD ~/src/STREAMING_DASHBOARD && sudo ~/src/STREAMING_DASHBOARD/vm/install.sh
# Puts the service in /usr/local/lib/streaming-dashboard, the unit streaming-dashboard.service (on at boot: it only reads;
# its four buttons run mrlinux, which streams only when pressed), the dashboard token (once), a desktop launcher that opens
# the page in the VM's Chrome as an app window, and the entry in /etc/chromium-vm/services.json (vmctl list, the gear).
set -e
SRC="$(cd "$(dirname "$0")/.." && pwd)"
LIB=/usr/local/lib/streaming-dashboard
install -d "$LIB/web"
install -m 755 "$SRC/vm/streaming_dashboard_vm.py" "$LIB/"
install -m 644 "$SRC/app/collector.py" "$LIB/"
install -m 644 "$SRC/vm/web/index.html" "$LIB/web/"
install -m 644 "$SRC/vm/systemd/streaming-dashboard.service" /etc/systemd/system/
# the token for control actions from other tailnet machines (the Mac app reads it over ssh); made once, never printed
T=/home/ubuntu/.config/streaming-dashboard
install -d -o ubuntu -g ubuntu -m 700 "$T"
[ -s "$T/token" ] || { head -c 32 /dev/urandom | base64 | tr -d '/+=\n' > "$T/token"; chown ubuntu:ubuntu "$T/token"; chmod 600 "$T/token"; }
# the launcher on the VM's desktop
A=/home/ubuntu/.local/share/applications
install -d -o ubuntu -g ubuntu "$A"
cat > "$A/streaming-dashboard.desktop" <<D
[Desktop Entry]
Version=1.0
Type=Application
Name=Streaming Dashboard (Mantra)
Comment=The streams on this VM: relay, studio, cloud mixer, the Meditation Room test stream, viewers and speeds
Exec=/usr/bin/google-chrome-stable --user-data-dir=/home/ubuntu/.config/chromium-vm-chrome --app=http://127.0.0.1:8996/
Icon=utilities-system-monitor
Terminal=false
Categories=Network;Monitor;
D
chown ubuntu:ubuntu "$A/streaming-dashboard.desktop"
# vmctl's registry
python3 - <<'PY'
import json
p = "/etc/chromium-vm/services.json"
try:
    d = json.load(open(p))
except Exception:
    raise SystemExit(0)
if not any(s.get("name") == "streaming-dashboard" for s in d["services"]):
    d["services"].append({"name": "streaming-dashboard", "short": "SDASH", "bar": False, "core": True, "kind": "systemd",
                          "units": ["streaming-dashboard.service"],
                          "title": "Streaming Dashboard (:8996 Tailscale, the streams' numbers + Meditation Room test stream buttons)"})
    json.dump(d, open(p, "w"), indent=1, ensure_ascii=False)
    print("added to", p)
PY
systemctl daemon-reload
systemctl enable streaming-dashboard.service >/dev/null 2>&1
systemctl restart streaming-dashboard.service
sleep 7
systemctl is-active streaming-dashboard.service
curl -s -m5 http://127.0.0.1:8996/health; echo
