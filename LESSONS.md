# LESSONS: Streaming Dashboard (Mantra)

1. **15.11.2026: ssh to the VM's Tailscale address is Tailscale SSH.** `ssh ubuntu@100.102.86.30` printed "Tailscale SSH
   requires an additional check" with a login link and hung. The app uses the `chromium-vm` alias of ~/.ssh/config (the VM's
   own sshd, key oracle_vm); plain HTTP to the Tailscale address (8987, 8841) works without a check.
2. **15.11.2026: the santoshi relay's API is on :8443 with TLS, not 9998.** 127.0.0.1:9998 is the Prometheus metrics door
   (/v3 gives 404). The test relay (mrlinux) has its API on plain http 127.0.0.1:9996.
3. **15.11.2026: nothing installed on the VM.** The collector travels with the app and goes over ssh on stdin at every poll,
   so a new version of the app never needs a VM deploy.
