# Linux Setup Playbook — CCDC Red Team

> **Phase:** Pre-game / initial access
> **Run as:** root (all scripts require `EUID=0`)
> **Target OS:** Ubuntu (Debian-based)

These scripts are run **once you have root access** on a target Linux box before or during the early minutes of the competition. Their job is to establish persistence, create backdoor accounts, and plant services/cron jobs that the blue team must find and remove.

---

## Script Execution Order

Run them in this order — each layer depends on the previous one being in place.

```
1. CCDC_Linux_Users_HomeIntruders.sh       ← accounts first (you need them for fallback access)
2. CCDC_Linux_WebShell_OopsAllWebShells.sh ← rogue service (visible target for blue team)
3. CCDC_Linux_CronJobs_ImGonnaCron.sh      ← cron persistence (keeps killing legit services)
4. CCDC_Linux_Persistence_PlantsVsZerodays.sh ← multi-location payload (hardest to fully remove)
```

---

## 1 — Rogue Users (`CCDC_Linux_Users_HomeIntruders.sh`)

**What it does:**
- Creates three backdoor accounts with `sudo` (full `NOPASSWD`) privileges:
  | Username | Password | Disguise level |
  |---|---|---|
  | `ubuntu` | `Rem0veMe!` | Low — obvious name |
  | `johnredteam` | `R3dT3am@2024` | None — obviously adversarial |
  | `systemd-bus-proxy` | `Ev1lR00t#!` | High — looks like a system account |
- Writes a `/etc/sudoers.d/99-<username>` drop-in for each user (second persistence point)
- Sets `chattr +i` (immutable bit) on `/etc/passwd`, `/etc/shadow`, and all three sudoers drop-ins

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_Users_HomeIntruders.sh
```

**Expected output:** Green `[+]` lines confirming each user created, password set, group added, sudoers written, and `chattr +i` applied.

**Blue team must:**
1. `chattr -i /etc/passwd /etc/shadow` — remove immutable flag before they can delete users
2. `chattr -i /etc/sudoers.d/99-ubuntu` (and the other two)
3. `userdel -r ubuntu && userdel -r johnredteam && userdel -r systemd-bus-proxy`
4. `rm /etc/sudoers.d/99-ubuntu /etc/sudoers.d/99-johnredteam /etc/sudoers.d/99-systemd-bus-proxy`

**Notes:**
- `systemd-bus-proxy` is the sneaky one — it impersonates a real systemd internal account name. Blue team may skip it.
- The sudoers drop-ins are a second persistence path: even if they delete the users, a re-add + the drop-in gives full root back.

---

## 2 — Rogue Web Service (`CCDC_Linux_WebShell_OopsAllWebShells.sh`)

**What it does:**
- Installs `php-cli` via apt
- Creates a PHP web app at `/opt/web-php/www/index.php` that displays **"GET RID OF ME!"**
- Registers and starts a systemd service called `web-php` listening on **port 8888**, running as root
- Enables the service so it persists across reboots

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_WebShell_OopsAllWebShells.sh
```

**Verify it's live:**
```bash
curl http://localhost:8888
ss -tlnp | grep 8888
```

**Blue team must:**
```bash
systemctl stop web-php
systemctl disable web-php
rm /etc/systemd/system/web-php.service
systemctl daemon-reload
rm -rf /opt/web-php
```

**Notes:**
- Script header says "CURRENTLY BUSTED AFTER TESTING" — verify it actually starts before competition day. Test on a clean VM.
- The service description reads `"system network optimiser daemon"` — designed to blend in.
- Running on non-standard port 8888; blue team needs to `ss -tlnp` or `netstat` to find it.

---

## 3 — Malicious Cron Jobs (`CCDC_Linux_CronJobs_ImGonnaCron.sh`)

**What it does:**
- Writes two files to `/etc/cron.d/`:
  | File | Schedule | Disguise |
  |---|---|---|
  | `grub-service` | every 5 min | Looks like a GRUB boot helper |
  | `sillyevilcronjob` | every 3 min | Obvious evil name for trainees to spot |
- Both jobs run as root and execute: `systemctl stop` + `systemctl mask` on **dovecot, postfix, apache2, splunk**
- Effect: even if blue team starts their services back up, these jobs kill them again within 3–5 minutes

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_CronJobs_ImGonnaCron.sh
```

**Blue team must:**
```bash
rm /etc/cron.d/grub-service /etc/cron.d/sillyevilcronjob
# Also unmask and restart their services:
systemctl unmask dovecot postfix apache2 splunkd
systemctl start dovecot postfix apache2 splunkd
```

**Notes:**
- `grub-service` is the harder one to find — its name looks plausible. `sillyevilcronjob` is intentionally obvious.
- Blue team often forgets to check `/etc/cron.d/` — they look at user crontabs first.
- The masking means restarting the service is not enough; they must unmask before the service will come back.

---

## 4 — Multi-Location Persistence (`CCDC_Linux_Persistence_PlantsVsZerodays.sh`)

**What it does:**
Deploys a payload script (`inject_evil_service.sh`, which you provide) into **five separate startup locations**:

| # | Location | Trigger |
|---|---|---|
| 1 | `/etc/rc.local` → `/usr/local/lib/.sysinit-helper` | Every boot (SysV shim) |
| 2 | `/etc/profile.d/99-sysenv-init.sh` → `/usr/local/lib/.sysenv-init` | Every root login shell |
| 3 | `/etc/systemd/system/sys-khelper-init.service` → `/usr/local/lib/.khelper-init` | Every boot (systemd oneshot) |
| 4 | `/etc/cron.d/syslogd-helper` → `/usr/local/lib/.syslogd-helper` | `@reboot` via cron |
| 5 | `/root/.bashrc` → `/usr/local/lib/.sysnet-diag` | Every interactive root bash session |

All payload copies are hidden with dot-prefix names inside `/usr/local/lib/`.

**Run it:**
```bash
sudo bash SetupScripts/linux/CCDC_Linux_Persistence_PlantsVsZerodays.sh /path/to/inject_evil_service.sh
```

**Blue team must find and remove ALL of:**
```
/etc/rc.local                              (or clear the payload call from it)
/usr/local/lib/.sysinit-helper
/etc/profile.d/99-sysenv-init.sh
/usr/local/lib/.sysenv-init
/etc/systemd/system/sys-khelper-init.service
/usr/local/lib/.khelper-init
/etc/cron.d/syslogd-helper
/usr/local/lib/.syslogd-helper
/root/.bashrc                              (remove the __sysnet_diag_hook__ block)
/usr/local/lib/.sysnet-diag
```
```bash
systemctl disable sys-khelper-init.service
systemctl daemon-reload
```

**Notes:**
- Script header says "UNTESTED" — dry-run on a VM before competition day.
- The payload copies all have inconspicuous dot-prefix names — blue team must `ls -la /usr/local/lib/` to see them.
- If blue team only finds 3 of 5, the payload keeps coming back on every reboot/login. This is the point.
- Systemd unit description: `"Kernel subsystem helper initialisation"` — looks legitimate.

---

## Quick Reference — What Blue Team Must Check

```
/etc/cron.d/
/etc/profile.d/
/etc/rc.local
/etc/systemd/system/
/etc/sudoers.d/
/usr/local/lib/       ← dot-prefix files (use ls -la)
/root/.bashrc
/opt/web-php/
/etc/passwd + /etc/shadow  ← check immutable bit with lsattr
```

Check immutable bits:
```bash
lsattr /etc/passwd /etc/shadow
lsattr /etc/sudoers.d/
```
