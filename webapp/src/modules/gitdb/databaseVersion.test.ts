import { describe, expect, it } from "vitest";
import {
  DatabaseVersionError,
  describeDatabaseVersionFailure,
  parseDatabaseVersion,
  requireSupportedDatabaseVersion,
} from "./databaseVersion";

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
  it("accepts the pinned version and rejects any other", () => {
    expect(() => requireSupportedDatabaseVersion("1\n")).not.toThrow();
    expect(() => requireSupportedDatabaseVersion("2\n")).toThrow(/unsupported gitdb database version 2/);
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

  it("asks the user to create a new library when the marker is missing or older", () => {
    const expected =
      "This library uses an incompatible database format and cannot be opened. Create a new library to continue - resyncing will not help.";
    expect(describeDatabaseVersionFailure(new DatabaseVersionError("missing gitdb/version"))).toBe(expected);
    expect(describeDatabaseVersionFailure(new DatabaseVersionError(
      "unsupported gitdb database version 1 (this client requires 2)",
    ))).toBe(expected);
  });
});
