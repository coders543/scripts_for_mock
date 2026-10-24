# CCDC Hardening README (simple version)

Use this if the scripts are too much, or one of them fails. Every manual step is: **back up, edit, test, restart, check the scored service from outside the box.**

Do NOT lock yourself out and do NOT break a scored service. Uptime beats hardening.

---

## 0. Run the scripts (the fast way)

```
sudo bash ssh_harden.sh
sudo bash apache_harden.sh
sudo bash dns_harden.sh
sudo bash samba_harden.sh
sudo bash ftp_harden.sh
sudo bash harden_all.sh      # runs all five
```

- You will see "Starting hardening for X..." then "Finished hardening X!". If you see FAILED, it rolled itself back.
- Backups go to `/root/ccdc_backups/<service>/` (a timestamped copy every run, plus a PRISTINE copy from the first run).
- After each one: test the scored service from another machine.

Restore a service by hand:
```
tar -xzf /root/ccdc_backups/<service>/PRISTINE_<service>_configs.tgz -C /
systemctl restart <service>
```

---

## 1. Before anything else

Read the README / scoring info

Take notes on scored services, their dependencies (DB, auth), users, and ports

Change default passwords (see section 3)

Back up configs

```
mkdir -p /root/ccdc_backups/manual
tar -czf /root/ccdc_backups/manual/etc_$(date +%H%M).tgz /etc
```

Copy `/root/ccdc_backups` OFF the box before hour 6 (red team wipes local backups)

Document every change: time, host, what, how to undo

---

## 2. Accounts

List users with an active login shell
```
awk -F: '$7 !~ /(nologin|false|sync|shutdown|halt)/ {print $1 " -> " $7}' /etc/passwd
```

List every user and its shell
```
cut -d: -f1,7 /etc/passwd
```

Find all UID 0 (root-equivalent) accounts. Only root should show up
```
awk -F: '$3 == 0 {print $1}' /etc/passwd
```

List regular users (UID 1000+) and their shells
```
awk -F: '$3 >= 1000 && $1 != "nobody" {print $1 ":" $3 ":" $7}' /etc/passwd
```

Who is in the admin/sudo groups (Ubuntu and RHEL)
```
getent group sudo wheel adm
```

Show all active sudoers rules and look for NOPASSWD
```
grep -rnv "^#\|^$" /etc/sudoers /etc/sudoers.d/
grep -r NOPASSWD /etc/sudoers /etc/sudoers.d
```

Remove someone from sudo
```
gpasswd -d $user sudo
```

Who is logged in right now, and from where
```
w; who -a
```

Last 20 logins and their source IPs
```
last -a | head -n 20
```

Check ssh keys you did not add
```
find /root /home -name 'authorized_keys*' -exec ls -l {} \;
```

Do NOT lock root or change `PermitRootLogin` unless you confirmed the scoring engine does not log in as root

---

## 3. Passwords and locking users

Change root's password (non-interactive). Pick your own password and RECORD IT
```
echo "root:<NEW_PASSWORD>" | chpasswd
```

Change one user's password
```
echo "$user:<NEW_PASSWORD>" | chpasswd
```

Mass-rotate every UID 1000+ user (same password for all, so change them again later). Don't rotate a scored service account until you know the scoring engine's new password is updated
```
for u in $(awk -F: '$3 >= 1000 && $1 != "nobody" {print $1}' /etc/passwd); do echo "$u:<NEW_PASSWORD>" | chpasswd; done
```

Lock a user and remove their shell
```
usermod -L -s /sbin/nologin $user
```

Unlock a user and restore their shell
```
usermod -U -s /bin/bash $user
```

Lock common service accounts. Skip any account a scored service logs in with (ftp, mysql, postgres)
```
for u in www-data apache nginx nobody ftp games lp news uucp proxy postgres mysql; do usermod -L -s /sbin/nologin "$u" 2>/dev/null; done
```

Show password lock status for every account
```
passwd -S -a
```

---

## 4. Services: stop what you don't need

```
ss -tulnp
systemctl list-units --type=service --state=running
```

Stop, disable, and mask (disabling beats firewalling)
```
systemctl stop $svc && systemctl disable $svc && systemctl mask $svc
```

