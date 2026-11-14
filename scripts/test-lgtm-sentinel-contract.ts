import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Sentinel contract for the LGTM stack's Gatus checks. They live in the same
// config.yaml as the existing checks, so this proves the insertion did not break
// that file (one `endpoints:` list, every old check still there) and that the new
// checks carry the thresholds the nightly backup pause and the one-push-per-run
// heartbeats require. Static only: nothing here loads the file in a real Gatus.
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
  // The three service probes ship disabled (a redeploy from main before Phase 1 would page for
  // doors that do not exist); the ICMP probe is true with or without the stack.
  if (name === "taylor-pc-reachable") {
    if (e.enabled === false) fail(`${name}: must ship enabled`);
  } else if (e.enabled !== false) fail(`${name}: must ship disabled; Phase 2 flips it`);
  if (want.body && !(e.conditions ?? []).includes(want.body)) fail(`${name}: missing condition ${want.body}`);
  const port = /:(\d+)(?:\/|$)/.exec(String(e.url).replace(/^[a-z]+:\/\//, ""))?.[1];
  if (port && !doorPorts.has(Number(port))) fail(`${name}: port ${port} is not a Serve door in serve.sh`);
}

// The dead-men: one push per run, one endpoint per job (a shared endpoint let a good
// backup clear a failed integrity check).
const deadmen: Record<string, { interval: string; script: string }> = {
  "lgtm-backup": { interval: "26h", script: "configs/lgtm/backup/lgtm-backup.sh" },
  "lgtm-restic-check": { interval: "192h", script: "configs/lgtm/backup/lgtm-restic-check.sh" },
};
for (const [name, want] of Object.entries(deadmen)) {
  const ext = (cfg["external-endpoints"] ?? []).find((e: any) => e.name === name);
  if (!ext) {
    fail(`missing external endpoint ${name}`);
    continue;
  }
  if (ext.group !== "lgtm") fail(`${name}: group must be lgtm`);
  if (ext.token !== "${GATUS_LGTM_BACKUP_TOKEN}") fail(`${name}: token must be the ${"$"}{GATUS_LGTM_BACKUP_TOKEN} reference`);
  if (ext.heartbeat?.interval !== want.interval) fail(`${name}: heartbeat interval must be ${want.interval}`);
  if (ext.enabled !== false) fail(`${name}: must ship disabled until Phase 4 has run its fire test`);
  const a = (ext.alerts ?? []).find((x: any) => x.type === "ntfy");
  if (!a || a["failure-threshold"] !== 1 || a["success-threshold"] !== 1) {
    fail(`${name}: ntfy alert must set failure-threshold 1 and success-threshold 1 (default-alert would take 3 missed runs)`);
  }
  // The key the job pushes to is <group>_<name>, and only that job pushes to it.
  const key = `${ext.group}_${ext.name}`;
  if (!new RegExp(`^endpoint=${key}\\b`, "m").test(read(want.script))) fail(`${want.script} must report to endpoint key ${key}`);
}
if (/26 ?h(?:our)?s? after|exactly 26/.test(raw)) fail("config.yaml must not claim the dead-man pages 26h after the last backup (it is 26 to 52h)");
// Gatus parses durations with Go's time.ParseDuration, which has no day unit: `8d` makes it panic at load.
for (const m of raw.matchAll(/^\s+interval:\s*(.+?)\s*$/gm)) {
  const v = m[1].replace(/\s+#.*$/, "");
  if (!/^(\d+(\.\d+)?(ns|us|µs|ms|s|m|h))+$/.test(v)) fail(`interval "${v}" is not a Go duration (write days as hours: 192h, not 8d)`);
}

// The runbook's flip commands must do what it says on THIS file: render the live copy (three
// probes on), the fire-test copy (two lines), and the final copy (both dead-men on).
{
  const doc = read("docs/lgtm-taylor-pc.md");
  const seds = [...doc.matchAll(/^\s*sed -E '([^']+)' "\$(?:F|LIVE)"/gm)].map((m) => m[1]);
  const run = (script: string, input: string) => Bun.spawnSync(["sed", "-E", script], { stdin: Buffer.from(input) }).stdout.toString();
  const changed = (a: string, b: string) => {
    const x = a.split("\n"), y = b.split("\n");
    return x.length === y.length ? x.flatMap((l, i) => (l !== y[i] ? [y[i].trim()] : [])) : ["<line count changed>"];
  };
  const enabledOf = (text: string) => {
    const c = Bun.YAML.parse(text) as any;
    const m = new Map<string, boolean>();
    for (const e of [...(c.endpoints ?? []), ...(c["external-endpoints"] ?? [])]) m.set(e.name, e.enabled !== false);
    return { m, c };
  };
  const livePats = seds.filter((s) => s.includes("loki-ready"));
  const livePat = livePats[0];
  const finalPat = seds.find((s) => s.includes("backup|restic-check"));
  const firePat = seds.find((s) => s.includes("interval: 26h"));
  if (!livePat || !finalPat || !firePat) fail("runbook must contain the live, fire-test and final sed commands");
  else {
    if (livePats.length < 3 || livePats.some((s) => s !== livePat)) fail(`every runbook occurrence of the live sed must be identical (found ${livePats.length}: Phase 2 step 2, the fire test and step 11)`);
    const liveOut = run(livePat, raw);
    const d1 = changed(raw, liveOut);
    if (d1.length !== 3 || d1.some((l) => l !== "enabled: true")) fail(`runbook live sed must change exactly three lines to enabled: true, changed: ${d1.join(" | ")}`);
    const e1 = enabledOf(liveOut).m;
    for (const n of ["lgtm-grafana", "lgtm-loki-ready", "lgtm-prometheus-ready"]) if (e1.get(n) !== true) fail(`runbook live sed must enable ${n}`);
    for (const n of ["lgtm-backup", "lgtm-restic-check"]) if (e1.get(n) !== false) fail(`runbook live sed must leave ${n} disabled`);
    const fireOut = run(firePat, liveOut);
    const d2 = changed(liveOut, fireOut);
    if (d2.length !== 2) fail(`runbook fire-test sed must change exactly two lines, changed: ${d2.join(" | ")}`);
    const f = enabledOf(fireOut).c["external-endpoints"].find((e: any) => e.name === "lgtm-backup");
    if (f?.enabled !== true || f?.heartbeat?.interval !== "2m") fail("runbook fire-test sed must enable lgtm-backup with a 2m heartbeat");
    if (enabledOf(fireOut).c["external-endpoints"].find((e: any) => e.name === "lgtm-restic-check")?.enabled === true) fail("runbook fire-test sed must not touch lgtm-restic-check");
    const finalOut = run(finalPat, liveOut);
    const d3 = changed(liveOut, finalOut);
    if (d3.length !== 2 || d3.some((l) => l !== "enabled: true")) fail(`runbook final sed must change exactly two lines to enabled: true, changed: ${d3.join(" | ")}`);
    const e3 = enabledOf(finalOut).m;
    if (e3.get("lgtm-backup") !== true || e3.get("lgtm-restic-check") !== true) fail("runbook final sed must enable both dead-men");
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
