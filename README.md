# 🖥️ Acer Homelab

A collection of sanitized Docker Compose examples, service configuration templates, and operational documentation for my self-hosted homelab.

This repository documents how I manage services on an older Acer Aspire laptop (it's like 15 years old now!!) running Debian 13. It also serves as a reference for my deployment, maintenance, backups, and recovery.

The goal is to keep these configuration examples understandable, reproducible, and safe to share without publishing any of my live credentials or application data (that would be troubling).

## 💿 Services

| Service                                             | Purpose                                       |
| --------------------------------------------------- | --------------------------------------------- |
| [Beszel](https://github.com/henrygd/beszel)         | Host and Docker monitoring                    |
| [Explo](https://github.com/LumePart/Explo)          | ListenBrainz-driven music playlist automation |
| [Homepage](https://github.com/gethomepage/homepage) | Self-hosted service dashboard                 |
| [Navidrome](https://www.navidrome.org/)             | Self-hosted music streaming                   |
| [Portainer CE](https://www.portainer.io/)           | Docker environment management                 |
| [slskd](https://github.com/slskd/slskd)             | Soulseek client and download service          |

The exact image versions used in the running homelab may change over time. Check each Compose example and the relevant upstream release notes before deploying.

## 📋 Repository Structure

```text
[   70]  ./
├── [   72]  docs/
│   ├── [  50K]  Server Backup 101.md
│   └── [  47K]  Server Manual.md
├── [   84]  services/
│   ├── [   40]  beszel/
│   │   └── [  936]  compose-example.yaml
│   ├── [   62]  explo/
│   │   ├── [    0]  config/
│   │   ├── [   12]  explo/
│   │   │   └── [   58]  config/
│   │   │       └── [  326]  custom-playlists-example.json
│   │   └── [ 1.2K]  compose-example.yaml
│   ├── [   52]  homepage/
│   │   ├── [  156]  config/
│   │   │   ├── [  297]  bookmarks.yaml
│   │   │   ├── [  12K]  custom.css
│   │   │   ├── [    0]  custom.js
│   │   │   ├── [ 1.6K]  service-example.yaml
│   │   │   ├── [  546]  settings.yaml
│   │   │   └── [  288]  widgets.yaml
│   │   └── [  404]  compose-example.yaml
│   ├── [   88]  navidrome/
│   │   ├── [  402]  compose-example.yaml
│   │   └── [ 1.1K]  remap-custom-playlist.sh*
│   ├── [   40]  portainer/
│   │   └── [  239]  compose-example.yaml
│   └── [   46]  slskd/
│       ├── [   34]  app/
│       │   └── [ 9.7K]  slskd-example.yml
│       └── [  630]  compose-example.yaml
└── [ 5.3K]  README.md
```

These are example files, not necessarily ready-to-run deployments. File names or paths may be adjusted as the repository evolves.

## 📃 Using the Examples

1. Choose the service you want to deploy and read its configuration example.
2. Copy the example files into your own deployment directory and rename them as required by the application.
3. Replace placeholder values, environment variables, host paths, network addresses, and other machine-specific settings.
4. Review the official documentation for the service before starting it.
5. Validate the configuration before deploying. For Docker Compose, a typical check is:

   ```bash
   docker compose config -q
   ```

6. Start and verify one service at a time:

   ```bash
   docker compose up -d
   docker compose ps
   docker compose logs --tail=100
   ```

**Do not** run these commands against a live environment without first checking the target directory and understanding which configuration will be applied.

## ⚙️ Configuration and Secrets

This is a public repository. Real credentials and private application state do not belong here.

- Use the provided placeholders and create local environment files where required.
- Keep real configuration and persistent application state separate from these public examples.
- Review Compose files and application configuration for embedded credentials before committing.
- Replace private addresses and host-specific values with your own settings.
- Treat `.gitignore` as an additional safeguard, not as a substitute for reviewing changes.

Some applications require matching credentials across services. For example, an application connecting to slskd must use the API key configured on the slskd side. Generate and configure your own credentials rather than copying values from an example.

## ⬇️ Backups and Recovery

The `docs/` directory contains operational documentation covering server maintenance, backups, upgrades, and recovery.

The core principle is that configuration, application state, and user data are different things:

- **Configuration** describes how a service should run.
- **Application state** may include databases, settings, indexes, and metadata.
- **User data** includes files such as a music library and downloads.

Keeping a copy of a Compose file is not a replacement for backing up databases or other persistent data. Likewise, rolling back a Docker image does not automatically roll back data that the application may have migrated.

Always identify the relevant data paths and make an appropriate backup before a significant update.

## 📜 Design Principles

- Prefer explicit image version tags when suitable upstream tags are available.
- Keep service configuration readable and under version control.
- Make upgrades one service at a time.
- Verify the application after deploying an update.
- Preserve a known-good rollback path.
- Avoid publishing secrets, private state, or unnecessary network details.

## ⚠️ Disclaimer

This repository reflects my personal homelab and environment. Paths, network settings, permissions, and service behavior depend on the local deployment.

The examples are provided for *reference* and may require adaptation. Review them carefully and consult each project's official documentation before using them in your own environment.