Disable and mask the usual suspects
```
for svc in avahi-daemon cups rpcbind nfs-server telnet.socket snmpd cockpit.socket; do systemctl disable --now "$svc" 2>/dev/null; systemctl mask "$svc" 2>/dev/null; done
```

Usually bad: telnet, rsh/rlogin/rexec, tftp, xinetd, cups, avahi, snmp, nfs, rpcbind (unless Samba/NFS is scored)

Which package owns a suspicious binary (Debian vs RHEL)
```
which dpkg >/dev/null 2>&1 && dpkg -S /path/to/file || rpm -qf /path/to/file
```

Find system binaries changed from their package checksums
```
which rpm >/dev/null 2>&1 && rpm -Va | grep '^..5' || debsums -c 2>/dev/null
```

---

## 5. Network, connections, and killing shells

Listening ports with process, PID, and user
```
ss -tulnpe
```

Active established connections with owning PID
```
ss -tnpe state established
```

Full process tree
```
ps -eo pid,ppid,user,tty,etime,cmd --forest
```

Spot reverse shells or shells owned by web users
```
ps -eo pid,ppid,user,tty,etime,cmd --forest | grep -E "bash|sh|nc|python|perl|php|ruby|socat|www-data|apache"
```

Everything running as a service account
```
ps -eo pid,ppid,user,tty,etime,cmd --forest | awk '$3 ~ /(www-data|apache|nginx|mysql|postgres|named|ftp|nobody)/'
```

Real binary, working directory, and open files of a suspicious PID
```
ls -l /proc/$PID/exe /proc/$PID/cwd /proc/$PID/fd
```

Kill the parent AND the child (killing only the child lets it respawn)
```
kill -9 $PPID $PID
```

Kill an attacker's whole terminal session (pts number comes from `w`)
```
pkill -KILL -t pts/$N
```

Kill whatever is using a port
```
fuser -k $PORT/tcp
```

Cut live connections to an attacker IP
```
ss -K dst $ATTACKER_IP
```

Then block the IP (section 11) and change root's password

---

## 6. SSH  (`/etc/ssh/sshd_config`)

Back up
```
mkdir -p /root/ccdc_backups/ssh && tar -czf /root/ccdc_backups/ssh/ssh_$(date +%H%M).tgz /etc/ssh
```

Put these at the TOP of the file (sshd uses the first value it sees)
```
PermitEmptyPasswords no
MaxAuthTries 4
LoginGraceTime 30
X11Forwarding no
HostbasedAuthentication no
IgnoreRhosts yes
PermitUserEnvironment no
LogLevel VERBOSE
```

Leave `PermitRootLogin` and `PasswordAuthentication` alone (scoring may need them)

Test and reload
```
sshd -t && systemctl reload ssh || systemctl reload sshd
```

Keep your current session open and test a NEW login before closing it

---

## 7. Apache  (`/etc/apache2/apache2.conf` or `/etc/httpd/conf/httpd.conf`)

Back up
```
mkdir -p /root/ccdc_backups/apache && tar -czf /root/ccdc_backups/apache/apache_$(date +%H%M).tgz /etc/apache2 /etc/httpd /var/www 2>/dev/null
```

Add to the config (Debian: `/etc/apache2/conf-enabled/security.conf`)
```
ServerTokens Prod
ServerSignature Off
TraceEnable Off
```

Remove `Indexes` from every Options line
```
grep -rn "Options" /etc/apache2 /etc/httpd 2>/dev/null | grep Indexes
```
Change `Options Indexes FollowSymLinks` to `Options -Indexes +FollowSymLinks`

Disable useless modules (Debian)
```
a2dismod autoindex status info userdir
```

Web user gets no shell
```
usermod -s /usr/sbin/nologin www-data
```

Make the web root owned by root so www-data can't overwrite code (skip if the app needs uploads)
```
chown -R root:root /var/www/ && chmod -R 755 /var/www/
```

Test and restart
```
apache2ctl -t && systemctl restart apache2        # or: apachectl -t && systemctl restart httpd
```

Scan for web shells
```
find /var/www -name '*.php' -mtime -1
grep -rnE "(eval\(|base64_decode|shell_exec|passthru|system\(|popen\(|proc_open|cmd=)" /var/www/ /usr/share/nginx/ 2>/dev/null
```

---

## 8. DNS / BIND  (`/etc/bind/named.conf.options` or `/etc/named.conf`)

