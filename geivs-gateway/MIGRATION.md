# Gateway cutover — safe, per-service, reversible

Goal: move each service's code under `geivs-gateway/services/` and point its systemd
unit here, **one service at a time**, verifying after each. No big-bang switch.

Order (lowest-risk first, so a mistake is cheap):
1. jeeves-health   (trivial; proves the pattern)
2. jeeves-email
3. render-bridge
4. jeeves-ollama-bridge
5. jeeves-openai-shim
6. jeeves-bridge   (Signal — most important; do last, verify a real message)

Per service:
1. `cp` source into `services/` (copy, don't move, until verified).
2. Back up the unit: `sudo cp /etc/systemd/system/<unit>.service{,.bak-cutover}`.
3. Edit `ExecStart=` to the new `services/` path (+ any `EnvironmentFile=`).
4. `sudo systemctl daemon-reload && sudo systemctl restart <unit>`.
5. Verify: `systemctl is-active`, port is listening, a real request works.
6. Only then delete the old source from `~/jeeves-butler`.

Rollback (any step): restore `<unit>.service.bak-cutover`, `daemon-reload`, restart.

Do NOT start this at the tail of a long session — each Signal/agent restart is
user-visible. Run it as its own focused pass.

## Status: cutover COMPLETE (2026-07-12)

All services now run from geivs-gateway/services/ via their systemd units:
- system_health  (user unit jeeves-health)        :4090
- jeeves-email   (user unit)                       :4091
- render-bridge  (system, venv-render python)      :8766
- jeeves-ollama-bridge (system)          172.17.0.1:11434
- jeeves-openai-shim   (system)                    :8788
- jeeves-bridge  (system, Signal path)             :8765

Unit backups saved as *.service.bak-cutover. Old sources archived out of
~/jeeves-butler and ~/ (see ~/archive/jeeves-services-preGateway-*).
