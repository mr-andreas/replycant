import { execSync } from "node:child_process";
import { writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const IMAGE = "replycant-integration:test";
const CONTAINER_ID_PATH = "/tmp/pw-integration-container-id";
const READINESS_TIMEOUT_S = 120;

// Removes stale integration containers so interrupted runs do not block required ports.
export default async function globalSetup() {
  const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "../../..");

  execSync(
    "docker rm -f $(docker ps -q --filter label=replycant-integration=true) 2>/dev/null || true",
    {
      cwd: repoRoot,
      stdio: "ignore",
    },
  );

  execSync(`docker build -f integration/Dockerfile -t ${IMAGE} .`, {
    cwd: repoRoot,
    stdio: "inherit",
  });

  const containerID = execSync(
    `docker run --rm -d --label replycant-integration=true -p 18080:8080 -p 18443:18443 -p 18444:18444 ${IMAGE}`,
  )
    .toString()
    .trim();

  writeFileSync(CONTAINER_ID_PATH, containerID);

  for (let i = 0; i < READINESS_TIMEOUT_S; i++) {
    try {
      execSync(`docker exec ${containerID} test -f /tmp/ready`, { stdio: "ignore" });
      return;
    } catch {
      execSync("sleep 1");
    }
  }

  const logs = execSync(`docker logs ${containerID}`).toString();
  execSync(`docker rm -f ${containerID}`, { stdio: "ignore" });
  throw new Error(`Integration container did not become ready in ${READINESS_TIMEOUT_S}s\n${logs}`);
}
