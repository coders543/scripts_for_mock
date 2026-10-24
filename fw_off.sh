#!/usr/bin/env bash
# fw_off.sh - PANIC BUTTON. Removes ALL firewall rules right now and opens everything.
# Usage: sudo bash fw_off.sh      (re-apply later with: sudo bash fw.sh)
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
echo "=== Removing all firewall rules ==="
for t in iptables ip6tables; do
    command -v "$t" >/dev/null 2>&1 || continue
    for p in INPUT OUTPUT FORWARD; do "$t" -P "$p" ACCEPT; done   # policies FIRST, flushing alone leaves DROP in place
    "$t" -F; "$t" -X
    for tbl in nat mangle; do "$t" -t "$tbl" -F 2>/dev/null; done
done
command -v nft >/dev/null 2>&1 && nft flush ruleset 2>/dev/null
command -v ufw >/dev/null 2>&1 && ufw --force disable >/dev/null 2>&1
command -v firewall-cmd >/dev/null 2>&1 && systemctl stop firewalld 2>/dev/null
pkill -f "sleep 120" 2>/dev/null   # cancel fw.sh's pending auto-revert timer if it is still running
echo "=== Firewall is OFF. Policies: $(iptables -S 2>/dev/null | grep '^-P' | tr '\n' ' ') ==="
echo "If services are still down, it was not the firewall: systemctl status <service>"
