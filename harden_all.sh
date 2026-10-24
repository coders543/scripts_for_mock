#!/usr/bin/env bash
# harden_all.sh - run every hardening script that matches a service on this box.
# Non-interactive, so it is safe to push over SSH from a central runner. Usage: sudo bash harden_all.sh
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
D=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
for s in ssh apache dns samba ftp; do
    if [ -f "$D/${s}_harden.sh" ]; then
        bash "$D/${s}_harden.sh"; echo "--- $s exit code: $? ---"; echo
    else
        echo "[!] ${s}_harden.sh missing next to this script"
    fi
done
echo "ALL DONE. Now test every scored service from outside the box."
