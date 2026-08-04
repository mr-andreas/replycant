import { execSync } from "node:child_process";
import { readFileSync, unlinkSync } from "node:fs";

const CONTAINER_ID_PATH = "/tmp/pw-integration-container-id";

export default async function globalTeardown() {
  try {
    const containerID = readFileSync(CONTAINER_ID_PATH, "utf-8").trim();
    if (containerID) {
      execSync(`docker rm -f ${containerID}`, { stdio: "ignore" });
    }
  } catch {
    // Container may already be gone.
  }
  try {
    unlinkSync(CONTAINER_ID_PATH);
  } catch {
    // File may not exist.
  }
}
