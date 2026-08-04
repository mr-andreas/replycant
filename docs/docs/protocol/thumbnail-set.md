# ThumbnailSet

`ThumbnailSet` manifests define the metadata contract for all derived preview images of one `Original`.

Unlike `Original` (1 manifest -> 1 binary), `ThumbnailSet` is a 1:N mapping (1 manifest -> many binaries).

## TypeScript Definition

```ts
export interface ThumbnailEntry {
  name: string;
  sha256: string;
  width: number;
  height: number;
  filesize: number;
}

export interface ThumbnailSetSpec {
  originalRef: string;
  thumbnails: ThumbnailEntry[];
}

export type ThumbnailSetManifest = ManifestEnvelope<"ThumbnailSet", ThumbnailSetSpec>;
```

## YAML Example

```yaml
apiVersion: media.replycant.com/v1alpha1
kind: ThumbnailSet
metadata:
  name: e88f3b2a-1234-photo-thumbs
  deviceSpace: iphone-14-abc123
spec:
  originalRef: iphone-14-abc123/media.replycant.com/v1alpha1/Original/e88f3b2a-1234-photo
  thumbnails:
    - name: e88f3b2a-1234-photo-thumb-150x150
      sha256: b4f9d82c2e5a6f78901bc23de45fg6789012bcd34efg56789012345678901bcd
      width: 150
      height: 150
      filesize: 8192
    - name: e88f3b2a-1234-photo-thumb-225x225
      sha256: d9e1a3b0c4d95f7412aa6f90ab12cd34ef5678901abc23def456789012345678
      width: 225
      height: 225
      filesize: 15360
    - name: e88f3b2a-1234-photo-thumb-1024
      sha256: f2ab9c72d55aa0189c3ef0a4bc567def8901abc23def45678901234567890abc
      width: 1024
      height: 768
      filesize: 102400
status: {}
```

## Schema Reference

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `apiVersion` | yes | string | Current value: `media.replycant.com/v1alpha1` |
| `kind` | yes | string | Must be `ThumbnailSet` |
| `metadata.name` | yes | string | Normalized thumbnail-set manifest name |
| `metadata.deviceSpace` | yes | string | Device namespace for isolation |
| `spec.originalRef` | yes | string | Fully qualified reference to source `Original` |
| `spec.thumbnails` | yes | array | Available thumbnail variants for this original |
| `spec.thumbnails[].name` | yes | string | Entry name used to locate the thumbnail binary |
| `spec.thumbnails[].sha256` | yes | string | SHA-256 of the thumbnail binary |
| `spec.thumbnails[].width` | yes | integer | Thumbnail width in pixels |
| `spec.thumbnails[].height` | yes | integer | Thumbnail height in pixels |
| `spec.thumbnails[].filesize` | yes | integer | Thumbnail size in bytes |
| `status` | yes | object | Currently empty object |

## Resolving Binary Paths

To find a binary for a specific resolution:

1. Load the `ThumbnailSet` manifest for the original.
2. Pick the entry in `spec.thumbnails[]` matching your target resolution.
3. Build the pointer path using:

```
binary/{metadata.deviceSpace}/{apiVersion}/ThumbnailSet/{entry.name}
```

### Worked Example

Given:

- `apiVersion = media.replycant.com/v1alpha1`
- `metadata.deviceSpace = iphone-14-abc123`
- `entry.name = e88f3b2a-1234-photo-thumb-225x225`

The binary pointer path is:

```
binary/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/e88f3b2a-1234-photo-thumb-225x225
```

For the sample manifest above, the three entry paths are:

```
binary/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/e88f3b2a-1234-photo-thumb-150x150
binary/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/e88f3b2a-1234-photo-thumb-225x225
binary/iphone-14-abc123/media.replycant.com/v1alpha1/ThumbnailSet/e88f3b2a-1234-photo-thumb-1024
```

Each path stores one LFS pointer, and each pointer references one derived thumbnail binary.
