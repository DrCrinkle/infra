import { chmodSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

// Behavior test for the backup and restic-check jobs, with docker, rsync, restic,
// curl and flock replaced by recording stubs. It proves call order, that the
// writers are always restarted, and what is reported to Gatus on each path.
// It does not touch docker, restic or the network, and it does not prove the real
// tools behave (the pause length, restic over SFTP, Gatus acceptance are measured
// on taylor-pc in the runbook).
const root = join(import.meta.dir, "..");
const backupDir = join(root, "configs/lgtm/backup");
const failures: string[] = [];

type Run = { rc: number; calls: string[]; stderr: string };

function run(script: string, failAt: string | null, extraEnv: Record<string, string> = {}): Run {
  const dir = mkdtempSync(join(tmpdir(), "lgtm-backup-test-"));
  const bin = join(dir, "bin");
  const log = join(dir, "calls.log");
  mkdirSync(bin);
  mkdirSync(join(dir, "data"));
  writeFileSync(log, "");
  // One generic stub: logs "<name> <args>" and fails when FAIL_AT matches "<name>" or "<name> <first arg>".
  const stub = `#!/usr/bin/env bash
echo "$(basename "$0") $*" >> "$STUB_LOG"
case "\${FAIL_AT:-}" in
  "$(basename "$0")"|"$(basename "$0") $1"|"$(basename "$0") compose $4") exit 1 ;;
esac
exit 0
`;
  for (const name of ["docker", "rsync", "restic", "curl", "flock"]) {
    writeFileSync(join(bin, name), stub);
    chmodSync(join(bin, name), 0o755);
  }
  const p = Bun.spawnSync(["bash", join(backupDir, script)], {
    env: {
      PATH: `${bin}:${process.env.PATH}`,
      HOME: dir,
      STUB_LOG: log,
      FAIL_AT: failAt ?? "",
      XDG_RUNTIME_DIR: dir,
      LGTM_DATA_DIR: join(dir, "data"),
      LGTM_STAGING_DIR: join(dir, "staging"),
      RESTIC_REPOSITORY: "sftp:example:repo",
      RESTIC_PASSWORD_FILE: join(dir, "pass"),
      GATUS_URL: "http://gatus.invalid:8080",
      GATUS_LGTM_BACKUP_TOKEN: "test-token-not-secret",
      ...extraEnv,
    },
    stderr: "pipe",
    stdout: "pipe",
  });
  const calls = readFileSync(log, "utf8").trim().split("\n").filter(Boolean);
  rmSync(dir, { recursive: true, force: true });
  return { rc: p.exitCode ?? -1, calls, stderr: p.stderr.toString() };
}

const idx = (r: Run, re: RegExp) => r.calls.findIndex((c) => re.test(c));
const has = (r: Run, re: RegExp) => idx(r, re) >= 0;
function expect(name: string, cond: boolean, detail = "") {
  if (!cond) failures.push(`${name}${detail ? `: ${detail}` : ""}`);
}
const dump = (r: Run) => `rc=${r.rc}\n  ${r.calls.join("\n  ")}`;

const stop = /^docker compose .*stop grafana loki tempo prometheus$/;
const start = /^docker compose .*start grafana loki tempo prometheus$/;
const pushOk = /^curl .*success=true/;
const pushBad = /^curl .*success=false/;

// 1. happy path: order, one green push, token only in the header.
{
  const r = run("lgtm-backup.sh", null);
  const order = [
    /^restic cat config$/,
    stop,
    /^rsync -a --delete -- .*\/data\/ .*\/staging\/$/,
    start,
    /^restic backup .* --tag lgtm --host taylor-pc$/,
    /^restic forget --tag lgtm --host taylor-pc --keep-daily 7 --keep-weekly 4 --prune$/,
    pushOk,
  ].map((re) => idx(r, re));
  expect("happy path exits 0", r.rc === 0, dump(r));
  expect("happy path order: preflight, stop, copy, start, backup, forget, green push", order.every((v, i) => v >= 0 && (i === 0 || v > order[i - 1])), `${order.join(",")}\n${dump(r)}`);
  expect("happy path pushes success exactly once and never success=false", r.calls.filter((c) => pushOk.test(c)).length === 1 && !has(r, pushBad), dump(r));
  const push = r.calls.find((c) => pushOk.test(c)) ?? "";
  expect("push uses the endpoint key and a Bearer header", /endpoints\/lgtm_lgtm-backup\/external/.test(push) && /Authorization: Bearer test-token-not-secret/.test(push), push);
  expect("token never appears in the URL", !/external\?[^ ]*test-token/.test(push) && !/https?:\/\/[^ ]*test-token/.test(push), push);
}

// 2. preflight failure: no downtime at all, red push.
{
  const r = run("lgtm-backup.sh", "restic cat");
  expect("preflight failure exits non-zero", r.rc !== 0, dump(r));
  expect("preflight failure never stops the stack", !has(r, stop), dump(r));
  expect("preflight failure pushes red", has(r, pushBad) && !has(r, pushOk), dump(r));
}

// 3. copy fails after the stop: writers restarted, no upload, red push.
{
  const r = run("lgtm-backup.sh", "rsync");
  expect("copy failure exits non-zero", r.rc !== 0, dump(r));
  expect("copy failure still restarts the writers", has(r, stop) && has(r, start) && idx(r, start) > idx(r, stop), dump(r));
  expect("copy failure uploads nothing", !has(r, /^restic backup/), dump(r));
  expect("copy failure pushes red, not green", has(r, pushBad) && !has(r, pushOk), dump(r));
}

// 4. upload fails after the stack is back: restarted once, no forget/prune, red push.
{
  const r = run("lgtm-backup.sh", "restic backup");
  expect("upload failure exits non-zero", r.rc !== 0, dump(r));
  expect("upload failure restarts the writers exactly once", r.calls.filter((c) => start.test(c)).length === 1, dump(r));
  expect("upload failure does not prune", !has(r, /^restic forget/), dump(r));
  expect("upload failure pushes red", has(r, pushBad) && !has(r, pushOk), dump(r));
}

// 5. forget/prune fails: a green push would be a lie.
{
  const r = run("lgtm-backup.sh", "restic forget");
  expect("prune failure exits non-zero and pushes red only", r.rc !== 0 && has(r, pushBad) && !has(r, pushOk), dump(r));
}

// 6. restart itself fails: loud, non-zero, red.
{
  const r = run("lgtm-backup.sh", "docker compose start");
  expect("restart failure exits non-zero", r.rc !== 0, dump(r));
  expect("restart failure pushes red", has(r, pushBad) && !has(r, pushOk), dump(r));
}

// 7. a failed heartbeat push does not fail the backup, but is visible.
{
  const r = run("lgtm-backup.sh", "curl");
  expect("failed heartbeat push leaves the backup green", r.rc === 0, dump(r));
  expect("failed heartbeat push is reported on stderr", /Gatus heartbeat push to lgtm_lgtm-backup \(success=true\) failed/.test(r.stderr), r.stderr);
}

// 8. a pause over the target is flagged.
{
  const r = run("lgtm-backup.sh", null, { LGTM_MAX_DOWN_SECONDS: "-1" });
  expect("over-target pause is warned about", /exceeds the -1s target/.test(r.stderr), r.stderr);
}

// 9. restic-check reports to ITS OWN endpoint: green after a clean check, red on failure,
// and never to the backup's endpoint (a shared one let a good backup clear a failed check).
{
  const toCheck = /^curl .*endpoints\/lgtm_lgtm-restic-check\/external/;
  const toBackup = /^curl .*endpoints\/lgtm_lgtm-backup\/external/;
  const ok = run("lgtm-restic-check.sh", null);
  expect("check success exits 0", ok.rc === 0, dump(ok));
  expect("check runs the 5% read, then pushes green once to its own endpoint", idx(ok, /^restic check --read-data-subset=5%$/) >= 0 && idx(ok, pushOk) > idx(ok, /^restic check/) && ok.calls.filter((c) => pushOk.test(c) && toCheck.test(c)).length === 1, dump(ok));
  expect("check never touches the backup's endpoint", !has(ok, toBackup), dump(ok));
  const bad = run("lgtm-restic-check.sh", "restic check");
  expect("check failure exits non-zero and pushes red to its own endpoint only", bad.rc !== 0 && bad.calls.filter((c) => pushBad.test(c) && toCheck.test(c)).length === 1 && !has(bad, pushOk) && !has(bad, toBackup), dump(bad));
  const b = run("lgtm-backup.sh", null);
  expect("backup never touches the check's endpoint", b.rc === 0 && !has(b, /restic-check/) && has(b, toBackup), dump(b));
  const bf = run("lgtm-backup.sh", "rsync");
  expect("a failed backup reports red to its own endpoint only", bf.rc !== 0 && has(bf, toBackup) && !has(bf, /restic-check/), dump(bf));
}

if (failures.length) {
  console.error(failures.join("\n"));
  process.exit(1);
}
console.log("lgtm backup behavior: PASS (stubbed docker/rsync/restic/curl/flock)");
