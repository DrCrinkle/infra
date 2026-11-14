import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Sentinel contract for the LGTM stack's Gatus checks. They live in the same
// config.yaml as the existing checks, so this proves the insertion did not break
// that file (one `endpoints:` list, every old check still there) and that the five
// new checks carry the thresholds the nightly backup pause and the one-push-a-night
// heartbeat require. Static only.
const root = join(import.meta.dir, "..");
const failures: string[] = [];
const fail = (m: string) => failures.push(m);

const read = (p: string) => {
  const a = join(root, p);
  if (!existsSync(a)) {
    fail(`missing ${p}`);
    return "";
  }
  return readFileSync(a, "utf8");
};

const raw = read("configs/sentinel/gatus/config.yaml");
const cfg = Bun.YAML.parse(raw) as any;

// One top-level list each: a second `endpoints:` would silently replace the first.
for (const key of ["endpoints", "external-endpoints"]) {
  const n = (raw.match(new RegExp(`^${key}:`, "gm")) ?? []).length;
  if (n !== 1) fail(`config.yaml must have exactly one top-level ${key}:, found ${n}`);
}

const byName = new Map<string, any>((cfg.endpoints ?? []).map((e: any) => [e.name, e]));
for (const old of ["openclaw-reachable", "openclaw-ssh", "openclaw-gateway", "public-https-placeholder"]) {
  if (!byName.has(old)) fail(`existing check ${old} was lost`);
}

const serve = read("configs/lgtm/serve.sh");
const doorPorts = new Set<number>([8443, ...(/tcp_ports=\(([^)]*)\)/.exec(serve)?.[1].trim().split(/\s+/).map(Number) ?? [])]);

const expected: Record<string, { url: RegExp; body?: string }> = {
  "taylor-pc-reachable": { url: /^icmp:\/\/taylor-pc\.[^/:]+\.ts\.net$/ },
  "lgtm-grafana": { url: /^https:\/\/taylor-pc\.[^/:]+\.ts\.net:8443\/api\/health$/, body: "[BODY].database == ok" },
  "lgtm-loki-ready": { url: /^http:\/\/taylor-pc\.[^/:]+\.ts\.net:3100\/ready$/ },
  "lgtm-prometheus-ready": { url: /^http:\/\/taylor-pc\.[^/:]+\.ts\.net:9090\/-\/ready$/ },
};
for (const [name, want] of Object.entries(expected)) {
  const e = byName.get(name);
  if (!e) {
    fail(`missing check ${name}`);
    continue;
  }
  if (e.group !== "lgtm") fail(`${name}: group must be lgtm`);
  if (!want.url.test(String(e.url))) fail(`${name}: unexpected url ${e.url}`);
  if (e.interval !== "60s") fail(`${name}: interval must be 60s`);
  const alert = (e.alerts ?? []).find((a: any) => a.type === "ntfy");
  // 5 x 60s: the nightly backup pause (under 90s plus time to ready) must never page.
  if (!alert || alert["failure-threshold"] !== 5) fail(`${name}: ntfy alert with failure-threshold 5 required`);
  if (want.body && !(e.conditions ?? []).includes(want.body)) fail(`${name}: missing condition ${want.body}`);
  const port = /:(\d+)(?:\/|$)/.exec(String(e.url).replace(/^[a-z]+:\/\//, ""))?.[1];
  if (port && !doorPorts.has(Number(port))) fail(`${name}: port ${port} is not a Serve door in serve.sh`);
}

// The OpenObserve option: committed disabled, with the same 5 x 60s tolerance, and exactly
// one option's service probes may be live (a live probe for a stack that is not running pages forever).
const door: Record<string, { url: RegExp }> = {
  "openobserve-health": { url: /^https:\/\/taylor-pc\.[^/:]+\.ts\.net:8443\/healthz$/ },
  "openobserve-grpc": { url: /^tcp:\/\/taylor-pc\.[^/:]+\.ts\.net:5081$/ },
};
const oo = read("configs/openobserve/serve.sh");
for (const [name, want] of Object.entries(door)) {
  const e = byName.get(name);
  if (!e) {
    fail(`missing check ${name}`);
    continue;
  }
  if (e.group !== "openobserve") fail(`${name}: group must be openobserve`);
  if (!want.url.test(String(e.url))) fail(`${name}: unexpected url ${e.url}`);
  if (e.enabled !== false) fail(`${name}: must ship disabled until the OpenObserve option is chosen`);
  const alert = (e.alerts ?? []).find((a: any) => a.type === "ntfy");
  if (!alert || alert["failure-threshold"] !== 5) fail(`${name}: ntfy alert with failure-threshold 5 required`);
  const port = /:(\d+)(?:\/|$)/.exec(String(e.url).replace(/^[a-z]+:\/\//, ""))?.[1];
  if (port && !oo.includes(`:${port}`)) fail(`${name}: port ${port} is not a door in openobserve/serve.sh`);
}
const live = (names: string[]) => names.filter((n) => byName.get(n) && byName.get(n).enabled !== false).length;
const lgtmLive = live(["lgtm-grafana", "lgtm-loki-ready", "lgtm-prometheus-ready"]);
const ooLive = live(Object.keys(door));
if ((lgtmLive === 0) === (ooLive === 0)) {
  fail(`exactly one option's service probes must be enabled (lgtm: ${lgtmLive} live, openobserve: ${ooLive} live)`);
}

// The dead-man heartbeat: one push a night.
const ext = (cfg["external-endpoints"] ?? []).find((e: any) => e.name === "lgtm-backup");
if (!ext) fail("missing external endpoint lgtm-backup");
else {
  if (ext.group !== "lgtm") fail("lgtm-backup: group must be lgtm");
  if (ext.token !== "${GATUS_LGTM_BACKUP_TOKEN}") fail("lgtm-backup: token must be the ${GATUS_LGTM_BACKUP_TOKEN} reference");
  if (ext.heartbeat?.interval !== "26h") fail("lgtm-backup: heartbeat interval must be 26h");
  if (typeof ext.enabled !== "boolean") fail("lgtm-backup: `enabled` must be explicit (false until Phase 4)");
  const a = (ext.alerts ?? []).find((x: any) => x.type === "ntfy");
  if (!a || a["failure-threshold"] !== 1 || a["success-threshold"] !== 1) {
    fail("lgtm-backup: ntfy alert must set failure-threshold 1 and success-threshold 1 (default-alert would take 3 missed days)");
  }
  // The key the backup job pushes to is <group>_<name>.
  const key = `${ext.group}_${ext.name}`;
  if (!read("configs/lgtm/backup/lib.sh").includes(`endpoints/${key}/external`)) {
    fail(`backup lib.sh must push to endpoint key ${key}`);
  }
}

// Once PR #1 (alerting) is in the file, the alerts above must have a provider.
if (cfg.alerting) {
  if (!cfg.alerting.ntfy) fail("alerting is configured but has no ntfy provider");
  if (cfg.alerting.ntfy?.topic !== "${NTFY_TOPIC}") fail("ntfy topic must stay the ${NTFY_TOPIC} reference");
}

// Nothing new may leak: the token and any ntfy topic are references only.
// (pattern built from parts so this file does not trip the contract test's own secret scan)
if (new RegExp("GATUS_LGTM_BACKUP_TOKEN" + "=\\S").test(raw)) fail("config.yaml contains a token value");

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`lgtm sentinel contract: PASS (alerting block ${cfg.alerting ? "present" : "absent: apply after PR #1"})`);
