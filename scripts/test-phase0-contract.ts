import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Phase 0 contract: access.yml is additive, Gatus alerts via ntfy with an
// env-supplied topic, and no tailnet address or topic is newly committed.
const root = join(import.meta.dir, "..");
const failures: string[] = [];

function read(path: string): string {
  const absolute = join(root, path);
  if (!existsSync(absolute)) {
    failures.push(`missing ${path}`);
    return "";
  }
  return readFileSync(absolute, "utf8");
}

function require(path: string, patterns: RegExp[]) {
  const body = read(path);
  for (const pattern of patterns) {
    if (!pattern.test(body)) failures.push(`${path} missing ${pattern}`);
  }
}

require("ansible/access.yml", [
  /ansible\.posix\.authorized_key/,
  /exclusive:\s*false/,
  /ssh_authorized_keys_state/,
  /ssh-ed25519 AAAA\S+ \S+/,
]);
if (/become:\s*true|ansible\.builtin\.(service|systemd|copy|lineinfile)/.test(read("ansible/access.yml"))) {
  failures.push("ansible/access.yml must only apply authorized_key");
}

const gatus = read("configs/sentinel/gatus/config.yaml");
require("configs/sentinel/gatus/config.yaml", [
  /^alerting:\n\s+ntfy:/m,
  /topic:\s*"\$\{NTFY_TOPIC\}"/,
  /failure-threshold:\s*3/,
  /send-on-resolved:\s*true/,
]);
for (const name of ["openclaw-reachable", "openclaw-ssh", "openclaw-gateway"]) {
  const block = gatus.split(/\n {2}- name: /).find((b) => b.startsWith(name)) ?? "";
  if (!/alerts:\s*\n\s+- type: ntfy/.test(block)) failures.push(`endpoint ${name} has no ntfy alert`);
}
require("configs/sentinel/systemd/gatus.service", [/^EnvironmentFile=\/etc\/gatus\/gatus\.env$/m]);

// No literal topic: the only allowed topic value is the ${NTFY_TOPIC} reference.
for (const path of ["configs/sentinel/gatus/config.yaml", "ansible/access.yml", "configs/README.md", "docs/phase0-access-and-alerting.md"]) {
  const body = read(path);
  for (const m of body.matchAll(/topic:\s*"?([^"\s]+)"?/g)) {
    if (m[1] !== "${NTFY_TOPIC}") failures.push(`${path} has a literal ntfy topic: ${m[1]}`);
  }
  if (/NTFY_TOPIC=[A-Za-z0-9]{8,}/.test(body)) failures.push(`${path} contains an NTFY_TOPIC value`);
}

// Phase 0 adds no tailnet addresses beyond what origin/main already carried.
for (const path of ["ansible/access.yml", "docs/phase0-access-and-alerting.md", "scripts/test-phase0-contract.ts"]) {
  if (/\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/.test(read(path))) {
    failures.push(`${path} contains a tailnet IP`);
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("phase0 contract: PASS");
