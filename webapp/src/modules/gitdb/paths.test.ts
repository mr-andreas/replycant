import { describe, expect, it } from "vitest";
import { shardName, deriveBinaryPointerPath } from "./paths";

describe("shardName", () => {
  it("returns short names unchanged", () => {
    expect(shardName("AB")).toBe("AB");
    expect(shardName("ABCD")).toBe("ABCD");
  });

  it("shards names of 5+ characters into fanout directories", () => {
    expect(shardName("ABCDE")).toBe("AB/CD/E");
    expect(shardName("ABCDEF")).toBe("AB/CD/EF");
    expect(shardName("ABCDEFGHIJ")).toBe("AB/CD/EFGHIJ");
  });
});

describe("deriveBinaryPointerPath", () => {
  it("constructs binary pointer path with sharded name", () => {
    expect(
      deriveBinaryPointerPath("myDevice", "media.replycant.com/v1alpha1", "Original", "ABCDEFGH"),
    ).toBe("binary/myDevice/media.replycant.com/v1alpha1/Original/AB/CD/EFGH");
  });

  it("constructs binary pointer path with short name", () => {
    expect(
      deriveBinaryPointerPath("dev", "media.replycant.com/v1alpha1", "ThumbnailSet", "AB"),
    ).toBe("binary/dev/media.replycant.com/v1alpha1/ThumbnailSet/AB");
  });
});
