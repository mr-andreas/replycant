# ADR-0003: Manifest-Based Git Database

## Status

Accepted

## Context

The application requires a structured data storage mechanism that provides versioning, auditability, and distributed synchronization capabilities. Traditional database solutions (SQLite, Core Data, Realm) do not natively provide these features.

Kubernetes demonstrates a proven pattern where the API server stores resource manifests in etcd as the source of truth. This approach provides:
- Declarative resource management
- Complete audit trail of changes
- Version control and rollback capabilities
- Conflict resolution through Git's merge capabilities

Options considered:
1. **Traditional database with separate versioning**: Adds complexity and doesn't solve distributed synchronization
2. **Manifest-based Git storage**: Store structured YAML manifests directly in Git repository
3. **Hybrid approach**: Database for active data, Git for archival - introduces consistency challenges

## Decision

We will implement a manifest-based database stored in the Git repository, following Kubernetes-style resource definitions.

### Manifest Structure

All resources will use the following structure:

```yaml
apiVersion: [api-version-identifier]
kind: [api-resource-name]
metadata:
  name: [object-name]
  deviceSpace: [device-space]
  ...
spec:
  ...
status:
  ...
```

### Storage Path Convention

Manifests will be stored at:
```
manifests/[device-space]/[api-version-identifier]/[api-resource-name].yaml
```

### Device Space Requirement

- All objects MUST specify a deviceSpace in metadata
- Device spaces provide namespace isolation for multi-device scenarios
- Initially hardcoded to "devspc" for all objects (to be expanded later)

### Naming Convention

Object names MUST adhere to the following regular expression pattern:
```
[a-z][a-z0-9-]+{0,252}
```

This ensures:
- Names start with a lowercase letter
- Names contain only lowercase letters, digits, and hyphens
- Names are between 1 and 253 characters in length
- Names are filesystem-safe and URL-safe

## Consequences

### Positive
- Full version control of all data changes with Git history
- Declarative state management similar to Kubernetes
- Built-in conflict resolution through Git merge strategies
- Human-readable YAML format for debugging and manual inspection
- Distributed synchronization via Git push/pull operations
- Audit trail comes free with Git commits
- Easy backup and restore through Git operations
- Device-specific namespacing through deviceSpace concept

### Negative
- Not optimized for high-frequency writes (Git commits have overhead)
- Query performance limited compared to indexed databases
- Need to parse YAML for all read operations
- Git repository size grows with history (mitigated by LFS for binaries)
- Requires careful commit strategy to avoid excessive repository bloat
- Need custom indexing layer for complex queries

### Implementation Notes
- Manifest files use YAML format for human readability
- Path structure enables filesystem-based organization and discovery
- deviceSpace is mandatory in metadata for all resources
- apiVersion enables schema evolution and migration
- kind identifies the resource type
- spec contains desired state, status contains observed state (Kubernetes pattern)
- Initial implementation uses hardcoded "devspc" deviceSpace
- Future work will implement proper device space management

### Integration Points
- Works with libgit2 (ADR-0001) for repository operations
- Compatible with manual LFS implementation (ADR-0002) for large binary data
- Manifest files themselves should be small (pointer files for binaries via LFS)

