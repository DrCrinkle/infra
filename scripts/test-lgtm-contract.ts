import { existsSync, readFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";

// LGTM contract: the personal LGTM stack on taylor-pc stays pinned, loopback-only,
// 30-day retention, secret-free and free of private identifiers, because this repo
// is public. Static checks only; nothing here proves the stack starts.
const root = join(import.meta.dir, "..");
const failures: string[] = [];
const fail = (msg: string) => failures.push(msg);

function read(path: string): string {
  const absolute = join(root, path);
  if (!existsSync(absolute)) {
    fail(`missing ${path}`);
    return "";
  }
  return readFileSync(absolute, "utf8");
}

function walk(dir: string): string[] {
  const absolute = join(root, dir);
  if (!existsSync(absolute)) return [];
  return readdirSync(absolute, { withFileTypes: true }).flatMap((e) => {
    const p = join(dir, e.name);
    return e.isDirectory() ? walk(p) : [p];
  });
}

const stripShellComments = (s: string) =>
  s
    .split("\n")
    .filter((l) => !/^\s*#/.test(l))
    .join("\n");

// ---------------------------------------------------------------- compose
type Service = Record<string, any>;
const compose = Bun.YAML.parse(read("configs/lgtm/compose.yaml")) as { services: Record<string, Service> };
const expected = ["grafana", "loki", "tempo", "prometheus"];
if (JSON.stringify(Object.keys(compose.services ?? {}).sort()) !== JSON.stringify([...expected].sort())) {
  fail(`compose services must be exactly ${expected.join(", ")}`);
}

const published = new Map<number, string>(); // host port -> service
for (const [name, svc] of Object.entries(compose.services ?? {})) {
  if (!/^[^\s@]+:[^\s@]+@sha256:[0-9a-f]{64}$/.test(String(svc.image ?? ""))) {
    fail(`${name}: image must be tag@sha256:<64 hex>, got ${svc.image}`);
  }
  if (!svc.stop_grace_period) fail(`${name}: missing stop_grace_period`);
  if (!svc.mem_limit) fail(`${name}: missing mem_limit`);
  if (svc.logging?.options?.["max-size"] !== "10m" || svc.logging?.options?.["max-file"] !== "3") {
    fail(`${name}: json-file rotation must be max-size 10m, max-file 3`);
  }
  if (svc.user !== "1000:1000") fail(`${name}: user must be 1000:1000 (backup runs unprivileged)`);
  if (svc.labels && JSON.stringify(svc.labels).includes("watchtower")) {
    fail(`${name}: a watchtower label would auto-update a pinned image`);
  }
  if (svc.network_mode === "host" && svc.ports) fail(`${name}: host networking cannot publish ports`);
  for (const port of svc.ports ?? []) {
    const m = /^127\.0\.0\.1:(\d+):\d+$/.exec(String(port));
    if (!m) fail(`${name}: port ${port} must start with 127.0.0.1:`);
    else published.set(Number(m[1]), name);
  }
  for (const arg of svc.command ?? []) {
    if (String(arg).includes("enable-admin-api")) fail(`${name}: --web.enable-admin-api must stay off`);
  }
  for (const f of svc.env_file ?? []) {
    if (!String(f).startsWith("${HOME}/")) fail(`${name}: env_file must live under \${HOME}, outside the repo`);
  }
}
const grafana = compose.services?.grafana ?? {};
if (grafana.network_mode !== "host") fail("grafana: network_mode must be host so auth.proxy sees 127.0.0.1");
if (grafana.environment?.GF_SERVER_HTTP_ADDR !== "127.0.0.1") fail("grafana: must bind 127.0.0.1");
if (!/^"?127\.0\.0\.1, ::1"?$/.test(String(grafana.environment?.GF_AUTH_PROXY_WHITELIST ?? ""))) {
  fail("grafana: auth.proxy whitelist must be loopback only");
}

// ------------------------------------------------------- restore drill override
// The drill runs beside the live stack over restored data: it must never mount the
// live data, collide with a live port, or leave loopback.
const drill = Bun.YAML.parse(read("configs/lgtm/drill/compose.drill.yaml")) as { services: Record<string, Service> };
const drillText = read("configs/lgtm/drill/compose.drill.yaml");
if (/\/srv\/lgtm\/data/.test(drillText)) fail("drill override must not mention the live data directory");
for (const name of expected) {
  const svc = drill.services?.[name];
  if (!svc) {
    fail(`drill override must remap ${name}`);
    continue;
  }
  if (name !== "grafana" && !/ports:\s*!override/.test(drillText)) fail("drill ports must use !override, or compose appends to the live ports");
  if (!/volumes:\s*!override/.test(drillText)) fail("drill volumes must use !override, or compose keeps the live mounts");
  for (const v of svc.volumes ?? []) {
    const src = String(v).split(":")[0];
    if (src.startsWith("/") && !src.startsWith("/srv/lgtm-drill/")) fail(`drill ${name}: absolute mount ${src} must live under /srv/lgtm-drill/`);
  }
  for (const port of svc.ports ?? []) {
    const m = /^127\.0\.0\.1:(\d+):\d+$/.exec(String(port));
    if (!m) fail(`drill ${name}: port ${port} must start with 127.0.0.1:`);
    else if (published.has(Number(m[1]))) fail(`drill ${name}: host port ${m[1]} collides with the live stack`);
  }
}
if (drill.services?.grafana?.environment?.GF_SERVER_HTTP_PORT === grafana.environment?.GF_SERVER_HTTP_PORT) {
  fail("drill grafana must listen on a different port than the live one");
}

// ------------------------------------------- the OpenObserve option (alternative)
// Same rules as the LGTM stack: pinned image, loopback only, 30 days, no secret in the
// compose file, Serve the only door, and a drill that cannot touch the live data.
const ooCompose = Bun.YAML.parse(read("configs/openobserve/compose.yaml")) as { services: Record<string, Service> };
if (JSON.stringify(Object.keys(ooCompose.services ?? {})) !== JSON.stringify(["openobserve"])) fail("openobserve compose must have exactly one service, openobserve");
const oo = ooCompose.services?.openobserve ?? {};
if (!/^openobserve\/openobserve:v\d+\.\d+\.\d+@sha256:[0-9a-f]{64}$/.test(String(oo.image ?? ""))) fail(`openobserve: image must be a stable vX.Y.Z tag @sha256:<64 hex>, got ${oo.image}`);
if (!oo.stop_grace_period) fail("openobserve: missing stop_grace_period");
if (!oo.mem_limit) fail("openobserve: missing mem_limit");
if (oo.user !== "1000:1000") fail("openobserve: user must be 1000:1000 (backup runs unprivileged)");
if (oo.logging?.options?.["max-size"] !== "10m" || oo.logging?.options?.["max-file"] !== "3") fail("openobserve: json-file rotation must be max-size 10m, max-file 3");
if (oo.labels && JSON.stringify(oo.labels).includes("watchtower")) fail("openobserve: a watchtower label would auto-update a pinned image");
if (String(oo.environment?.ZO_COMPACT_DATA_RETENTION_DAYS) !== "30") fail("openobserve: ZO_COMPACT_DATA_RETENTION_DAYS must be 30");
if (String(oo.environment?.ZO_TELEMETRY) !== "false") fail("openobserve: ZO_TELEMETRY must be false");
for (const k of Object.keys(oo.environment ?? {})) if (/^ZO_ROOT_USER/.test(k)) fail(`openobserve: ${k} must come from the env_file, not the compose file`);
for (const f of oo.env_file ?? []) if (!String(f).startsWith("${HOME}/")) fail("openobserve: env_file must live under ${HOME}, outside the repo");
const ooPorts = new Set<number>();
for (const port of oo.ports ?? []) {
  const m = /^127\.0\.0\.1:(\d+):\d+$/.exec(String(port));
  if (!m) fail(`openobserve: port ${port} must start with 127.0.0.1:`);
  else ooPorts.add(Number(m[1]));
}
if (JSON.stringify([...ooPorts].sort()) !== JSON.stringify([5080, 5081])) fail("openobserve must publish exactly 127.0.0.1:5080 and :5081");
if (!(oo.volumes ?? []).some((v: string) => String(v).startsWith("/srv/lgtm/data/openobserve:"))) fail("openobserve data must live under /srv/lgtm/data/openobserve, the path the backup copies");

const ooServe = stripShellComments(read("configs/openobserve/serve.sh"));
if (!/--https=8443 http:\/\/127\.0\.0\.1:5080\b/.test(ooServe)) fail("openobserve serve.sh must serve https 8443 -> 127.0.0.1:5080");
if (!/--tcp=5081 tcp:\/\/127\.0\.0\.1:5081\b/.test(ooServe)) fail("openobserve serve.sh must forward tcp 5081");
if (/--https=443\b/.test(ooServe)) fail("openobserve serve.sh must never touch :443");
if (/\bserve\s+reset\b/.test(ooServe)) fail("openobserve serve.sh must never run `serve reset`");
if (!(statSync(join(root, "configs/openobserve/serve.sh")).mode & 0o111)) fail("openobserve serve.sh must be executable");

const ooDrillText = read("configs/openobserve/drill/compose.drill.yaml");
const ooDrill = Bun.YAML.parse(ooDrillText) as { services: Record<string, Service> };
if (/\/srv\/lgtm\/data/.test(ooDrillText)) fail("openobserve drill must not mention the live data directory");
if (!/ports:\s*!override/.test(ooDrillText) || !/volumes:\s*!override/.test(ooDrillText)) fail("openobserve drill must !override ports and volumes");
for (const port of ooDrill.services?.openobserve?.ports ?? []) {
  const m = /^127\.0\.0\.1:(\d+):\d+$/.exec(String(port));
  if (!m) fail(`openobserve drill: port ${port} must start with 127.0.0.1:`);
  else if (ooPorts.has(Number(m[1]))) fail(`openobserve drill: host port ${m[1]} collides with the live stack`);
}
for (const v of ooDrill.services?.openobserve?.volumes ?? []) {
  const src = String(v).split(":")[0];
  if (src.startsWith("/") && !src.startsWith("/srv/lgtm-drill/")) fail(`openobserve drill: absolute mount ${src} must live under /srv/lgtm-drill/`);
}

for (const f of ["linux", "taylor-pc", "macos"]) {
  const a = read(`configs/alloy/openobserve/${f}.alloy`);
  const pc = f === "taylor-pc";
  const urls = [...a.matchAll(/url\s*=\s*"(https?:\/\/[^"]*)"(?:\s*\+[^\n]*":(\d+)(\/[^"]*)")?/g)].map((m) => (m[2] ? `${m[1]}*:${m[2]}${m[3]}` : m[1])).sort();
  const want = pc
    ? ["http://127.0.0.1:5080/api/default/loki/api/v1/push", "http://127.0.0.1:5080/api/default/prometheus/api/v1/write"]
    : ["https://*:8443/api/default/loki/api/v1/push", "https://*:8443/api/default/prometheus/api/v1/write"];
  if (JSON.stringify(urls) !== JSON.stringify(want)) fail(`openobserve/${f}.alloy must push to ${want.join(", ")}, got ${urls.join(", ")}`);
  if ((a.match(/basic_auth\s*\{/g) ?? []).length !== 2) fail(`openobserve/${f}.alloy: both remote-write and loki.write need basic_auth`);
  if ((a.match(/password_file\s*=\s*coalesce\(sys\.env\("OO_PASSCODE_FILE"\)/g) ?? []).length !== 2) fail(`openobserve/${f}.alloy: the passcode must come from a file (OO_PASSCODE_FILE), never inline`);
  if (/^\s*password\s*=/m.test(a)) fail(`openobserve/${f}.alloy: no inline password`);
  if (!/sys\.env\("OO_USER_FILE"\)/.test(a)) fail(`openobserve/${f}.alloy: the login must come from OO_USER_FILE or a file`);
  if (!pc && !/sys\.env\("LGTM_HOST_FILE"\)/.test(a)) fail(`openobserve/${f}.alloy: the stack host must come from LGTM_HOST_FILE or a file`);
  const sources = (a.match(/^loki\.source\.\w+\s+"/gm) ?? []).length;
  if ((a.match(/stream_name\s*=/g) ?? []).length < sources) fail(`openobserve/${f}.alloy: every Loki source needs its own stream_name label (OpenObserve names the stream from it)`);
  if (/loki\.source\.file[^}]*\{[^}]*\}/s.test(a) && !/tail_from_end\s*=\s*true/.test(a)) fail(`openobserve/${f}.alloy tails files without tail_from_end`);
}

// ----------------------------------------------------- retention (30 days)
const loki = read("configs/lgtm/loki.yaml");
for (const [re, why] of [
  [/^\s+retention_period:\s*720h\b/m, "loki retention_period 720h"],
  [/^\s+retention_enabled:\s*true\b/m, "loki compactor retention_enabled"],
  [/^\s+delete_request_store:\s*filesystem\b/m, "loki delete_request_store"],
  [/^\s+period:\s*24h\b/m, "loki 24h index period (retention needs it)"],
] as const) {
  if (!re.test(loki)) fail(`loki.yaml missing ${why}`);
}
if (!/^\s+block_retention:\s*720h\b/m.test(read("configs/lgtm/tempo.yaml"))) fail("tempo.yaml missing block_retention 720h");
if (!/^\s+time:\s*30d\b/m.test(read("configs/lgtm/prometheus.yml"))) fail("prometheus.yml missing retention time 30d");

// ------------------------------------------------- Serve doors vs compose
const serve = stripShellComments(read("configs/lgtm/serve.sh"));
if (!/--https=8443\b/.test(serve)) fail("serve.sh must serve Grafana on https 8443");
if (/--https=443\b/.test(serve)) fail("serve.sh must never touch :443");
if (/\bserve\s+reset\b/.test(serve)) fail("serve.sh must never run `serve reset`");
const grafanaPort = String(grafana.environment?.GF_SERVER_HTTP_PORT ?? "");
if (!serve.includes(`http://127.0.0.1:${grafanaPort}`)) fail(`serve.sh must forward 8443 to 127.0.0.1:${grafanaPort}`);
const tcpPorts = /tcp_ports=\(([^)]*)\)/.exec(serve)?.[1].trim().split(/\s+/).map(Number) ?? [];
if (JSON.stringify([...tcpPorts].sort()) !== JSON.stringify([3100, 4317, 4318, 9090])) {
  fail(`serve.sh tcp_ports must be 3100 4317 4318 9090, got ${tcpPorts.join(" ")}`);
}
for (const p of tcpPorts) if (!published.has(p)) fail(`serve.sh forwards ${p} but compose does not publish it on loopback`);

// ------------------------------------------------------------ backup jobs
const backup = read("configs/lgtm/backup/lgtm-backup.sh");
const check = read("configs/lgtm/backup/lgtm-restic-check.sh");
const lib = read("configs/lgtm/backup/lib.sh");
if (!/--keep-daily 7 --keep-weekly 4 --prune/.test(backup)) fail("backup must keep 7 daily + 4 weekly");
if ((backup.match(/gatus_ok/g) ?? []).length !== 1) fail("lgtm-backup.sh must report success exactly once, at the end");
if (/gatus_ok|success=true|gatus_push\s+true/.test(check)) {
  fail("lgtm-restic-check.sh must never report success: a green push resets the dead-man without a backup");
}
if (!/gatus_fail/.test(check)) fail("lgtm-restic-check.sh must report failure");
if (/Authorization: Bearer \$\{GATUS_LGTM_BACKUP_TOKEN\}/.test(lib) === false) fail("lib.sh must send the token as a Bearer header");
if (/[?&]token=/.test(lib)) fail("lib.sh must not put the token in a URL");
if (!/lgtm_lgtm-backup\/external/.test(lib)) fail("lib.sh must push to endpoint key lgtm_lgtm-backup");
if (/\|\|\s*true/.test(lib)) fail("lib.sh must not swallow a failed heartbeat push silently");
for (const f of ["lgtm-backup.sh", "lgtm-restic-check.sh", "rsyncnet-own-key.sh"]) {
  if (!(statSync(join(root, "configs/lgtm/backup", f)).mode & 0o111)) fail(`${f} must be executable`);
}
if (!(statSync(join(root, "configs/lgtm/serve.sh")).mode & 0o111)) fail("serve.sh must be executable");
const ownKey = read("configs/lgtm/backup/rsyncnet-own-key.sh");
if (!/oflag=append conv=notrunc/.test(ownKey)) fail("rsyncnet-own-key.sh must append with dd oflag=append conv=notrunc");
if (/\bscp\b|>\s*\.ssh\/authorized_keys/.test(stripShellComments(ownKey))) fail("rsyncnet-own-key.sh must not overwrite authorized_keys");

// ---------------------------------------------------------- systemd units
const unit = (n: string) => read(`configs/lgtm/systemd/${n}`);
const bsvc = unit("lgtm-backup.service");
const csvc = unit("lgtm-restic-check.service");
for (const [svc, script] of [
  [bsvc, "lgtm-backup.sh"],
  [csvc, "lgtm-restic-check.sh"],
] as const) {
  if (!/^EnvironmentFile=%h\/\.config\/lgtm\/backup\.env$/m.test(svc)) fail(`${script} unit must load %h/.config/lgtm/backup.env`);
  if (!/^Environment=RESTIC_PASSWORD_FILE=%h\/\.config\/lgtm\/restic\.pass$/m.test(svc)) fail(`${script} unit must set RESTIC_PASSWORD_FILE with %h`);
  if (!svc.includes(`ExecStart=%h/deploy/infra/configs/lgtm/backup/${script}`)) fail(`${script} unit ExecStart path wrong`);
  if (!/^Type=oneshot$/m.test(svc)) fail(`${script} unit must be Type=oneshot`);
}
const btimer = unit("lgtm-backup.timer");
if (!/^OnCalendar=\*-\*-\* 03:30:00$/m.test(btimer) || !/^Persistent=true$/m.test(btimer)) fail("backup timer must be 03:30 daily with Persistent=true");
if (!/^OnCalendar=Sun \*-\*-\* 05:00:00$/m.test(unit("lgtm-restic-check.timer"))) fail("restic-check timer must be Sunday 05:00");

// ------------------------------------------------------------------ Alloy
for (const f of ["linux", "taylor-pc", "macos"]) {
  const a = read(`configs/alloy/${f}.alloy`);
  if (!/sys\.env\("LGTM_HOST_FILE"\)/.test(a)) fail(`${f}.alloy must read the stack host from LGTM_HOST_FILE or a file`);
  const urls = [...a.matchAll(/url\s*=\s*"http:\/\/"\s*\+[^\n]*":(\d+)(\/[^"]*)"/g)].map((m) => `${m[1]}${m[2]}`).sort();
  if (JSON.stringify(urls) !== JSON.stringify(["3100/loki/api/v1/push", "9090/api/v1/write"])) {
    fail(`${f}.alloy must push to :9090/api/v1/write and :3100/loki/api/v1/push, got ${urls.join(", ")}`);
  }
  if (/loki\.source\.file[^}]*\{[^}]*\}/s.test(a) && !/tail_from_end\s*=\s*true/.test(a)) fail(`${f}.alloy tails files without tail_from_end`);
}

