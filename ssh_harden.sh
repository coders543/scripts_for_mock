#!/usr/bin/env bash
# ssh_harden.sh - lightweight SSH hardening. Usage: sudo bash ssh_harden.sh
# SCORING SAFE: PermitRootLogin and PasswordAuthentication are intentionally NOT touched.
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
BK=/root/ccdc_backups/ssh; TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"; chmod 700 /root/ccdc_backups "$BK"
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

echo "=== Starting hardening for SSH ==="
CONF=/etc/ssh/sshd_config
[ -f "$CONF" ] || { echo "No $CONF - SSH not installed. Skipping."; exit 0; }
snapshot ssh etc/ssh
BAK="$BK/sshd_config.$TS"; cp -a "$CONF" "$BAK"

# sshd uses the FIRST value it sees, so we prepend (this also beats any Include/drop-in and Match blocks)
setssh() { sed -i -E "/^[[:space:]#]*$1[[:space:]]/d" "$CONF"; sed -i "1i $1 $2" "$CONF"; }
for kv in "PermitEmptyPasswords no" "MaxAuthTries 4" "LoginGraceTime 30" "X11Forwarding no" \
          "HostbasedAuthentication no" "IgnoreRhosts yes" "PermitUserEnvironment no" \
          "StrictModes yes" "LogLevel VERBOSE" "ClientAliveInterval 300" "ClientAliveCountMax 2"; do
    setssh "${kv%% *}" "${kv#* }"
done

mkdir -p /run/sshd /var/run/sshd 2>/dev/null
if have sshd && ! sshd -t 2>/tmp/sshd_test.err; then
    cp -a "$BAK" "$CONF"; cat /tmp/sshd_test.err
    echo "FAILED hardening SSH - config rolled back (nothing changed)."; exit 1
fi
svc reload ssh sshd || svc restart ssh sshd
sleep 1
if ! pgrep -x sshd >/dev/null; then
    cp -a "$BAK" "$CONF"; svc restart ssh sshd
    echo "FAILED hardening SSH - sshd did not come back, rolled back."; exit 1
fi

echo "[i] PermitRootLogin untouched (scoring). Effective value: $(sshd -T 2>/dev/null | grep -i '^permitrootlogin' || echo unknown)"
echo "[i] Review these authorized_keys files for keys you did not add:"
find /root /home -maxdepth 3 -name 'authorized_keys*' -type f 2>/dev/null | while read -r f; do echo "    $f ($(wc -l < "$f") lines)"; done
echo "=== Finished hardening SSH! (backup: $BAK) ==="