Back up
```
mkdir -p /root/ccdc_backups/dns && tar -czf /root/ccdc_backups/dns/dns_$(date +%H%M).tgz /etc/bind /etc/named.conf /var/named /var/lib/bind 2>/dev/null
```

Inside `options { ... };` add
```
allow-recursion { localhost; localnets; };
allow-transfer { none; };
version "not disclosed";
```

If the scoring engine asks for outside names, add its network to `allow-recursion`

Test and restart
```
named-checkconf && systemctl restart bind9        # or: systemctl restart named
```

Check the answer
```
dig @127.0.0.1 yourzone.example A
```

---

## 9. Samba  (`/etc/samba/smb.conf`)

Back up
```
mkdir -p /root/ccdc_backups/samba && tar -czf /root/ccdc_backups/samba/samba_$(date +%H%M).tgz /etc/samba
```

Add under `[global]`
```
restrict anonymous = 2
map to guest = never
server min protocol = SMB2
ntlm auth = ntlmv2-only
```

Check shares for guest access, only change them if the share is not scored
```
grep -niE 'guest ok|public' /etc/samba/smb.conf
```

Test and restart
```
testparm -s && systemctl restart smbd nmbd        # or: systemctl restart smb nmb
```

Only lower `server min protocol` to NT1 if scoring proves it needs SMB1

---

## 10. FTP  (vsftpd: `/etc/vsftpd.conf`, proftpd: `/etc/proftpd/proftpd.conf`)

Back up
```
mkdir -p /root/ccdc_backups/ftp && tar -czf /root/ccdc_backups/ftp/ftp_$(date +%H%M).tgz /etc/vsftpd* /etc/proftpd* 2>/dev/null
```

vsftpd settings
```
anonymous_enable=NO
anon_upload_enable=NO
anon_mkdir_write_enable=NO
local_enable=YES
chroot_local_user=YES
allow_writeable_chroot=YES
```

Only set `ssl_enable=YES` if `rsa_cert_file` points to a file that exists, otherwise vsftpd will not start

Leave `write_enable` alone unless you know scoring doesn't upload

proftpd: add `DefaultRoot ~` and comment out the whole `<Anonymous>` block

Restart and test a real login
```
systemctl restart vsftpd        # or proftpd
```

---

## 11. Firewall (ingress AND egress)

Inventory first. You can't firewall what you haven't found
```
ss -tulnp
```

See the current rules
```
iptables -L -n -v --line-numbers
```

STEP 1: set a safety net first. It flushes the firewall in 5 minutes if you lock yourself out (needs `atd` running)
```
echo "iptables -P INPUT ACCEPT; iptables -P OUTPUT ACCEPT; iptables -F" | at now + 5 minutes
```

STEP 2: flush and allow loopback
```
iptables -F && iptables -A INPUT -i lo -j ACCEPT && iptables -A OUTPUT -o lo -j ACCEPT
```

STEP 3: allow established connections both ways
```
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT && iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
```

STEP 4: allow inbound to scored ports only (change the list)
```
for port in 22 80 443; do iptables -A INPUT -p tcp --dport "$port" -j ACCEPT; done
```

STEP 5: allow outbound DNS to your DNS server
```
iptables -A OUTPUT -p udp -d $DNS_IP --dport 53 -j ACCEPT && iptables -A OUTPUT -p tcp -d $DNS_IP --dport 53 -j ACCEPT
```

STEP 6: log what gets dropped
```
iptables -A INPUT -m limit --limit 5/min -j LOG --log-prefix "[FW-DROP-IN] " && iptables -A OUTPUT -m limit --limit 5/min -j LOG --log-prefix "[FW-DROP-OUT] "
```

STEP 7: default DROP both ways (locked egress stops red team shells from calling home)
```
iptables -P INPUT DROP && iptables -P OUTPUT DROP
```

STEP 8: test every scored service, then cancel the safety net
```
atq && atrm $JOB_ID
```

Block an attacker IP both ways
```
iptables -I INPUT 1 -s $ATTACKER_IP -j DROP && iptables -I OUTPUT 1 -d $ATTACKER_IP -j DROP
```

Emergency flush if a scored service breaks
```
iptables -P INPUT ACCEPT && iptables -P OUTPUT ACCEPT && iptables -F
```

