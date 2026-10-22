# Self-hosted Buzz relay and sandboxed @rupert agent on SER8

Written 2026-10-21/22 while building it; every step below was run on SER8 unless marked **not verified**. Background on
Buzz itself, deep links and the Settings keys is in [buzz.md](buzz.md). This is an admin-only setup: **no staff have been
invited**, nobody is notified, and the only people in the relay are the owner key, the agent, and two test identities.

## Status

| Piece | State |
| --- | --- |
| Relay (`buzz` container: relay, Postgres, Redis, MinIO) | Running, closed relay (only listed pubkeys join) |
| `#rupert` and `#general` channels, agent + test members | Created |
| Rupert Settings, agent profile, Rupert test notice | Done; the notice arrived on the relay |
| Sandboxed agent (`rupert-agent` container) | Built and **proven end to end with a mock model**; service stopped until a model key exists |
| Hostname `buzz-herbalhealers.rupertpos.com` | DNS already resolves to 71.162.207.117; **needs the Caddy block below** |
| opencode key | **Waiting on you** (the old key is expired) |
| Phone scan of the QR code | **Waiting on you** (nothing to scan until TLS is live) |

Until the Caddy block exists the relay URL is plain `ws://buzz-herbalhealers.rupertpos.com` and works only from SER8's own
containers through temporary scaffolding (below).

## Layout

```
host (Caddy: TLS, public 71.162.207.117:443)
  |-- buzz-herbalhealers.rupertpos.com --> buzz container 10.96.131.4:3000   (relay)
  |-- herbalhealers.rupertpos.com      --> rupert container 10.96.131.8:3000 (production Rails, untouched)

Incus container `buzz` (Ubuntu 24.04, 4 CPU, 4 GiB, own 30 GiB btrfs pool `buzz`, isolated idmap, nesting)
  Docker: relay (pinned by digest), postgres 17, redis 7, minio; /opt/buzz/.env and /root/buzz-secrets (root-only)
  egress-proxy.service: allow-list HTTPS CONNECT proxy 10.96.131.4:3128 for the agent (opencode.ai, models.dev)

Incus container `rupert-agent` (Ubuntu 24.04, 10.96.131.6, 2 CPU, 1.5 GiB, isolated idmap, same btrfs pool)
  /usr/local/bin/{buzz, buzz-acp} built from block/buzz c37d6b8e; opencode 1.19.3
  rupert-agent.service -> buzz-acp -> opencode acp -> rupert_mcp_bridge.py (its only tools)
  network ACL `rupert-agent-egress`: tcp 443 to 71.162.207.117/32 and tcp 3128 to 10.96.131.4/32, everything else dropped
```

### Why a separate `rupert-agent` container (not the `buzz` one, not `rupert`)

The agent turns text written by chat participants into tool calls, so it is the most attackable process in the system.
`rupert` holds the production database, `/etc/rupert.env` and the Rails app; `buzz` holds the relay signing key, the
owner key, Postgres/Redis/S3 passwords and the backups of them. A third, empty container holding only the agent's own key
and a scoped token means a fully compromised agent gets neither. It also lets the network ACL name exactly what the agent
may reach.

## Threat model and what limits a compromised agent

Assume the model is fully controlled by an attacker (prompt injection from a chat message, a poisoned tool result, or a
bug in opencode). What it can do:

| It can | Limit |
| --- | --- |
| Post messages as `@rupert` in channels the agent was added to | By design; the relay is closed and admin-only today |
| Call Rupert tools | Only the bridge's allow-list (`rupert_mcp_bridge.py`): `get_workspace_info`, `list_reports`, `sales_summary`, `sales_tax_report`, `inventory_search`, `stock_comparison`, `swipesimple_items`, `list_tasks`, `list_alerts`, `submit_feedback`, `list_my_feedback`. `create_task`, `ai_health`, `recent_errors`, `list_feedback`, `report_context` and everything else are refused by the bridge even though the token could reach some |
| ... with the token | `reports:read inventory:read alerts:read tasks:read tasks:write`, owned by the first super admin; every call is re-checked against that owner's permissions; revocable (below). `tasks:write` exists only so an allow-listed sender can mark a report "ready"; the allow-list (`FEEDBACK_READY_SENDERS`) is enforced by Rupert, not the agent |
| Run commands, read files, browse | **Cannot**: opencode's `rupert` agent is `{"*": "deny", "rupert_*": "allow"}`, so the model is offered no shell, file, web or task tools at all (verified: `agent/sandbox-test/run.sh`) |
| Reach the network | Only via the ACL (next table) |
| Touch `rupert` files, DB, `/etc/rupert.env`, Rails, sockets | There is no mount, no shared storage and no Rails in the container; the only route to Rupert is HTTPS to its public API with the token |

