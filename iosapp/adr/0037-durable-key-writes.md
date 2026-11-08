# ADR-0037: Durable key writes

## Status

Accepted

## Context

Adding or removing a device key or a recovery key committed locally
and then pushed. When the push failed, the commit stayed on the
device. A later push could conflict with history another device had
published, and a new device kept waiting for a key that never reached
the server.

Waiting for the tailnet before linking stops one way to create that
commit. It does not cover a push that fails after the commit, a
recovery-key change, or a library that has already diverged from the
server.

## Decision

GitDB provides a durable commit for these writes:

- Wait until the tailnet is connected. The app supplies that wait.
  GitDB does not import the tailnet.
- Hold the repository lock for the rest of the operation, so no other
  write lands in the middle. The settings status refresh fetches
  under that same lock.
- Fetch, and require HEAD to equal the remote branch. Otherwise
  refuse without writing.
- Build the file change only after that check, so a key re-wrap reads
  the commit the push will extend.
- Commit, then push. If the push fails, move the branch back to the
  checked commit and leave the manifest cache unchanged.

Device linking and recovery-key creation and removal use this path.
Photo uploads, first-device setup, and recovery enrollment do not.
Those still commit before a later push.

A thrown error does not prove the server missed the commit. The
server can accept the push and drop the connection before the reply.
The local commit is removed in that case too. The next pull
fast-forwards to the server's copy, and a retry asks the user to sync
first.

## Consequences

- A failed key write leaves the device where it started, or one pull
  away from a commit the server already stored.
- Photo uploads can still sit unpublished. They are not key changes.
- The settings screen no longer fetches on a second repository
  instance, so it cannot race a key write's remote-tracking refs.
