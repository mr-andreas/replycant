# ADR-0001: SyncEngine Agnostic Refactor

## Status

Accepted

## Context

`SyncEngine` imported `runtimeConfig` from outside the `gitdb` module and hardcoded replycant-specific constants (media path regex, FS volume name, log prefix, product-specific error messages). This contradicted the schema-agnostic architecture established by ADR-0017 and already followed by `ManifestRegistry` and `ManifestDatabase`.

## Decision

1. **`SyncEngineConfig` interface** — All runtime/app-specific values (`gitBranch`, `syncIntervalMs`, `gitRemoteUrl`, `fsVolumeName`, `initialCloneDepth`, `logPrefix`) are captured in a plain config object. Callers build it at the app boundary; the engine never imports application configuration directly.

2. **Registry-directed tree traversal** — Instead of walking the entire `manifests/` and `binary/` trees, the engine uses `ManifestRegistry.registeredKindDirectories()` to derive exact subtree paths (`{deviceSpace}/{apiVersion}/{kind}`) and reads only those via `git.readTree`. Unregistered kinds are never traversed or read.

3. **Path-aware decode validation** — A new `ManifestRegistry.decodeYamlForExpectedKind()` helper validates that a blob's envelope matches the subtree it was read from. The generic `decodeYaml()` retains its existing semantics for callers without path context.

4. **Worker config transport** — `SyncWorkerInitMessage` carries a full serializable `SyncEngineConfig` instead of ad-hoc fields, ensuring the worker and main-thread construction paths stay aligned.

## Consequences

- `syncEngine.ts` has no imports from outside the `gitdb` module boundary.
- Full hydration and incremental diff skip large unregistered subtrees entirely.
- Adding a new manifest kind only requires registering it; no sync engine constants or path patterns need updating.
- `computeBackoffMs` now requires an explicit `syncIntervalMs` parameter.
