# Schema Validation

GitDB uses JSON Schema (draft 2020-12) to formally define the structure and validation rules for all manifest types. Schemas provide a machine-readable contract that ensures consistency across different platform implementations.

## Purpose

Without formal schemas, each implementation (iOS, Android, web) might interpret manifest structures differently. JSON Schema provides:

- **Cross-platform consistency**: All implementations share the same validation rules
- **Self-documenting**: Schemas include field descriptions and constraints
- **Early error detection**: Manifests can be validated before commit or sync
- **Contract enforcement**: Acts as formal API contract between implementations

## Schema Storage

Schemas are stored alongside manifests in the repository:

```
schemas/{apiVersion}/{kind}.json
```

### Examples

```
schemas/media.replycant.com/v1alpha1/Original.json
schemas/media.replycant.com/v1alpha1/ThumbnailSet.json
```

## Schema Requirements

Each schema must include:

1. **`$schema`**: JSON Schema version identifier
2. **`$id`**: Unique identifier for the schema
3. **Complete structure**: Define `apiVersion`, `kind`, `metadata`, `spec`, and `status`
4. **Constant enforcement**: Ensure `apiVersion` and `kind` match expected values
5. **Validation rules**: Required fields, types, patterns, ranges
6. **Descriptions**: Documentation for all fields

## Example Schema

```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "$id": "https://replycant.com/schemas/media.replycant.com/v1alpha1/Original.json",
  "type": "object",
  "required": ["apiVersion", "kind", "metadata", "spec"],
  "properties": {
    "apiVersion": {
      "const": "media.replycant.com/v1alpha1",
      "description": "API version for Original resources"
    },
    "kind": {
      "const": "Original",
      "description": "Resource type identifier"
    },
    "metadata": {
      "type": "object",
      "required": ["name", "deviceSpace"],
      "properties": {
        "name": {
          "type": "string",
          "pattern": "^[a-z][a-z0-9-]{0,252}$",
          "description": "Unique identifier for the resource"
        },
        "deviceSpace": {
          "type": "string",
          "description": "Device namespace for isolation"
        }
      }
    },
    "spec": {
      "type": "object",
      "required": ["id", "sha256", "filesize", "mediaType"],
      "properties": {
        "id": {
          "type": "string",
          "description": "Original asset identifier from source library"
        },
        "sha256": {
          "type": "string",
          "pattern": "^[a-f0-9]{64}$",
          "description": "SHA-256 hash of binary content"
        },
        "filesize": {
          "type": "integer",
          "minimum": 0,
          "description": "File size in bytes"
        },
        "mediaType": {
          "enum": ["photo", "video"],
          "description": "Type of media content"
        }
      }
    }
  }
}
```

## Schema Versioning

Schemas follow the `apiVersion` of the resources they validate:

- Schemas are versioned through Git alongside manifests
- Breaking changes require a new `apiVersion` directory
- Non-breaking additions can extend existing schemas
- Old manifests remain valid against their version's schema

## Usage Scenarios

### Validation Before Commit

Validate manifests locally before committing to prevent invalid data:

```swift
let validator = JSONSchemaValidator(schema: originalSchema)
let result = validator.validate(manifest)
if !result.isValid {
    // Handle validation errors
}
```

### CI/CD Pipeline

Automated testing can validate all manifests against their schemas on every commit.

### Code Generation

Generate type definitions for various languages from schemas, ensuring type safety across platforms.

### Migration Tooling

Schema evolution enables building migration tools that transform manifests between versions while preserving validity.

## Benefits

| Benefit | Description |
|---------|-------------|
| Cross-platform | All implementations validate identically |
| Self-documenting | Field descriptions live with the schema |
| Tooling ecosystem | Rich ecosystem of JSON Schema validators |
| Language agnostic | Works with any programming language |
| Test generation | Generate test fixtures from schemas |

## Trade-offs

| Consideration | Impact |
|---------------|--------|
| Maintenance | Schemas must stay in sync with code models |
| Validation overhead | Runtime validation adds processing cost |
| Learning curve | Team must understand JSON Schema syntax |
| YAML-JSON | Schemas are JSON but manifests are YAML |
