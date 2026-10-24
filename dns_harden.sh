#!/usr/bin/env bash
# dns_harden.sh - lightweight BIND/named hardening. Usage: sudo bash dns_harden.sh
# Optional env:  DNS_RECURSION_EXTRA="10.0.0.0/8;"   extra nets allowed to recurse (e.g. your internal LAN / scoring engine)
#                DNS_XFER="10.0.0.5;"                servers allowed zone transfers (default: none)
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
BK=/root/ccdc_backups/dns; TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"; chmod 700 /root/ccdc_backups "$BK"
snapshot() { # snapshot NAME PATH... (paths relative to /): tar copy per run + a PRISTINE copy that is never overwritten
  SN=$1; shift; L=""; for p in "$@"; do [ -e "/$p" ] && L="$L $p"; done; [ -n "$L" ] || return 0
  tar -czf "$BK/${SN}_configs.$TS.tgz" -C / $L 2>/dev/null
  [ -e "$BK/PRISTINE_${SN}_configs.tgz" ] || cp -a "$BK/${SN}_configs.$TS.tgz" "$BK/PRISTINE_${SN}_configs.tgz"
  echo "[i] Backup copy: $BK/${SN}_configs.$TS.tgz (PRISTINE_${SN}_configs.tgz = first copy, never overwritten)"; }
have() { command -v "$1" >/dev/null 2>&1; }
svc() { a=$1; shift; for n in "$@"; do
    if have systemctl && systemctl cat "$n" >/dev/null 2>&1; then systemctl "$a" "$n" >/dev/null 2>&1 && return 0
    elif have service; then service "$n" "$a" >/dev/null 2>&1 && return 0; fi
  done; return 1; }

echo "=== Starting hardening for DNS ==="
CONF=""
for c in /etc/bind/named.conf.options /etc/named.conf /etc/bind/named.conf; do
    [ -f "$c" ] && grep -qE 'options[[:space:]]*\{' "$c" && { CONF=$c; break; }
done
[ -n "$CONF" ] || { echo "No BIND/named options block found - skipping."; exit 0; }
snapshot dns etc/bind etc/named.conf etc/named var/named var/lib/bind
BAK="$BK/$(basename "$CONF").$TS"; cp -a "$CONF" "$BAK"
rollback() { cp -a "$BAK" "$CONF"; svc restart bind9 named; echo "FAILED hardening DNS - rolled back to $BAK"; exit 1; }

# insert into the FIRST options { } block, only if the directive is not already there
addopt() { grep -qE "^[[:space:]]*$1[[:space:]]" "$CONF" || sed -i "0,/options[[:space:]]*{/s//&\n    $2/" "$CONF"; }
addopt allow-recursion "allow-recursion { localhost; localnets; ${DNS_RECURSION_EXTRA:-} };"
addopt allow-transfer  "allow-transfer { ${DNS_XFER:-none;} };"
addopt version         "version \"not disclosed\";"

MAIN=/etc/named.conf; [ -f /etc/bind/named.conf ] && MAIN=/etc/bind/named.conf
if have named-checkconf && ! named-checkconf "$MAIN" >/tmp/named_test.err 2>&1; then cat /tmp/named_test.err; rollback; fi
svc restart bind9 named; sleep 2
pgrep -x named >/dev/null || rollback

echo "[i] If the scoring engine asks this server for EXTERNAL names, add its network via DNS_RECURSION_EXTRA and re-run."
echo "=== Finished hardening DNS! (backup: $BAK) ==="