Do NOT disable ping unless you checked it isn't scored (`icmp_echo_ignore_all` can fail a scored ping check)

---

## 12. /etc/hosts

Backup, rewrite with only localhost and this box's own name, then lock it
```
cp -a /etc/hosts /root/ccdc_backups/hosts.bak && printf "127.0.0.1\tlocalhost\n::1\tlocalhost\n$(hostname -I | awk '{print $1}')\t$(hostname)\n" > /etc/hosts && chmod 644 /etc/hosts && chattr +i /etc/hosts
```

Check the DNS lookup order, nameservers, and TCP wrappers (hosts line should be `files dns`)
```
grep "^hosts:" /etc/nsswitch.conf && cat /etc/resolv.conf /etc/hosts.allow /etc/hosts.deny 2>/dev/null
```

Spot tampering later
```
diff /root/ccdc_backups/hosts.bak /etc/hosts
```

Check the README first: a scored service may need a hosts entry

---

## 13. chattr +i (immutable)

Even root can't change or delete the file until you remove the flag

Empty ld.so.preload first, then lock the critical files
```
truncate -s 0 /etc/ld.so.preload
chattr +i /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/hosts /etc/resolv.conf /etc/ld.so.preload
```

Lock the cron and sudoers directories
```
chattr -R +i /etc/cron.d /etc/cron.daily /etc/cron.hourly /etc/sudoers.d 2>/dev/null
```

Unlock to make a legitimate change (needed before passwd/useradd/package updates), then lock again
```
chattr -i /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/hosts /etc/resolv.conf /etc/ld.so.preload
```

Verify the flag is set (look for `-i-`)
```
lsattr /etc/passwd /etc/shadow /etc/sudoers /etc/hosts /etc/ld.so.preload
```

Find files red team locked
```
lsattr -R /etc /tmp /var /opt /usr 2>/dev/null | grep -- '-i-'
```

Never lock a file a scored service must write. Red team with root can undo it, so it slows them, it doesn't stop them

---

## 14. Persistence sweep (red team coming back)

Every authorized_keys file on the system
```
find / -name "authorized_keys*" -exec ls -la {} + -exec cat {} + 2>/dev/null
```

All active cron lines for every user
```
grep -rnv "^#\|^$" /etc/crontab /etc/cron* /var/spool/cron/ 2>/dev/null
```

systemd timers (cron alternative)
```
systemctl list-timers --all
```

systemd units modified in the last 3 hours
```
find /etc/systemd/system /lib/systemd/system /usr/lib/systemd/system -type f -mmin -180 2>/dev/null
```

rc.local and ld.so.preload
```
cat /etc/rc.local /etc/init.d/rc.local /etc/ld.so.preload 2>/dev/null
```

PAM backdoors
```
grep -rnE "pam_permit\.so|pam_exec\.so" /etc/pam.d/
```

Malicious aliases and bashrc backdoors
```
grep -rnE "(alias |PROMPT_COMMAND|curl|wget|nc |/dev/tcp)" /etc/profile* /etc/bash* /root/.* /home/*/.* 2>/dev/null
```

SUID and SGID binaries
```
find / -xdev \( -perm -4000 -o -perm -2000 \) -type f -exec ls -la {} + 2>/dev/null
```

Strip SUID/SGID from common privilege-escalation binaries
```
for bin in /bin/bash /bin/sh /usr/bin/find /usr/bin/vim /usr/bin/python* /usr/bin/perl /usr/bin/cp /usr/bin/nano; do chmod u-s,g-s "$bin" 2>/dev/null; done
```

Files hiding in temp directories
```
ls -laR /tmp /var/tmp /dev/shm
```

Stop binaries from running out of /tmp and /dev/shm (skip if a scored app runs code from /tmp)
```
mount -o remount,noexec,nosuid,nodev /tmp 2>/dev/null && mount -o remount,noexec,nosuid,nodev /dev/shm 2>/dev/null
```

World-writable files
```
find / -xdev -type f -perm -0002 ! -path "/proc/*" ! -path "/sys/*" -ls 2>/dev/null
```

Files changed in the last 60 minutes
```
find /etc /var/www /opt /home /root /usr/local -mmin -60 -o -cmin -60 2>/dev/null
```

Processes owned by www-data running bash = compromised

---

## 15. Logging and auditd

