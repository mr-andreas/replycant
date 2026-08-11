# Replycant

A self-hosted photo library focused on privacy, data durability, and ease of use.

Replycant is a simple photo library based on proven technologies. It uses Git with LFS for storage of metadata and binary objects, mTLS for client authentication, Age for key encryption and AES-GCM for metadata/object encryption.

Part of Replycant is also an open source iOS app which is published on the app store.

## Screenshots

![Replycant iOS and desktop](docs/static/img/readme/apps.png)

Regenerate with `make readme-screenshots`.

## Why Replycant

- **Untrusted server** — media and metadata are encrypted on-device; the server never sees plaintext
- **Git-backed storage (GitDB)** — ordinary push/pull sync, full history, easy backup and mirroring. Binary objects stored in Git LFS.
- **Zero-conf hosting** — bring up the stack with Docker Compose. No configuration needed.
- **Inspectable data** — YAML manifests and Git history you can read with ordinary tools

## Getting started

**1. Start the server**

Download [`docker-compose.yaml`](https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml)
from the latest GitHub Release, and then start it:

```bash
curl -fsSL -o docker-compose.yaml \
  https://github.com/mr-andreas/replycant/releases/latest/download/docker-compose.yaml
docker compose up
```

This will use the directory where you have placed docker-compose.yaml for both metadata and binary storage, which is usually fine. If you wish to select another directory, simply create a `.env` with storage paths, then bring the stack up:

```bash
cat > .env << EOF
REPLYCANT_DATA_DIR=/var/lib/replycant/data
REPLYCANT_LFS_DIR=/var/lib/replycant/lfs
EOF
```

The Git server listens on port `8443` (HTTPS). On the LAN it advertises as
`<hostname>.local`.

**2. Install the iOS client**

[iOS app on the App Store](https://apps.apple.com/) *(coming soon)*

**3. Link a device**

Using your computer, open the URL that you host the server on. Usually, this is http://localhost:8080. Start the iOS app and scan the QR code.

## Policies and support

- [Privacy policy](./PRIVACY.md)
- [Support](./SUPPORT.md)
