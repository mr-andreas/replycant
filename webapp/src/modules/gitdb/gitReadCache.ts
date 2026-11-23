// A full resync reads every manifest by object id. Each read stats the
// git directory, lists the pack directory, and misses a loose object
// this repository never wrote. Those answers stay the same until a
// write, and repeating them is what makes "Reading manifests" take
// milliseconds per file.

const mutatingMethods = new Set([
  "writeFile",
  "unlink",
  "mkdir",
  "rmdir",
  "rename",
  "symlink",
  "backFile",
  "rm",
  "cp",
  "truncate",
  "chmod",
  "init",
]);

const looseObjectPath = /^(.*)\/objects\/([0-9a-f]{2})\/[0-9a-f]{38}$/;

type AsyncMethod = (...args: never[]) => Promise<unknown>;

interface ReadPromises {
  readdir(path: string, opts?: unknown): Promise<string[]>;
  stat(path: string, opts?: unknown): Promise<unknown>;
  lstat(path: string, opts?: unknown): Promise<unknown>;
  readFile(path: unknown, opts?: unknown): Promise<unknown>;
}

// Remembers directory listings and stats, and answers a missing loose
// object from the objects directory instead of touching the filesystem.
export function cacheRepeatedGitReads(fs: { promises: object }): void {
  const inner = fs.promises as ReadPromises & Record<PropertyKey, unknown>;
  let generation = 0;
  const readdirCache = new Map<string, { generation: number; names: string[] }>();
  const statCache = new Map<string, { generation: number; value: unknown }>();
  const lstatCache = new Map<string, { generation: number; value: unknown }>();

  // A write can land while a listing is still being read. The generation
  // keeps that stale listing from being stored as the current one.
  const invalidate = (): void => {
    generation += 1;
    readdirCache.clear();
    statCache.clear();
    lstatCache.clear();
  };

  const canReaddir = typeof inner.readdir === "function";
  const readdir = async (filepath: string, opts?: unknown): Promise<string[]> => {
    if (!cacheableOptions(opts)) return inner.readdir(filepath, opts);
    const key = normalizeGitPath(filepath);
    const hit = readdirCache.get(key);
    if (hit && hit.generation === generation) return hit.names.slice();
    const started = generation;
    const names = await inner.readdir(filepath, opts);
    if (started === generation) readdirCache.set(key, { generation: started, names });
    return names.slice();
  };

  // A backend that never stats or lists has nothing to remember.
  // Wrapping the missing method would throw before the first read.
  const stat = typeof inner.stat === "function" ? cachedStat(inner.stat.bind(inner), statCache) : undefined;
  const lstat = typeof inner.lstat === "function" ? cachedStat(inner.lstat.bind(inner), lstatCache) : undefined;

  const readFile = async (filepath?: unknown, opts?: unknown): Promise<unknown> => {
    if (canReaddir && typeof filepath === "string") {
      const match = looseObjectPath.exec(normalizeGitPath(filepath));
      if (match) {
        const shard = match[2];
        let names: string[];
        try {
          names = await readdir(`${match[1]}/objects`);
        } catch (error) {
          const code = (error as { code?: string }).code;
          if (code === "ENOENT" || code === "ENOTDIR") throw missingFile(filepath);
          throw error;
        }
        if (!names.includes(shard)) throw missingFile(filepath);
      }
    }
    return inner.readFile(filepath, opts);
  };

  function cachedStat(
    read: (filepath: string, opts?: unknown) => Promise<unknown>,
    cache: Map<string, { generation: number; value: unknown }>,
  ): (filepath: string, opts?: unknown) => Promise<unknown> {
    return async (filepath: string, opts?: unknown) => {
      if (!cacheableOptions(opts)) return read(filepath, opts);
      const key = normalizeGitPath(filepath);
      const hit = cache.get(key);
      if (hit && hit.generation === generation) return hit.value;
      const started = generation;
      const value = await read(filepath, opts);
      if (started === generation) cache.set(key, { generation: started, value });
      return value;
    };
  }

  fs.promises = new Proxy(inner, {
    get(target, prop, receiver) {
      if (prop === "readdir" && canReaddir) return readdir;
      if (prop === "stat" && stat) return stat;
      if (prop === "lstat" && lstat) return lstat;
      if (prop === "readFile" && typeof target.readFile === "function") return readFile;
      if (typeof prop === "string" && mutatingMethods.has(prop)) {
        const method = target[prop];
        if (typeof method === "function") {
          return (...args: unknown[]) => {
            invalidate();
            return (method as AsyncMethod).apply(target, args as never[]);
          };
        }
      }
      const value = Reflect.get(target, prop, receiver);
      return typeof value === "function" ? (value as AsyncMethod).bind(target) : value;
    },
  });
}

// Options such as withFileTypes change the listing shape, so only a
// plain listing is safe to reuse.
function cacheableOptions(opts: unknown): boolean {
  return opts == null || (typeof opts === "object" && Object.keys(opts as object).length === 0);
}

function normalizeGitPath(filepath: string): string {
  const absolute = filepath.startsWith("/");
  const parts: string[] = [];
  for (const part of filepath.split("/")) {
    if (part === "" || part === ".") continue;
    if (part === "..") {
      parts.pop();
      continue;
    }
    parts.push(part);
  }
  const joined = parts.join("/");
  return absolute ? `/${joined}` : joined;
}

function missingFile(filepath: string): Error {
  const error = new Error(`ENOENT: no such file or directory, open '${filepath}'`) as Error & { code: string };
  error.code = "ENOENT";
  return error;
}
