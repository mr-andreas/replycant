// Pins the only gitdb/version this client will open so a plaintext
// marker cannot steer decryption onto a weaker path.
export const DATABASE_FORMAT_VERSION = 1;
export const DATABASE_VERSION_PATH = "gitdb/version";

// Names gitdb/version failures so sync and rewind can refuse without
// treating a format mismatch as a generic transport error.
export class DatabaseVersionError extends Error {
  readonly found?: number;
  readonly required?: number;

  constructor(message: string, extras?: { found?: number; required?: number }) {
    super(message);
    this.name = "DatabaseVersionError";
    this.found = extras?.found;
    this.required = extras?.required;
  }
}

// Turns a reject-only version check into the action the user can
// actually take. A newer marker means update the app; anything else
// means this library cannot be opened and resyncing will not help.
export const describeDatabaseVersionFailure = (error: DatabaseVersionError): string => {
  if (
    error.found != null &&
    error.required != null &&
    error.found > error.required
  ) {
    return `This library uses database format ${error.found}. This app supports format ${error.required}. Update the app to continue.`;
  }
  const match = error.message.match(
    /unsupported gitdb database version (\d+) \(this client requires (\d+)\)/,
  );
  if (match) {
    const found = Number(match[1]);
    const required = Number(match[2]);
    if (found > required) {
      return `This library uses database format ${found}. This app supports format ${required}. Update the app to continue.`;
    }
  }
  return "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help.";
};

// Parses gitdb/version so three language clients reject the same
// malformed markers instead of accepting signed or padded integers.
export const parseDatabaseVersion = (raw: Uint8Array | string): number => {
  const text = typeof raw === "string" ? raw : new TextDecoder().decode(raw);
  const trimmed = text.endsWith("\n") ? text.slice(0, -1) : text;
  if (trimmed.length === 0) {
    throw new DatabaseVersionError("gitdb/version is empty");
  }
  if (!/^[1-9][0-9]*$/.test(trimmed)) {
    throw new DatabaseVersionError(`invalid gitdb/version value ${JSON.stringify(trimmed)}`);
  }
  return Number(trimmed);
};

// Refuses any marker that is not an exact match for the pinned version
// so a tampered value can only deny service.
export const requireSupportedDatabaseVersion = (raw: Uint8Array | string): void => {
  const version = parseDatabaseVersion(raw);
  if (version !== DATABASE_FORMAT_VERSION) {
    throw new DatabaseVersionError(
      `unsupported gitdb database version ${version} (this client requires ${DATABASE_FORMAT_VERSION})`,
      { found: version, required: DATABASE_FORMAT_VERSION },
    );
  }
};
