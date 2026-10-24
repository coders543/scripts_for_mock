#!/usr/bin/env bash
# apache_harden.sh - lightweight Apache/httpd hardening. Usage: sudo bash apache_harden.sh
[ -n "${BASH_VERSION:-}" ] || { echo "Run with bash: sudo bash $0"; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }
BK=/root/ccdc_backups/apache; TS=$(date +%Y%m%d_%H%M%S); mkdir -p "$BK"; chmod 700 /root/ccdc_backups "$BK"
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
# setkv FILE KEY VALUE : drop old/commented lines for KEY, append "KEY VALUE"
setkv() { sed -i -E "/^[[:space:]#]*$2([[:space:]]|\$)/d" "$1"; echo "$2 $3" >> "$1"; }

echo "=== Starting hardening for APACHE ==="
CONF=""; DIR=""
if [ -f /etc/apache2/apache2.conf ]; then CONF=/etc/apache2/apache2.conf; DIR=/etc/apache2
elif [ -f /etc/httpd/conf/httpd.conf ]; then CONF=/etc/httpd/conf/httpd.conf; DIR=/etc/httpd
else echo "Apache/httpd not found - skipping (nginx is not handled here)."; exit 0; fi

ARCH="$BK/apache_configs.$TS.tgz"; snapshot apache "${DIR#/}"; snapshot webroot var/www srv/www
rollback() { tar -xzf "$ARCH" -C /; svc restart apache2 httpd; echo "FAILED hardening APACHE - rolled back to $ARCH"; exit 1; }

# 1) hide version, no TRACE
SEC=$CONF
[ -f /etc/apache2/conf-enabled/security.conf ] && SEC=$(readlink -f /etc/apache2/conf-enabled/security.conf)
setkv "$SEC" ServerTokens Prod
setkv "$SEC" ServerSignature Off
setkv "$SEC" TraceEnable Off

# 2) strip "Indexes" from every Options line (never leaves a bare "Options")
grep -rlE '^[[:space:]]*Options[[:space:]].*Indexes' "$DIR" 2>/dev/null | while read -r f; do
    tmp=$(mktemp)
    awk '{
        if ($1 == "Options") {
            match($0, /^[ \t]*/); ind = substr($0, 1, RLENGTH); out = $1; n = 0; ch = 0
            for (i = 2; i <= NF; i++) {
                if ($i == "Indexes" || $i == "+Indexes" || $i == "-Indexes") { ch = 1; continue }
                out = out " " $i; n++
            }
            if (ch) { if (n == 0) out = out " None"; else out = out " -Indexes"; print ind out; next }
        }
        print
    }' "$f" > "$tmp" && cat "$tmp" > "$f"; rm -f "$tmp"
done

# 3) web user: unprivileged, no login shell
NOLOGIN=$(command -v nologin || echo /sbin/nologin)
for u in www-data apache; do id "$u" >/dev/null 2>&1 && usermod -s "$NOLOGIN" "$u" 2>/dev/null; done
if [ -f /etc/apache2/envvars ] && id www-data >/dev/null 2>&1; then
    sed -i -E 's/^export APACHE_RUN_USER=.*/export APACHE_RUN_USER=www-data/; s/^export APACHE_RUN_GROUP=.*/export APACHE_RUN_GROUP=www-data/' /etc/apache2/envvars
fi
chown -R root:root "$DIR" 2>/dev/null

# 4) disable modules that leak info or expose directories (Debian/Ubuntu only)
if have a2dismod; then for m in autoindex status info userdir; do a2dismod -q "$m" >/dev/null 2>&1; done; fi

# 5) test, restart, verify
for ctl in apache2ctl apachectl httpd; do have "$ctl" && break; ctl=""; done
if [ -n "$ctl" ] && ! "$ctl" -t >/tmp/apache_test.err 2>&1; then tail -3 /tmp/apache_test.err; rollback; fi
svc restart apache2 httpd; sleep 2
pgrep -x 'apache2|httpd' >/dev/null || rollback

echo "[i] Web root should be owned by root and only READABLE by the web user (not writable) unless the app needs uploads."
echo "=== Finished hardening APACHE! (backup: $ARCH) ==="
