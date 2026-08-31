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

// Marks a failed object read so callers do not treat "could not
// open the tree" as "the marker is absent". This is a retryable
// transport problem, not a format verdict.
export class DatabaseVersionUnreadableError extends Error {
  constructor(message: string, options?: { cause?: unknown }) {
    super(message, options);
    this.name = "DatabaseVersionUnreadableError";
  }
}

// Turns a reject-only version check into the action the user can
// actually take. A newer marker means update the app; an older
// marker means run the migration tool; a stripped marker is a
// tamper warning; malformed means this library cannot be opened.
export const describeDatabaseVersionFailure = (error: DatabaseVersionError): string => {
  if (error.message.includes("was removed after this cache was built")) {
    const stored = error.required ?? Number(
      error.message.match(/built from format (\d+)/)?.[1],
    );
    const format = Number.isFinite(stored) ? stored : "unknown";
    return `This library's database format marker was removed after this app last synced format ${format}. This is unsafe to open. Restore the marker to continue.`;
  }
  const found = error.found ?? Number(
    error.message.match(/unsupported gitdb database version (\d+)/)?.[1],
  );
  const required = error.required ?? Number(
    error.message.match(/this client requires (\d+)/)?.[1],
  );
  if (Number.isFinite(found) && Number.isFinite(required) && found > required) {
    return `This library uses database format ${found}. This app supports format ${required}. Update the app to continue.`;
  }
  if (Number.isFinite(found) && Number.isFinite(required) && found < required) {
    return `This library uses database format ${found}. This app supports format ${required}. Run the migration tool to continue.`;
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

// Accepts the compiled pin and the pre-marker integer 0 so old alpha
// libraries stay readable until a later migration writes 1. The check
// is an explicit set, not `<= current`, so a future bump to 2 does
// not silently keep accepting 1.
export const isAcceptedDatabaseVersion = (version: number): boolean =>
  version === 0 || version === DATABASE_FORMAT_VERSION;

// Refuses any integer that is not in the accepted set so a tampered
// value can only deny service.
export const requireAcceptedDatabaseVersion = (version: number): void => {
  if (!isAcceptedDatabaseVersion(version)) {
    throw new DatabaseVersionError(
      `unsupported gitdb database version ${version} (this client requires ${DATABASE_FORMAT_VERSION})`,
      { found: version, required: DATABASE_FORMAT_VERSION },
    );
  }
};

// Parses a present marker and refuses any value outside the accepted
// set. Absence is handled by the blob reader, not by this parser.
export const requireSupportedDatabaseVersion = (raw: Uint8Array | string): void => {
  requireAcceptedDatabaseVersion(parseDatabaseVersion(raw));
};

// Refuses a later-absent marker when this cache was built from a
// higher format so a hostile strip cannot look like an old library.
export const requireNoDatabaseVersionDowngrade = (observed: number, stored: number): void => {
  if (observed < stored) {
    throw new DatabaseVersionError(
      `gitdb/version was removed after this cache was built from format ${stored}`,
      { found: observed, required: stored },
    );
  }
};
