# Importing Media

`replycant-importer` bulk-imports photos and videos into a Replycant
repository. It encrypts each binary, uploads ciphertext to the LFS
server, and commits only LFS pointer files plus manifests.

## Prerequisites

- A repository cloned with `git-replycant clone --no-lfs`
- `ffmpeg` and `ffprobe` on your `PATH`
- An authorized device identity in the clone (created during onboarding)

Full-LFS clones (with `binary/** filter=replycant-crypt` or `lfs.url`)
are rejected. Re-clone with `--no-lfs` before importing.

## Usage

```bash
replycant-importer /path/to/repo /path/to/media device-space-name
```

Optional flags:

- `--push-every N` — push after every N commits (with fetch/rebase on rejection)
- `--workers N` — parallel import workers (default: all CPUs)
- `-v` / `--verbose` — stream git and LFS upload progress

## How It Differs From Interactive Clients

iOS and normal `git-replycant` clones still use the clean filter plus
pre-push hook: plaintext binaries land in the worktree, git encrypts
them on `git add`, and the pre-push hook uploads on `git push`.

The importer skips that path for throughput. It never stages plaintext
under `binary/**`. Instead it:

1. Encrypts each original/thumbnail with a fresh DEK
2. Uploads the ciphertext through the LFS batch API
3. Writes the pointer file (including Replycant encryption headers)
4. Commits the pointer alongside the YAML manifests

That keeps rebases cheap because Git only moves small pointer blobs.

Scanning the source tree overlaps with import work: workers begin
encrypting and uploading as soon as files are discovered. Progress
lines show `(calculating, N found)` as the denominator until the scan
finishes, then switch to the concrete total.
