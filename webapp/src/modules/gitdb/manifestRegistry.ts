// Carries one decoded manifest record through gitdb's storage and event pipeline without
// gitdb needing to know the concrete type. The app provides decode/primaryKey at registration;
// gitdb decodes YAML and resolves keys generically, while the app resolves LFS pointer data
// separately via the pointer table when it needs encryption or download metadata.
export interface RegisteredManifestRecord {
  apiVersion: string;
  kind: string;
  key: string;
  manifest: unknown;
}

// Describes one non-unique index so the app can declare queryable projections at registration time
// without gitdb understanding the projected field's domain meaning.
export interface ManifestIndexDefinition {
  name: string;
  fieldPath: string;
  multiEntry?: boolean;
}

// Captures one app-provided manifest kind registration so gitdb can decode, key, and
// persist manifests generically while the app retains full control of schema and semantics.
export interface ManifestKindRegistration<T = unknown> {
  apiVersion: string;
  kind: string;
  decode: (rawYaml: string) => T | null;
  primaryKey: (decoded: T) => string;
  indexes?: ManifestIndexDefinition[];
}

// Normalizes resource identity into one deterministic object-store name derived from apiVersion and kind.
export const deriveManifestStoreName = (apiVersion: string, kind: string): string => {
  const normalizedApiVersion = apiVersion.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "").toLowerCase();
  const normalizedKind = kind.replace(/[^a-zA-Z0-9]+/g, "_").replace(/^_+|_+$/g, "");
  return `manifests_${normalizedApiVersion}_${normalizedKind}`;
};

// Produces one stable schema key so registration lookups do not depend on object identity.
const registrationKey = (apiVersion: string, kind: string): string => `${apiVersion}::${kind}`;

// Owns manifest kind registrations so gitdb can decode any YAML blob by kind without importing
// app-layer types. Mirrors the iOS ManifestRegistry pattern from ADR-0017.
export class ManifestRegistry {
  private readonly registrations = new Map<string, ManifestKindRegistration>();

  register<T>(registration: ManifestKindRegistration<T>): void {
    const key = registrationKey(registration.apiVersion, registration.kind);
    if (this.registrations.has(key)) {
      throw new Error(`Manifest kind already registered: ${registration.apiVersion}/${registration.kind}`);
    }
    this.registrations.set(key, registration as ManifestKindRegistration);
  }

  get(apiVersion: string, kind: string): ManifestKindRegistration | undefined {
    return this.registrations.get(registrationKey(apiVersion, kind));
  }

  has(apiVersion: string, kind: string): boolean {
    return this.registrations.has(registrationKey(apiVersion, kind));
  }

  allRegistrations(): ManifestKindRegistration[] {
    return [...this.registrations.values()];
  }

  // Returns the repo-relative directory suffix for each registered kind so the sync engine
  // can target only registered subtrees during tree traversal.
  registeredKindDirectories(): string[] {
    return [...this.registrations.values()].map(
      (reg) => `${reg.apiVersion}/${reg.kind}`,
    );
  }

  // Extracts kind from a YAML envelope's top-level fields and decodes via the matching registration.
  // Returns null if the kind is unregistered or decoding fails.
  decodeYaml(rawYaml: string): { apiVersion: string; kind: string; decoded: unknown } | null {
    const apiVersionMatch = rawYaml.match(/^apiVersion:\s*(.+)$/m);
    const kindMatch = rawYaml.match(/^kind:\s*(.+)$/m);
    if (!apiVersionMatch || !kindMatch) return null;
    const apiVersion = apiVersionMatch[1].trim();
    const kind = kindMatch[1].trim();
    const registration = this.get(apiVersion, kind);
    if (!registration) return null;
    const decoded = registration.decode(rawYaml);
    if (decoded == null) return null;
    return { apiVersion, kind, decoded };
  }

  // Decodes a YAML blob that is expected to belong to a specific registered kind because
  // the sync engine read it from a targeted subtree. Throws when the blob's envelope does
  // not match the expected identity or when the expected kind has no registration.
  decodeYamlForExpectedKind(
    rawYaml: string,
    expected: { apiVersion: string; kind: string },
  ): { apiVersion: string; kind: string; decoded: unknown } | null {
    const apiVersionMatch = rawYaml.match(/^apiVersion:\s*(.+)$/m);
    const kindMatch = rawYaml.match(/^kind:\s*(.+)$/m);
    if (!apiVersionMatch || !kindMatch) return null;
    const apiVersion = apiVersionMatch[1].trim();
    const kind = kindMatch[1].trim();
    if (apiVersion !== expected.apiVersion || kind !== expected.kind) {
      throw new Error(
        `Manifest envelope mismatch: expected ${expected.apiVersion}/${expected.kind}, ` +
        `got ${apiVersion}/${kind}`,
      );
    }
    const registration = this.get(apiVersion, kind);
    if (!registration) {
      throw new Error(`No registration for expected kind ${apiVersion}/${kind}`);
    }
    const decoded = registration.decode(rawYaml);
    if (decoded == null) return null;
    return { apiVersion, kind, decoded };
  }

  // Resolves the primary key for a decoded manifest using the app-provided key extractor.
  resolveKey(apiVersion: string, kind: string, decoded: unknown): string {
    const registration = this.get(apiVersion, kind);
    if (!registration) {
      throw new Error(`No registration for ${apiVersion}/${kind}`);
    }
    return registration.primaryKey(decoded);
  }
}
