#!/usr/bin/env bash
# samba_harden.sh - lightweight Samba hardening. Usage: sudo bash samba_harden.sh
# Optional env (all default to the scoring-safe choice):
#   SMB_MIN_PROTO=SMB2     lower to NT1 ONLY if the scoring engine proves it needs SMB1
#   SMB_ENCRYPT=yes        require encryption (off by default: old scoring clients may fail)
#   DISABLE_GUEST=yes      flip every "guest ok = yes" share to no (off by default: a scored share may be guest)
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
BK=/root/ccdc_backups/samba; TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"; chmod 700 /root/ccdc_backups "$BK"
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

echo "=== Starting hardening for SAMBA ==="
CONF=/etc/samba/smb.conf
[ -f "$CONF" ] || { echo "Samba not installed ($CONF missing) - skipping."; exit 0; }
grep -qiE '^\[global\]' "$CONF" || { echo "No [global] section in $CONF - skipping."; exit 0; }
snapshot samba etc/samba
BAK="$BK/smb.conf.$TS"; cp -a "$CONF" "$BAK"
rollback() { cp -a "$BAK" "$CONF"; svc restart smbd smb; echo "FAILED hardening SAMBA - rolled back to $BAK"; exit 1; }

# setg KEY VALUE : remove any existing "KEY =" line, add a fresh one right under [global]
setg() { sed -i -E "/^[[:space:]]*$1[[:space:]]*=/Id" "$CONF"; sed -i "/^\[global\]/I a\\   $1 = $2" "$CONF"; }
setg "restrict anonymous" 2
setg "map to guest" never
setg "server min protocol" "${SMB_MIN_PROTO:-SMB2}"
setg "ntlm auth" ntlmv2-only
[ "${SMB_ENCRYPT:-no}" = yes ] && setg "smb encrypt" required
[ "${DISABLE_GUEST:-no}" = yes ] && sed -i -E 's/^([[:space:]]*guest ok[[:space:]]*=[[:space:]]*)yes/\1no/I' "$CONF"

if have testparm && ! testparm -s "$CONF" >/tmp/smb_test.err 2>&1; then tail -5 /tmp/smb_test.err; rollback; fi
svc restart smbd smb; svc restart nmbd nmb; sleep 2
pgrep -x 'smbd|smb' >/dev/null || rollback

echo "[i] Shares currently allowing guest (review):"; grep -niE 'guest ok[[:space:]]*=[[:space:]]*yes|public[[:space:]]*=[[:space:]]*yes' "$CONF" || echo "    none"
echo "=== Finished hardening SAMBA! (backup: $BAK) ==="
