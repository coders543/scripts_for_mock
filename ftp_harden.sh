#!/usr/bin/env bash
# ftp_harden.sh - lightweight vsftpd / proftpd hardening. Usage: sudo bash ftp_harden.sh
# write_enable is left alone on purpose (a scored FTP check may upload). Set FTP_WRITE=no to force it off.
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
BK=/root/ccdc_backups/ftp; TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"; chmod 700 /root/ccdc_backups "$BK"
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
# setkv FILE KEY VALUE : drop old/commented lines for KEY, append "KEY=VALUE"
setkv() { sed -i -E "/^[[:space:]#]*$2([[:space:]=]|\$)/d" "$1"; echo "$2=$3" >> "$1"; }

echo "=== Starting hardening for FTP ==="
V=""; [ -f /etc/vsftpd.conf ] && V=/etc/vsftpd.conf; [ -z "$V" ] && [ -f /etc/vsftpd/vsftpd.conf ] && V=/etc/vsftpd/vsftpd.conf
P=""; [ -f /etc/proftpd/proftpd.conf ] && P=/etc/proftpd/proftpd.conf; [ -z "$P" ] && [ -f /etc/proftpd.conf ] && P=/etc/proftpd.conf

snapshot ftp etc/vsftpd.conf etc/vsftpd etc/proftpd etc/proftpd.conf etc/ftpusers etc/vsftpd.userlist
if [ -n "$V" ]; then
    BAK="$BK/vsftpd.conf.$TS"; cp -a "$V" "$BAK"
    rollback() { cp -a "$BAK" "$V"; svc restart vsftpd; echo "FAILED hardening FTP (vsftpd) - rolled back to $BAK"; exit 1; }
    for kv in anonymous_enable=NO anon_upload_enable=NO anon_mkdir_write_enable=NO local_enable=YES \
              chroot_local_user=YES allow_writeable_chroot=YES ftpd_banner=Authorized_use_only; do
        setkv "$V" "${kv%%=*}" "${kv#*=}"
    done
    [ "${FTP_WRITE:-}" = no ] && setkv "$V" write_enable NO
    # ssl_enable=YES with no certificate stops vsftpd from starting, so only turn it on if a cert exists
    CERT=$(awk -F= '/^[[:space:]]*rsa_cert_file/ {print $2}' "$V" | tr -d '[:space:]')
    if [ -n "$CERT" ] && [ -f "$CERT" ]; then setkv "$V" ssl_enable YES; setkv "$V" allow_anon_ssl NO
    else echo "[i] no usable rsa_cert_file - leaving ssl_enable alone so FTP keeps working"; fi
    svc restart vsftpd; sleep 2
    pgrep -x vsftpd >/dev/null || rollback
elif [ -n "$P" ]; then
    BAK="$BK/proftpd.conf.$TS"; cp -a "$P" "$BAK"
    rollback() { cp -a "$BAK" "$P"; svc restart proftpd; echo "FAILED hardening FTP (proftpd) - rolled back to $BAK"; exit 1; }
    grep -q '^[[:space:]]*DefaultRoot' "$P" || echo "DefaultRoot ~" >> "$P"
    sed -i '/^[[:space:]]*<Anonymous/,/^[[:space:]]*<\/Anonymous>/ s/^/#DISABLED /' "$P"
    if have proftpd && ! proftpd -t -c "$P" >/tmp/ftp_test.err 2>&1; then tail -3 /tmp/ftp_test.err; rollback; fi
    svc restart proftpd; sleep 2
    pgrep -x proftpd >/dev/null || rollback
else
    echo "No vsftpd/proftpd config found - skipping."; exit 0
fi
echo "[i] anonymous disabled, local users chrooted. Confirm a scored login still works."
echo "=== Finished hardening FTP! (backup: ${BAK}) ==="
