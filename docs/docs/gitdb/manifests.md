# Manifests

GitDB stores all structured data as Kubernetes-style YAML manifest files. This approach provides version control, auditability, and distributed synchronization through standard Git operations.

For kind-specific protocol contracts (`Original`, `ThumbnailSet`), see [Protocol](../protocol/index.md).

## Manifest Structure

All resources follow this structure:

```yaml
apiVersion: [api-version-identifier]
kind: [resource-type]
metadata:
  name: [object-name]
  deviceSpace: [device-namespace]
spec:
  # Desired state fields
status:
  # Observed state fields (optional)
```

### Field Descriptions

| Field | Description |
|-------|-------------|
| `apiVersion` | Identifies the schema version (e.g., `media.replycant.com/v1alpha1`) |
| `kind` | The resource type (e.g., `Original`, `ThumbnailSet`) |
| `metadata.name` | Unique identifier for the object within its namespace |
| `metadata.deviceSpace` | Device namespace for isolation |
| `spec` | Desired state of the resource |
| `status` | Observed/operational state (reserved for future use) |

## Storage Path Convention

Manifests are stored at predictable paths based on their metadata:

```
manifests/{device-space}/{api-version}/{kind}/{name[0:2]}/{name[2:4]}/{name[4:]}.yaml
```

### Example Paths

```
manifests/iphone-14-abc123/media.replycant.com/v1alpha1/Original/im/g-/1234.yaml
manifests/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/im/g-/1234-thumbs.yaml
```

`ThumbnailSet` is a 1:N mapping: one manifest file lists multiple thumbnail entries, and each entry has its own binary pointer path in `binary/.../ThumbnailSet/{entry-name}`.

## Why Name Sharding Exists

Manifest names are sharded into two prefix directories (`XX/YY/`) to reduce git tree rewrite cost and pack growth.

- Git stores each directory as a tree object. Updating one file in a directory rewrites that directory tree object.
- Without sharding, one kind directory can hold 100,000+ files, so each commit rewrites an extremely large tree.
- Packfiles delta-compress tree objects, but giant trees that change a little still generate large deltas and bloat.
- With sharding, each kind directory has at most 256 first-level entries and each first-level shard has at most 256 second-level entries.
- A single-file change rewrites only a small leaf shard tree plus small parents, instead of one massive flat tree.
- This mirrors git's own object-store fanout strategy (`objects/ab/cdef...`).

## Naming Convention

Object names must follow this pattern to ensure filesystem and URL safety:

```
[a-z][a-z0-9-]{0,252}
```

### Rules

- Must start with a lowercase letter
- Can contain only lowercase letters, digits, and hyphens
- Must be between 1 and 253 characters
- Must be unique within the device space and resource type

### Normalization Process

When creating names from external identifiers (like photo library asset IDs):

1. Convert to lowercase
2. Replace non-alphanumeric characters (except hyphens) with hyphens
3. Collapse consecutive hyphens into single hyphens
4. Remove leading/trailing hyphens
5. If name doesn't start with a letter, prepend "a"
6. Truncate to 253 characters maximum

**Example:**
- Original ID: `E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001`
- Normalized: `e88f3b2a-1234-5678-9abc-def012345678-l0-001`

## Device Spaces

Every object must specify a `deviceSpace` in its metadata. Device spaces provide:

- **Namespace isolation**: Objects from different devices don't conflict
- **Multi-device support**: Each device writes to its own namespace
- **Query scoping**: Can filter queries by device
- **Conflict prevention**: Same asset ID from different devices won't collide

Device space identifiers are generated per-device and remain stable for the device's lifetime.

## Schema Evolution

The `apiVersion` field enables schema evolution:

- Breaking changes require a new API version (e.g., `v1alpha1` → `v1alpha2`)
- Non-breaking additions can be made within the same version
- Migration tools can transform manifests between versions
- Old manifests remain readable by checking their version

## Design Rationale

This manifest-based approach was chosen over traditional databases because:

**Advantages:**
- Full version control with Git history
- Built-in conflict resolution through Git merge strategies
- Human-readable format for debugging
- Distributed synchronization via Git push/pull
- Free audit trail through Git commits
- Easy backup and restore

**Trade-offs:**
- Not optimized for high-frequency writes (Git commit overhead)
- Query performance limited compared to indexed databases
- Requires YAML parsing for all reads
- Repository size grows with history (mitigated by LFS for binaries)
