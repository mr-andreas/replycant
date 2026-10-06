# ADR-0011: Headscale State Derived From Git

## Status
Accepted. Supersedes the parts of
[ADR-0010](0010-headscale-tailnet-transport.md) that say where tailnet keys
come from, that `hsproxy` is a pure byte splicer, and that keys are captured
at init time.

## Context
ADR-0010 put every device on a headscale tailnet and made `pubkeys/` the
authority for who may reach the control plane. Membership itself, though,
lived only in headscale's database:

- `headscale-init` minted gitd's pre-auth key once and wrote it to
  `gitd.authkey`.
- gitd minted each paired device's key and sealed it into the pairing record.
- A node re-authenticated from its own saved state on every later launch.

So the repository said who was authorized, but a separate database said who
was actually on the tailnet. Losing that database meant re-pairing every
device by hand. Removing a key from `pubkeys/` stopped new control sessions,
but nodes that were already registered stayed in every peer's netmap.

headscale generates key material itself and stores only a hash, so its keys
cannot be kept in git and replayed. What can be kept in git is the right to
ask for one.

## Decision
headscale's database is a cache of `pubkeys/`. Any node git authorizes can
mint a fresh single-use key whenever headscale does not know it.

- **Devices mint through hsproxy.** After authorizing the client
  certificate, `hsproxy` peeks the request line. It answers
  `POST /replycant/preauthkey` itself with a `tag:device` key minted over
  headscale's API, valid for 10 minutes. Every other request is spliced
  unchanged. Connections admitted under the empty-repository bootstrap
  exemption get `403` on that path, so only the CA page hands out keys
  while nothing is committed.
- **Clients log in whenever they need to.** A node that cannot use the
  tailnet shows up in one of two ways. A node starting from saved state
  headscale does not know, or whose key gitd expired, lands in
  `NeedsLogin`. A running node that a wiped headscale forgot keeps
  reporting `Running` while every map poll fails with
  `404 node not found`. The Go clients
  (`pkg/tailnetlogin`) and the iOS `TailnetManager` watch for both, mint a
  key through their loopback shim (pinned CA, device certificate,
  tailnet-first route), and log in again. They wait at least 30 seconds
  between mints.
- **gitd mints its own key** (`tag:server`) over headscale's API with the
  same watcher. `gitd.authkey` and `--tsnet-auth-key-file` are removed.
- **A first login gets its key before the node starts.** A node that has
  never logged in, sitting in `NeedsLogin`, does not register when the
  watcher restarts its backend with a key. So gitd mints a key on every
  start, and a device without a saved login mints one before starting. The
  watcher then waits one cooldown before second-guessing that login.
- **The pairing record drops `preauth_key`.** By the time the record is
  published, the authorizing device has already committed the new device's
  key, so the new device mints its own key. The first device still gets a
  key from the CA page, because nothing is in `pubkeys/` yet.
- **Revocation is reconciled from git.** gitd keeps a state file with the
  `pubkeys/` set it last reconciled. It compares that set with `main` at
  startup and after every successful push. If any key was removed, the
  first keys arrived, or the state is missing, it expires device nodes.
  Expiring rather than deleting matters: headscale 0.29 deletes a node
  without closing its live map session, so a running device would never
  notice, while an expiry is pushed to it and moves it to `NeedsLogin`.
- **gitd knows which node is whose.** headscale cannot store a node-to-key
  mapping: tags are fixed by the policy, and hostnames do not match key
  filenames. gitd learns it instead. Every authenticated request arrives
  over its tsnet listener, so gitd asks tsnet which node the peer address
  belongs to and records that node's machine key against the request's key
  fingerprint in the same state file. A revocation then expires only the
  device nodes not bound to a key still in `pubkeys/`: the revoked
  device's, and any gitd has not seen yet. Authorized devices among the
  latter log the same node back in with a minted key; the revoked one is
  refused and its node stays listed as expired. Machine keys rather than
  node IDs, because headscale's IDs restart after its database is wiped,
  and a stale ID could protect a node it no longer names. At the first
  push this spares the device that created the library, which has just
  authenticated with the key it pushed, and drops anything else that
  joined while the repository was empty.
- **Only the noise key is durable.** It is the control plane's identity, and
  every node pins it, so it moves to its own mount (`headscale/noise`).
  `headscale-init` replaces the API key whenever `headscale apikeys list` no
  longer shows it, and gitd and hsproxy re-read the key file on every call.

## Consequences

### Positive
- Deleting `headscale/lib` and running `docker compose up` recovers the
  whole tailnet without re-pairing anyone.
- Removing a `.pub` file takes that device off the tailnet within one push,
  not just off future control sessions.
- No tailnet credential is stored anywhere or carried in a pairing record.

### Negative
- A revocation also expires device nodes gitd has never seen authenticate,
  and losing gitd's state file makes the next reconcile treat every device
  that way. Each of those costs a mint and a brief reconnect.
- `hsproxy` is no longer a pure splicer. It parses one request line per
  connection, and it holds a headscale API key.
- A running node notices it was forgotten only through a log line, which
  depends on the wording of Tailscale's log messages.
