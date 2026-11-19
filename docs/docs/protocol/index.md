# Protocol

Replycant protocol docs define the YAML manifest contract used by producers and consumers across the ecosystem.

## Scope

This section documents currently implemented manifest kinds:

- `Original`
- `ThumbnailSet`

Each type page includes:

- TypeScript type definitions for integration work
- YAML examples for on-disk manifest shape
- Field-level requirements and constraints

## Shared Manifest Envelope

All manifests use the same top-level envelope:

```yaml
apiVersion: media.replycant.com/v1alpha1
kind: [Original|ThumbnailSet]
metadata:
  name: [normalized-manifest-name]
spec:
  # Kind-specific fields
status: {}
```

A manifest's [encryption space](../gitdb/encryption.md#encryption-spaces) is
not a field. It is the `{space}` segment of the manifest's path,
`encryptionspaces/{space}/manifests/...`. Writers do not emit
`metadata.deviceSpace`, and readers ignore it when an existing manifest
still contains it.

## Common TypeScript Types

```ts
export interface ManifestMetadata {
  name: string;
}

export interface ManifestEnvelope<TKind extends string, TSpec> {
  apiVersion: "media.replycant.com/v1alpha1";
  kind: TKind;
  metadata: ManifestMetadata;
  spec: TSpec;
  status: Record<string, never>;
}
```

## Manifest Kind Pages

- [Original](./original.md)
- [ThumbnailSet](./thumbnail-set.md)
