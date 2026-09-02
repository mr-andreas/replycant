# Replycant

A self-hosted photo library focused on privacy, data durability, and ease of use.

Replycant is a simple photo library based on proven technologies. It uses Git with LFS for storage of metadata and binary objects, mTLS for client authentication, Age for key encryption and AES-GCM for metadata/object encryption.

## Why Replycant

- **[Private by design](#private-by-design)** — photos and metadata are
  encrypted before upload; the server stores only ciphertext
- **[Based on proven technologies](#based-on-proven-technologies)** — uses Git
  and Git LFS, with metadata structured as YAML
- **[Zero-config hosting](#zero-config-hosting)** — start with Docker Compose
  and connect by scanning a QR code
- **[Easy to back up](#easy-to-back-up)** — copy or mirror your complete
  library using standard Git and filesystem tools
- **[Device-centric auth](#device-centric-auth)** — each device authenticates
  with its own mTLS certificate; no passwords or central user database

Part of Replycant is also an open source iOS app which is published on the app store.

![Replycant iOS and desktop](docs/static/img/readme/apps.png)

## Getting started

**1. Start the server**

Download [`docker-compose.yaml`](https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml)
from the latest GitHub Release, and then start it:

```bash
curl -fsSL -o docker-compose.yaml \
  https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml
docker compose up
```

This will use the directory where you have placed docker-compose.yaml for both metadata and binary storage, which is usually fine. If you wish to select another directory or change the published ports, create a `.env`, then bring the stack up:

```bash
cat > .env << EOF
REPLYCANT_DATA_DIR=/var/lib/replycant/data
REPLYCANT_LFS_DIR=/var/lib/replycant/lfs
REPLYCANT_GIT_PORT=8443
REPLYCANT_CA_PORT=8080
EOF
```

The Git server listens on port `8443` (HTTPS) by default, and the
discovery server on port `8080`. On the LAN the stack advertises as
`<hostname>.local`. Set `REPLYCANT_HOSTNAME` to override that name, and
`REPLYCANT_GIT_PORT` and `REPLYCANT_CA_PORT` when those defaults are
already in use. Already-linked devices need re-onboarding after a
hostname or port change.

> **Note:** On Mac and Windows, Docker runs in a VM, so hostname
> auto-detection does not work. Set the name this computer uses on the
> LAN before starting the stack:
>
> ```bash
> echo REPLYCANT_HOSTNAME=$(hostname) >> .env
> docker compose up
> ```

**2. Install the iOS client**

[iOS app on the App Store](https://apps.apple.com/se/app/replycant/id6760653798)

**3. Link a device**

Using your computer, open the URL that you host the server on. Usually, this is http://localhost:8080 (or `http://localhost:$REPLYCANT_CA_PORT` if you changed the CA port). Start the iOS app and scan the QR code.

## How Replycant works

### Private by design

Replycant encrypts photos, videos, and metadata on the client before uploading
them. The server stores only opaque ciphertext, so compromising the server is
not enough to expose your library. Only authorized devices hold the keys needed
to decrypt it.

### Based on proven technologies

Replycant builds on Git for versioned metadata and Git LFS for photos and
videos. Metadata is structured as YAML manifests, giving the library an
inspectable data model and a complete history instead of tying it to an opaque
hosted database.

### Zero-config hosting

On a typical Linux host, download the Docker Compose file and run
`docker compose up`. Replycant supplies sensible defaults for storage, ports,
and local-network discovery. Open the discovery page and scan its QR code to
connect the iOS app.

### Easy to back up

The Git repository can be copied, moved, or mirrored with established tools.
Git records the metadata history, while Git LFS storage holds encrypted media.
Backing up both gives you an independent copy of the complete library. Want an
extra backup somewhere? Simply create one using `git-replycant clone` and do
regular `git pull` to receive updates.

### Device-centric auth

Each device generates its own key pair and authenticates with an mTLS client
certificate. Private keys remain on the device, while authorized public keys
are committed to the library repository, making access control auditable
through Git history. New devices are authorized by an existing device using QR
codes—without passwords, user accounts, or a central identity database.

## Policies and support

- [Privacy policy](./PRIVACY.md)
- [Support](./SUPPORT.md)
