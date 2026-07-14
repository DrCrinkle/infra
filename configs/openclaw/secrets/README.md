# OpenClaw secrets → OCI Vault (exec SecretRef resolver)

OpenClaw's formerly-plaintext credentials are backed by **OCI Vault**, read at
runtime by an on-box exec resolver using **instance-principal** auth (no static
API key on the box). Provisioned 2026-07-14.

## Pieces

- **`oci-vault-resolver`** → deployed to `/home/opc/.local/bin/oci-vault-resolver` (mode `0755`).
  Implements OpenClaw's exec SecretRef protocol (protocolVersion 1): reads
  `{ids:[...]}` on stdin, returns `{values:{...}}` on stdout, fetching each
  secret bundle by name from the vault via instance principal. Requires the OCI
  Python SDK (`pip3 install --user oci`) and `passEnv: ["HOME","PATH"]` so the
  minimal exec child can find the user site-packages.
- **`terraform/vault.tf`** → the KMS vault, AES-256 software key, dynamic group
  (matches the OpenClaw instance OCID), and a least-privilege
  `read secret-bundles` policy.
- **`~/.openclaw/openclaw.json`** → `secrets.providers.oci-vault` (`source: exec`,
  `command: /home/opc/.local/bin/oci-vault-resolver`), plus SecretRef objects on
  the migrated config fields.

## Secrets (7, deduped from 17 fields)

`gateway-auth-token`, `discord-token`, `google-apikey`, `opencode-go-apikey`,
`openrouter-key` (shared by all 5 agents' auth profiles), `memorysearch-remote-apikey`
(the shared NVIDIA/embeddings key — used by memorySearch + all nvidia providers),
and `gbrain-mcp-token`.

Field → secret mapping lives on the box at `~/.openclaw/secret-map.json`
(mode `0600`, names + sha256 prefixes only, no values).

## Surface conventions (how each field references its secret)

| Surface | Field | Rewritten to |
|---------|-------|--------------|
| `openclaw.json` model/config/channel fields | `apiKey` / `token` | inline SecretRef object |
| agent `openclaw-agent.sqlite` auth profiles | `profiles.*.key` | sibling `keyRef` + empty `key` |
| agent `models.json` providers | `apiKey` | `"secretref-managed"` marker (real key resolves from openclaw.json) |

The openclaw.json + auth-profile rewrites were done with `openclaw secrets apply
--from <plan>`; discord with `openclaw config set … --ref-*`; models.json markers
directly. Verify anytime with `openclaw secrets audit --check --allow-exec`
(expect `plaintext=0, unresolved=0`; a single `openai:default` OAuth
`LEGACY_RESIDUE` is expected and out of scope).

## gbrain MCP token

`GBRAIN_MCP_TOKEN` is stored in the vault (`gbrain-mcp-token`) for centralization,
but the gateway still reads it from `~/.openclaw/gateway.systemd.env` (mode `0600`)
at runtime because `mcp.servers.gbrain.headers.Authorization` uses `${VAR}` env
substitution, not a SecretRef. Acceptable per the migration brief.

## Redeploy the resolver

```bash
scp configs/openclaw/secrets/oci-vault-resolver opc@openclaw:/home/opc/.local/bin/oci-vault-resolver
ssh opc@openclaw 'chmod 0755 ~/.local/bin/oci-vault-resolver && systemctl --user restart openclaw-gateway.service'
```
