import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export interface ProxyConfig {
  gitBaseUrl?: string;
  lfsBaseUrl?: string;
  transcodedBaseUrl?: string;
  decryptdBaseUrl?: string;
  port: number;
  upstreamCa?: string;
}

// Captures startup overrides so operators can route proxy traffic without env-only workflows.
export interface CliArgs {
  gitBaseUrl?: string;
  transcodedBaseUrl?: string;
  decryptdBaseUrl?: string;
  port?: number;
  gitCaCert?: string;
  gitCaCertFile?: string;
}

// Parses `--flag value` and `--flag=value` CLI syntax used by npm/tsx startup scripts.
export const parseCliArgs = (argv: string[] = process.argv.slice(2)): CliArgs => {
  const args: CliArgs = {};
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token?.startsWith("--")) continue;
    const [rawKey, inlineValue] = token.slice(2).split("=", 2);
    const nextValue = inlineValue ?? argv[index + 1];
    const consumeNext = inlineValue === undefined && nextValue !== undefined && !nextValue.startsWith("--");
    const value = consumeNext ? nextValue : inlineValue;
    if (consumeNext) index += 1;
    if (value === undefined) continue;
    switch (rawKey) {
      case "git-base-url":
      case "gitBaseUrl":
        args.gitBaseUrl = value;
        break;
      case "transcoded-base-url":
      case "transcodedBaseUrl":
        args.transcodedBaseUrl = value;
        break;
      case "decryptd-base-url":
      case "decryptdBaseUrl":
        args.decryptdBaseUrl = value;
        break;
      case "git-ca-cert":
      case "gitCaCert":
        args.gitCaCert = value;
        break;
      case "git-ca-cert-file":
      case "gitCaCertFile":
        args.gitCaCertFile = value;
        break;
      case "port": {
        const parsed = Number(value);
        if (Number.isFinite(parsed)) {
          args.port = parsed;
        }
        break;
      }
      default:
        break;
    }
  }
  return args;
};

interface ConfigLoadDependencies {
  exists: (path: string) => boolean;
  readText: (path: string, encoding: BufferEncoding) => string;
  resolvePath: (...paths: string[]) => string;
  cwd: () => string;
}

// Loads optional Git CA material so setup can start unconfigured and switch at runtime after discovery.
const loadOptionalUpstreamCa = (
  cliArgs: CliArgs,
  env: NodeJS.ProcessEnv,
  deps: ConfigLoadDependencies,
): string | undefined => {
  const inlineCa = cliArgs.gitCaCert ?? env.GIT_CA_CERT;
  if (inlineCa !== undefined) {
    const normalized = inlineCa.trim();
    if (normalized.length === 0) {
      throw new Error("Git CA certificate is empty. Set --gitCaCert or GIT_CA_CERT to a PEM value.");
    }
    return normalized;
  }

  const explicitCaFile = cliArgs.gitCaCertFile ?? env.GIT_CA_CERT_FILE;
  const caFile = explicitCaFile ?? deps.resolvePath(deps.cwd(), "server.crt");
  if (!deps.exists(caFile)) {
    if (explicitCaFile) {
      throw new Error(
        `Git CA certificate file not found at "${caFile}". Set --gitCaCert/--gitCaCertFile or GIT_CA_CERT/GIT_CA_CERT_FILE.`,
      );
    }
    return undefined;
  }
  let fileContents: string;
  try {
    fileContents = deps.readText(caFile, "utf8");
  } catch (error) {
    const detail = error instanceof Error ? error.message : String(error);
    throw new Error(`Failed to read Git CA certificate file at "${caFile}": ${detail}`);
  }
  const normalized = fileContents.trim();
  if (normalized.length === 0) {
    throw new Error(`Git CA certificate file at "${caFile}" is empty.`);
  }
  return normalized;
};

// Derives a backend service route from the git origin. Every backend service is
// proxied by gitd under its own path prefix, so reusing the git origin is what
// makes those services inherit gitd's mTLS boundary instead of being exposed on
// their own unauthenticated ports.
const deriveServiceBaseUrl = (gitBaseUrl: string | undefined, path: string): string | undefined => {
  if (!gitBaseUrl) {
    return undefined;
  }
  try {
    const gitURL = new URL(gitBaseUrl);
    return `${gitURL.protocol}//${gitURL.host}${path}`;
  } catch {
    return undefined;
  }
};

// Derives LFS base URL from git origin so clients always use the same server.
const deriveLfsBaseUrl = (gitBaseUrl: string | undefined): string | undefined =>
  deriveServiceBaseUrl(gitBaseUrl, "/lfs");

// Resolves transcoded routing with explicit config taking precedence over git-origin derivation.
export const resolveTranscodedBaseUrl = (
  configuredTranscodedBaseUrl: string | undefined,
  runtimeGitBaseUrl?: string,
): string | undefined => configuredTranscodedBaseUrl ?? deriveServiceBaseUrl(runtimeGitBaseUrl, "/transcoded");

// Resolves decryptd routing with explicit config taking precedence over git-origin derivation.
export const resolveDecryptdBaseUrl = (
  configuredDecryptdBaseUrl: string | undefined,
  runtimeGitBaseUrl?: string,
): string | undefined => configuredDecryptdBaseUrl ?? deriveServiceBaseUrl(runtimeGitBaseUrl, "/decryptd");

// Builds proxy runtime settings from CLI args with env/default fallback for local development.
export const loadProxyConfig = (
  cliArgs: CliArgs = parseCliArgs(),
  env: NodeJS.ProcessEnv = process.env,
  deps: ConfigLoadDependencies = {
    exists: existsSync,
    readText: readFileSync,
    resolvePath: resolve,
    cwd: () => process.cwd(),
  },
): ProxyConfig => {
  const gitBaseUrl = cliArgs.gitBaseUrl ?? env.GIT_BASE_URL;
  const lfsBaseUrl = deriveLfsBaseUrl(gitBaseUrl);
  const transcodedBaseUrl = resolveTranscodedBaseUrl(cliArgs.transcodedBaseUrl ?? env.TRANSCODED_BASE_URL, gitBaseUrl);
  const decryptdBaseUrl = resolveDecryptdBaseUrl(cliArgs.decryptdBaseUrl ?? env.DECRYPTD_BASE_URL, gitBaseUrl);
  const port = cliArgs.port ?? Number(env.PORT ?? 8787);
  if (!Number.isFinite(port) || port <= 0) {
    throw new Error("Invalid proxy port. Use --port <number> or PORT.");
  }

  const upstreamCa = loadOptionalUpstreamCa(cliArgs, env, deps);

  return {
    gitBaseUrl,
    lfsBaseUrl,
    transcodedBaseUrl,
    decryptdBaseUrl,
    port,
    upstreamCa,
  };
};