// --------------------------------------- public-repo hygiene on new files
const scanned = [
  ...walk("configs/lgtm"),
  ...walk("configs/alloy"),
  ...walk("configs/openobserve"),
  ...walk("docs").filter((p) => /\/(lgtm|openobserve)/.test(p)),
  ...walk("scripts").filter((p) => /lgtm/.test(p) && !p.endsWith("test-lgtm-contract.ts")),
];
const rules: [RegExp, string][] = [
  [/\b100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7])\.\d{1,3}\.\d{1,3}\b/, "tailnet IP"],
  [/\btail[0-9a-f]{6}\.ts\.net\b/, "tailnet name (only the pre-existing files may carry it; use <tailnet>)"],
  [/[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b/, "email address"],
  [/\b(?!www\.|docs\.)[a-z0-9-]+\.rsync\.net\b/, "rsync.net account hostname"],
  [/SHA256:[A-Za-z0-9+/]{43}/, "ssh key fingerprint"],
  [/\/Users\/|\/home\/(?!<)[A-Za-z0-9_-]+/, "home directory path"],
  [/-----BEGIN [A-Z ]*PRIVATE KEY-----/, "private key"],
  [/\btopic:\s*"?(?!\$\{)[^"\s]+/, "literal ntfy topic"],
  [/NTFY_TOPIC=[A-Za-z0-9-]{8,}/, "NTFY_TOPIC value"],
  [/(?:PASSWORD|TOKEN|SECRET)\w*\s*=\s*(?![<$%'"{\s])\S+/, "secret-looking assignment"],
  [/(?<!sha256:)\b[0-9a-f]{32,}\b/, "long hex string that is not an image digest"],
];
for (const path of scanned) {
  const body = readFileSync(join(root, path), "utf8");
  for (const [re, what] of rules) {
    const m = re.exec(body);
    if (m) fail(`${relative(".", path)} contains a ${what}: ${m[0].slice(0, 40)}`);
  }
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log(`lgtm contract: PASS (${scanned.length} files scanned for private identifiers)`);
