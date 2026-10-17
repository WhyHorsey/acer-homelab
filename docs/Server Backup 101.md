# Acer Server — Backup 101 / Upgrade & Recovery Runbook

**Owner:** WhyHorsey  
**Last reviewed:** 2026-09-26  
**Host:** `acer-server`  
**Primary focus:** Navidrome + Docker services + music data + remote backup

> This is the “what do I do before I touch something?” guide.
>
> **Core rule:** a backup is only useful if you can identify where it is, know what it contains, and have tested that it can be restored.

> **New in this revision:** the runbook now separates **tag, image, container, config, and persistent data** more explicitly, explains what happens to an old image when a moving tag such as `latest` is refreshed, and adds a worked upgrade/rollback example plus a clearer general-service backup model.

**Contents:**

[1. The backup mental model](#1.%20The%20backup%20mental%20model)
[2. Current Navidrome backup setup](#2.%20Current%20Navidrome%20backup%20setup)
[3. “I am about to update Navidrome” — safe procedure](#3.%20“I%20am%20about%20to%20update%20Navidrome”%20—%20safe%20procedure)
[4. Pull the new Navidrome image](#4.%20Pull%20the%20new%20Navidrome%20image)
[5. Apply the new image](#5.%20Apply%20the%20new%20image)
[6. Immediately verify the new container](#6.%20Immediately%20verify%20the%20new%20container)
[7. Verify the application, not just Docker](#7.%20Verify%20the%20application,%20not%20just%20Docker)
[8. What if the new version is broken?](#8.%20What%20if%20the%20new%20version%20is%20broken?)
[9. Rollback strategy](#9.%20Rollback%20strategy)
[10. Emergency Navidrome DB restore](#10.%20Emergency%20Navidrome%20DB%20restore)
[11. This exact restore procedure has already been tested](#11.%20This%20exact%20restore%20procedure%20has%20already%20been%20tested)
[12. Backup other Docker services](#12.%20Backup%20other%20Docker%20services)
[13. Music backup is separate](#13.%20Music%20backup%20is%20separate)
[14. “I changed a config file. Do I need a DB backup?”](#14.%20“I%20changed%20a%20config%20file.%20Do%20I%20need%20a%20DB%20backup?”)
[15. “I accidentally pulled the image before backing up”](#15.%20“I%20accidentally%20pulled%20the%20image%20before%20backing%20up”)
[16. “I ran compose up after pulling. Did my data get deleted?”](#16.%20“I%20ran%20compose%20up%20after%20pulling.%20Did%20my%20data%20get%20deleted?”)
[17. Restore-test policy](#17.%20Restore-test%20policy)
[18. Current backup maturity](#18.%20Current%20backup%20maturity)
[19. One-page “before I update anything” cheat sheet](#19.%20One-page%20“before%20I%20update%20anything”%20cheat%20sheet)
[20. Golden rules](#20.%20Golden%20rules)
[21. Official references](#21.%20Official%20references)
[Appendix A — Image Pinning 101](#Appendix%20A%20—%20Image%20Pinning%20101)
[Appendix B — General Docker Rollback 101](#Appendix%20B%20—%20General%20Docker%20Rollback%20101)
[Appendix C — Recommended Upgrade Pattern for This Acer](#Appendix%20C%20—%20Recommended%20Upgrade%20Pattern%20for%20This%20Acer)
[Appendix D — One-minute rollback cheat sheet](#Appendix%20D%20—%20One-minute%20rollback%20cheat%20sheet)

---

# 1. The backup mental model

There are several different things to protect. Do not treat “the container” as the backup target.

```text
Docker image
  = disposable application package

Container
  = disposable runtime instance

Compose file / config
  = recipe for recreating the service

Bind-mounted data
  = persistent application state

Navidrome DB backup
  = users, play counts, playlists, metadata/state stored in the DB

Music library
  = the actual FLAC/MP3/etc. files
```

For this server, the important layers are:

```text
                    DISASTER RECOVERY
                           │
        ┌──────────────────┼──────────────────┐
        │                  │                  │
     Config            App data           Music
        │                  │                  │
   compose.yaml      Navidrome DB       /srv/media/music
   service config    slskd data         and future data
   scripts            app state
```

Navidrome's built-in backup only covers the database. It does **not** back up the music files or configuration files. https://www.navidrome.org/docs/usage/admin/backup/

---

# 2. Current Navidrome backup setup

## On Acer

```text
Live database:
/srv/containers/navidrome/data/navidrome.db

Local Navidrome DB backups:
/srv/containers/navidrome/backup/
```

Current automated settings:

```text
Backup.Path      = /backup
Backup.Count     = 7
Backup.Schedule  = 0 0 * * *
```

In Compose these are configured through:

```text
ND_BACKUP_PATH
ND_BACKUP_COUNT
ND_BACKUP_SCHEDULE
```

Navidrome creates scheduled database backups and prunes old backups according to `Backup.Count`. citehttps://www.navidrome.org/docs/usage/admin/backup/https://www.navidrome.org/docs/usage/admin/cli/backup/

## On Zenbook

The Fedora Zenbook pulls the Acer's Navidrome DB backups daily:

```text
systemd user timer:
acer-navidrome-backup.timer

service:
acer-navidrome-backup.service

script:
~/.local/bin/pull-acer-navidrome-backup

destination:
/mnt/the-big/Fedora/server-backups/navidrome/
```

The pull uses rsync over SSH and the `acer-backup` SSH alias, which currently points directly to the Acer Tailscale IP.

---

# 3. “I am about to update Navidrome” — safe procedure

## Step 0 — Decide what kind of update it is

Before touching Docker, check the Navidrome release notes/changelog.

Why this matters: Navidrome releases can include database/schema migrations. For example, the 0.64.0 release included a migration that touched every table and explicitly told administrators to back up the database before upgrading. https://github.com/navidrome/navidrome/releases/tag/v0.64.0

Do not assume that every update is equally trivial.

---

## Step 1 — Go to the correct Compose directory

Run on **Acer**:

```bash
cd /srv/containers/navidrome
```

Verify:

```bash
pwd
```

Expected:

```text
/srv/containers/navidrome
```

This matters because `docker compose ...` reads the Compose file from the current project directory.

---

## Step 2 — Check current service state

```bash
sudo docker compose ps
sudo docker compose logs --tail=50 navidrome
```

You are establishing a **known-good starting point** before changing anything.

If Navidrome is already unhealthy or throwing errors, stop the update process and diagnose that first.

---

## Step 3 — Create a manual Navidrome DB backup

Run:

```bash
sudo docker compose run --rm navidrome backup create
```

What this means:

- `run` = create a temporary one-off container using the same Compose service definition.
- `--rm` = remove that temporary container when it finishes.
- `navidrome` = the Compose service name.
- `backup create` = ask Navidrome to create a DB backup now.

This does **not** restart or replace the normal running container. Navidrome documents this exact Compose pattern for manual DB backups. https://www.navidrome.org/docs/usage/admin/cli/backup/

Then verify the new file:

```bash
ls -lh /srv/containers/navidrome/backup/
```

You want a fresh timestamped `.db` file.

### Important

`backup create` does not prune older backups. Pruning is a separate operation. https://www.navidrome.org/docs/usage/admin/cli/backup/

Do **not** run prune just because you made a manual backup.

---

## Step 4 — Make sure the backup exists on the Zenbook

Because the Acer backup has already been successfully pulled to the Zenbook, the safest pre-upgrade pattern is:

On **Zenbook**:

```bash
systemctl --user start acer-navidrome-backup.service
```

Then:

```bash
ls -lh /mnt/the-big/Fedora/server-backups/navidrome/
```

You want the same newest backup visible there.

This creates a useful separation:

```text
Acer live DB
    ↓
Acer DB backup
    ↓
Zenbook copy
```

If the update later breaks the Acer, you still have a copy on another machine.

---

## Step 5 — Back up the service recipe/config if you are changing it too

The Navidrome DB backup is not a backup of `compose.yaml` or arbitrary config files.

Before changing Compose/config, make a separate copy of the relevant text files.

For this server, the primary recipe is:

```text
/srv/containers/navidrome/compose.yaml
```

A quick local snapshot is possible with `cp -a`, but for a clean backup layout prefer a separate backup tree rather than placing many `.before-*` copies beside live files. For example:

```bash
sudo mkdir -p /srv/backups/pre-upgrade/navidrome/2026-09-26-before-0.65.0
sudo cp -a /srv/containers/navidrome/compose.yaml \
  /srv/backups/pre-upgrade/navidrome/2026-09-26-before-0.65.0/
```

This keeps the mental separation clear:

```text
/srv/containers/   = LIVE APPLICATIONS
/srv/backups/      = BACKUP / PRE-UPGRADE SNAPSHOTS
```

A copy beside the live file is still useful as a short-term rollback snapshot, for example:

```bash
cp -a /path/to/config /path/to/config.before-UPGRADE
```

but remember that a same-disk copy is **not** a disaster backup. If the Acer's SSD dies, both copies are gone.

Use a meaningful timestamp/version in the snapshot directory, for example:

```text
/srv/backups/pre-upgrade/navidrome/2026-09-26-before-0.65.0/
```

**Do not put secrets into Git just because you copied a config file.** Store secret material securely.

For live databases, do **not** replace an application-aware backup with `cp -a` of the database files while the application is running. For Navidrome, use its documented DB backup command instead.

---

## Step 6 — Record what version/image you are running

Current Navidrome is using the `deluan/navidrome:latest` tag.

Record the container's current image ID:

```bash
sudo docker inspect navidrome --format 'image={{.Image}}'
```

Also record the application version from the logs:

```bash
sudo docker compose logs --tail=30 navidrome | grep -F 'Version:'
```

This gives you a useful “before” reference.

### Why record this?

Docker tags such as `latest` are movable labels. Docker also supports immutable image digests, and version-pinned references make exact rollback/reproduction easier. https://docs.docker.com/reference/cli/docker/image/pull/

For future high-risk upgrades, prefer recording/pinning the exact release tag instead of relying only on `latest`.

---

# 4. Pull the new Navidrome image

After the backup is verified:

```bash
sudo docker compose pull navidrome
```

**Important:** `docker compose pull` downloads the image but does **not** start containers from it. https://docs.docker.com/reference/cli/docker/compose/pull/

That means this command alone does not upgrade the running Navidrome instance.

---

# 5. Apply the new image

Run:

```bash
sudo docker compose up -d navidrome
```

Compose will recreate the service when the image/config changed and preserve mounted persistent data. https://docs.docker.com/reference/cli/docker/compose/up/

You normally **do not need**:

```bash
sudo docker compose down
```

for a normal image update.

Avoid unnecessary downtime and avoid removing the entire project when a service-specific update is enough.

---

# 6. Immediately verify the new container

```bash
sudo docker compose ps
```

Then:

```bash
sudo docker compose logs --tail=100 navidrome
```

Look for:

```text
Version: <new version>
```

and a normal startup sequence.

If the release contains a DB migration, expect migration messages in the logs. Do not panic just because the database is being migrated; what matters is that the process completes cleanly.

---

# 7. Verify the application, not just Docker

Test from a client:

```text
Homepage → not relevant to Navidrome health
Navidrome → login works
          → library is present
          → play a track
          → scrobbling still works
```

Also check the things that are specific to this setup:

```text
Navidrome → ListenBrainz scrobble
Navidrome → Explo Subsonic connection
Navidrome → music files under /srv/media/music
```

Do not immediately run a full library scan just because Navidrome was upgraded. Let startup logs and normal behavior tell you whether a scan is needed.

---

# 8. What if the new version is broken?

## First: do not immediately restore the DB

A broken application does not automatically mean a broken database.

First collect evidence:

```bash
sudo docker compose ps
sudo docker compose logs --tail=200 navidrome
```

Check whether the problem is:

```text
- application startup failure
- incompatible config
- plugin issue
- database migration issue
- scan issue
- client/API compatibility
```

Only then choose the recovery path.

---

# 9. Rollback strategy

There are two different rollback operations:

```text
A. Roll back the application image
B. Restore the database
```

They are **not the same thing**.

If the new application can be reverted safely to the prior release, you can point Compose at the prior known-good version and recreate the service.

However, **do not assume a database that has already been migrated by a newer Navidrome version can safely be opened by an older version**. Consult that release's migration/rollback guidance before downgrading.

That is why the pre-upgrade database backup is critical.

---

# 10. Emergency Navidrome DB restore

Use this only when you have decided that the database itself must be reverted.

## Step 1 — Stop live Navidrome

On Acer:

```bash
cd /srv/containers/navidrome
sudo docker compose stop navidrome
```

Do not restore a Navidrome DB while Navidrome is actively running. Official documentation explicitly requires the service to be stopped before restore. https://www.navidrome.org/docs/usage/admin/cli/backup/

---

## Step 2 — Preserve the current state if needed

Before overwriting the current database, consider creating a backup of the current post-update DB so that the failed state itself is preserved for investigation.

With Navidrome stopped:

```bash
sudo docker compose run --rm navidrome backup create
```

Check the backup directory:

```bash
ls -lh /srv/containers/navidrome/backup/
```

The exact sequence may be adjusted depending on what failed and what state you need to preserve.

---

## Step 3 — Restore the selected backup

Example:

```bash
sudo docker compose run --rm navidrome \
  backup restore \
  --backup-file navidrome_backup_YYYY.MM.DD_HH.MM.SS.db
```

Navidrome will ask for confirmation unless you use `--force`.

**Do not use `--force` by habit.** The confirmation is a useful safety barrier.

A restore replaces the current database. Changes made after the chosen backup — such as newer users, play counts, or playlists — are lost. https://www.navidrome.org/docs/usage/admin/cli/backup/

---

## Step 4 — Start Navidrome again

```bash
sudo docker compose start navidrome
```

Then:

```bash
sudo docker compose logs --tail=100 navidrome
```

Finally verify:

```text
login
users
library
playlists
playback
scrobbling
```

---

# 11. This exact restore procedure has already been tested

The server's Navidrome restore process was tested in an isolated environment on 2026-09-23.

The sequence was:

```text
fresh test instance
    ↓
start once so a DB exists
    ↓
stop instance
    ↓
backup restore
    ↓
start test instance
    ↓
login successfully
    ↓
existing library/user data visible
```

The test completed successfully and showed the restored account/library, including 42 albums in the UI.

This means the current Navidrome DB backup format has been **restore-tested**, not merely generated.

---

# 12. Backup other Docker services

The same mental model applies to Homepage, slskd, and Explo.

## Homepage

Protect:

```text
/srv/containers/homepage/compose.yaml
/srv/containers/homepage/config/
/srv/containers/homepage/icons/
/srv/containers/homepage/images/
```

Most of Homepage's important state is configuration rather than a large database.

## slskd

Protect:

```text
/srv/containers/slskd/compose.yaml
/srv/containers/slskd/app/
```

But be careful with secrets inside `slskd.yml` or Compose files. Do not commit passwords/API keys to a public or ordinary Git repository.

## Explo

Protect:

```text
/srv/containers/explo/compose.yaml
/srv/containers/explo/explo/.env/
srv/containers/explo/explo/config/
```

The current nested `.env/.env` layout is awkward but functional. Do not restructure it as part of a backup operation unless that is an intentional maintenance task.

---

# 12.5 General service backup model

A useful rule for **all** Docker services on this server is:

```text
                 RECOVERY SET
                      │
          ┌───────────┼───────────┐
          │           │           │
        RECIPE       STATE      USER DATA
          │           │           │
     compose.yaml   DB/state    music/files
     config         metadata    downloads
     env/secrets    indexes     documents
     scripts        app state   etc.
```

The goal is not to copy every byte on the server before every update. The goal is to preserve enough information to **recreate the service and restore the state that matters**.

### What usually belongs in each category

**Recipe/config**

Examples:

```text
compose.yaml
application config
.env / secret material (stored securely)
scripts
```

**Persistent application state**

Examples:

```text
databases
metadata
indexes
application state
queue/job state
```

**User data**

Examples:

```text
music
photos
documents
downloads
other irreplaceable files
```

### What does not automatically need disaster-grade backup?

Caches and other clearly regenerable data often do not need the same treatment as the database or user data. However, this is **application-specific**. Never assume a directory named `cache` is disposable without checking what the application stores there.

### Current service map

| Service | Recipe/config to protect | Persistent state / user data to protect |
|---|---|---|
| Homepage | `/srv/containers/homepage/compose.yaml`, `config/`, `icons/`, `images/` | mostly configuration; regenerateable app runtime state is less important |
| Navidrome | `/srv/containers/navidrome/compose.yaml`, relevant config | `data/` DB/state, plus `/srv/media/music` as separate user data; DB backup is especially important |
| slskd | `/srv/containers/slskd/compose.yaml`, `app/slskd.yml` and related config | `/srv/containers/slskd/app/` includes application state, downloads, and incomplete files; decide which parts need separate backup |
| Explo | `/srv/containers/explo/compose.yaml`, `.env`, config | application state under its mounted data/config paths; actual music output under `/srv/media/music/explo` is user data |

The exact backup mechanism can differ by application. A Navidrome SQLite DB can have an application-aware backup/restore command; a slskd state directory may instead require a filesystem-level copy with the service stopped, depending on what the application documents. **Do not invent a universal restore command for every container.**

# 12.6 Where should a backup live?

“Backup” can mean several different layers. They solve different failure modes.

```text
A. LOCAL PRE-UPGRADE SNAPSHOT
   Fast rollback on the same Acer

   /srv/containers/SERVICE/
            ↓
   /srv/backups/pre-upgrade/SERVICE/TIMESTAMP/

B. OFF-DEVICE BACKUP
   Recovery if the Acer or its SSD dies

   Acer  ─────────→  Zenbook

C. APPLICATION-AWARE BACKUP
   A backup method that understands the application's data format

   e.g. Navidrome DB backup command
```

These are complementary, not interchangeable. A local snapshot can make an update rollback convenient, but it does not protect against loss of the Acer itself. An off-device copy provides the separate-machine safety net. An application-aware backup helps ensure state such as a database is captured consistently.

### Recommended storage layout for this homelab

For ordinary files/configuration:

```text
LIVE
/srv/containers/SERVICE/...

LOCAL SNAPSHOT
/srv/backups/pre-upgrade/SERVICE/YYYY-MM-DD-before-VERSION/...

OFF-DEVICE
Zenbook / dedicated backup location
```

For important state, prefer having both the local snapshot and an off-device copy when practical. For the most important service data, the off-device copy is the part that protects against host/storage failure.

### Does every update need a full copy of every folder?

No. Backup the state that matters for the operation you are about to perform. The goal is **recoverability**, not making a byte-for-byte copy of the entire server before every change.

A useful decision tree is:

```text
What am I changing?
       │
       ├── config/recipe only
       │      → snapshot the config/Compose files
       │
       ├── application data/state
       │      → back up the relevant persistent state
       │
       ├── database
       │      → prefer the application's backup/dump mechanism
       │
       └── irreplaceable user data
              → maintain an off-device backup
```

Clearly regenerable caches usually do not need the same disaster-recovery treatment as databases or irreplaceable user data, but whether something is safely regenerable is **application-specific**.

### Important distinction: snapshot vs backup

```text
Same Acer:
    “Can I quickly undo this update?”

Another device:
    “Can I recover if the Acer itself is lost?”
```

A pre-upgrade snapshot is therefore a **rollback convenience**. The Zenbook/off-device copy is a **disaster-recovery layer**. They can contain overlapping data, but they serve different purposes.

### Example: slskd

For a stateful filesystem-based service such as slskd, a reasonable pre-upgrade snapshot might be:

```bash
sudo mkdir -p /srv/backups/pre-upgrade/slskd/2026-09-26-before-0.27.0
sudo cp -a /srv/containers/slskd/compose.yaml \
  /srv/backups/pre-upgrade/slskd/2026-09-26-before-0.27.0/
```

If you also need application state, snapshot the relevant state directory according to what the application documents as persistent state. For a live database or actively changing application state, stop the service first when a filesystem-level copy is not guaranteed to be consistent.

Do **not** blindly delete the live directory and copy a snapshot back just because an update failed. First determine whether the problem is the image, configuration, or data, and preserve the current post-update state before destructive recovery steps.

### Example: Navidrome

Navidrome uses an application-aware database backup for its SQLite state:

```bash
sudo docker compose run --rm navidrome backup create
```

That backup belongs in the backup chain:

```text
Navidrome live DB
      ↓
application-aware DB backup
      ↓
Acer local backup file
      ↓
Zenbook off-device copy
```

The actual music files remain a separate user-data backup concern.

---

### The critical recovery question

When a service breaks after an update, ask:

```text
Is the IMAGE bad?
Is the CONFIG bad?
Is the DATA bad?
Or more than one of them?
```

That determines what actually needs to be rolled back.

---

# 13. Music backup is separate

Navidrome DB backup does **not** back up music.

The actual music library is:

```text
/srv/media/music/
```

The source/sync workflow currently uses rsync from the Fedora Zenbook side.

For a safe manual rsync check, use a dry run first:

```bash
rsync -avhn SOURCE/ DEST/
```

Then perform the real sync:

```bash
rsync -avh SOURCE/ DEST/
```

### The critical mental model

```text
rsync SOURCE DESTINATION
```

The order matters.

Also:

```text
SOURCE/
```

with the trailing slash means “the contents of this directory”.

And:

```text
--delete
```

is destructive: it can delete files at the destination that do not exist in the source.

**Always dry-run before using `--delete`.**

---

# 14. “I changed a config file. Do I need a DB backup?”

Not always, but ask what kind of change it is.

### Safe/read-only inspection

No backup required merely to run:

```bash
cat ...
ls ...
docker inspect ...
docker compose config
```

### Service configuration change

Back up the config/Compose file before editing if the change is meaningful or hard to reproduce.

### Database/data mutation

Create a DB/app-data backup before destructive or hard-to-undo operations.

### Image upgrade

For Navidrome or another stateful service:

```text
backup DB/data
→ verify backup
→ record current version
→ pull image
→ recreate service
→ verify
```

---

# 15. “I accidentally pulled the image before backing up”

Do not panic.

`docker compose pull` only pulls the image; it does not start the updated container. https://docs.docker.com/reference/cli/docker/compose/pull/

If you have only pulled the image:

```text
STOP
→ make the backup now
→ verify it
→ then run compose up
```

The important destructive/application-changing step is the service recreation, not the image download itself.

---

# 16. “I ran compose up after pulling. Did my data get deleted?”

Normally, no — not when your persistent data is stored in the bind mounts shown in the Compose files.

Compose recreates the container when its image/config changes, while mounted persistent data remains on the host. https://docs.docker.com/reference/cli/docker/compose/up/

This is the reason the server stores important state under host paths such as:

```text
/srv/containers/navidrome/data
/srv/containers/navidrome/backup
/srv/containers/slskd/app
```

Do not confuse:

```text
container
```

with:

```text
persistent host data
```

---

# 17. Restore-test policy

The restore test already passed once.

For this homelab, a practical policy is:

```text
Before major/stateful upgrades:
    make a fresh backup

After major backup-system changes:
    perform a restore test

Periodically (for example, every few months):
    perform another restore test
```

The goal is not to test constantly. The goal is to avoid discovering during a disaster that your backup process only *looked* correct.

---

# 18. Current backup maturity

## Navidrome DB

```text
Acer local backup          ✅
Daily automated backup     ✅
Zenbook off-device copy    ✅
Restore tested             ✅
```

## Music library

```text
Local library              ✅
Manual rsync workflow      ✅
Automatic full-library sync ❌ not fully automated yet
```

## Compose/config

```text
Live config exists         ✅
Centralized config backup  ⚠ future improvement
```

## Full disaster recovery

```text
Complete bare-metal backup ❌ not currently implemented
```

So the server has a **good Navidrome DB recovery path**, but it is **not yet a complete image-level/bare-metal disaster-recovery system**. That is okay for the current homelab; just keep the distinction clear.

---

# 19. One-page “before I update anything” cheat sheet

```text
============================================================
              BEFORE A STATEFUL DOCKER UPDATE
============================================================

1. Identify the service
   cd /srv/containers/SERVICE

2. Check current state
   sudo docker compose ps
   sudo docker compose logs --tail=50 SERVICE

3. Read the release notes
   Look for migrations / breaking changes

4. Back up state
   Navidrome:
   sudo docker compose run --rm navidrome backup create

5. Verify the backup exists
   ls -lh /srv/containers/navidrome/backup/

6. Make sure the off-device copy is current
   On Zenbook:
   systemctl --user start acer-navidrome-backup.service

7. If needed, make a local pre-upgrade snapshot
   /srv/backups/pre-upgrade/SERVICE/YYYY-MM-DD-before-VERSION/
   Use cp -a for ordinary files/config; use the app's backup/dump mechanism for databases.

8. Back up important config if you are editing it
   compose.yaml / service config / scripts

9. Record current version/image
   sudo docker inspect SERVICE --format 'image={{.Image}}'

10. Pull new image
    sudo docker compose pull SERVICE

11. Apply update
    sudo docker compose up -d SERVICE

12. Watch logs
    sudo docker compose logs --tail=100 SERVICE

13. Test the actual application
    login / playback / API / integration / automation

14. If broken:
    STOP
    read logs
    do not immediately restore the DB
    determine whether the problem is app/config/DB

============================================================
```

---

# 20. Golden rules

```text
1. Backup BEFORE the risky operation, not after.

2. A database backup is not a music backup.

3. A container is not the data.

4. `docker compose pull` downloads; it does not itself deploy the new image.

5. `docker compose up -d` may recreate the container while preserving bind-mounted data.

6. Never restore a live Navidrome DB.

7. Do not restore a backup just because an application update is inconvenient.
   Diagnose first.

8. Never use `--delete` in rsync casually.

9. Never assume an old database is safe to use with a downgraded application
   after a schema migration.

10. A backup is not proven until restore has been tested.

11. A tag is a reference; a digest identifies exact image content.

12. A same-disk pre-upgrade snapshot is useful for quick rollback, but it is not a disaster backup.

13. Keep live application data and backup snapshots in separate directory trees when practical.

14. For important data, maintain an off-device copy; the backup that lives only on Acer cannot protect against Acer/SSD failure.

15. Do not use `cp -a` of a live database as a substitute for an application-aware database backup unless the application documents that method as safe.

12. Do not treat the old Docker image as your only backup. It lives on the same host.
```

---

# 21. Official references

- Navidrome backup/restore: https://www.navidrome.org/docs/usage/admin/cli/backup/
- Navidrome automated backup: https://www.navidrome.org/docs/usage/admin/backup/
- Navidrome CLI: https://navidrome.org/docs/usage/admin/cli/
- Navidrome releases: https://github.com/navidrome/navidrome/releases
- Docker Compose `pull`: https://docs.docker.com/reference/cli/docker/compose/pull/
- Docker Compose `up`: https://docs.docker.com/reference/cli/docker/compose/up/
- Docker image pull / tags / digests: https://docs.docker.com/reference/cli/docker/image/pull/

---

# Appendix A — Image Pinning 101

This section explains one of the easiest Docker concepts to misunderstand: **the image reference in `compose.yaml` is not the same thing as the image currently running in a container**.

## A.1 The full image mental model

The most useful distinction is that **a tag is a name, an image is the actual package, and a container is a runtime instance created from an image**.

```text
compose.yaml
    │
    │ contains an image reference
    ▼
image reference
    │
    ├── repository + tag
    │      e.g. deluan/navidrome:0.64.1
    │
    └── or repository + digest
           e.g. deluan/navidrome@sha256:...
             │
             ▼
        concrete Docker image
             │
             ▼
        running container
```

The image reference may be a moving tag:

```yaml
image: deluan/navidrome:latest
```

A release tag:

```yaml
image: deluan/navidrome:0.64.1
```

or a digest:

```yaml
image: deluan/navidrome@sha256:...
```

Docker Compose accepts both tags and digests in the `image` field. Docker documents digests as immutable identifiers for exact image content, while tags are labels that can be moved to different image contents. citehttps://docs.docker.com/reference/compose-file/services/https://docs.docker.com/reference/cli/docker/image/pull/https://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/

### The four things not to confuse

```text
TAG
  human-readable label / pointer

IMAGE
  concrete package identified internally by an image ID / digest

CONTAINER
  runtime instance created from an image

PERSISTENT DATA
  application state stored in bind mounts or volumes
```

This gives the core rule for rollback:

```text
image rollback ≠ container rollback ≠ data rollback
```

Recreating a container does not normally erase a bind-mounted host directory. Conversely, changing an image reference does not magically restore an older database or config file. citehttps://docs.docker.com/reference/cli/docker/compose/up/

## A.2 What `latest` actually means

`latest` is **a tag**, not a promise that the running container always magically updates itself.

For example:

```text
Today:
latest → image A

Later:
latest → image B
```

If you run:

```bash
sudo docker compose pull navidrome
```

Compose pulls the image currently referenced by `latest`, but `pull` does not start or recreate the running container. citehttps://docs.docker.com/reference/cli/docker/compose/pull/

The running container can therefore still be using image A.

When you subsequently run:

```bash
sudo docker compose up -d navidrome
```

Compose notices that the service image has changed and recreates the container with the newly pulled image, while preserving mounted persistent data. citehttps://docs.docker.com/reference/cli/docker/compose/up/

## A.3 Does pinning automatically change `compose.yaml`?

**No.** Pinning is normally a change you make to the Compose configuration.

For example, changing:

```yaml
image: deluan/navidrome:latest
```

to:

```yaml
image: deluan/navidrome:0.64.1
```

means **you edited `compose.yaml`**.

Docker did not silently rewrite the file just because you pulled an image.

The practical consequence is important:

```text
compose.yaml says latest
        ↓
next pull can resolve to a newer image
```

versus:

```text
compose.yaml says 0.64.1
        ↓
future pulls keep requesting 0.64.1
```

A version tag is much easier for a human to understand and is a useful middle ground for this homelab. However, tags are technically mutable unless the registry makes them immutable. A digest is the stronger form of pinning because it identifies the exact image content. citehttps://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/https://docs.docker.com/dhi/explore/security-concepts/digests/

### What happens to the old image when `latest` moves?

This deserves its own mental model. Imagine the registry starts with:

```text
latest ───────► Image A
```

A newer image is published and the publisher moves the tag:

```text
latest ───────► Image B
                 ▲
                 │
          Image A is still a different image
```

When Acer runs:

```bash
sudo docker compose pull navidrome
```

Docker downloads/resolves the image currently referenced by `latest`. It does **not** rewrite `compose.yaml`, and it does **not** by itself replace the running container. citehttps://docs.docker.com/reference/cli/docker/compose/pull/

The old Image A does not automatically become `0.64.1`, nor is it automatically guaranteed to be deleted. If `latest` was the only tag pointing to Image A, Image A can become an **untagged/dangling image** locally. `docker image ls` hides dangling images by default; `docker image ls -a` can show them. If an existing container still references that image, Docker warns against removing it because the container is using it. citehttps://docs.docker.com/reference/cli/docker/image/ls/

So think:

```text
old image
   │
   ├── may remain locally
   ├── may be untagged after tag movement
   └── can later be cleaned up if it is no longer needed
```

A moving tag is therefore **a pointer, not a history system**. If rollback matters, record the old version and/or digest before updating.

Useful inspection commands on Acer:

```bash
sudo docker image ls --all deluan/navidrome

sudo docker inspect navidrome \
  --format 'image={{.Config.Image}} image-id={{.Image}}'
```

The first shows local repository/tag entries, including dangling images when `--all` is used. The second shows both the Compose-style reference configured for the container and the concrete image ID used by that container.

## A.4 Version tag vs digest

### Version tag

Example:

```yaml
image: deluan/navidrome:0.64.1
```

Mental model:

```text
"Give me the Navidrome 0.64.1 release."
```

Advantages:

- readable
- easy to edit during upgrades
- easy to understand during rollback
- good fit for a small personal homelab

Caveat:

- a tag is still a mutable label in Docker's general model

### Digest

Example:

```yaml
image: deluan/navidrome@sha256:YOUR_DIGEST_HERE
```

Mental model:

```text
"Give me exactly this image content, identified by this SHA-256 digest."
```

Advantages:

- exact/reproducible image
- immutable reference
- strongest rollback/reproduction anchor

Caveat:

- much harder for humans to read
- you have to intentionally update the digest when you want a new image

Docker Compose can also resolve image references to digests or generate an override file containing digest pins. The original `compose.yaml` does not have to be rewritten to use that workflow. citehttps://docs.docker.com/reference/cli/docker/compose/config/

For this server, **version-tag pinning is a perfectly reasonable first step**. Digest pinning can be added later if you want stronger reproducibility.

### A.5 Practical pinning workflows

There are three useful levels:

```text
LEVEL 0 — moving tag
image: deluan/navidrome:latest

LEVEL 1 — release/version tag
image: deluan/navidrome:0.64.1

LEVEL 2 — digest pin
image: deluan/navidrome@sha256:...
```

#### Level 1: pin by editing `compose.yaml`

For the current homelab, this is the easiest starting point:

```yaml
image: deluan/navidrome:0.64.1
```

There is no magic “pin” command required. You are making the Compose recipe explicit. Future `docker compose pull` operations for that file request the `0.64.1` tag rather than `latest`. The tag is still technically mutable at the registry level, so a digest is stronger when exact byte-for-byte reproducibility is important. citehttps://docs.docker.com/docker-hub/repos/manage/hub-images/immutable-tags/https://docs.docker.com/reference/cli/docker/image/pull/

#### Level 2: resolve/persist digests

Compose can show or generate digest-pinned configuration:

```bash
docker compose config --resolve-image-digests
```

And it can generate an override file containing digest pins:

```bash
docker compose config --lock-image-digests -o compose.lock.yaml
```

These options are useful when you want reproducibility without replacing the human-readable Compose file immediately. `--resolve-image-digests` resolves image tags to digests in rendered output, while `--lock-image-digests` produces an override file with image digests. citehttps://docs.docker.com/reference/cli/docker/compose/config/

For this server, do **not** start digest-pinning every service just because the feature exists. The practical learning path remains: explicit release tags first, then digest pinning when there is a reason to need stronger reproducibility.

---

# Appendix B — General Docker Rollback 101

Rollback is easier when you distinguish three things:

```text
1. application image
2. application configuration
3. application data
```

A rollback may involve one, two, or all three.

## B.1 The simplest case: application-only rollback

Typical for a service where the new image did not work but its persistent data did not need a schema change.

Example situation:

```text
Known-good:
    image X

Upgrade:
    image Y

Result:
    service Y is broken
```

Recovery:

```text
Compose image → X
        ↓
compose pull (if X is a registry tag and not already local)
        ↓
compose up -d
        ↓
verify
```

For a concrete version-tag rollback:

```yaml
image: deluan/navidrome:0.64.1
```

then:

```bash
cd /srv/containers/navidrome
sudo docker compose pull navidrome
sudo docker compose up -d navidrome
```

`pull` only retrieves the selected image; `up -d` is what applies it to the running service. citehttps://docs.docker.com/reference/cli/docker/compose/pull/https://docs.docker.com/reference/cli/docker/compose/up/

## B.2 What if the old image was only `latest`?

This is exactly why relying on `latest` makes rollback less convenient. `latest` does not remember what it pointed to yesterday.

Before an update, you ideally know the exact old release, for example:

```text
running application version: 0.64.1
```

Then you can use the official release tag explicitly during a rollback:

```yaml
image: deluan/navidrome:0.64.1
```

An even stronger practice is to record the exact image identity before updating. This gives you an audit trail even when the Compose file still uses `latest`:

```bash
sudo docker inspect navidrome --format 'image-id={{.Image}}'
```

That value is the concrete image ID used by the container. It is useful evidence during troubleshooting even when the Compose file only says `latest`.

For an immediate local rollback anchor, an administrator can also assign a temporary local tag to the old image before upgrading. This is an advanced technique and is not a substitute for a real backup because the local image is still stored on the same server.

## B.3 Rollback with a temporary local tag

Only use this when you understand that the tag exists **locally on Acer**.

Before updating:

```bash
OLD_IMAGE_ID=$(sudo docker inspect navidrome --format '{{.Image}}')
sudo docker image tag "$OLD_IMAGE_ID" deluan/navidrome:rollback-known-good
```

Now there is a local human-readable reference:

```text
deluan/navidrome:rollback-known-good
```

If the upgrade fails, temporarily point Compose at that tag:

```yaml
image: deluan/navidrome:rollback-known-good
```

Then:

```bash
sudo docker compose up -d navidrome
```

Important limitations:

- this tag is local to Acer
- it is not a disaster-recovery backup
- it does not replace the DB/config backup
- do not delete the old image until the upgrade has been accepted

For this reason, the preferred long-term rollback reference is a known release tag or digest, while a local rollback tag is a useful short-term safety net. A local tag is still stored on Acer, so it disappears as a recovery option if the Acer's storage is lost.

## B.4 Stateful service rollback

This is where things become more serious.

Suppose:

```text
old app
   ↓
old database schema

upgrade
   ↓
new app migrates database
   ↓
new schema
```

If the new application is broken, simply changing the image back may **not** be sufficient.

The old application may not understand the migrated database schema.

In that case, the safe recovery can become:

```text
1. stop service
2. preserve the current post-upgrade state
3. restore pre-upgrade application data
4. restore known-good application image
5. start service
6. verify
```

This is exactly why Navidrome deserves the heavier backup procedure in this server's runbook.

For Navidrome, the recovery decision is therefore:

```text
New image broken?
       │
       ├── DB still compatible and data is fine
       │       ↓
       │   image rollback may be enough
       │
       └── DB was migrated / DB itself is bad
               ↓
           image rollback + DB restore
```

**Never assume that downgrading a database-backed application is safe.** Check the release's migration/rollback guidance before opening a migrated database with an older release.

## B.5 Generic rollback playbook for Homepage, slskd, Explo, etc.

When a service update goes wrong:

```text
STOP
  ↓
Don't delete anything yet
  ↓
Read logs
  ↓
Identify known-good image/config
  ↓
Decide whether data also needs rollback
  ↓
Revert image/config
  ↓
Recreate only that service
  ↓
Verify
  ↓
Only after success: clean up old resources
```

Useful checks:

```bash
sudo docker compose ps
sudo docker compose logs --tail=200 SERVICE
sudo docker inspect SERVICE --format 'image={{.Config.Image}} image-id={{.Image}}'
```

Replace `SERVICE` with the actual Compose service name.

For a service-specific rollback, prefer:

```bash
sudo docker compose up -d SERVICE
```

over tearing down the whole Compose project.

Compose recreates a service when its configuration or image has changed and preserves its mounted persistent data. citehttps://docs.docker.com/reference/cli/docker/compose/up/

## B.6 What NOT to do during rollback

Avoid these unless you have a very specific reason and understand the consequences:

```bash
sudo docker compose down -v
```

`-v` is dangerous for stateful services because it asks Compose to remove named/anonymous volumes associated with the project.

Also avoid broad cleanup commands while troubleshooting:

```bash
sudo docker system prune
sudo docker volume prune
```

They are not rollback commands.

During an incident, **preserve evidence first**.

---

# Appendix B.7 — Worked example: Navidrome 0.64.1 → 0.65.0 → rollback

This is the practical scenario that ties image pinning and data rollback together. The version numbers below are an example of the workflow; always use the real release numbers and release notes at the time of the update.

## Stage 1 — Known-good state

Suppose the current Compose file says:

```yaml
image: deluan/navidrome:0.64.1
```

The machine has:

```text
Compose recipe → 0.64.1
Running container → Image A
Database → pre-update state
Music → unchanged user data
```

Before updating, create/verify the DB backup and record the current image identity.

```bash
sudo docker inspect navidrome \
  --format 'image={{.Config.Image}} image-id={{.Image}}'
```

## Stage 2 — Upgrade

Change Compose to:

```yaml
image: deluan/navidrome:0.65.0
```

Then:

```bash
sudo docker compose pull navidrome
sudo docker compose up -d navidrome
```

The second command recreates the container when the image/config changed and preserves mounted volumes/bind mounts. citehttps://docs.docker.com/reference/cli/docker/compose/up/

Now:

```text
Compose recipe → 0.65.0
Running container → Image B
Database → may still be compatible OR may have been migrated
Music → unchanged user data
```

## Stage 3 — The new app is broken

Do **not** immediately restore the database. First inspect:

```bash
sudo docker compose ps
sudo docker compose logs --tail=200 navidrome
sudo docker inspect navidrome \
  --format 'image={{.Config.Image}} image-id={{.Image}}'
```

Now branch based on evidence.

### Case A — Image/config problem, data still valid

Suppose the new release fails to start because of an application/config problem and there is no evidence of an incompatible DB migration.

Change Compose back to:

```yaml
image: deluan/navidrome:0.64.1
```

Then:

```bash
sudo docker compose pull navidrome
sudo docker compose up -d navidrome
```

If the known-good image starts and the existing data works, the rollback is complete. **No DB restore was necessary.**

### Case B — The database was migrated or is itself corrupted

Now image rollback alone may be insufficient. The correct recovery becomes a coordinated rollback:

```text
1. preserve the current post-upgrade state
2. stop the service
3. restore the pre-upgrade database/state
4. point Compose at the compatible known-good image
5. start the service
6. verify the application and data
```

For Navidrome, use the documented DB restore procedure in Section 10. The database restore must happen while the live Navidrome service is stopped.

### Why the backup matters

Without a pre-upgrade DB backup, you may be able to put the old image back, but you may not be able to put the **old application state** back. That is the distinction between:

```text
rollback the program
```

and:

```text
rollback the program + state
```

## Stage 4 — What happened to Image A?

If the old release was previously referenced only by `0.64.1`, the old tag still gives you a human-readable reference:

```text
deluan/navidrome:0.64.1 → Image A
deluan/navidrome:0.65.0 → Image B
```

This is much easier to reason about than having only `latest`. With a moving tag, the old image may instead have become untagged after `latest` moved. Docker may still retain it locally, but that local copy is not a substitute for a backup. citehttps://docs.docker.com/reference/cli/docker/image/ls/

## Stage 5 — Final verification

After rollback, verify **both** layers:

```text
APPLICATION
  version / logs / startup

DATA
  users / playlists / metadata / expected files
```

For Navidrome specifically, also verify playback and ListenBrainz scrobbling.

---

# Appendix C — Recommended Upgrade Pattern for This Acer

For the current homelab, the practical pattern is:

```text
BEFORE UPDATE
    │
    ├── check release notes
    ├── backup application data
    ├── verify backup exists on Zenbook
    ├── record current version/image
    └── record current Compose/config state
             ↓
        PULL NEW IMAGE
             ↓
        RECREATE SERVICE
             ↓
          VERIFY
             │
       ┌─────┴─────┐
       │           │
      GOOD        BAD
       │           │
       ▼           ▼
   keep it      rollback image
                   │
            if needed, restore
             pre-update data
```

For **Navidrome**, use the detailed database backup/restore procedure in the main body of this document.

For **Homepage, slskd, and Explo**, the same image/config/data mental model applies, but their own persistent-state requirements must be checked before any major version jump.

## Practical recommendation for this server

For now, do not make every service digest-pinned just for the sake of it.

A sensible progression is:

```text
current learning stage
    ↓
use explicit release version tags for important services
    ↓
learn upgrade + rollback procedure
    ↓
optionally add digest pinning later
```

The key improvement over `latest` is that the Compose file itself documents **which application release the server is intentionally running**.

---

# Appendix D — One-minute rollback cheat sheet

```text
1. Don't panic.
2. Don't delete the old image.
3. Check:
   sudo docker compose ps
   sudo docker compose logs --tail=200 SERVICE
4. Decide whether this is:
   image problem / config problem / data problem
5. Revert the Compose image reference to the known-good tag/digest.
6. If data migration is involved, stop and consult the service's rollback guidance.
7. If data must be restored, stop the service before restoring it.
8. Recreate only the affected service:
   sudo docker compose up -d SERVICE
9. Verify logs + application + data.
10. Only clean up old images/resources after the rollback/update is proven stable.
```

**Core mental model:**

```text
image rollback ≠ data rollback

A new image can be replaced by an old image.
A migrated database is a separate problem.
A backup is what gives you the option to undo data changes.
```
