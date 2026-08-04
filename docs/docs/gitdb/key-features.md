# Key Features

GitDB exists to make Replycant durable, self-hostable, offline-capable, and
inspectable without depending on a hosted database service.

## Version Control

Every change is stored as a Git commit.

This gives Replycant a complete history of metadata changes, which makes it
possible to inspect what changed, recover from mistakes, and reason about data
as a timeline instead of only as the latest database state.

## Distributed Sync

GitDB syncs through ordinary Git push and pull operations.

This is desirable for self-hosting because the database is not tied to one
special server process or one physical location. A Git repository can be
replicated, backed up, moved, mirrored, or hosted in multiple places using
well-understood tooling. That makes Replycant easier to run at home, on a VPS,
or across several machines without designing a custom replication system first.

## Offline Operation

Clients keep a local copy of the repository and can read cached data without a
network connection.

This lets Replycant remain useful when a device is offline or the self-hosted
server is temporarily unavailable. The app can treat sync as a background
activity instead of requiring every database read to contact the server.

## Human-Readable Metadata

Structured data is stored as YAML manifests.

Human-readable data makes the system easier to debug and recover. A user or
developer can inspect the repository with ordinary text tools, understand what
objects exist, and diagnose bad state without requiring a proprietary database
viewer.

## Audit Trail

Git history records what changed and when.

For a personal media archive, this is valuable because the data is expected to
last a long time. An audit trail helps explain how the archive reached its
current state, whether a file was added by a device import, a repair task, or a
manual correction.

## Content Addressing

Media files and metadata references use SHA-256 hashes.

Content addressing gives Replycant a stable identity for binary data. It enables
integrity checks after download or decryption, supports deduplication when the
same media appears more than once, and makes corruption easier to detect.

## Untrusted Server Storage

GitDB encrypts application data before it reaches the server.

This lets the server act mostly as storage and synchronization infrastructure.
A compromised or curious server should not be enough to read the user's media
metadata or binary contents, which is especially important for a self-hosted
photo library.

## Large Object Separation

Large media files are stored separately from structured metadata using Git LFS.

This keeps the Git repository small enough to sync and query efficiently while
still allowing photos and videos to be part of the same logical database. The
metadata can change frequently without rewriting large binary objects.

## Device Isolation

Each device writes into its own device space.

Device spaces reduce conflicts between independently syncing clients. They let
multiple phones, browsers, or desktop clients contribute data to the same
archive without relying on every device to coordinate names globally.