Network probes run from inside `rupert-agent` after the ACL was applied (2026-10-22):

| Destination | Result |
| --- | --- |
| `https://herbalhealers.rupertpos.com/up` via 71.162.207.117:443 (Rupert, relay front) | 200 |
| `opencode.ai`, `models.dev` through the proxy | 200 |
| `example.com` through the proxy | refused (403) |
| direct internet (`1.1.1.1`), DNS, host bridge `10.96.131.1`, the `rupert` container, other containers (`haven`), the relay on 3000/80 directly | dropped |

Residual risks, stated plainly: the agent shares the public front (71.162.207.117:443) with every public Caddy site, so
it can talk to any of them like an internet user can; the agent holds the same Nostr key Rupert uses for notices (see
Keys), so compromise of either lets an attacker post as `@rupert`; the proxy lives in the `buzz` container, so the agent
can reach one extra port (3128) there; nothing stops the agent from sending data out through the model provider (it must
be allowed to call it). The Buzz channel is only as private as its member list.

### Revoking the agent (any one of these cuts it off)

1. **Rupert token:** System → API access → revoke "Buzz agent (sandboxed container)". The bridge then gets 401 on every
   tool call; the reply tool still works.
2. **Stop it:** `incus exec rupert-agent -- systemctl disable --now rupert-agent` (or `incus stop rupert-agent`).
3. **Relay:** `incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh remove-member <agent hex pubkey>'`.
4. **Rotate the key** (if it may have leaked): generate a new keypair, put it in `/etc/rupert-agent/secrets.env` as
   `BUZZ_PRIVATE_KEY` and in Rupert Settings, add the new pubkey to the relay and channels, remove the old one.
5. **Network:** `incus config device set rupert-agent eth0 security.acls=` (and stop it) removes nothing from the
   container; to cut it off at the wire delete the ACL rules instead: `incus network acl rule remove rupert-agent-egress egress`.

## Hostname and TLS: what you need to add

The chosen name is **`buzz-herbalhealers.rupertpos.com`**. Its DNS already answers `71.162.207.117`, the same address
`herbalhealers.rupertpos.com` has (checked 2026-10-22), so **no DNS change is needed** unless that answer is a placeholder.

1. **Caddy** (`/etc/caddy/Caddyfile`), same conventions as the existing `herbalhealers.rupertpos.com` block (WebSockets
   work through `reverse_proxy` with no extra settings):

   ```
   buzz-herbalhealers.rupertpos.com {
       import cockpit_incus_access
       bind 192.168.3.251
       encode zstd gzip
       reverse_proxy 10.96.131.4:3000
   }
   ```

   then reload Caddy.
2. Check from anywhere: `curl -s -H 'Accept: application/nostr+json' https://buzz-herbalhealers.rupertpos.com/ | head -c 200`
   prints JSON starting `{"name":"Buzz Relay"`.

The relay derives its community from this host name, so changing the name later means recreating the channels.

**After it answers, switch to wss (all on SER8):**

```bash
incus exec buzz -- sed -i 's|^RELAY_URL=.*|RELAY_URL=wss://buzz-herbalhealers.rupertpos.com|' /opt/buzz/.env
incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh restart'
# agent container: relay now via the public front, drop the temporary pieces
incus exec rupert-agent -- bash -c 'sed -i "s#^BUZZ_RELAY_URL=.*#BUZZ_RELAY_URL=wss://buzz-herbalhealers.rupertpos.com#" /etc/rupert-agent/agent.env
  sed -i "/buzz-herbalhealers/d" /etc/hosts; echo "71.162.207.117 buzz-herbalhealers.rupertpos.com" >> /etc/hosts'
incus network acl rule remove rupert-agent-egress egress destination=10.96.131.4/32 destination_port=80 protocol=tcp
# remove the temporary port-80 forwarder and hosts lines
incus exec buzz -- bash -c 'systemctl disable --now buzz-test-port80; rm /etc/systemd/system/buzz-test-port80.service; sed -i "/buzz-herbalhealers/d" /etc/hosts'
incus exec rupert -- sed -i '/buzz-herbalhealers/d' /etc/hosts
```

