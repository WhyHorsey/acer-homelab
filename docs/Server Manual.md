# Acer Server — User Manual / Runbook

**Owner:** WhyHorsey  
**Last reviewed:** 2026-09-24  
**Host:** `acer-server`  
**OS:** Debian 13 Trixie (headless)  
**Primary purpose:** home music server + Soulseek/Explo automation + general homelab

> This document is the practical memory of the server: what is running, where it lives, why it is configured that way, what to check, and how to recover it.
>
> **Rule of thumb:** before changing something, understand whether it affects the host, a container, a bind-mounted file, a network path, or a client device. Prefer read-only checks first.

**Contents**:

[0. Quick Reference — “I forgot everything, what do I do?”](#0.%20Quick%20Reference%20—%20“I%20forgot%20everything,%20what%20do%20I%20do?”)
[1. Architecture / Mental Model](#1.%20Architecture%20/%20Mental%20Model)
[2. Hardware / Host Baseline](#2.%20Hardware%20/%20Host%20Baseline)
[3. Services and Where They Live](#3.%20Services%20and%20Where%20They%20Live)
[4. Zenbook / Backup Side](#4.%20Zenbook%20/%20Backup%20Side)
[5. Routine Maintenance Schedule](#5.%20Routine%20Maintenance%20Schedule)
[6. Command Cheat Sheet](#6.%20Command%20Cheat%20Sheet)
[7. Config Notes — Why Things Are the Way They Are](#7.%20Config%20Notes%20—%20Why%20Things%20Are%20the%20Way%20They%20Are)
[8. Glossary — Build the Mental Image](#8.%20Glossary%20—%20Build%20the%20Mental%20Image)
[9. Known Non-Fatal Issues / “We Are Leaving This Alone For Now”](#9.%20Known%20Non-Fatal%20Issues%20/%20“We%20Are%20Leaving%20This%20Alone%20For%20Now”)
[10. Security Notes](#10.%20Security%20Notes)
[11. Recovery Playbooks](#11.%20Recovery%20Playbooks)
[12. Final Pre-Departure Checklist](#12.%20Final%20Pre-Departure%20Checklist)
[13. Future Plans / Roadmap](#13.%20Future%20Plans%20/%20Roadmap)
[14. Wishlist / Possible Future Services](#14.%20Wishlist%20/%20Possible%20Future%20Services)
[15. Backup Philosophy](#15.%20Backup%20Philosophy)
[16. “Do Not Do This Casually” List](#16.%20“Do%20Not%20Do%20This%20Casually”%20List)
[17. Official Documentation References](#17.%20Official%20Documentation%20References)
[18. Current “Known Good” Snapshot — 2026-09-24](#18.%20Current%20“Known%20Good”%20Snapshot%20—%202026-09-24)


---

## 0. Quick Reference — “I forgot everything, what do I do?”

### Server addresses

| Purpose | Address |
|---|---|
| Acer LAN | `192.168.x.x` |
| Acer Tailscale | `100.x.x.x` |
| Router LAN | `192.168.0.1` |

### Main services

| Service | Host port | Access |
|---|---:|---|
| Homepage | `3000` | `http://100.x.x.x:3000` |
| Navidrome | `4533` | `http://100.x.x.x:4533` |
| slskd | `5030` / `5031` / `50300` | `http://100.x.x.x:5030` for Web UI |
| Explo | `7288` | `http://100.x.x.x:7288` |

### Main directories on Acer

```text
/srv/containers/
├── homepage/
├── navidrome/
├── slskd/
└── explo/

/srv/media/music/              # main music library
/srv/media/music/explo/        # Explo-managed subfolder
```

### Most useful commands

```bash
# quick Docker overview (alias created in ~/.bashrc)
dockps

# system health
uptime
free -h
df -h /
sensors
systemctl --failed --no-legend

# Docker
sudo docker ps
sudo docker stats --no-stream
sudo docker system df

# Compose service state — run from the service directory
sudo docker compose ps
sudo docker compose logs --tail=100

# Network / Tailscale
ip -br a
tailscale status
sudo systemctl is-active tailscaled
```

### Remote access from outside home

Install and sign into **Tailscale on the client device**. Then use the Acer Tailscale IP (`100.x.x.x`) for apps and the existing SSH alias for SSH:

```bash
ssh acer-server
```

You do **not** need the Acer's LAN address `192.168.x.x` when you are away from home.

---

# 1. Architecture / Mental Model

## 1.1 The whole system

```text
                                INTERNET
                                    │
                         ┌──────────┴──────────┐
                         │ Tailscale / clients  │
                         └──────────┬──────────┘
                                    │
                             Home Router
                              192.168.0.1
                                    │
                           Wi-Fi 192.168.x.x
                                    │
                         ┌──────────▼──────────┐
                         │      Acer Server    │
                         │   Debian 13 Trixie  │
                         │  192.168.x.x      │
                         │  100.x.x.x      │
                         └──────────┬──────────┘
                                    │
                              Docker Engine
                                    │
           ┌────────────────────────┼────────────────────────┐
           │                        │                        │
      Homepage :3000          Navidrome :4533          slskd :5030+
           │                        │                        │
           │                   /srv/media/music             │
           │                        │                        │
           │                        └────────────┐           │
           │                                     │           │
           │                                  ListenBrainz  │
           │                                     ▲           │
           │                                     │ scrobble  │
           │                                     │           │
           │                                  Navidrome     │
           │                                     │           │
           │                                  playlists     │
           │                                     │           │
           │                                     ▼           │
           │                                    Explo :7288  │
           │                                      │          │
           │                                      │ API      │
           │                                      ▼          │
           │                                    slskd       │
           │                                      │          │
           │                                 Soulseek       │
           │                                      │          │
           │                                      ▼          │
           │                         /srv/containers/slskd/  │
           │                              app/downloads      │
           │                                      │          │
           │                                      ▼          │
           │                            Explo migration      │
           │                                      │          │
           │                                      ▼          │
           │                          /srv/media/music/explo │
           │                                      │          │
           └──────────────────────────────────────┴──────────┘

                    Zenbook (Fedora)
                    ├── SSH client
                    ├── Tailscale client
                    └── daily Navidrome DB backup pull
                         ↓
                    /mnt/the-big/Fedora/server-backups/navidrome/
```

## 1.2 Two important “address worlds”

```text
192.168.x.x
= Acer's normal LAN address at home.
= Useful only when the client can reach the home LAN.

100.x.x.x
= Acer's Tailscale address.
= Use this from a remote network when the client also has Tailscale.
```

Tailscale forms an encrypted overlay network between enrolled devices. It may use a direct peer-to-peer path or a relay (DERP) when direct connectivity is not possible. Direct is normally preferred for performance. See the official Tailscale connection-type documentation.

**MagicSock is not MagicDNS.** MagicSock is the networking/peer-path machinery; MagicDNS is DNS/name resolution for the tailnet.

---

# 2. Hardware / Host Baseline

## Hardware

- Acer Aspire 4739
- Intel Core i3-370M (2C/4T)
- 4 GB DDR3 (~3.5 GiB usable)
- Kingston A400 480 GB SATA SSD
- Wi-Fi: Qualcomm Atheros AR9285 (`ath9k`)
- Ethernet: Qualcomm Atheros AR8152 100 Mbps
- Headless Debian 13 Trixie

## Power / lid behavior

- Server is intended to run plugged in 24/7.
- Lid close is intentionally ignored by systemd-logind.
- Wi-Fi/power reliability workaround is in GRUB:

```text
pcie_aspm=off
```

Do not remove it casually; it was added because the AR9285 Wi-Fi link previously failed when AC power was removed.

## Current power findings (2026-09-24)

- AC adapter: online (`ACAD online: 1`)
- Battery: present, 100%, status `Full`
- No AC offline event seen in the inspected journal
- One ACPI firmware warning was observed:

```text
ACPI: battery: [Firmware Bug]: (dis)charge rate invalid.
```

This was treated as a firmware/ACPI quirk, not proof of charger failure. Continue to watch for actual AC online/offline transitions.

## Typical healthy resource baseline

A recent good snapshot:

- load average around `0.02–0.07`
- ~2.4 GiB RAM available
- swap essentially unused
- root filesystem ~2% used
- temperatures roughly mid-40s to low-50s °C
- no failed systemd services

**Do not judge RAM health from `free` alone.** `available` is the more useful number on Linux because the kernel uses RAM for cache.

---

# 3. Services and Where They Live

## 3.1 Acer: Docker services

### Homepage

**Host directory**

```text
/srv/containers/homepage/
```

**Port**

```text
3000 -> 3000
```

**Role**

- Main dashboard/front page for the homelab.
- Service cards and UI config are in `config/services.yaml`, `settings.yaml`, etc.

**Important files**

```text
/srv/containers/homepage/compose.yaml
/srv/containers/homepage/config/services.yaml
/srv/containers/homepage/config/settings.yaml
/srv/containers/homepage/config/widgets.yaml
/srv/containers/homepage/custom.css / custom.js equivalent paths as currently configured
/srv/containers/homepage/icons/
```

**Current state:** healthy.

---

### Navidrome

**Host directory**

```text
/srv/containers/navidrome/
```

**Port**

```text
4533 -> 4533
```

**Music library**

```text
/srv/media/music
```

**Persistent data**

```text
/srv/containers/navidrome/data/
```

**Database**

```text
/srv/containers/navidrome/data/navidrome.db
```

**Important:** `navidrome.db-wal` and `navidrome.db-shm` are normal SQLite files while the DB is active. Do not delete them manually.

**Backup directory**

```text
/srv/containers/navidrome/backup/
```

**Automatic DB backup**

- schedule: daily at midnight in the server's Navidrome timezone
- keep count: 7
- backups are DB-only; they do **not** back up the music library or application config

See official Navidrome backup documentation.

**Current state:** working; music streaming has been verified from the Zenbook client.

---

### slskd

**Host directory**

```text
/srv/containers/slskd/
```

**Compose**

```text
/srv/containers/slskd/compose.yaml
```

**Persistent app data**

```text
/srv/containers/slskd/app/
```

**Ports**

```text
5030 -> 5030  # web UI
5031 -> 5031  # HTTPS endpoint
50300 -> 50300 # Soulseek listening port
```

**Container user**

```text
1000:1000
```

**Download paths inside container**

```text
/app/incomplete
/app/downloads
```

**Host equivalents**

```text
/srv/containers/slskd/app/incomplete
/srv/containers/slskd/app/downloads
```

**Shared music library**

```text
Host:      /srv/media/music
Container: /srv/media/music
Mode:      read-only
```

**Share path in slskd**

```text
/srv/media/music
```

This works because the host path is mounted into the container at the same absolute path and marked read-only. slskd can read/share it but should not modify the library through that mount.

**Important config**

```text
/srv/containers/slskd/app/slskd.yml
```

The file currently contains the active Soulseek username/password and the Explo API key. **Do not put secrets in this manual.**

The Compose file also contains Web UI and Soulseek environment variables. Because remote configuration is enabled and `slskd.yml` is actively used, treat the YAML file as the practical source of truth and avoid editing both representations casually.

**Known security note**

`SLSKD_REMOTE_CONFIGURATION=true` is enabled and the Explo API key currently has a broad CIDR (`0.0.0.0/0,::/0`). This is acceptable only while the service is kept within the intended trusted network/Tailscale environment. Before any public exposure, harden this configuration.

**Current state:** healthy and connected to the Soulseek account.

---

### Explo

**Host directory**

```text
/srv/containers/explo/
```

**Port**

```text
7288 -> 7288
```

**Actual current persistent layout**

```text
/srv/containers/explo/
├── compose.yaml
├── config/                 # currently empty / unused
└── explo/
    ├── config/
    │   ├── cache/
    │   └── logs/
    └── .env/
        └── .env            # actual env file is here
```

The nesting is awkward, but it is working. **Do not restructure it casually.**

**Current mounts (verified with `docker inspect`)**

```text
/srv/media/music/explo              -> /data
/srv/containers/slskd/app/downloads -> /slskd
/srv/containers/explo/explo/.env    -> /opt/explo/.env
/srv/containers/explo/explo/config -> /opt/explo/config
```

**Core configuration currently includes**

```text
TZ=Asia/Makassar
LISTENBRAINZ_DISCOVERY=playlist
SYSTEM_URL=http://100.x.x.x:4533
EXPLO_SYSTEM=subsonic
PUBLIC_PLAYLIST=true
DOWNLOAD_SERVICES=slskd,youtube
SLSKD_MIGRATE_DOWNLOADS=true
USE_SUBDIRECTORY=true
TRACK_EXTENSION=flac
```

Secrets are intentionally omitted from this manual.

**Role**

Explo connects ListenBrainz recommendations/playlists to the music server. It can use slskd/YouTube as download sources and can migrate slskd downloads into its music destination.

Official Explo docs say the `/slskd/` mapping is required when using slskd migration, and recommend pointing Explo at a subfolder of the music library. See Explo's Docker/Getting Started documentation.

**Current intended pipeline**

```text
Navidrome scrobble
      ↓
ListenBrainz
      ↓
generated playlist / discovery
      ↓
Explo
      ↓
slskd / YouTube downloader
      ↓
/srv/containers/slskd/app/downloads
      ↓
Explo migration
      ↓
/srv/media/music/explo
      ↓
Navidrome library
```

**Current state:** running; ListenBrainz scrobbling into ListenBrainz is confirmed; first Daily Jams automation still needs a successful generation/run cycle.

---

# 4. Zenbook / Backup Side

The Fedora Zenbook is not the music server. It is primarily the **backup pull client and remote administration workstation**.

## Navidrome backup pull

### Service files

```text
~/.local/bin/pull-acer-navidrome-backup
~/.config/systemd/user/acer-navidrome-backup.service
~/.config/systemd/user/acer-navidrome-backup.timer
```

### Destination

```text
/mnt/the-big/Fedora/server-backups/navidrome/
```

### Mechanism

The script uses rsync over SSH via the `acer-backup` SSH host alias. The alias currently resolves to the Acer Tailscale IP:

```text
acer-backup -> 100.x.x.x
```

### Expected timer behavior

```text
Daily at 12:00 WITA
```

The `.service` is `Type=oneshot`, so after a successful run its status normally becomes:

```text
inactive (dead)
```

That is normal. The important unit for recurring scheduling is the `.timer`, which should remain:

```text
active (waiting)
```

### Known wake-from-sleep failure mode

On 2026-09-24 the backup failed exactly when the Zenbook woke from about 2h19m of sleep. Tailscale logged a major link change, temporary DNS/control-plane failures, interface rebinding, and a timeout to Acer SSH. A manual retry after Tailscale recovered succeeded.

**Interpretation:** the backup design is currently healthy, but the job is not yet perfectly resilient to “Zenbook wakes exactly when the timer fires.”

**Update (2026-09-26):** Fixed by adding a line in the config. `~/.config/systemd/user/acer-navidrome-backup.service`

```
[Unit]
StartLimitIntervalSec=10min
StartLimitBurst=6

[Service]
Restart=on-failure
RestartSec=30s
```

---

# 5. Routine Maintenance Schedule

## Daily — normally passive

**You do not need to manually touch the server every day.** The system is designed to run unattended.

Optional 30-second glance:

```bash
dockps
```

Look for:

- all four containers present
- no container in `Restarting` / `Exited`
- slskd says `healthy`
- Homepage says `healthy`

For a remote sanity check:

```bash
tailscale status
```

No daily reboot is required.

---

## Weekly

### 1. System health

```bash
uptime
free -h
df -h /
sensors
systemctl --failed --no-legend
```

### 2. Docker health

```bash
sudo docker ps
sudo docker stats --no-stream
```

Do not restart healthy containers “just because.” Restart when updating, changing config, or troubleshooting.

### 3. Backup verification

On the **Zenbook**:

```bash
systemctl --user list-timers --all | grep acer-navidrome
systemctl --user status acer-navidrome-backup.timer
ls -lh /mnt/the-big/Fedora/server-backups/navidrome/
```

Check that there is a recent `.db` file.

### 4. Storage

```bash
sudo smartctl -H /dev/sda
```

Expected:

```text
SMART overall-health self-assessment test result: PASSED
```

### 5. SSD TRIM

```bash
systemctl list-timers --all | grep fstrim
```

`fstrim.timer` is expected to remain enabled and scheduled weekly.

---

## Monthly / “when convenient”

### 1. Manual package maintenance

Automatic package-list updates and unattended upgrades are already enabled. A manual check is still useful periodically or before planned changes:

```bash
sudo apt update
sudo apt full-upgrade
```

This changes packages, so read the proposed transaction before confirming.

### 2. Check Docker disk use

```bash
sudo docker system df
```

Do **not** blindly run global `docker system prune` commands. Containers/images/volumes may belong to other services.

### 3. Check logs for recurring problems

```bash
sudo docker compose logs --tail=200
```

Run this from a service directory if you want logs for one Compose project.

### 4. Consider a backup restore test

The Navidrome restore was already successfully tested once. Repeat after major changes, or periodically if you want extra assurance.

---

# 6. Command Cheat Sheet

## 6.1 System health

### Uptime / load

```bash
uptime
```

Read-only. Shows how long the server has been running and recent load average.

### RAM

```bash
free -h
```

Read-only. Prefer `available` over `free` for judging whether RAM is actually under pressure.

### Disk

```bash
df -h /
```

Read-only. Shows filesystem capacity and free space.

### Temperatures

```bash
sensors
```

Read-only sensor values.

### Failed systemd services

```bash
systemctl --failed --no-legend
```

Read-only. Empty output is good.

### Full systemd failed-unit details

```bash
systemctl --failed
```

Useful when the short view shows something.

---

## 6.2 Docker basics

### Show running containers

```bash
sudo docker ps
```

Only running containers.

### Show all containers

```bash
sudo docker ps -a
```

Useful for finding exited containers.

### Quick formatted service list

```bash
dockps
```

User alias for the long `docker ps --format ...` command.

### Resource usage snapshot

```bash
sudo docker stats --no-stream
```

One snapshot, then exits.

### Disk usage

```bash
sudo docker system df
```

Shows Docker disk consumption. Read-only.

### Enter service directory and inspect Compose

Example for Navidrome:

```bash
cd /srv/containers/navidrome
sudo docker compose ps
```

### Compose logs

```bash
sudo docker compose logs --tail=100
```

or one service:

```bash
sudo docker compose logs --tail=100 navidrome
```

### Follow logs live

```bash
sudo docker compose logs -f navidrome
```

Press `Ctrl+C` to stop following. This does not stop the container.

### Restart one container

```bash
sudo docker compose restart navidrome
```

Use when you changed environment/config that requires a restart or when troubleshooting. It does not recreate the container.

### Stop without removing the container

```bash
sudo docker compose stop
```

Useful when you want to bring a stack down temporarily without deleting its containers.

### Stop and remove Compose containers/network

```bash
sudo docker compose down
```

This removes Compose-managed containers and its network. Bind-mounted host data remains.

### Start/create the stack

```bash
sudo docker compose up -d
```

Creates missing resources and starts the services in the background.

### Validate Compose configuration

```bash
sudo docker compose config
```

Very useful before restarting after editing YAML.

### Pull newer images

```bash
sudo docker compose pull
```

Downloads newer images but does not replace running containers by itself.

A common update sequence:

```bash
sudo docker compose pull
sudo docker compose up -d
```

For stateful services, consider a database/application backup before major updates.

---

## 6.3 rsync

### Dry run first — preferred

```bash
rsync -avhn SOURCE/ DEST/
```

Flags:

- `-a` archive-ish copy behavior (recursive + preserve common metadata)
- `-v` verbose
- `-h` human-readable
- `-n` **dry run** — show what would happen without changing files

### Real sync

```bash
rsync -avh SOURCE/ DEST/
```

Be precise about **source first, destination second**.

### Trailing slash mental model

```text
SOURCE/    = copy the CONTENTS of SOURCE
SOURCE     = copy the DIRECTORY itself into DEST
```

Example:

```bash
rsync -avhn /mnt/the-big/Fedora/Music/ /srv/media/music/
```

means “compare the contents of Fedora `Music` with Acer `music`.”

### Destructive option: `--delete`

```bash
rsync -avh --delete SOURCE/ DEST/
```

**Danger:** files existing only on the destination may be deleted.

Always dry-run first:

```bash
rsync -avhn --delete SOURCE/ DEST/
```

Do not use `--delete` until you are completely sure which side is source and which side is destination.

---

## 6.4 Tailscale / network

### Interface summary

```bash
ip -br a
```

Shows LAN, Tailscale, Docker bridges, etc.

Do not worry merely because `enp1s0` is `DOWN` when no Ethernet cable is plugged in. `docker0` can also be `DOWN` while user-defined Docker bridges are `UP`.

### Tailscale peer status

```bash
tailscale status
```

### Tailscale daemon status

```bash
systemctl is-active tailscaled
```

Expected:

```text
active
```

### Test a Tailscale peer

```bash
tailscale ping 100.x.x.x
```

### Test local LAN reachability

```bash
ping -c 20 192.168.0.1
```

### Test Acer from the Zenbook using Tailscale

```bash
ping -c 20 100.x.x.x
```

### SSH to Acer

From Zenbook or another client with the SSH alias:

```bash
ssh acer-server
```

### Inspect SSH alias resolution

```bash
ssh -G acer-backup | grep '^hostname '
```

Current expected result:

```text
hostname 100.x.x.x
```

---

## 6.5 Navidrome

Run these from:

```text
/srv/containers/navidrome
```

### Normal library scan

```bash
sudo docker compose run --rm navidrome scan
```

Use this for normal changes/new files.

### Full library scan

```bash
sudo docker compose run --rm navidrome scan --full
```

`--full` checks every folder and ignores modification times. Do not run full scans for every tiny change; use the normal scan when appropriate.

### Database health check

```bash
sudo docker compose run --rm navidrome doctor
```

`doctor` checks database integrity and foreign keys without changing the database.

### Manual database backup

```bash
sudo docker compose run --rm navidrome backup create
```

### List backup files on host

```bash
ls -lh /srv/containers/navidrome/backup/
```

### Restore a database backup — destructive

**STOP Navidrome first.** A restore replaces the current database; changes made after the backup are lost.

```bash
cd /srv/containers/navidrome
sudo docker compose stop navidrome
sudo docker compose run --rm navidrome backup restore --backup-file BACKUP_FILENAME.db
sudo docker compose start navidrome
```

Never use `--force` until you understand the consequences; the normal command intentionally asks for confirmation.

---

## 6.6 Navidrome backup pull on Zenbook

### See timer

```bash
systemctl --user list-timers --all | grep acer-navidrome
```

### Timer status

```bash
systemctl --user status acer-navidrome-backup.timer
```

Expected:

```text
active (waiting)
```

### Last service result

```bash
systemctl --user status acer-navidrome-backup.service
```

A successful one-shot service normally ends at:

```text
inactive (dead)
```

with `status=0/SUCCESS`.

### Service journal

```bash
journalctl --user -u acer-navidrome-backup.service
```

### Today's entries

```bash
journalctl --user -u acer-navidrome-backup.service --since today
```

### Manual backup retry

```bash
systemctl --user start acer-navidrome-backup.service
```

Then:

```bash
systemctl --user status acer-navidrome-backup.service
ls -lh /mnt/the-big/Fedora/server-backups/navidrome/
```

### If backup fails with rsync 255 after Zenbook sleep

Use this order:

```bash
ssh -o ConnectTimeout=10 acer-backup true
tailscale ping 100.x.x.x
systemctl --user start acer-navidrome-backup.service
systemctl --user status acer-navidrome-backup.service
```

If SSH/Tailscale is healthy and the retry succeeds, the earlier failure was likely a transient post-sleep network/Tailscale recovery event.

---

## 6.7 slskd

Run these from:

```text
/srv/containers/slskd
```

### Status

```bash
sudo docker compose ps
```

### Logs

```bash
sudo docker compose logs --tail=100 slskd
```

### Current persistent data

```bash
ls -lah /srv/containers/slskd/app
```

### Download folder

```bash
ls -lah /srv/containers/slskd/app/downloads
```

### Incomplete downloads

```bash
ls -lah /srv/containers/slskd/app/incomplete
```

Do not delete incomplete files blindly; they may be active transfers.

### Config backup

```text
/srv/containers/slskd/app/slskd.yml.bak
```

Keep this file private because it can contain secrets.

---

## 6.8 Explo

Run these from:

```text
/srv/containers/explo
```

### Status

```bash
sudo docker compose ps
```

### Logs

```bash
sudo docker compose logs --tail=100 explo
```

### Restart after `.env` changes

```bash
sudo docker compose restart explo
```

### Inspect actual mounts

```bash
sudo docker inspect explo --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
```

Expected important mappings:

```text
/srv/media/music/explo              -> /data
/srv/containers/slskd/app/downloads -> /slskd
```

### Current Explo schedules (WITA)

```text
Daily Jams          01:15 every day
Weekly Jams         Monday 00:30
Weekly Exploration  Tuesday 00:15
```

The schedule is an Explo-side fetch/run schedule. It does not force ListenBrainz to generate a playlist earlier than ListenBrainz itself does.

---

## 6.9 Homepage

Run these from:

```text
/srv/containers/homepage
```

### Status

```bash
sudo docker compose ps
```

### Logs

```bash
sudo docker compose logs --tail=100 homepage
```

### Main service config

```text
config/services.yaml
```

For a service card, the core mental model is:

```yaml
- Service Name:
    icon: ...
    href: ...
    description: ...
```

Remember: `href` is resolved by the browser. `localhost` refers to the **client device**, not the Acer.

---

# 7. Config Notes — Why Things Are the Way They Are

## 7.1 Navidrome music mount is read-only

The main library is mounted into Navidrome as read-only because Navidrome needs to read/scan/stream the library, not modify the underlying files as part of ordinary operation.

## 7.2 slskd music mount is read-only

Same concept: slskd shares `/srv/media/music`, but should not be able to rewrite the main music library through that mount.

## 7.3 slskd download directory is inside `/app`

The official Docker image uses `/app` as its application directory. The current host mapping makes:

```text
/srv/containers/slskd/app/downloads
```

become:

```text
/app/downloads
```

This is why Explo can mount the host download folder independently as:

```text
/slskd
```

## 7.4 Explo `/data` is inside the music library

Explo is pointed at:

```text
/srv/media/music/explo
```

rather than the entire music library. This isolates Explo-generated/imported content in its own subfolder while still keeping everything under Navidrome's music root.

## 7.5 Explo uses Subsonic because Navidrome exposes that API

Explo's `EXPLO_SYSTEM=subsonic` lets it interact with Navidrome through a Subsonic-compatible API. This is why `SYSTEM_URL` points at Navidrome's port 4533.

## 7.6 `SLSKD_MIGRATE_DOWNLOADS=true`

This tells Explo to process completed slskd downloads for migration into its `/data` destination. The current `/slskd` mount is what gives Explo access to the download folder.

## 7.7 `USE_SUBDIRECTORY=true`

This is intended to organize imported tracks into a playlist-named subdirectory rather than dumping everything into one flat folder.

## 7.8 `TRACK_EXTENSION=flac`

The current Explo preference is to use FLAC for imported tracks where the chosen downloader supports it.

## 7.9 Tailscale instead of public port forwarding

Current remote-access design is:

```text
Client with Tailscale
        ↓
   Tailscale network
        ↓
Acer 100.x.x.x
        ↓
service port
```

No router port-forwarding is currently required for personal remote access.

---

# 8. Glossary — Build the Mental Image

## Host

The physical/VM machine actually running everything.

Here:

```text
acer-server
```

## Container

An isolated userspace/process environment that shares the host kernel. It is not automatically a VM and it is not cloud infrastructure.

A container can be destroyed and recreated while its persistent data remains on the host.

## Image

The packaged application filesystem/template used to create containers.

Examples:

```text
deluan/navidrome:latest
ghcr.io/gethomepage/homepage:latest
slskd/slskd
ghcr.io/lumepart/explo:latest
```

## Docker Compose

A declarative description of one or more containers, their ports, mounts, environment variables, and policies.

Think:

```text
compose.yaml = recipe
container     = cooked instance
image         = package/template
```

## Bind mount

A host directory exposed inside a container.

Example:

```text
/srv/media/music -> /music
```

The data still fundamentally lives on the Acer host filesystem.

## Published port

The `HOST:CONTAINER` mapping in Compose.

Example:

```yaml
"4533:4533"
```

means “listen on Acer host port 4533 and forward that traffic to port 4533 in the container.”

## Docker bridge

A virtual network connecting containers to each other and the host.

The many `br-*` and `veth*` interfaces seen in `ip -br a` are normal parts of Docker networking.

## `veth`

A virtual Ethernet pair. One side is associated with a container network namespace; the other side is on the host bridge.

## Daemon / service

A background process that stays available to do work.

Examples:

```text
docker.service
tailscaled
sshd
```

## systemd service

A unit describing a process/job systemd can start/stop/status.

## systemd timer

A scheduler for systemd services. Your Zenbook backup uses one.

Important:

```text
timer = scheduler
service = thing being run
```

## rsync

A file synchronization/copy program. It compares source and destination and transfers what is needed. Source/destination order matters.

## SQLite WAL

SQLite can use `-wal` and `-shm` sidecar files while a DB is active. They are normal. Do not delete them manually.

## Scrobble

A record saying “I listened to this track,” sent from the music client/server to a service such as ListenBrainz.

## ListenBrainz

The external service receiving listening history and generating/distributing music recommendations/playlists.

## Explo

The automation layer connecting ListenBrainz recommendations to the music server and download backends.

## slskd

A headless/web-controlled client for the Soulseek network. In this setup it is the download backend for Explo and can also share the read-only music library.

## Subsonic API

A music-server API that Navidrome implements and Explo can use to authenticate, inspect the library, trigger/observe scans where supported, and manage playlists.

## Tailscale

A WireGuard-based private overlay networking system. It gives enrolled devices stable tailnet addresses and handles NAT traversal/relay selection.

Mental image:

```text
ordinary Internet
      │
      ├──── device A
      │
      └──── device B

Tailscale adds an encrypted virtual network
so A and B can communicate as peers.
```

## Direct Tailscale connection

A peer-to-peer encrypted path between two Tailscale nodes. Usually lowest latency / highest throughput.

## DERP

A Tailscale relay fallback used when direct connectivity cannot be established. It is still encrypted; performance is the main difference.

## MagicDNS

Tailscale DNS/name-resolution functionality. It lets tailnet device names resolve to their Tailscale addresses.

## MagicSock

Tailscale's networking machinery for peer discovery/path selection and packet transport. It is **not** MagicDNS.

## Control plane

The service Tailscale clients use to coordinate membership, keys/routes/endpoints and network state. It is separate from the actual packet path between peers.

## ACPI

Firmware-defined interfaces through which Linux can read things like battery and AC-adapter state.

## `wlp2s0`

The Acer's Wi-Fi network interface.

## `enp1s0`

The Acer's Ethernet interface.

## `docker0` / `br-*`

Docker-managed virtual network interfaces. They are not physical NICs.

---

# 9. Known Non-Fatal Issues / “We Are Leaving This Alone For Now”

## A. Explo's nested `.env/.env` layout

Current actual layout:

```text
/srv/containers/explo/explo/.env/.env
```

This is awkward compared with the cleaner documented layout:

```text
/srv/containers/explo/.env
```

but Explo currently works and the Docker mount has been verified.

**Decision:** leave it alone until there is a planned Explo maintenance window.

---

## B. Empty `/srv/containers/explo/config`

This directory is currently unused. The actual config being mounted is:

```text
/srv/containers/explo/explo/config
```

**Decision:** leave it alone for now.

---

## C. Tailscale DNS warning on phone

The phone showed a “DNS unavailable” warning.

This can affect DNS/name resolution, but it does not automatically mean Tailscale IP connectivity is broken. Accessing Acer directly by `100.x.x.x` does not rely on MagicDNS resolution.

**Decision:** monitor. If the phone cannot resolve tailnet names or cannot reach Tailscale IPs, investigate further.

---

## D. Zenbook backup can fail when waking from sleep

Observed once on 2026-09-24:

```text
sleep
↓
wake
↓
Tailscale major link change / rebind
↓
SSH to Acer times out
↓
rsync exits 255
```

Manual retry succeeded.

**Decision:** current backup system remains usable. Future improvement: add retry/backoff logic so one post-sleep transient does not become a failed daily run.

**Update:** it's fixed now, see [above](#Known%20wake-from-sleep%20failure%20mode).

---

## E. Acer Wi-Fi signal is weak

Observed:

```text
signal: -78 dBm
```

But the LAN ping test showed:

```text
0% packet loss
```

and the server remained connected.

**Decision:** monitor rather than move hardware immediately. If packet loss/disconnects begin, investigate AP position, Wi-Fi channel, or consider Ethernet.

---

## F. ACPI battery “charge rate invalid” warning

Observed once in the journal.

Current evidence shows:

```text
ACAD online = 1
BAT1 = Full
no AC offline event observed
```

**Decision:** monitor actual AC transitions rather than treating this firmware warning as proof of a bad charger.

---

## G. slskd remote configuration / broad API CIDR

Current configuration is intentionally convenient for the current private homelab but would be too permissive for a public-facing setup.

**Decision:** harden before exposing slskd publicly or putting it behind a public reverse proxy.

---

# 10. Security Notes

## Secrets

Never put these into this manual, Git, screenshots, or chat logs:

- Wi-Fi passwords
- SSH private keys
- SSH key passphrases
- Tailscale auth keys
- Soulseek passwords
- slskd API keys
- Explo API keys
- Web UI passwords
- router admin passwords

## Do not expose services casually

Current Docker ports are published on the Acer host interfaces. This is not the same thing as “public Internet access”; the home router currently does not expose these ports through Internet port forwarding.

Before public exposure, revisit:

- firewall policy
- reverse proxy
- TLS/HTTPS
- authentication
- slskd remote configuration
- slskd API key CIDR restriction
- least-privilege API roles
- Tailscale ACLs

---

# 11. Recovery Playbooks

## 11.1 “A container is down”

```bash
sudo docker ps -a
```

Then from its directory:

```bash
sudo docker compose ps
sudo docker compose logs --tail=100 SERVICE_NAME
```

Only after reading the logs:

```bash
sudo docker compose restart SERVICE_NAME
```

or, if configuration/image recreation is needed:

```bash
sudo docker compose up -d
```

---

## 11.2 “Navidrome is up but a new music file is missing”

First verify the file exists on the host:

```bash
ls -lah /srv/media/music/...
```

Then run a normal scan:

```bash
cd /srv/containers/navidrome
sudo docker compose run --rm navidrome scan
```

Use `scan --full` only when the normal scan does not explain the issue.

---

## 11.3 “Navidrome database seems broken”

Run the read-only diagnostic:

```bash
cd /srv/containers/navidrome
sudo docker compose run --rm navidrome doctor
```

Only consider restore after understanding the diagnostic result.

---

## 11.4 “Backup failed”

On Zenbook:

```bash
systemctl --user status acer-navidrome-backup.service
journalctl --user -u acer-navidrome-backup.service --since today
```

Then test:

```bash
ssh -o ConnectTimeout=10 acer-backup true
tailscale ping 100.x.x.x
```

If connectivity is healthy, retry:

```bash
systemctl --user start acer-navidrome-backup.service
```

Verify the new file:

```bash
ls -lh /mnt/the-big/Fedora/server-backups/navidrome/
```

---

## 11.5 “I am away from home and Acer is unreachable”

Work from least disruptive to most disruptive:

```text
1. Check Tailscale on client
2. Try pinging 100.x.x.x
3. Try ssh acer-server
4. If unavailable, check whether Acer itself is offline
5. If Acer is online but LAN networking is broken, suspect the router workaround/history
```

Do not immediately reboot or power off a remote server unless you have a good reason.

---

## 11.6 “The router is acting weird again”

Known historical symptom:

```text
clients can reach the router/internet,
but clients cannot reach each other
```

A router reboot restored client-to-client connectivity.

Current workaround:

```text
automatic router reboot every day at 05:00 WITA
```

If the same symptom returns, test:

```bash
ping -c 20 192.168.x.x
```

from a LAN client.

---

# 12. Final Pre-Departure Checklist

Use this when leaving Acer unattended for a longer period.

## Power

```bash
# verify current state if needed
for p in /sys/class/power_supply/*; do
    echo "=== $(basename "$p") ==="
    [ -f "$p/type" ] && echo "type: $(cat "$p/type")"
    [ -f "$p/online" ] && echo "online: $(cat "$p/online")"
    [ -f "$p/status" ] && echo "status: $(cat "$p/status")"
    [ -f "$p/capacity" ] && echo "capacity: $(cat "$p/capacity")"
done
```

Expected for the current setup:

```text
ACAD: online 1
BAT1: Full / high enough
```

## Server

```bash
uptime
free -h
df -h /
sensors
systemctl --failed --no-legend
```

## Docker

```bash
dockps
```

All four should be present:

```text
homepage
navidrome
slskd
explo
```

## Tailscale

```bash
tailscale status
systemctl is-active tailscaled
```

## Backup

On Zenbook:

```bash
systemctl --user status acer-navidrome-backup.timer
ls -lh /mnt/the-big/Fedora/server-backups/navidrome/
```

If the latest run failed because the Zenbook had just woken from sleep, retry it manually before leaving.

## Final functional checks

- Homepage opens
- Navidrome plays music
- slskd is connected
- Explo UI is running
- Tailscale SSH works

Then stop tinkering. 🙂

---

# 13. Future Plans / Roadmap

## Priority 1 — make the current system boring and reliable

1. Add retry/backoff to the Zenbook backup pull so a post-sleep Tailscale/network transition does not produce a failed daily backup. ([Done](#Known%20wake-from-sleep%20failure%20mode))
2. Keep watching the Acer charger/power behavior.
3. Keep watching the Wi-Fi signal / packet loss.
4. Confirm the first complete ListenBrainz → Explo → slskd → migrate → Navidrome cycle.

## Priority 2 — cleanups that are not urgent

5. Eventually straighten Explo's nested `.env/.env` directory layout.
6. Remove/rename the unused outer `/srv/containers/explo/config` directory once the Explo layout is deliberately migrated.
7. Harden slskd remote configuration and API-key CIDR before any public exposure.
8. Document/automate full music-library backups separately from the Navidrome DB backup.

## Priority 3 — architecture improvements

9. Add a reverse proxy (Nginx or Caddy) only when there is a concrete need.
10. Consider Syncthing or a scheduled rsync system for continuous/automatic library synchronization.
11. Add real monitoring/alerting later if the number of services grows.
12. Consider moving from hosted Tailscale control plane to a self-hosted control plane such as Headscale if vendor dependence becomes unacceptable.

### Tailscale migration principle

Do not build the whole homelab around an assumption that Tailscale is irreplaceable. Keep service access concepts simple:

```text
service IP/port
        ↓
private network path
        ↓
client
```

That makes a future move to Headscale or another WireGuard-based overlay much easier.

---

# 14. Wishlist / Possible Future Services

These are ideas, not commitments:

- Reverse proxy (Nginx/Caddy)
- Syncthing
- Vaultwarden
- Jellyfin
- Minecraft server
- Headscale
- Server monitoring / metrics dashboard
- More automated backups

Do not deploy everything at once. The current goal is a stable core.

---

# 15. Backup Philosophy

The current backup model has two layers for Navidrome:

```text
Layer 1: Navidrome automatically creates DB backups on Acer
Layer 2: Zenbook pulls those DB backups off the Acer
```

This means a failure of the Acer's live database does not automatically destroy every copy.

But remember:

```text
Navidrome DB backup != full server backup
```

The Navidrome built-in backup covers database state such as users/play counts/playlists, not the actual music files or all application configuration.

A fuller disaster-recovery model should eventually back up:

```text
Compose files
Application config
Persistent app data
Navidrome DB backups
Music library
Important scripts
```

The exact backup destination and retention policy still need to be formalized.

---

# 15.1 Backup 101 — Update, Backup, Rollback, Restore

For the full step-by-step upgrade and recovery procedure, see the dedicated runbook:

**[Server Backup 101-Old](Server%20Backup%20101-Old.md)**

Core Navidrome flow:

```text
read release notes
    ↓
create fresh DB backup
    ↓
verify local backup
    ↓
verify Zenbook copy
    ↓
record current version/image
    ↓
`docker compose pull navidrome`
    ↓
`docker compose up -d navidrome`
    ↓
check logs + application
    ↓
only restore DB if diagnosis says the DB itself must be reverted
```

Important current facts:

- Navidrome automatic backups are DB-only; music and config need separate backup coverage.
- Navidrome restore must be done while Navidrome is stopped.
- `docker compose pull` downloads the image but does not deploy it by itself.
- `docker compose up -d` can recreate the service when the image/config changes while preserving mounted persistent data.
- The Navidrome restore process has already been tested successfully in an isolated test instance on 2026-09-23.

See `ACER-SERVER-BACKUP-101.md` for the exact commands, rollback cautions, rsync notes, and recovery sequence.

# 16. “Do Not Do This Casually” List

```text
DO NOT:

- delete navidrome.db-shm / navidrome.db-wal manually
- restore a Navidrome DB while Navidrome is running
- run rsync with --delete without a dry run
- reverse rsync source/destination because of a typo
- delete slskd/incomplete contents blindly
- use docker system prune globally without checking what will be removed
- expose slskd's remote configuration publicly without hardening
- expose API keys broadly without understanding CIDR scope
- reflash router firmware for the wrong hardware revision
- remove pcie_aspm=off without understanding the Wi-Fi power-state regression it was added to prevent
- restructure Explo files just for aesthetics while it is working
```

---

# 17. Official Documentation References

These are the primary references used to build/maintain this manual.

- Docker Compose / bind mounts: https://docs.docker.com/
- Navidrome CLI: https://navidrome.org/docs/usage/admin/cli/
- Navidrome scan: https://navidrome.org/docs/usage/admin/cli/scan/
- Navidrome backup/restore: https://navidrome.org/docs/usage/admin/cli/backup/
- Navidrome automated backup: https://www.navidrome.org/docs/usage/admin/backup/
- slskd configuration: https://github.com/slskd/slskd/blob/master/docs/config.md
- slskd Docker guide: https://github.com/slskd/slskd/blob/master/docs/docker.md
- Explo wiki: https://github.com/LumePart/Explo/wiki
- Explo configuration: https://github.com/LumePart/Explo/wiki/3.-Configuration-Parameters
- Explo getting started: https://github.com/LumePart/Explo/wiki/3.-Getting-Started
- Tailscale connection types: https://tailscale.com/docs/reference/connection-types
- Tailscale firewall/networking: https://tailscale.com/kb/1181/firewalls

---

# 18. Current “Known Good” Snapshot — 2026-09-24

```text
Acer server
├── Debian 13 Trixie                       ✅
├── SSH key login                          ✅
├── Lid-ignore headless setup              ✅
├── Wi-Fi connected                        ✅
├── Tailscale active                       ✅
├── Docker running                         ✅
│   ├── Homepage                           ✅ healthy
│   ├── Navidrome                          ✅ playing music
│   ├── slskd                              ✅ healthy + Soulseek connected
│   └── Explo                              ✅ running
├── Navidrome DB automatic backup           ✅
├── Backup pull to Zenbook                  ✅ (manual retry verified after one wake failure)
├── Navidrome restore test                  ✅ successfully tested
├── SMART health                            ✅ PASSED
├── fstrim timer                            ✅ enabled
├── apt timers / unattended upgrades        ✅ enabled
└── systemd failed units                   ✅ none

Known yellow/non-fatal:
├── Wi-Fi signal around -78 dBm              ⚠️ monitor
├── one ACPI charge-rate firmware warning    ⚠️ monitor
├── Zenbook backup wake/sleep race            ⚠️ future retry improvement
├── Explo nested .env/.env layout             ⚠️ leave alone for now
├── Tailscale DNS warning observed on phone   ⚠️ monitor
└── slskd remote-config/API-key hardening     ⚠️ before public exposure
```

**Bottom line:** the server is currently in a good state to be left running headless. The next meaningful engineering work is reliability/hardening, not adding random containers.
