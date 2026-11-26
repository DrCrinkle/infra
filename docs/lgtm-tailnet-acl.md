# Tailnet ACL for the LGTM stack (admin-console snippet)

This is a **template for the Tailscale admin console**, not committed policy. The real
policy stays in the console, because it names devices and addresses, and this repo is
public. Nothing in this file has been applied. Apply it **before any door opens** (Phase 1
step 6 of `docs/lgtm-taylor-pc.md`), in the console, by hand. Phase 3 then opens with a check
that must fail, so a policy that was never applied cannot go unnoticed.

## Why it is needed

The stack's doors are unauthenticated at the network layer:

- Loki `:3100`, Prometheus `:9090` and Tempo `:4317`/`:4318` accept pushes from anyone who
  can reach them, and Prometheus and Loki answer reads. **Every reporting node can therefore
  read every host's logs and metrics**, including taylor-pc's own journal. Loki's delete API
  is switched off in `configs/lgtm/loki.yaml` (`deletion_mode: disabled`), so a compromised
  reporter cannot erase logs. What remains is accepted, pending the captain's confirmation: every
  admitted reporter can read all of it, and can also restart Loki (one unauthenticated
  `POST /ingester/shutdown` stopped it in the re-review's run). The ACL decides who gets that.
- Grafana `:8443` logs in whoever Tailscale Serve identifies, as **Org Admin**
  (`GF_USERS_AUTO_ASSIGN_ORG_ROLE=Admin`). Grafana runs on taylor-pc's host network, so an
  Admin can point a datasource at any loopback service on that machine.

The tailnet is flat and almost every device belongs to one Tailscale user. A device
owned by that user arrives at Grafana *as that user*, so it gets Org Admin. That
includes devices that have no business near it, such as a smart TV or a router that you signed in to your tailnet. Switching
the default role to Viewer would not help, because they are the same user. The control
is the ACL.

## Two traps this design avoids

1. **Tagging a device removes its user identity.** Serve only sends
   `Tailscale-User-Login` for requests from user-owned devices. If you tag a laptop or
   phone to give it an ACL identity, it can no longer log in to Grafana. So the devices
   that should log in to Grafana **stay user-owned**, and you restrict by *address alias*,
   not by tag. The one deliberate exception is sentinel, which should *not* be able to log
   in: see "Tag sentinel" below.
2. **Default-deny bites.** The moment an `acls` list exists without a blanket rule,
   anything not listed stops working: SSH, the other Serve apps, everything. This
   template adds rules; it does not tell you to delete your current blanket rule. See
   "Order of operations".

## Who needs what

| Device class | Grafana `:8443` | Ingest `:3100` `:9090` `:4317` `:4318` |
|---|---|---|
| taylor-pc | yes | not needed (its own Alloy pushes over loopback) |
| Your laptops | yes | yes (Alloy) |
| Your phone | yes | no |
| sentinel (**tagged**) | **yes, `:8443` health probe only**; no Grafana login | yes (Alloy), and Gatus probes `:3100`/`:9090` |
| Other reporting servers | no | yes (Alloy) |
| Any other device on your login (TV, router, guest gear) | **no** | **no** |

**One deliberate difference from the original decision text.** Decision 6 listed
`:8443` for your laptops, phone and taylor-pc. The sentinel Gatus check
`lgtm-grafana` (`https://…:8443/api/health`) has to reach Grafana from sentinel, so this
template also lets **sentinel reach `:8443`**. Left user-owned, sentinel would arrive as you
and be auto-enrolled as Org Admin, and an Admin here can point a datasource at any loopback
service on taylor-pc. So **tag it** (next section): a tagged node carries no identity, Serve
sends no login header for it, and `/api/health` needs no login, so the probe keeps working
while the admin path disappears. If you would rather not allow sentinel on `:8443` at all,
drop the `lgtm-grafana` check from `configs/sentinel/gatus/config.yaml` and delete the
sentinel entry from the first rule below; the Loki and Prometheus checks still cover the stack.

Related: **every identity that reaches `:8443` is auto-enrolled as Org Admin**, so a node
share or a tailnet invite to someone else would grant them Admin. Do not share taylor-pc, and
review who is on the tailnet when you apply this.

## Tag sentinel

In the console, add the `tagOwners` entry from the template below and put the tag on sentinel
(Machines, the sentinel row, Edit ACL tags). Whether sentinel is tagged today has not been
checked from here.

Tagging changes the device's Tailscale identity and turns off its node-key expiry; its address
and MagicDNS name stay, so the address aliases below keep matching. **But a rule whose `src` is a
user or `autogroup:member` stops matching a tagged device**, so confirm sentinel's existing flows
(its probes to openclaw: ICMP, SSH `:22` and the gateway `:443`, and SSH from taylor-pc) are still
allowed by an address- or tag-based rule before you tag it. After tagging, **at Phase 3-0 of the
runbook, with the stack running**, check from sentinel: `curl -s -o /dev/null -w '%{http_code}\n' https://<taylor-pc>.<tailnet>.ts.net:8443/api/health`
returns `200`, and the same request to `/api/user/orgs` is refused (a `401`, not the org list).
That second result is what I expect from Grafana with no login header; confirm it when you do this.

## Template

Replace each `<...>` with the device's tailnet address **in the console only**. Do not put
the addresses in this repository, a PR or a chat. Merge these entries into your existing
`hosts`, `acls` and `tests`; keep every rule you already have.

```jsonc
{
  "hosts": {
    "lgtm-host":        "<taylor-pc tailnet address>",
    "lgtm-laptop-1":    "<first laptop address>",
    "lgtm-laptop-2":    "<second laptop address>",
    "lgtm-phone":       "<phone address>",
    "lgtm-sentinel":    "<sentinel address>",
    "lgtm-edge-lab":    "<edge-lab address>",
    "lgtm-openclaw":    "<openclaw address>",
    "lgtm-server-3":    "<any other reporting server address>",
    "lgtm-iot-1":       "<a TV, router or other device that needs nothing here>"
  },

  "acls": [
    // Grafana UI: the devices that should be Org Admin, plus sentinel for the health probe
    // only (tagged, so it carries no login identity; see "Tag sentinel").
    {
      "action": "accept",
      "src": ["lgtm-host", "lgtm-laptop-1", "lgtm-laptop-2", "lgtm-phone", "lgtm-sentinel"],
      "dst": ["lgtm-host:8443"]
    },
    // Ingest doors: only nodes that report, or probe the doors.
    {
      "action": "accept",
      "src": ["lgtm-host", "lgtm-laptop-1", "lgtm-laptop-2", "lgtm-sentinel",
              "lgtm-edge-lab", "lgtm-openclaw", "lgtm-server-3"],
      "dst": ["lgtm-host:3100,9090,4317,4318"]
    },
    // The backup job on taylor-pc pushes its heartbeat to Gatus on sentinel. Without this
    // rule (once the blanket rule is gone) the push fails with only a journal warning, and
    // the dead-man pages for backups that are fine.
    {
      "action": "accept",
      "src": ["lgtm-host"],
      "dst": ["lgtm-sentinel:8080"]
    }
  ],

  "tests": [
    // Must be reachable.
    { "src": "lgtm-host",     "accept": ["lgtm-sentinel:8080"] },
    { "src": "lgtm-laptop-1", "accept": ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-sentinel", "accept": ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-openclaw", "accept": ["lgtm-host:3100", "lgtm-host:9090", "lgtm-host:4317"] },
    // Must not be reachable.
    { "src": "lgtm-iot-1",    "deny":   ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090", "lgtm-host:4317", "lgtm-host:4318"] },
    { "src": "lgtm-phone",    "deny":   ["lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-edge-lab", "deny":   ["lgtm-host:8443"] },
    { "src": "lgtm-edge-lab", "deny":   ["lgtm-sentinel:8080"] }
  ],

  // Put the tag on sentinel in the console (see "Tag sentinel").
  "tagOwners": { "tag:monitor": ["autogroup:admin"] }
}
```

The `tests` block is what makes this safe to apply: the console refuses to save a policy
whose tests fail, so a typo in an address cannot silently open or close a door.

## Order of operations

The `deny` tests only pass if your **existing** policy does not already accept those
flows. A flat tailnet usually has a blanket `* -> *:*` rule, which makes them fail. That
is the point: the tests tell you the blanket rule is what you must narrow.

1. In the admin console, open the policy file and **copy the current policy somewhere
   safe**. The console also keeps version history, which is the rollback.
2. Paste the `hosts`, `acls` and `tests` entries in, without removing anything.
3. Save once with the `deny` tests removed and confirm the `accept` tests pass.
4. Replace the blanket rule with explicit rules for what you actually use (SSH to the OCI
   hosts and taylor-pc, the other Serve apps on `:443`, anything else you reach). Use the
   console's rule preview and add a `tests` entry for each flow before you remove the
   blanket rule. This is the step to take slowly: do not guess which flows you rely on.
5. Add the `deny` tests back. Save. They must pass.
6. The reachability checks need the stack, which does not exist yet when this is applied
   (the ACL comes before any door opens). They run at **Phase 3-0** of the runbook: a Mac reaches
   `https://<taylor-pc>.<tailnet>.ts.net:8443/api/health`, edge-lab is refused, and sentinel's
   tag check passes. Your other devices (TV, router) have no way to run a check, so the console's
   tests are the evidence for those.

Rollback: restore the previous policy from the console's version history. Nothing on any
host changes, so rollback is immediate.

## Not in this template

- The copied rsync.net key and the OCI hosts' SSH access (Decision 8).
- Tailscale SSH, exit nodes, app connectors or any rule unrelated to the stack.
- Tagging other devices. Reporting nodes that are already `tagged-devices` (openclaw) keep
  working through their existing identity, and the devices that should log in to Grafana must
  stay untagged; the address alias is enough for both. Only sentinel is tagged, on purpose.
