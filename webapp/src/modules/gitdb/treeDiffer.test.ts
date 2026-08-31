import { describe, expect, it, vi } from "vitest";
import git from "isomorphic-git";
import { TreeDiffer } from "./treeDiffer";

describe("TreeDiffer.discoverDeviceSpaces", () => {
  const createDiffer = () =>
    new TreeDiffer({
      fs: { promises: {} } as never,
      gitdir: "/repo",
      registeredKindDirectories: () => [],
      log: () => {},
      cache: {},
    });

  it("returns absent device spaces when the root tree has no manifests entry", async () => {
    vi.spyOn(git, "readCommit").mockResolvedValue({
      oid: "commit",
      commit: { tree: "root-oid" },
      payload: "",
    } as never);
    vi.spyOn(git, "readTree").mockResolvedValue({
      oid: "root-oid",
      tree: [{ path: "gitdb", oid: "gitdb-oid", type: "tree", mode: "040000" }],
    } as never);

    await expect(createDiffer().discoverDeviceSpaces("commit")).resolves.toEqual({
      status: "ok",
      deviceSpaces: [],
    });
    vi.restoreAllMocks();
  });

  it("reports unreadable when the commit cannot be opened", async () => {
    const cause = new Error("repo not fetch-ready");
    vi.spyOn(git, "readCommit").mockRejectedValue(cause);

    await expect(createDiffer().discoverDeviceSpaces("commit")).resolves.toEqual({
      status: "unreadable",
      cause,
    });
    vi.restoreAllMocks();
  });
});
