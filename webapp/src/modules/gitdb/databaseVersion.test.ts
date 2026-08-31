import { describe, expect, it } from "vitest";
import {
  DatabaseVersionError,
  DatabaseVersionUnreadableError,
  describeDatabaseVersionFailure,
  parseDatabaseVersion,
  requireAcceptedDatabaseVersion,
  requireNoDatabaseVersionDowngrade,
  requireSupportedDatabaseVersion,
} from "./databaseVersion";
import { describeSyncFailure } from "./syncDiagnostics";

describe("parseDatabaseVersion", () => {
  it("accepts an exact decimal integer", () => {
    expect(parseDatabaseVersion("1")).toBe(1);
    expect(parseDatabaseVersion("1\n")).toBe(1);
    expect(parseDatabaseVersion("42\n")).toBe(42);
    expect(parseDatabaseVersion(new TextEncoder().encode("1\n"))).toBe(1);
  });

  it("rejects malformed content", () => {
    const cases = ["", "\n", "0", "01", "+1", "-1", "1 2", "1\n2", "1 ", " 1", "abc", "1\r\n", "\uFEFF1", "1\n\n"];
    for (const input of cases) {
      expect(() => parseDatabaseVersion(input)).toThrow(/gitdb\/version/);
    }
  });
});

describe("requireSupportedDatabaseVersion", () => {
  it("accepts the pinned version and version 0, and rejects any other", () => {
    expect(() => requireSupportedDatabaseVersion("1\n")).not.toThrow();
    expect(() => requireAcceptedDatabaseVersion(0)).not.toThrow();
    expect(() => requireAcceptedDatabaseVersion(1)).not.toThrow();
    expect(() => requireSupportedDatabaseVersion("2\n")).toThrow(/unsupported gitdb database version 2/);
    expect(() => requireAcceptedDatabaseVersion(2)).toThrow(/unsupported gitdb database version 2/);
  });
});

describe("DatabaseVersionUnreadableError", () => {
  it("is not a DatabaseVersionError so sync can keep retrying", () => {
    const error = new DatabaseVersionUnreadableError("could not read gitdb/version");
    expect(error).toBeInstanceOf(Error);
    expect(error).not.toBeInstanceOf(DatabaseVersionError);
    expect(error.name).toBe("DatabaseVersionUnreadableError");
  });
});

describe("describeSyncFailure", () => {
  it("treats an unreadable marker as a retryable sync error", () => {
    const message = describeSyncFailure(
      "sync",
      new DatabaseVersionUnreadableError("could not read gitdb/version at abc"),
    );
    expect(message).toMatch(/could not read gitdb\/version/);
    expect(message).not.toMatch(/Restore the marker/);
    expect(message).not.toMatch(/Create a new library/);
  });
});

describe("requireNoDatabaseVersionDowngrade", () => {
  it("refuses when the observed version is below the stored cache format", () => {
    expect(() => requireNoDatabaseVersionDowngrade(0, 0)).not.toThrow();
    expect(() => requireNoDatabaseVersionDowngrade(1, 0)).not.toThrow();
    expect(() => requireNoDatabaseVersionDowngrade(0, 1)).toThrow(/was removed after this cache was built from format 1/);
  });
});

describe("describeDatabaseVersionFailure", () => {
  it("asks the user to update when the marker is newer than this client", () => {
    expect(describeDatabaseVersionFailure(new DatabaseVersionError(
      "unsupported gitdb database version 2 (this client requires 1)",
    ))).toBe(
      "This library uses database format 2. This app supports format 1. Update the app to continue.",
    );
  });

  it("asks the user to run the migration tool when the marker is older than this client", () => {
    expect(describeDatabaseVersionFailure(new DatabaseVersionError(
      "unsupported gitdb database version 1 (this client requires 2)",
      { found: 1, required: 2 },
    ))).toBe(
      "This library uses database format 1. This app supports format 2. Run the migration tool to continue.",
    );
  });

  it("asks the user to create a new library when the marker is malformed", () => {
    const expected =
      "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help.";
    expect(describeDatabaseVersionFailure(new DatabaseVersionError("gitdb/version is empty"))).toBe(expected);
  });

  it("warns when a previously synced marker was removed", () => {
    expect(describeDatabaseVersionFailure(new DatabaseVersionError(
      "gitdb/version was removed after this cache was built from format 1",
      { found: 0, required: 1 },
    ))).toBe(
      "This library's database format marker was removed after this app last synced format 1. This is unsafe to open. Restore the marker to continue.",
    );
  });
});
