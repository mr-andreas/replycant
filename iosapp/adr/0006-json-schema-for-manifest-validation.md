# ADR-0006: JSON Schema for Manifest Validation

## Status

Accepted

## Context

The application uses Kubernetes-style manifest files to store structured data (ADR-0003). As the system grows to support multiple platform implementations (iOS, Android, web, etc.), we need a formal, machine-readable contract that defines the structure and validation rules for each manifest type.

Without formal schemas:
- Each implementation might interpret manifest structures differently
- Breaking changes can be introduced without detection
- Validation logic must be duplicated across implementations
- Documentation lives separately from the schema definition
- No automated way to validate manifests before committing

Options considered:
1. **No formal schema**: Rely on documentation and runtime validation in each implementation
2. **JSON Schema**: Industry-standard, tool-rich ecosystem, language-agnostic
3. **Protocol Buffers**: More complex, requires code generation, overkill for YAML manifests
4. **Custom validation DSL**: Would require building our own tooling

## Decision

We will use JSON Schema (draft 2020-12) to formally define the structure, types, and validation rules for all manifest types. Each manifest type will have its own schema file.

### Storage Convention

Schemas will be stored at:
```
schemas/{apiVersion}/{kind}.json
```

Examples:
- `schemas/media.replycant.com/v1alpha1/Original.json`
- `schemas/media.replycant.com/v1alpha1/Thumbnail.json`

### Schema Requirements

Each schema must:
1. Specify JSON Schema version (`$schema`)
2. Include an `$id` that identifies the schema uniquely
3. Define the complete structure including `apiVersion`, `kind`, `metadata`, `spec`, and optional `status`
4. Enforce that `apiVersion` and `kind` match the schema's path
5. Include validation rules (required fields, types, patterns, ranges)
6. Include descriptions for all fields to serve as inline documentation

### Schema Versioning

- Schemas follow the apiVersion of the resources they validate
- Schema files are versioned through Git along with the manifests
- Breaking changes require a new apiVersion directory
- Non-breaking additions can be made to existing schemas with appropriate `required` field management

### Usage

Schemas serve multiple purposes:
1. **Cross-platform validation**: All implementations can validate manifests using the same schema
2. **Documentation**: Schemas document field meanings, constraints, and expectations
3. **Code generation**: Can generate type definitions for various languages
4. **CI/CD validation**: Automated testing can validate all manifests against their schemas
5. **Migration tooling**: Schema evolution enables building migration tools between versions

## Consequences

### Positive

- **Cross-platform consistency**: All implementations share the same validation rules
- **Self-documenting**: Schemas include field descriptions and constraints
- **Early error detection**: Manifests can be validated before commit or sync
- **Tooling ecosystem**: Rich ecosystem of JSON Schema validators and generators
- **Version management**: Schema evolution is tracked in Git alongside manifests
- **Language agnostic**: Works with any programming language
- **Industry standard**: Well-understood format with extensive tooling support
- **Test generation**: Can generate test fixtures from schemas
- **Contract enforcement**: Acts as formal API contract between implementations

### Negative

- **Additional maintenance**: Schemas must be kept in sync with code models
- **Validation overhead**: Runtime validation adds processing cost
- **Learning curve**: Team must understand JSON Schema syntax
- **YAML-JSON mismatch**: Schemas are JSON but manifests are YAML (minor tooling consideration)
- **Schema complexity**: Advanced validation rules can become verbose

### Integration Points

- Builds on manifest-based storage (ADR-0003)
- Schemas stored in Git repository alongside manifests
- Validation runs before libgit2 commits (ADR-0001)
- Ensures manifest integrity before LFS operations (ADR-0002)
- Compatible with both Original (ADR-0004) and Thumbnail (ADR-0005) architectures

