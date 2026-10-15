# proAV.Net Edge

The on-site connector between a client's control processors and proAV.Net Cloud, for sites where processors cannot reach the internet directly. Processors point at the edge; the edge makes the one outbound connection (straight out or through the site's web proxy), registers itself in the portal as a device, and serves its own management dashboard.

This repository is the **distribution**: the installer, the compose file, the environment template and the release notes. The image is `ghcr.io/proav-net/proav-edge`, public, built and signed by proAV's CI.

## Requirements

- A Linux host with Docker Engine and the Compose plugin, x86-64 or ARM64 (a small VM is fine: 2 vCPU, 2 GB RAM, 20 GB disk; so is a Raspberry Pi 4 or an ARM mini-PC). The host needs a route to the cloud, directly or through a web proxy, and the processors need a route to the host.
- A namespace API key from the portal with the **device register** capability (**Settings → API keys → New key**). The edge only needs it for its first registration: once it is registered and **May enrol processors** is switched on for it in the portal, it enrols processors with its own device key and the key can be removed from `.env` (the dashboard's **Processors** tab says when).

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/proAV-net/proav-edge/main/install.sh | bash
```

The installer checks Docker, downloads this release's files into `/opt/proav-edge` (or `~/proav-edge` for a non-root user), asks for the edge's name, the cloud, the API key, a dashboard password and an optional proxy, pins the release in `.env`, starts the stack and prints the dashboard address and the certificate fingerprint processors pin. Options for unattended installs:

```bash
bash install.sh --cloud proav.cloud --api-key proav_ns... --name "Head office edge" --password '...' --yes
```

`--proxy http://host:port` for a site proxy, `--version 2026.10.15.123` to pin a particular release, `--no-https` to relay over plain HTTP only, `--dir` to choose the folder.

By hand: copy `docker-compose.yml` and `.env.example` (as `.env`) into a folder, fill in `.env`, run `docker compose up -d`.

## After installing

- Dashboard: `http://<host>:8090/edge/`, user `admin`. Overall status, the processors relayed, the cloud connection (and the proxy settings, changeable there), software updates, and the relay certificate.
- The edge appears in the portal as a device within a minute, on the location's **Edges** tab. Switch on **May enrol processors** there (Enrolment section), then remove `EDGE_CLOUD_API_KEY` from `.env` and run `docker compose up -d`: no namespace key stays on site.
- Deploys from the portal reach processors behind the edge through its package cache: each package or firmware file crosses the uplink once and is checked against its SHA-256 before it is kept (`EDGE_CACHE_MAX_GB`, default 10).
- Point a processor at the edge by changing its cloud config (the installer and the dashboard's **Processors** tab show the exact block). Over HTTPS the processor pins the edge's self-signed certificate by fingerprint; no certificate authority, no renewal.
- Or let new processors find it: with `"cloudConfig": { "host": "auto" }` a processor that is not registered yet browses the local network by mDNS, finds the edge (it advertises `_proav-edge._tcp` with its address, ports and certificate fingerprint), saves that into its config and asks to join; approve it on the dashboard. A registered processor never switches on its own. Discovery is why the compose file runs the edge with host networking (multicast does not cross Docker's bridge), so the edge uses the host's ports 8080, 8443, 8090 and UDP 5353 directly; set `EDGE_DISCOVERY=false` to turn the advertisement off.

## Updating

From the dashboard's **Software** tab: it lists the releases, with their notes, and installs one on request. The updater sidecar pulls the image, verifies its signature (a key signature that works offline, plus proAV's CI identity when Sigstore is reachable), swaps the container, waits for the new edge to be healthy and restores the old one if it is not. **Roll back** is one click. Or from the host:

```bash
cd /opt/proav-edge && docker compose pull && docker compose up -d
```

Releases are versioned `YYYY.MM.DD.REV`; `-beta` builds come from the `next` channel for test sites.

## Security notes

- The updater service mounts `/var/run/docker.sock`, which is root-equivalent on the host. It has no network port; only the edge's dashboard, behind its password, can ask it to do anything, and it only installs `ghcr.io/proav-net/proav-edge` images that carry a valid signature. On a shared host where that is not acceptable, remove the `updater` service and update from the command line.
- The identity, device key, settings, relay certificate and package cache live in the `edge-data` volume. Deleting it makes the edge a new device (and needs an API key again to register).
- The namespace API key can register devices in the whole namespace; remove it from `.env` once the edge is registered and allowed to enrol processors.
- The dashboard is for the site's engineers. Keep port 8090 off the internet.

## Verifying an image

```bash
cosign verify --key cosign.pub ghcr.io/proav-net/proav-edge:latest
cosign verify --certificate-identity-regexp '^https://github\.com/proAV-net/core/\.github/workflows/edge\.yml@refs/heads/(main|develop)$' \
              --certificate-oidc-issuer https://token.actions.githubusercontent.com ghcr.io/proav-net/proav-edge:latest
```

## Uninstall

```bash
cd /opt/proav-edge && docker compose down -v && cd .. && rm -rf proav-edge
```

Then unclaim the edge device in the portal.

## Support

Open an issue here for installation problems. Source, design notes and the full documentation are in proAV's internal repository.
