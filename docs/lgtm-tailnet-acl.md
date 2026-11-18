# Tailnet ACL for the LGTM stack (admin-console snippet)

This is a **template for the Tailscale admin console**, not committed policy. The real
policy stays in the console, because it names devices and addresses, and this repo is
public. Nothing in this file has been applied. Apply it **before Phase 3** of
`docs/lgtm-taylor-pc.md`, in the console, by hand.

## Why it is needed

The stack's doors are unauthenticated at the network layer:

- Loki `:3100`, Prometheus `:9090` and Tempo `:4317`/`:4318` accept pushes from anyone who
  can reach them, and Prometheus and Loki answer reads.
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
   that should reach Grafana **stay user-owned**, and you restrict by *address alias*, not
   by tag.
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
| sentinel | **yes, `:8443` only** (Gatus health check) | yes (Alloy), and Gatus probes `:3100`/`:9090` |
| Other reporting servers | no | yes (Alloy) |
| Any other device on your login (TV, router, guest gear) | **no** | **no** |

**One deliberate difference from the original decision text.** Decision 6 listed
`:8443` for your laptops, phone and taylor-pc. The sentinel Gatus check
`lgtm-grafana` (`https://…:8443/api/health`) has to reach Grafana from sentinel, so this
template also lets **sentinel reach `:8443`**. Sentinel is then able to log in to
Grafana as Org Admin, which is the cost of that check. If you would rather not allow it,
drop the `lgtm-grafana` check from `configs/sentinel/gatus/config.yaml` and delete the
sentinel line below; the Loki and Prometheus checks still cover the stack.

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
    // Grafana UI: only devices that should be Org Admin.
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
    }
  ],

  "tests": [
    // Must be reachable.
    { "src": "lgtm-laptop-1", "accept": ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-sentinel", "accept": ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-openclaw", "accept": ["lgtm-host:3100", "lgtm-host:9090", "lgtm-host:4317"] },
    // Must not be reachable.
    { "src": "lgtm-iot-1",    "deny":   ["lgtm-host:8443", "lgtm-host:3100", "lgtm-host:9090", "lgtm-host:4317", "lgtm-host:4318"] },
    { "src": "lgtm-phone",    "deny":   ["lgtm-host:3100", "lgtm-host:9090"] },
    { "src": "lgtm-edge-lab", "deny":   ["lgtm-host:8443"] }
  ]
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
6. Check from each device class, with the stack running: a Mac reaches
   `https://<taylor-pc>.<tailnet>.ts.net:8443/api/health`; your other devices
   (TV, router) cannot. They have no way to run the check, so the console's tests are the evidence.

Rollback: restore the previous policy from the console's version history. Nothing on any
host changes, so rollback is immediate.

## If you chose the OpenObserve option

OpenObserve (`docs/openobserve-taylor-pc.md`) has **one** HTTP door, `:8443`, that carries the
UI and every ingest path, plus `:5081` for OTLP over gRPC. Replace the two rules above with
one, and drop the `:3100`, `:9090`, `:4317`, `:4318` entries from the `tests`:

```jsonc
{
  "action": "accept",
  "src": ["lgtm-host", "lgtm-laptop-1", "lgtm-laptop-2", "lgtm-phone", "lgtm-sentinel",
          "lgtm-edge-lab", "lgtm-openclaw", "lgtm-server-3"],
  "dst": ["lgtm-host:8443"]
}
```

Sentinel also needs `:5081` for the `openobserve-grpc` probe (add `lgtm-host:5081` to its
destinations, or drop that probe). What this loses compared with the LGTM option: every device
allowed to ingest can also reach the **login page**, because the UI and ingest share a port. The
network can no longer keep reporters away from the UI; OpenObserve's own login is the control, and
the ingestion passcode on each node should be treated as admin-equivalent. Keep the `deny` tests
for the devices that need nothing.

## Not in this template

- The copied rsync.net key and the OCI hosts' SSH access (Decision 8).
- Tailscale SSH, exit nodes, app connectors or any rule unrelated to the stack.
- Tagging. Reporting nodes that are already `tagged-devices` (openclaw) keep working
  through their existing identity; the address alias is enough here.
