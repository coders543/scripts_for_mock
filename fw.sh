#!/usr/bin/env bash
# fw.sh - bare-minimum CCDC firewall (iptables). SSH + DNS work out of the box.
# Usage:  sudo bash fw.sh
# Add your scored ports:  IN_TCP="22 53 80 443" IN_UDP="53" sudo -E bash fw.sh
# Egress is locked to DNS only. For updates: OUT_TCP="53 80 443" sudo -E bash fw.sh
# SAFETY: it undoes itself after 120s unless you run:  touch /tmp/fw_ok
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
command -v iptables >/dev/null 2>&1 || { echo "iptables not found"; exit 1; }
IN_TCP=${IN_TCP:-"22 53"}; IN_UDP=${IN_UDP:-"53"}; OUT_TCP=${OUT_TCP:-"53"}; OUT_UDP=${OUT_UDP:-"53"}

mkdir -p /root/ccdc_backups; iptables-save > "/root/ccdc_backups/iptables.$(date +%H%M%S).rules" 2>/dev/null
rm -f /tmp/fw_ok
( sleep 120; [ -f /tmp/fw_ok ] || { iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F; } ) >/dev/null 2>&1 &

echo "=== Starting firewall ==="
iptables -F
iptables -A INPUT  -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT  -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT          # keep ping working in case it is scored
for p in $IN_TCP;  do iptables -A INPUT  -p tcp --dport "$p" -j ACCEPT; done
for p in $IN_UDP;  do iptables -A INPUT  -p udp --dport "$p" -j ACCEPT; done
for p in $OUT_TCP; do iptables -A OUTPUT -p tcp --dport "$p" -j ACCEPT; done
for p in $OUT_UDP; do iptables -A OUTPUT -p udp --dport "$p" -j ACCEPT; done
iptables -A INPUT  -m limit --limit 5/min -j LOG --log-prefix "[FW-DROP-IN] "
iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "[FW-DROP-OUT] "
iptables -P INPUT DROP; iptables -P OUTPUT DROP; iptables -P FORWARD DROP

echo "=== Finished firewall! Inbound TCP: $IN_TCP | UDP: $IN_UDP | Outbound TCP: $OUT_TCP | UDP: $OUT_UDP ==="
echo "Test SSH + DNS + every scored service from ANOTHER machine, then run:  touch /tmp/fw_ok"
echo "(no confirmation = it reverts itself in 120s. Manual undo: iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F)"
