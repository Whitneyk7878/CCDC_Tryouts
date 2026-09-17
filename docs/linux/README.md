# Linux Red Team Playbooks — CCDC Tryout

Operational playbooks for the Linux red team track.

## Playbooks

| File | Phase | Scripts covered |
|---|---|---|
| [setup-playbook.md](setup-playbook.md) | Pre-game / initial access | `SetupScripts/linux/` |
| [runtime-playbook.md](runtime-playbook.md) | In-game / active attack | `RuntimeScripts/linux/` |

## High-Level Flow

```
1. Get root on target
2. Run setup scripts (users → web service → cron jobs → persistence)
3. During competition: escalate through runtime scripts 00 → 10 → 20 → 30 → 40
```

## Scripts at a Glance

### SetupScripts/linux/
| Script | What it plants |
|---|---|
| `CCDC_Linux_Users_HomeIntruders.sh` | 3 sudo backdoor accounts + immutable /etc/passwd |
| `CCDC_Linux_WebShell_OopsAllWebShells.sh` | Rogue PHP service on port 8888 |
| `CCDC_Linux_CronJobs_ImGonnaCron.sh` | 2 cron jobs that keep killing legit services |
| `CCDC_Linux_Persistence_PlantsVsZerodays.sh` | Payload in 5 startup locations |

### RuntimeScripts/linux/
| Script | Impact |
|---|---|
| `00_drop_service.sh` | Stop + disable apache2/dovecot/postfix/splunk |
| `10_mask_service.sh` | Mask services (harder to start back up) |
| `20_block_with_firewall.sh` | Drop ports 25/80/110/143/443/8000 |
| `30_delete_services.sh` | Purge packages + delete all data ⚠️ irreversible |
| `40_nyan_hell.sh` | Replace UEFI bootloader → host bricks on reboot 💀 |
