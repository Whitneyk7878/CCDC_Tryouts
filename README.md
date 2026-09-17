# CCDC Tryout — Red Team Scripts

Attack scripts for the Cyber@Stout CCDC tryout. Organized into **setup scripts** (run once on initial access to plant persistence) and **runtime scripts** (run during the competition to degrade blue team services).

> **Platform coverage:** Linux ✅ · Windows ✅ (setup only)

---

## Repository Layout

```
.
├── SetupScripts/
│   ├── linux/          ← Persistence, users, services, cron (Bash)
│   └── windows/        ← Persistence, users, scheduled tasks, web shell (PowerShell)
├── RuntimeScripts/
│   ├── linux/          ← Escalating service disruption (Bash)
│   └── windows/        ← (in progress)
└── docs/
    └── linux/
        ├── README.md              ← Linux scripts quick-reference
        ├── setup-playbook.md      ← How/when to run setup scripts
        └── runtime-playbook.md    ← How/when to run runtime scripts
```

---

## Linux Scripts

### SetupScripts/linux/ — run once on initial access

| Script | What it does |
|---|---|
| `CCDC_Linux_Users_HomeIntruders.sh` | Creates 3 backdoor sudo accounts; sets `/etc/passwd` + `/etc/shadow` immutable |
| `CCDC_Linux_WebShell_OopsAllWebShells.sh` | Installs a rogue PHP service (`web-php`) on port 8888 running as root |
| `CCDC_Linux_CronJobs_ImGonnaCron.sh` | Plants 2 cron jobs in `/etc/cron.d/` that stop+mask legit services every 3–5 min |
| `CCDC_Linux_Persistence_PlantsVsZerodays.sh` | Deploys a payload to 5 separate startup locations across the system |

### RuntimeScripts/linux/ — run during the competition

| Script | Impact | Reversible? |
|---|---|---|
| `00_drop_service.sh` | Stop + disable apache2, dovecot, postfix, splunkd | ✅ Yes |
| `10_mask_service.sh` | Mask the same services (harder to start back up) | ✅ Yes |
| `20_block_with_firewall.sh` | Drop inbound traffic on ports 25/80/110/143/443/8000 | ✅ Yes |
| `30_delete_services.sh` | Purge packages + delete all config/data/logs | ⚠️ No |
| `40_nyan_hell.sh` | Replace UEFI bootloader → host bricks on reboot | 💀 No |

Run runtime scripts in order (00 → 40) to escalate impact. See [`docs/linux/runtime-playbook.md`](docs/linux/runtime-playbook.md) for timing guidance.

---

## Windows Scripts

### SetupScripts/windows/ — run once on initial access

| Script | What it does |
|---|---|
| `CCDC_Windows_Users_UsersAreInYourWalls.ps1` | Creates backdoor admin accounts |
| `CCDC_Windows_Persistence_ClusterBombShells.ps1` | Plants persistent payload in multiple startup locations |
| `CCDC_Windows__ScheduledTasks_ScheduledTaskinator.ps1` | Creates malicious scheduled tasks |
| `CCDC_Windows_WebShell_SheWebShellOnMyIIS.ps1` | Deploys a web shell on IIS |

---

## Playbooks

Full operational details — prerequisites, execution steps, what blue team has to do to clean up — are in `docs/`:

- **[docs/linux/setup-playbook.md](docs/linux/setup-playbook.md)** — Linux setup scripts (order, how to run, blue team recovery steps)
- **[docs/linux/runtime-playbook.md](docs/linux/runtime-playbook.md)** — Linux runtime scripts (escalation ladder, timing, caveats)

---

## Requirements

All Linux scripts require **root** (`sudo`). All Windows scripts require an **Administrator** shell.

Linux targets must be **Debian/Ubuntu**-based. The `40_nyan_hell.sh` script additionally requires UEFI boot mode and internet access from the target.
