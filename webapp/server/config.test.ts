import { describe, expect, it } from "vitest";
import { loadProxyConfig, parseCliArgs } from "./config";

describe("loadProxyConfig", () => {
  it("allows startup without preconfigured git CA", () => {
    const config = loadProxyConfig({}, {}, {
      exists: () => false,
      readText: () => "",
      resolvePath: (...parts) => parts.join("/"),
      cwd: () => "/tmp/replycant",
    });
    expect(config.upstreamCa).toBeUndefined();
  });

  it("prefers cli overrides when provided", () => {
    const config = loadProxyConfig(
      {
        gitBaseUrl: "https://git-cli.example",
        transcodedBaseUrl: "https://transcoded-cli.example",
        decryptdBaseUrl: "https://decryptd-cli.example",
        gitCaCert: "cli-ca-cert",
        port: 9999,
      },
      {
        GIT_BASE_URL: "https://git-env.example",
        TRANSCODED_BASE_URL: "https://transcoded-env.example",
        DECRYPTD_BASE_URL: "https://decryptd-env.example",
        PORT: "5555",
      },
      {
        exists: () => false,
        readText: () => "",
        resolvePath: (...parts) => parts.join("/"),
        cwd: () => "/tmp/replycant",
      },
    );
    expect(config.gitBaseUrl).toBe("https://git-cli.example");
    expect(config.lfsBaseUrl).toBe("https://git-cli.example/lfs");
    expect(config.transcodedBaseUrl).toBe("https://transcoded-cli.example");
    expect(config.decryptdBaseUrl).toBe("https://decryptd-cli.example");
    expect(config.port).toBe(9999);
    expect(config.upstreamCa).toBe("cli-ca-cert");
  });

  it("uses env overrides when cli args are absent", () => {
    const config = loadProxyConfig(
      {},
      {
        GIT_BASE_URL: "https://git.example",
        TRANSCODED_BASE_URL: "https://transcoded.example",
        DECRYPTD_BASE_URL: "https://decryptd.example",
        GIT_CA_CERT: "env-ca-cert",
        PORT: "8788",
      },
      {
        exists: () => false,
        readText: () => "",
        resolvePath: (...parts) => parts.join("/"),
        cwd: () => "/tmp/replycant",
      },
    );
    expect(config.gitBaseUrl).toBe("https://git.example");
    expect(config.lfsBaseUrl).toBe("https://git.example/lfs");
    expect(config.transcodedBaseUrl).toBe("https://transcoded.example");
    expect(config.decryptdBaseUrl).toBe("https://decryptd.example");
    expect(config.port).toBe(8788);
    expect(config.upstreamCa).toBe("env-ca-cert");
  });

  it("does not inject default git base URL", () => {
    const config = loadProxyConfig({}, {}, {
      exists: () => false,
      readText: () => "",
      resolvePath: (...parts) => parts.join("/"),
      cwd: () => "/tmp/replycant",
    });
    expect(config.gitBaseUrl).toBeUndefined();
    expect(config.lfsBaseUrl).toBeUndefined();
  });

  it("derives media base URLs as gitd routes so they inherit its mTLS boundary", () => {
    const config = loadProxyConfig(
      {
        gitBaseUrl: "https://replycant.local:8443",
      },
      {},
      {
        exists: () => false,
        readText: () => "",
        resolvePath: (...parts) => parts.join("/"),
        cwd: () => "/tmp/replycant",
      },
    );
    expect(config.transcodedBaseUrl).toBe("https://replycant.local:8443/transcoded");
    expect(config.decryptdBaseUrl).toBe("https://replycant.local:8443/decryptd");
  });

  it("throws when port is invalid", () => {
    expect(() => loadProxyConfig({}, { PORT: "nope" })).toThrow("Invalid proxy port");
  });

  it("loads default CA from server.crt when present", () => {
    const config = loadProxyConfig({}, {}, {
      exists: (path) => path.endsWith("/server.crt"),
      readText: (path) => {
        if (path.endsWith("/server.crt")) return "default-ca";
        return "";
      },
      resolvePath: (...parts) => parts.join("/"),
      cwd: () => "/tmp/replycant",
    });
    expect(config.upstreamCa).toBe("default-ca");
  });

  it("fails fast when configured CA file does not exist", () => {
    expect(() =>
      loadProxyConfig(
        {
          gitCaCertFile: "/tmp/missing-ca.crt",
        },
        {},
        {
          exists: () => false,
          readText: () => "",
          resolvePath: (...parts) => parts.join("/"),
          cwd: () => "/tmp/replycant",
        },
      ),
    ).toThrow('Git CA certificate file not found at "/tmp/missing-ca.crt"');
  });

  it("ignores missing default server.crt when no explicit CA source exists", () => {
    const config = loadProxyConfig({}, {}, {
      exists: () => false,
      readText: () => "",
      resolvePath: (...parts) => parts.join("/"),
      cwd: () => "/tmp/replycant",
    });
    expect(config.upstreamCa).toBeUndefined();
  });

  it("fails fast when CA file cannot be read", () => {
    expect(() =>
      loadProxyConfig(
        {
          gitCaCertFile: "/tmp/ca.crt",
        },
        {},
        {
          exists: () => true,
          readText: () => {
            throw new Error("EACCES");
          },
          resolvePath: (...parts) => parts.join("/"),
          cwd: () => "/tmp/replycant",
        },
      ),
    ).toThrow('Failed to read Git CA certificate file at "/tmp/ca.crt": EACCES');
  });

  it("fails fast when inline CA is empty", () => {
    expect(() =>
      loadProxyConfig(
        {
          gitCaCert: "   ",
        },
        {},
        {
          exists: () => true,
          readText: () => "default-ca",
          resolvePath: (...parts) => parts.join("/"),
          cwd: () => "/tmp/replycant",
        },
      ),
    ).toThrow("Git CA certificate is empty");
  });

  it("fails fast when CA file is empty", () => {
    expect(() =>
      loadProxyConfig({}, {}, {
        exists: (path) => path.endsWith("/server.crt"),
        readText: () => " \n\t ",
        resolvePath: (...parts) => parts.join("/"),
        cwd: () => "/tmp/replycant",
      }),
    ).toThrow('Git CA certificate file at "/tmp/replycant/server.crt" is empty.');
  });
});