and set Rupert's `BUZZ_RELAY_URL` to `wss://buzz-herbalhealers.rupertpos.com` (Settings → Buzz agent), then **Check status**.
The agent container resolves names only from `/etc/hosts` (it has no DNS), so if `71.162.207.117` ever changes, update
`/etc/hosts` there and the ACL destination.

### Temporary scaffolding (remove when TLS is live)

| Where | What |
| --- | --- |
| `buzz` container | `buzz-test-port80.service` (`socat` 80 → relay 3000) and `127.0.0.1 buzz-herbalhealers.rupertpos.com` in `/etc/hosts`; `RELAY_URL=ws://…` in `.env` |
| `rupert` container | one `/etc/hosts` line `10.96.131.4 buzz-herbalhealers.rupertpos.com` |
| `rupert-agent` | `/etc/hosts` line to `10.96.131.4` and the ACL rule tcp 80 → `10.96.131.4/32` |

## Keys and secrets (nothing is in Git or in chat)

| What | Where |
| --- | --- |
| Relay signing key, DB/Redis/S3 secrets | `buzz` `/opt/buzz/.env` (0600 root) |
| Community owner key; test sender and reader keys | `buzz` `/root/buzz-secrets/*.key` (0600 root). Public keys: owner `650f1cfa…d1c198`, tester `5aab33c6…a793c` (member), reader `e18a849d…a98f65` (guest) |
| Agent Nostr key | `rupert-agent` `/etc/rupert-agent/secrets.env` (0600 root, `BUZZ_PRIVATE_KEY`); also in Rupert Settings (encrypted) because Rupert posts its own notices with it. Public key `454095f3…371b4`, npub `npub1g4qftu7d8p3ly0ek8etrkaeps94cec4ylve3rwnmkhv2k4wnwx6qffluc8`. It is the key Rupert already had (since 2026-08-14), copied without printing it. |
| Rupert token | `/etc/rupert-agent/secrets.env` (`RUPERT_MCP_TOKEN`), name "Buzz agent (sandboxed container)", expires 2027-10-21 |
| Model key | `/etc/rupert-agent/secrets.env` (`OPENCODE_API_KEY`) once you supply it |
| Backups of the relay secrets | `~/backups/buzz/` on the host, AES-256 with `~/.config/rupert/offhost.key` |

## Channels and members

