# Original

`Original` manifests define the metadata contract for full-resolution media stored in Git LFS.

## TypeScript Definition

```ts
export interface OriginalLocation {
  latitude: number;
  longitude: number;
  altitude?: number;
}

export interface OriginalSpec {
  id: string;
  localID?: string;
  sha256: string;
  path: string;
  filesize: number;
  mediaType: string;
  width: number;
  height: number;
  modifiedAt?: string;
  duration?: number;
  mimeType?: string;
  location?: OriginalLocation;
  isFavorite: boolean;
  isHidden: boolean;
  burstIdentifier?: string;
  createdAt: string;
  takenAt?: string;
  clientCTime?: string;
  guessedTakenAt?: string;
}

export type OriginalManifest = ManifestEnvelope<"Original", OriginalSpec>;
```

## YAML Example

```yaml
apiVersion: media.replycant.com/v1alpha1
kind: Original
metadata:
  name: e88f3b2a-1234-5678-9abc-def012345678-l0-001
  deviceSpace: iphone-14-abc123
spec:
  id: E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001
  localID: E88F3B2A-1234-5678-9ABC-DEF012345678/L0/001
  sha256: a3f8c92b1e4d5f67890ab12cd34ef5678901abc23def45678901234567890abc
  path: /var/mobile/Media/DCIM/100APPLE/IMG_1234.JPG
  filesize: 4521890
  mediaType: photo
  width: 4032
  height: 3024
  modifiedAt: 2025-10-19T14:23:45Z
  duration: null
  mimeType: image/jpeg
  location:
    latitude: 37.7749
    longitude: -122.4194
    altitude: 10.5
  isFavorite: false
  isHidden: false
  burstIdentifier: null
  createdAt: 2025-10-19T14:24:10Z
  takenAt: 2025-10-19T14:23:45Z
  clientCTime: 2025-10-19T14:23:45Z
  guessedTakenAt: 2025-10-19T14:23:45Z
status: {}
```

## Schema Reference

| Field | Required | Type | Notes |
|-------|----------|------|-------|
| `apiVersion` | yes | string | Current value: `media.replycant.com/v1alpha1` |
| `kind` | yes | string | Must be `Original` |
| `metadata.name` | yes | string | Normalized resource name used in manifest path |
| `metadata.deviceSpace` | yes | string | Device namespace for isolation |
| `spec.id` | yes | string | Source media identifier |
| `spec.localID` | no | string | Platform-local media identifier |
| `spec.sha256` | yes | string | SHA-256 of original binary |
| `spec.path` | yes | string | Source absolute path at ingest time |
| `spec.filesize` | yes | integer | Size in bytes |
| `spec.mediaType` | yes | string | Current values: `photo` or `video` |
| `spec.width` | yes | integer | Display pixel width (after EXIF/container rotation is applied) |
| `spec.height` | yes | integer | Display pixel height (after EXIF/container rotation is applied) |
| `spec.modifiedAt` | no | string | ISO-8601 timestamp |
| `spec.duration` | no | number | Video duration in seconds |
| `spec.mimeType` | no | string | MIME type such as `image/jpeg` |
| `spec.location` | no | object | Capture location; includes latitude/longitude and optional altitude |
| `spec.isFavorite` | yes | boolean | Favorite state from source library |
| `spec.isHidden` | yes | boolean | Hidden state from source library |
| `spec.burstIdentifier` | no | string | Burst grouping identifier |
| `spec.createdAt` | yes | string | Manifest creation timestamp |
| `spec.takenAt` | no | string | Capture timestamp if known |
| `spec.clientCTime` | no | string | Client filesystem ctime if provided |
| `spec.guessedTakenAt` | no | string | Best-effort capture timestamp |
| `status` | yes | object | Currently empty object |
