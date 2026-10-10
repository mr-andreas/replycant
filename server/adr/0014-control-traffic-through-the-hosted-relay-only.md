# ADR-0014: Control Traffic Through the Hosted Relay Only

## Status
Accepted. Supersedes the in-tailnet control splice in
[ADR-0010](0010-headscale-tailnet-transport.md): gitd's `:8444` listener,
the `gitd.replycant.internal` SAN on hsproxy, and the tailnet-first route
with a two-second fallback. Also supersedes the "tailnet-first route"
wording in
[ADR-0011](0011-headscale-state-derived-from-git.md).

## Context
ADR-0010 gave a joined device two ways to reach hsproxy. The first control
session of every launch still crossed the hosted relay, because a node
cannot route to peers until that session has brought it up. After the node
was up, both shims tried `gitd.replycant.internal:8444` first and fell back
to the relay after two seconds. gitd spliced that listener to hsproxy.

That second path did not move the session that was already open. Tailscale
keeps its control connection for the life of the node, so a desktop session
could sit on the relay for hours, and the tailnet path only served later
reconnects. The cost was a fallback state machine in Go and in Swift, a
second certificate name, a second policy port, and a status row whose only
job was to say which of the two paths had been used.

## Decision
Control traffic goes through the hosted relay only.

- gitd does not listen for control traffic on the tailnet. The headscale
  policy grants `tag:device` access to `tag:server` on the Git port only.
- hsproxy's certificate names only the tunnel hostname devices dial.
- The loopback shims dial that hostname and do not prefer a tailnet route.
- The apps no longer report a control path. The path to gitd (direct,
  DERP, or offline) is unchanged.

## Consequences

### Positive
- One control path, so a failed control connection is a failed dial rather
  than a two-second wait followed by a fallback.
- The relay remains a hard dependency either way: every launch already
  needs it for the first session.

### Negative
- The relay holds one control stream for each device that is online, not
  only for the moment it launches. Control traffic is netmap updates and
  keepalives, so this is connections and memory on a shard, not bandwidth.
