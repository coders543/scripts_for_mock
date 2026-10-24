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

Change default passwords

```
passwd root
passwd $user
```

Back up configs

```
mkdir -p /root/ccdc_backups/manual
tar -czf /root/ccdc_backups/manual/etc_$(date +%H%M).tgz /etc
```

Copy `/root/ccdc_backups` OFF the box before hour 6 (red team wipes local backups)

Document every change: time, host, what, how to undo

---

## 2. Accounts

List users that can log in, and any UID 0

```
grep -vE 'nologin|false' /etc/passwd
awk -F: '$3==0' /etc/passwd
```

Lock or delete unauthorized users

```
usermod -L -s /sbin/nologin $user
userdel -r $user
```

Check sudo for unauthorized users and NOPASSWD

```
cat /etc/sudoers; ls /etc/sudoers.d; grep -r NOPASSWD /etc/sudoers /etc/sudoers.d
getent group sudo wheel
gpasswd -d $user sudo
```

Check ssh keys you did not add

```
find /root /home -name 'authorized_keys*' -exec ls -l {} \;
```

Do NOT lock root or change `PermitRootLogin` unless you confirmed the scoring engine does not log in as root

---

## 3. Services: stop what you don't need

```
ss -tulnp
systemctl list-units --type=service --state=running
```

Stop and disable (disabling beats firewalling)

```
systemctl disable --now $service
```

Usually bad: telnet, rsh/rlogin/rexec, tftp, xinetd, cups, avahi, snmp, nfs, rpcbind (unless Samba/NFS is scored)

Anything on a port you don't recognize: find it

```
lsof -i :$port
ls -l /proc/$PID/exe
```

---

## 4. SSH  (`/etc/ssh/sshd_config`)

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

## 5. Apache  (`/etc/apache2/apache2.conf` or `/etc/httpd/conf/httpd.conf`)

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

Test and restart
```
apache2ctl -t && systemctl restart apache2        # or: apachectl -t && systemctl restart httpd
```

Look for web shells
```
find /var/www -name '*.php' -mtime -1
grep -rlE 'eval\(|base64_decode|system\(|shell_exec' /var/www
```

---

## 6. DNS / BIND  (`/etc/bind/named.conf.options` or `/etc/named.conf`)

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

## 7. Samba  (`/etc/samba/smb.conf`)

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

## 8. FTP  (vsftpd: `/etc/vsftpd.conf`, proftpd: `/etc/proftpd/proftpd.conf`)

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

## 9. Firewall (ingress AND egress)

Inventory first. You can't firewall what you haven't found

```
ss -tulnp
```

Allow only what is scored (example, change the ports)
```
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p tcp --dport 80 -j ACCEPT
iptables -P INPUT DROP

iptables -A OUTPUT -o lo -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -P OUTPUT DROP
```

Add the OUTPUT policy last. Locked egress stops red team shells from calling home

Block an attacker IP both ways
```
iptables -I INPUT -s $IP -j DROP
iptables -I OUTPUT -d $IP -j DROP
```

Do NOT disable ping unless you checked it isn't scored (`icmp_echo_ignore_all` can fail a scored ping check)

---

## 10. /etc/hosts

```
cp -a /etc/hosts /root/ccdc_backups/manual/hosts.bak
cat /etc/hosts
```

Remove entries you don't recognize, keep only localhost and this box's own name

```
chown root:root /etc/hosts && chmod 644 /etc/hosts
chattr +i /etc/hosts
```

Also check
```
grep '^hosts' /etc/nsswitch.conf
cat /etc/resolv.conf
```

---

## 11. Persistence (red team coming back)

```
crontab -l; ls -l /etc/cron* /var/spool/cron* 2>/dev/null
cat /etc/rc.local
systemctl list-timers; systemctl list-unit-files --state=enabled
cat /etc/ld.so.preload
find / -perm -4000 -type f 2>/dev/null
find /tmp /dev/shm /var/tmp -type f
```

Kill a suspicious process and its parent
```
ps -eo pid,ppid,user,tty,cmd --forest
kill -9 $PID
```

Processes owned by www-data running bash = compromised

---

## 12. chattr +i (immutable)

Even root can't change or delete the file until you remove the flag

```
chattr +i /etc/passwd /etc/shadow /etc/group /etc/sudoers /etc/hosts
lsattr /etc/passwd
chattr -i /etc/passwd          # needed before passwd/useradd/package updates, then lock again
```

Never lock a file a scored service must write. Red team with root can undo it, so it slows them, it doesn't stop them

---

## 13. Updates

Only patch what is actually exploitable. If patching costs uptime or needs a reboot, block the port instead

```
apt-get update && apt-get -y upgrade        # or: yum -y update
```

Don't reboot a scored box without a plan

---

## 14. Last 30 minutes

Every scored service works from outside the box

Passwords rotated again

```
ss -tulnp
```
No unknown listeners

Backups copied off the box

Change log up to date