Live auth logs (Debian and RHEL)
```
tail -f /var/log/auth.log /var/log/secure 2>/dev/null
```

Live SSH, sudo, and su events
```
journalctl -f -u ssh -u sshd -t sudo -t su
```

Same, filtered to logins and sudo commands
```
journalctl -f -u ssh -u sshd -t sudo -t su -g "Accepted|Failed|session opened|COMMAND"
```

SSH, sudo, and su activity in the last 15 minutes
```
journalctl --since "15 minutes ago" _COMM=sshd _COMM=sudo _COMM=su --no-pager
```

Live firewall drops
```
journalctl -f -k | grep --line-buffered -iE "DROP|REJECT|UFW|CCDC"
```

Start auditd
```
service auditd start || systemctl start auditd
```

Watch the important files
```
auditctl -w /etc/passwd -p wa -k identity_tamper
auditctl -w /etc/shadow -p wa -k identity_tamper
auditctl -w /etc/sudoers -p wa -k sudo_tamper
```

Log every command run as root
```
auditctl -a always,exit -F arch=b64 -S execve -F euid=0 -k root_commands
```

Read the results
```
ausearch -k identity_tamper -i
ausearch -k sudo_tamper -i
ausearch -k root_commands -ts recent -i | grep -E "proctitle|SYSCALL"
```

---

## 16. Backups and anti-destruction (hours 4 to 8)

Red team gets destructive late. Backups on the same box can be wiped, so copy them OFF the box

Initial local backup of /etc and the web root
```
mkdir -p /root/ccdc_backups && chmod 700 /root/ccdc_backups && cp -a /etc /root/ccdc_backups/etc_bak && cp -a /var/www /root/ccdc_backups/var_www_bak 2>/dev/null
```

Spot anything in /etc changed since the backup
```
diff -rq /root/ccdc_backups/etc_bak /etc 2>/dev/null | grep -vE "mtab|resolv|adjtime|ld\.so\.cache"
```

Dump the databases
```
mysqldump -u root -p --all-databases > /root/ccdc_backups/all_db.sql
sudo -u postgres pg_dumpall > /root/ccdc_backups/pg_all.sql
```

Bundle everything into one "golden" archive
```
tar -czf /root/ccdc_backups/golden_$(hostname).tar.gz /etc /var/www /var/named /etc/samba /root/ccdc_backups/*.sql 2>/dev/null
```

Copy it off the box
```
scp /root/ccdc_backups/golden_$(hostname).tar.gz $USER@$OFF_BOX_IP:/backups/
```

Restore the web root and delete anything red team added
```
rsync -av --delete /root/ccdc_backups/var_www_bak/ /var/www/
```

Restore the databases
```
mysql -u root -p < /root/ccdc_backups/all_db.sql
```

Disk full? Check space, inodes, and deleted-but-open files
```
df -h && df -i && lsof +L1
```

Big files created in the last 3 hours
```
find / -xdev -size +100M -mmin -180 -ls 2>/dev/null
```

Limit processes per user to stop fork bombs
```
printf "* hard nproc 512\nwww-data hard nproc 128\napache hard nproc 128\n" >> /etc/security/limits.conf
```

Keep immutable copies of emergency binaries in case red team deletes /bin
```
mkdir -p /lib/.recovery_bin && cp -a /bin/sh /bin/bash /bin/cp /bin/ls /bin/chmod /bin/chown /bin/mount /usr/bin/chattr /usr/bin/lsattr /sbin/iptables /lib/.recovery_bin/ && chattr -R +i /lib/.recovery_bin
```

Disable and lock the power-off binaries so red team scripts can't shut the box down. This also stops YOU from rebooting, so undo it with `chattr -i` then `chmod 755` if you need a reboot
```
chmod 000 /sbin/reboot /sbin/shutdown /sbin/poweroff /sbin/halt && chattr +i /sbin/reboot /sbin/shutdown /sbin/poweroff /sbin/halt
```

---

## 17. Updates

Only patch what is actually exploitable. If patching costs uptime or needs a reboot, block the port instead

```
apt-get update && apt-get -y upgrade        # or: yum -y update
```

Don't reboot a scored box without a plan

---

## 18. Last 30 minutes

Every scored service works from outside the box

Passwords rotated again

```
ss -tulnp
```
No unknown listeners

Backups copied off the box

Change log up to date
