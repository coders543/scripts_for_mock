#!/usr/bin/env bash
# apache_harden.sh - Simple cross-distro Apache hardening (Ubuntu/Debian & RHEL/CentOS/Fedora)
# Usage: sudo bash apache_harden.sh

[ "$(id -u)" -eq 0 ] || { echo "Run as root: sudo bash $0"; exit 1; }

echo "=== Starting hardening for APACHE ==="

# 1. Detect Ubuntu (/etc/apache2) vs RHEL/CentOS/Fedora (/etc/httpd)
if [ -d /etc/apache2 ]; then
  DIR=/etc/apache2; CONF=/etc/apache2/apache2.conf; SVC=apache2; CTL=apache2ctl
elif [ -d /etc/httpd ]; then
  DIR=/etc/httpd; CONF=/etc/httpd/conf/httpd.conf; SVC=httpd; CTL=apachectl
else
  echo "Apache not found - skipping."; exit 0
fi

# 2. Backup config directory & web root before touching anything
BK="/root/ccdc_backups/apache_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$BK" && chmod 700 /root/ccdc_backups "$BK"
cp -a "$DIR" "$BK/conf_bak"
[ -d /var/www ] && cp -a /var/www "$BK/www_bak"

rollback() {
  echo "FAILED hardening APACHE - rolling back from $BK"
  rm -rf "$DIR" && cp -a "$BK/conf_bak" "$DIR"
  systemctl restart "$SVC" 2>/dev/null || service "$SVC" restart 2>/dev/null
  exit 1
}

# 3. Lock down web user (no login shell) and config ownership
NOLOGIN=$(command -v nologin || echo /sbin/nologin)
for u in www-data apache; do id "$u" >/dev/null 2>&1 && usermod -s "$NOLOGIN" "$u" 2>/dev/null; done
chown -R root:root "$DIR"

# 4. Hide Apache version, OS signature, and disable HTTP TRACE
sed -i -E '/^[[:space:]]*(ServerTokens|ServerSignature|TraceEnable)[[:space:]]/Id' "$CONF"
[ -f /etc/apache2/conf-enabled/security.conf ] && sed -i -E '/^[[:space:]]*(ServerTokens|ServerSignature|TraceEnable)[[:space:]]/Id' /etc/apache2/conf-enabled/security.conf
printf "\nServerTokens Prod\nServerSignature Off\nTraceEnable Off\n" >> "$CONF"

# 5. Disable directory listing (turn '+Indexes' into '-Indexes', drop bare 'Indexes', use 'None' if empty)
grep -rlE '^[[:space:]]*Options[[:space:]].*Indexes' "$DIR" 2>/dev/null | while read -r f; do
  sed -i -E '
    /^[[:space:]]*Options[[:space:]]/ {
      s/([[:space:]]+)\+Indexes(\b|$)/\1-Indexes\2/g
      s/([[:space:]]+)Indexes(\b|$)//g
      s/^([[:space:]]*Options)[[:space:]]*$/\1 None/
    }
  ' "$f"
done

# 6. Disable leaky modules (Skip autoindex so bare IndexIgnore lines never break syntax)
if command -v a2dismod >/dev/null 2>&1; then
  for m in status info userdir; do
    a2dismod -f -q "$m" </dev/null >/dev/null 2>&1
  done
else
  for f in /etc/httpd/conf.d/userdir.conf /etc/httpd/conf.d/welcome.conf; do
    [ -f "$f" ] && : > "$f"
  done
fi

# 7. Test config syntax, restart service, or auto-rollback if broken
if ! "$CTL" -t >/tmp/apache_test.err 2>&1; then
  cat /tmp/apache_test.err
  rollback
fi
(systemctl restart "$SVC" 2>/dev/null || service "$SVC" restart 2>/dev/null) || rollback