describe("parseCliArgs", () => {
  it("parses inline and split cli flag formats", () => {
    const parsed = parseCliArgs([
      "--git-base-url=https://git.example",
      "--transcoded-base-url=http://transcoded.example",
      "--decryptd-base-url=http://decryptd.example",
      "--port",
      "7777",
    ]);
    expect(parsed).toEqual({
      gitBaseUrl: "https://git.example",
      transcodedBaseUrl: "http://transcoded.example",
      decryptdBaseUrl: "http://decryptd.example",
      port: 7777,
    });
  });

  it("parses camelCase CLI flag aliases", () => {
    const parsed = parseCliArgs([
      "--gitBaseUrl",
      "https://git.camel.example",
      "--transcodedBaseUrl",
      "http://transcoded.camel.example",
      "--decryptdBaseUrl=http://decryptd.camel.example",
      "--port=7788",
    ]);
    expect(parsed).toEqual({
      gitBaseUrl: "https://git.camel.example",
      transcodedBaseUrl: "http://transcoded.camel.example",
      decryptdBaseUrl: "http://decryptd.camel.example",
      port: 7788,
    });
  });

  it("parses CA flags", () => {
    const parsed = parseCliArgs([
      "--git-ca-cert",
      "ca-pem",
      "--gitCaCertFile=/tmp/ca.crt",
    ]);
    expect(parsed.gitCaCert).toBe("ca-pem");
    expect(parsed.gitCaCertFile).toBe("/tmp/ca.crt");
  });
});