| Channel | Id |
| --- | --- |
| `#rupert` (Rupert's `BUZZ_CHANNEL`) | `61d13f21-6b96-4ac4-ae80-ee9dd455a500` |
| `#general` | `89c42578-6603-46c1-a92e-21ac225403ff` |

(The first community, on the earlier host name `buzz.stoverparc.org`, was discarded; its channel ids no longer exist.)
Members: owner, agent (`bot`), tester (`member`), reader (`guest`). Add a person:

```bash
incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh add-member npub1… --role member'
# then each channel, as the owner:
incus exec buzz -- bash -c 'export BUZZ_RELAY_URL=http://buzz-herbalhealers.rupertpos.com BUZZ_PRIVATE_KEY=$(cat /root/buzz-secrets/owner.key)
  buzz channels add-member --channel <uuid> --pubkey <hex> --role member'
```

Nobody else has been added; the Rupert header's Buzz card is visible to staff with Overview access, so hold off sharing it
until you want staff in.

## Rupert settings (production tenant)

| Key | Now | Before 2026-10-21 |
| --- | --- | --- |
| `BUZZ_RELAY_URL` | `ws://buzz-herbalhealers.rupertpos.com` (`wss://` after TLS) | `wss://techmore.communities.buzz.xyz` |
| `BUZZ_CHANNEL` | `61d13f21-6b96-4ac4-ae80-ee9dd455a500` | `c4c0ac29-2440-4914-afee-ab1b26e06a31` |

[buzz.md](buzz.md) said Buzz was not configured, but those settings existed and the hosted community is still online. They
were overwritten before this was noticed. To go back: `EnvStore.set('BUZZ_RELAY_URL', 'wss://techmore.communities.buzz.xyz')` and
`EnvStore.set('BUZZ_CHANNEL', 'c4c0ac29-2440-4914-afee-ab1b26e06a31')` under `Current.tenant = Tenant.first`.

Rupert still holds the agent key so `BuzzNotifyJob` (sync and stock notices) can post. Because the agent key now lives
in two places, a leak of either means rotating it (Revoking, step 4).

### Fixed on the way: Rupert never delivered a message

`BuzzAgent.publish` / `NostrPublisher.publish` took the **first** `OK` as the answer to their event, but the relay also
answers the NIP-42 `AUTH` event with an `OK`; both returned success and closed before the event was stored. Fixed in
#297 (match the `OK` to the event id); verified live: `register!` and a notice now arrive and the status shows "registered".

## Running the agent

Files (all in `deploy/ser8/agent/`): `rupert_mcp_bridge.py` (the only tool set: `buzz_reply`, plus the allow-listed Rupert
tools), `opencode.json` (agent `rupert`, `"*": "deny"`), `rupert-agent-run`, `rupert-agent.service`, `agent.env.example`.
`buzz-acp` runs `opencode acp` with `BUZZ_ACP_RESPOND_TO=anyone` (membership of the closed relay is the gate).

**Why no shell tool:** replying is done by the bridge's `buzz_reply`, which runs `buzz messages send` as an argument list
(no shell), so opencode needs no bash. Filing reports is the Rupert `submit_feedback` tool; the allow-list for "ready for
development" is checked by Rupert from the sender pubkey in the event metadata, as before.

Install (already done in this container; for a rebuild):

```bash
useradd --system --home-dir /var/lib/rupert-agent --shell /usr/sbin/nologin rupert-agent
install -d /etc/rupert-agent        # then push: opencode.json, prompt.txt (docs/ops/buzz-agent-prompt.txt), agent.env
install -m 0755 rupert-agent-run /usr/local/bin/ ; install -m 0755 rupert_mcp_bridge.py /usr/local/lib/rupert-agent/
# secrets.env (0600): BUZZ_PRIVATE_KEY, RUPERT_MCP_TOKEN, OPENCODE_API_KEY
systemctl enable --now rupert-agent
```

### The opencode key (you must supply one)

The old key (host `~/.local/share/opencode/auth.json`) is expired. Create a key in the OpenCode Console and add it to
`/etc/rupert-agent/secrets.env` as `OPENCODE_API_KEY=…`, then `systemctl enable --now rupert-agent`. Tell me whether it is
a Zen or a Go key: `deepseek-v4-flash` (in `opencode.json`) is in the Zen catalog, not Go's. The free tier does not
work: calls from anything but the OpenCode apps return `403 free tier can only be used from within OpenCode`.
The AI-health card in Rupert reads `OPENCODE_API_KEY` from Rupert's own environment, so it will keep saying "not set"
unless you also put a key there (a second key is safest); the agent does not need Rupert to hold it.

### opencode versions

- **Agent: opencode 1.19.3** (GitHub release, tarball sha256 `13a8fb29…3336c9b`). It is the one that exposes MCP tools and
  enforces `permission` for them.
- opencode 2.0.32 (what is on the host) **does not expose configured MCP servers to the model** (tried remote and local
  servers, config and ACP, every permission open), and 1.19.3 crashes (`embedder failed to suspend thread`) in a plain
  container but runs in the nesting-enabled containers used here. That is why the agent container has `security.nesting=true`.
- `OpencodeCli` (merged in #297) keeps Ask Rupert and the text-only runner working with 2.0.32's flags; Ask Rupert's
  provider needs `opencode` and a `chat` agent in the `rupert` container, which this change no longer installs.

### Tests that were run

- Mock model, real everything else, through the real unit (relay → buzz-acp → opencode 1.19.3 → bridge → relay / Rupert):
  a `@rupert` ping from the tester identity got a reply from the agent; `get_workspace_info` returned live data from
  Rupert through the ACL; `submit_feedback` with `ready_for_development` from a **non-allow-listed** sender created a
  report "NOT marked ready for development"; after adding the tester to `FEEDBACK_READY_SENDERS` the same call produced a
  ready report. The test reports/tasks were deleted and the allow-list cleared.
- `agent/sandbox-test/run.sh`: the model is offered exactly `rupert_buzz_reply`+allowed tools and a shell call is impossible.
- `agent/test_bridge.py`: forbidden tools never reach Rupert; reply input is validated; no shell is used.
- A real model's behaviour is **not verified** (no key).

## Backups

`~/.local/bin/buzz-backup.sh` + host user timer `buzz-backup.timer` (every 6 h): encrypted, decrypt-verified `pg_dump`,
MinIO/git volumes and relay secrets in `~/backups/buzz/` (same key as `rupert-offhost-backup.sh`, keeps 35). A restore drill
loaded the dump into a scratch database (93 tables, 83 events, equal to live) and dropped it. The weekly `incus-backup.timer`
also exports `buzz` and `rupert-agent` (crash-consistent). The agent container has nothing to back up beyond its env files.

## Operations notes and incidents

- **Never snapshot, freeze or restart the production `rupert` container.** On the `dir` pool a snapshot copies the 49 GB
  root while the instance is frozen. An early `incus snapshot create rupert …` here froze production for about 4.5
  minutes (22:05–22:09 UTC 2026-10-21; `/up` returned nothing) and took host free space from 88 GB to 40 GB; the snapshot
  was deleted straight away. No other operation has touched `rupert` beyond reads, the planned Settings changes, one
  `/etc/hosts` line, and installing then removing the agent binaries. Snapshots of `buzz`/`rupert-agent` are on btrfs.
- `incus snapshot create buzz …` sometimes hangs the client; kill it and retry with `timeout`. Processes started in one
  `incus exec` session often cannot be killed from another in these isolated-idmap containers (`Permission denied`); restart
  the container instead.
- `security.idmap.isolated=true` is needed for Docker in `buzz`; the default idmap shares a kernel key quota
  (`unable to join session keyring: disk quota exceeded`).
- The relay derives its community from the host in `RELAY_URL` and checks NIP-42 `relay` tags against
  `<scheme>://<Host header>`; IP or port URLs do not authenticate.
- Upgrading the relay: back up, change `BUZZ_IMAGE` in `/opt/buzz/.env` to a newer digest, `./run.sh upgrade`; rebuild
  `buzz`/`buzz-acp` from the matching source revision (Rust 1.95 in a throwaway Ubuntu 24.04 container, not the 26.04 host:
  glibc 2.43 binaries do not run on 24.04). Current binaries (block/buzz `c37d6b8e`): `buzz` sha256 `37624a48…be7850`,
  `buzz-acp` `7aef093d…dc54763`.

## Rollback

| Change | Undo |
| --- | --- |
| Relay stack | `incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh stop'`, `incus snapshot restore buzz stack-up-clean`, or `incus delete -f buzz; incus storage delete buzz` once `rupert-agent` is gone too |
| Agent | `incus delete -f rupert-agent; incus network acl delete rupert-agent-egress`; revoke its token |
| Proxy | `incus exec buzz -- systemctl disable --now egress-proxy` |
| Rupert Settings | the `EnvStore.set` lines above |
| `rupert` `/etc/hosts` line | `sed -i '/buzz-herbalhealers/d' /etc/hosts` |
| Backup timer | `systemctl --user disable --now buzz-backup.timer` |

## Not verified

- A real model's replies, and the permission-sensitive question end to end with real prose (no key).
- `wss://` through your Caddy block and any real phone or desktop client; the QR code opening the Buzz mobile app; whether a
  public mobile build exists.
- Whether opencode 1.19.3 honours `HTTPS_PROXY` for the model provider (the proxy and ACL are verified with curl; the first
  real model call will show in `journalctl -u egress-proxy` in the `buzz` container as `CONNECT opencode.ai`).
- Behaviour of the relay under real use.
