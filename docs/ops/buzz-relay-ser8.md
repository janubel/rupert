# Self-hosted Buzz relay on SER8

Written 2026-10-21 while building it; every step below was run on SER8 unless marked **not verified**. It covers the
relay (an Incus container), the `@rupert` agent (a systemd service in the `rupert` container), how Rupert is wired to
it, backups, rollback, and what is still waiting on a person. Background on Buzz itself, deep links and the Settings
keys is in [buzz.md](buzz.md).

## Status

| Piece | State |
| --- | --- |
| Relay (`buzz` container: relay, Postgres, Redis, MinIO) | Running, closed relay (only listed pubkeys join) |
| Channels `#rupert` and `#general`, owner, agent, test identities | Created |
| Rupert Settings (`BUZZ_RELAY_URL`, `BUZZ_CHANNEL`, agent key) | Set; agent profile published |
| `buzz`, `buzz-acp`, `opencode` in the `rupert` container | Installed (`/usr/local/bin`) |
| `rupert-buzz` agent service | Unit and config committed; **install after the PR deploys** (steps below) |
| Public hostname and TLS | **Waiting on you** (Caddy block and DNS record below) |
| opencode key | **Waiting on you**: the old key is expired |
| Phone scan of the QR code | **Waiting on you** (cannot be done from here) |

Until the Caddy block and DNS record exist, the relay URL is plain `ws://buzz.stoverparc.org` and works only from SER8's
own containers through temporary scaffolding (see "Temporary scaffolding"). Phones cannot reach it yet.

## What was added and where

```
Incus container `buzz` (Ubuntu 24.04, 10.96.131.4 pinned, 4 CPU, 4 GiB RAM, own 30 GiB btrfs pool `buzz`)
  Docker (docker.io 29.1.3 + compose 2.40.3) running the upstream production bundle in /opt/buzz
    relay    ghcr.io/block/buzz@sha256:0a818e27…862422   (main at revision c37d6b8e, 2026-10-21; pinned by digest)
    postgres 17-alpine, redis 7-alpine, minio (Silo fork, pinned by digest upstream)
  /opt/buzz/.env             root-only secrets (relay key, Postgres, Redis, S3, hook HMAC)
  /root/buzz-secrets/        root-only: owner.key/.pub, tester.key/.pub, reader.key/.pub
Incus container `rupert` (production Rails, unchanged apart from the items marked below)
  /usr/local/bin/buzz, buzz-acp   built from block/buzz at c37d6b8e (Rust 1.95, release build)
  /usr/local/bin/opencode         v2.0.32
```

Why a container with Docker inside: upstream ships a Compose bundle only (relay + Postgres + Redis + S3-compatible
store); Incus 6.0.5 here has no native OCI containers. The relay itself uses about 70 MB of RAM; the whole stack
about 250 MB idle.

Capacity before creating anything (2026-10-21 17:58): host disk 94 GB free of 915 GB (90 % used), 21 GB RAM available
of 26 GB. The new container is bounded by its own 30 GiB pool (a loop file that grows as written), 4 CPUs and 4 GiB.

### Choices that were not obvious

- **Own storage pool.** The `default` pool is a plain `dir` pool with no quota. A 30 GiB btrfs loop pool gives the relay
  a hard disk ceiling and cheap snapshots.
- **`security.idmap.isolated=true`.** With the shared idmap, Docker failed to start containers with
  `unable to join session keyring: disk quota exceeded`: the kernel's per-uid key quota is shared by every container
  that uses the default idmap. An isolated idmap gives the `buzz` container its own uid range and quota.
- **`security.nesting=true`** plus `security.syscalls.intercept.mknod/setxattr` for Docker.
- **Do not snapshot the `rupert` container.** On the `dir` pool a snapshot is a full copy: its root is about 49 GB (mostly
  `/var`) and took host free space from 88 GB to 40 GB within a minute. That snapshot was deleted at once. Changes to
  `rupert` are therefore small files with their own rollback (see Rollback). The `buzz` container sits on btrfs, where
  snapshots are cheap: `baseline-before-start` and `stack-up-clean` exist.
- **Closed relay.** Upstream defaults kept: `BUZZ_REQUIRE_RELAY_MEMBERSHIP=true`, `BUZZ_REQUIRE_AUTH_TOKEN=true`,
  `RELAY_OWNER_PUBKEY` set, no admin console (`BUZZ_ADMIN_HOST` unset), push gateway off.
- The relay derives its **community from the host name** in `RELAY_URL` and expects NIP-42 `relay` tags to equal
  `<scheme-from-RELAY_URL>://<Host header>`. A client must therefore connect with the real host name; an IP address or
  a port in the URL does not work.

## Hostname and TLS: what you need to add

The relay host name used everywhere so far is **`buzz.stoverparc.org`**. I chose it because `stoverparc.org` names
(`rupert.stoverparc.org`, `tasks.stoverparc.org`) already resolve to 71.162.207.117 and are served by the same Caddy; it
does not exist in DNS yet. If you prefer another name (for example under `rupertpos.com`), tell me before you add
anything and I will change `RELAY_URL` and the Rupert setting; do not add DNS for a different name first, because the
relay's community is keyed by the host name.

1. **DNS** (wherever `stoverparc.org` is managed): `buzz.stoverparc.org  A  71.162.207.117` (the same address as
   `rupert.stoverparc.org`; a CNAME to that name works as well).
2. **Caddy** (`/etc/caddy/Caddyfile` on the host), next to the other site blocks, same conventions:

   ```
   buzz.stoverparc.org {
       import cockpit_incus_access
       bind 192.168.3.251
       encode zstd gzip
       reverse_proxy 10.96.131.4:3000
   }
   ```

   Then `sudo systemctl reload caddy` (or however you reload it). Caddy proxies WebSockets without extra settings, so
   `wss://buzz.stoverparc.org` works through the same block.
3. Check from any machine: `curl -s -H 'Accept: application/nostr+json' https://buzz.stoverparc.org/ | head -c 200`
   should print JSON that starts with `{"name":"Buzz Relay"`.

This exposes the relay to the internet exactly as Rupert is exposed. The relay is closed (only pubkeys added by the
owner can read or write), and the admin console is off.

**After it answers**, tell me (or run these on SER8):

```bash
# relay: switch the community URL to wss and restart the relay only
incus exec buzz -- sed -i 's|^RELAY_URL=.*|RELAY_URL=wss://buzz.stoverparc.org|' /opt/buzz/.env
incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh restart'
# remove the temporary scaffolding
incus exec buzz -- bash -c 'systemctl disable --now buzz-test-port80; rm /etc/systemd/system/buzz-test-port80.service; sed -i "/buzz.stoverparc.org/d" /etc/hosts'
incus exec rupert -- sed -i '/buzz.stoverparc.org/d' /etc/hosts
```

and change Rupert's `BUZZ_RELAY_URL` to `wss://buzz.stoverparc.org` (Settings → Buzz agent, or the runner recipe below),
then **Check status**.

### Temporary scaffolding (remove after DNS and TLS work)

| Where | What | Remove with |
| --- | --- | --- |
| `buzz` container | `buzz-test-port80.service`: `socat` from port 80 to the relay on 3000, and `127.0.0.1 buzz.stoverparc.org` in `/etc/hosts` | commands above |
| `rupert` container | one line in `/etc/hosts`: `10.96.131.4 buzz.stoverparc.org` | commands above |
| `buzz` `.env` | `RELAY_URL=ws://buzz.stoverparc.org` (plain) | switch to `wss://` as above |

## Keys and secrets (nothing is in Git or in chat)

| What | Where | Notes |
| --- | --- | --- |
| Relay signing key, Postgres/Redis/S3 secrets, hook HMAC | `buzz` container `/opt/buzz/.env` (0600 root) | must stay stable across restarts |
| Community owner identity | `buzz` container `/root/buzz-secrets/owner.key` (0600 root); public key `650f1cfa…d1c198` | used for `buzz-admin`/CLI administration |
| Test sender and test reader identities | `/root/buzz-secrets/tester.key`, `reader.key` | public keys `5aab33c6…a793c` (member) and `e18a849d…a98f65` (guest) |
| The `@rupert` agent key | Rupert Settings (`BUZZ_PRIVATE_KEY`, encrypted at rest) | public key `454095f3…371b4`, npub `npub1g4qftu7d8p3ly0ek8etrkaeps94cec4ylve3rwnmkhv2k4wnwx6qffluc8` |
| Backups of all of the above | `~/backups/buzz/` on the host, AES-256 encrypted with `~/.config/rupert/offhost.key` | see Backups |

The agent key is the one Rupert already had (generated 2026-08-14 for an earlier community). It was kept so the agent keeps
one identity; it is a member of the new relay as role `bot`.

## Channels, members, test identities

| Channel | Id | Purpose |
| --- | --- | --- |
| `#rupert` | `1fa0b6c7-e910-4dcf-b93b-018caa224642` | `BUZZ_CHANNEL`: Rupert notices and the agent |
| `#general` | `2a5156df-36d4-4994-980d-87913a6f5d3e` | team chat |

Relay members (`./run.sh list-members` in `/opt/buzz`): owner, the agent (`bot`), `tester` (member), `reader` (guest).
Channel creation and membership are done with the `buzz` CLI as the owner:

```bash
incus exec buzz -- bash -c 'export BUZZ_RELAY_URL=http://buzz.stoverparc.org BUZZ_PRIVATE_KEY=$(cat /root/buzz-secrets/owner.key)
  buzz channels create --name ops --type stream --visibility open
  buzz channels add-member --channel <uuid> --pubkey <hex> --role member'
```

**Adding people.** A person installs Buzz Desktop (link on Rupert's `/buzz` card), creates their identity, and gives you
their public key (`npub1…`). Then, on SER8:

```bash
incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh add-member npub1… --role member'   # relay membership (closed relay)
# then add them to each channel with the owner CLI above (use their hex pubkey)
```

Add yourself first as `--role admin`. When adding several people in a loop, `sleep 1` between calls (upstream note).
I could not find a CLI command that creates invite links, so the flow is "send your npub".

## Rupert settings (production tenant)

Set from a `rails runner` (the same `EnvStore`/`BuzzAgent` calls the Settings page makes):

| Key | Value now | Before 2026-10-21 |
| --- | --- | --- |
| `BUZZ_RELAY_URL` | `ws://buzz.stoverparc.org` (becomes `wss://` after DNS) | `wss://techmore.communities.buzz.xyz` |
| `BUZZ_CHANNEL` | `1fa0b6c7-e910-4dcf-b93b-018caa224642` (`#rupert`) | `c4c0ac29-2440-4914-afee-ab1b26e06a31` |
| `BUZZ_PRIVATE_KEY` | unchanged (set 2026-08-14) | same |

**Heads-up:** [buzz.md](buzz.md) said Buzz was not configured in production, but the settings above already existed,
pointing at a hosted community that is still online (`techmore.communities.buzz.xyz`). They were overwritten before
this was noticed (the previous values were recovered from the 22:09 UTC SQLite backup). To go back:
`EnvStore.set('BUZZ_RELAY_URL', 'wss://techmore.communities.buzz.xyz'); EnvStore.set('BUZZ_CHANNEL', 'c4c0ac29-2440-4914-afee-ab1b26e06a31')`
under `Current.tenant = Tenant.first`. Nothing else referenced those values.

The agent profile was published with `BuzzAgent.register!`; the owner added the agent to the relay
(`./run.sh add-member`) and to both channels.

### Bug found and fixed on the way: Rupert never actually delivered a message

`BuzzAgent.publish` and `NostrPublisher.publish` took the **first** `OK` the relay sent as the answer to their event.
The relay also answers the NIP-42 `AUTH` event with an `OK`, so both returned success and closed the socket before the
real event was stored. Against the live relay `BuzzAgent.notify` and `register!` reported `[true, "OK"]` and nothing
arrived; the profile never appeared. They now accept only the `OK` whose event id is the one they sent
(`web/test/services/buzz_agent_test.rb`, `nostr_publisher_test.rb` fail on the old behaviour). Until this ships, run
`register!` and the Settings test message only after the deploy.

## The agent (`rupert-buzz`)

**One runner**: `buzz-acp` drives `opencode acp`. It replies by running the `buzz` CLI, reads Rupert through the
read-only `scripts/quick_reports.rb`, `scripts/sales_report.rb`, and files reports through `scripts/feedback_intake.rb`
(the allow-list for "ready for development" is enforced server-side, see [feedback-reports.md](feedback-reports.md)).
Do not also run `bin/opencode_agent` or `bin/buzz_listener`: they speak as the same identity.

Pieces in this repo:

- `deploy/ser8/rupert-buzz.service`: the unit (user `rupert`, `Restart=on-failure`, no listening port,
  `ProtectSystem=strict` with only `storage`, `tmp`, `log` and its own `/var/lib/rupert-buzz` writable).
- `web/bin/buzz_acp_agent`: reads the key, relay and `BUZZ_AUTH_TAG` from the tenant settings with one Rails call, writes
  the current acp prompt, then execs `buzz-acp` with `opencode acp` as the agent and `BUZZ_ACP_RESPOND_TO=anyone`
  (membership of the closed relay is the gate; the default `owner-only` would ignore everybody but the agent's owner).
- `deploy/ser8/buzz/opencode.json`: install as `/etc/rupert-buzz/opencode.json`. Agent `buzz` (the default) may run only
  `buzz messages send *`, the three Rupert scripts, and nothing else; agent `chat` denies every tool (Ask Rupert).

### Install (after the PR deploys, on SER8)

```bash
incus exec rupert -- install -d -m 0755 /etc/rupert-buzz
incus file push deploy/ser8/buzz/opencode.json rupert/etc/rupert-buzz/opencode.json --mode 0644 --uid 0 --gid 0
incus file push deploy/ser8/rupert-buzz.service rupert/etc/systemd/system/rupert-buzz.service --mode 0644 --uid 0 --gid 0
incus exec rupert -- bash -c 'systemctl daemon-reload && systemctl enable --now rupert-buzz && sleep 8 && systemctl status rupert-buzz --no-pager | head -12'
```

The service only starts when `BUZZ_PRIVATE_KEY` and `BUZZ_RELAY_URL` are set, and `opencode` needs a working key (below).

### The opencode key (you must supply a new one)

The key in the host's `~/.local/share/opencode/auth.json` is expired (`401 api_key_expired`, see
[ai-health-monitor.md](ai-health-monitor.md)). Create a key in the OpenCode Console and put it in `/etc/rupert.env` as
`OPENCODE_API_KEY=…` (root-only file; the unit and the AI-health job both read it), then
`systemctl restart rupert-buzz rupert-jobs`. Also set `OPENCODE_PROVIDER=zen` (or the model in
`opencode.json`) to match the plan the key belongs to: `deepseek-v4-flash` is in the Zen catalog, not the Go catalog.
Until then the agent connects and sees messages but the model call fails; **System → AI health** shows the key as
expired. The free tier is not an option: calling it from anything but the OpenCode apps returns
`403 free tier can only be used from within OpenCode`.

### opencode version and flags

- **Pinned: opencode 2.0.32** (the build already on the host; binary sha256 `489b5181…47ab607`). Copied to
  `/usr/local/bin/opencode` in `rupert`.
- v1.19.3 (latest on GitHub) was tried and **crashes in these containers** (`embedder failed to suspend thread`), so it
  is not an alternative here.
- 2.0.32 has no `--pure` or `--dir` and runs a persistent background service unless `--standalone` is given.
  `OpencodeCli` (new, `web/app/services/opencode_cli.rb`) now builds the one-shot command
  (`run --standalone --format json --agent <name> <prompt>`, working directory `/tmp/opencode`) for
  `OpencodeChatAgent` and Ask Rupert, which were failing with `Unrecognized flag: --pure`.
- Commands that talk to the background service (`opencode debug …`, `opencode mcp list`) start a long-lived server that
  cannot be killed from another `incus exec` session; avoid them on production. `run --standalone` needs stdin closed
  (`< /dev/null`; systemd and `IO.popen` with `in: File::NULL` do that) or it never exits.
- Ask Rupert needs the same `chat` agent: set `OPENCODE_CONFIG=/etc/rupert-buzz/opencode.json` for the web and jobs
  processes (for example in `/etc/rupert.env`) and restart them. Not done here (out of scope for the Buzz change).
- MCP: opencode 2.0.32 did not expose a configured remote MCP server to the model (the tool list stayed at the built-in
  tools even with every permission open), so the planned read-only Rupert MCP token was **not** used and was revoked.
  The agent reads Rupert through the report scripts instead.

### What the permission rules were tested against

Run with a mock OpenAI-compatible model (so no key is needed) driving `buzz-acp` → `opencode acp` → the `buzz` CLI → the
relay, on SER8. Each row is a command the "model" tried:

| Command | Result |
| --- | --- |
| `buzz messages send --channel … --content "pong"` | allowed, message posted by the agent identity |
| `ls /root`, `cat /etc/passwd` | denied |
| `buzz messages send …; ls /root`, `… && ls`, `… \| cat`, newline + second command | denied |
| `buzz messages send … --content "$(ls /root)"`, backticks | denied |
| `buzz messages send … --content "$BUZZ_PRIVATE_KEY"` (any `$`) | denied |
| `buzz messages send … > /root/pwned.txt` | denied (output redirection) |
| `buzz messages send … --content - < /etc/hostname` | denied (input redirection) |
| `bin/rails runner scripts/feedback_intake.rb file <<'END' … END` (heredoc) | allowed |
| same with an extra `< /etc/passwd` | denied |
| `bin/rails runner scripts/quick_reports.rb today` | allowed |

The first version of the rules allowed `> file`; the redirect and `$` rules were added after that test. The mock server
and test script are in `deploy/ser8/buzz/permission-test/`; rerun them whenever `opencode.json` or the opencode version
changes. The real model's behaviour on the same inputs is **not verified** (no key).

## Backups

- **`~/.local/bin/buzz-backup.sh`** (from `deploy/ser8/buzz/backup-buzz.sh`) with a host user timer
  (`buzz-backup.timer`, every 6 h) writes three AES-256 encrypted, decrypt-verified sets to `~/backups/buzz/`: a `pg_dump`,
  the MinIO and git volumes, and `/opt/buzz/.env` with `/root/buzz-secrets`. It uses the same key file as
  `rupert-offhost-backup.sh` and keeps 35 sets.
- The weekly `incus-backup.timer` already exports every instance, so the `buzz` container is included automatically
  (crash-consistent only, as that script says).
- **Restore drill done:** the latest dump was restored into a scratch database: 93 tables and 83 events, identical to the
  live database; the scratch database was dropped.
- Restore: see the header of `backup-buzz.sh`.

## Rollback

| Change | Undo |
| --- | --- |
| Relay stack | `incus exec buzz -- bash -c 'cd /opt/buzz && ./run.sh stop'`; or `incus snapshot restore buzz stack-up-clean`; or delete the container and pool (`incus delete -f buzz; incus storage delete buzz`). Nothing else uses them. |
| Rupert Settings | the `EnvStore.set` lines under "Rupert settings" |
| Binaries in `rupert` | `rm /usr/local/bin/{buzz,buzz-acp,opencode}` |
| `/etc/hosts` line in `rupert` | `sed -i '/buzz.stoverparc.org/d' /etc/hosts` |
| Agent service (once installed) | `systemctl disable --now rupert-buzz; rm /etc/systemd/system/rupert-buzz.service` |
| Backup timer | `systemctl --user disable --now buzz-backup.timer` |

## Not verified

- The agent's replies from a **real model** (no valid key): the mock model proved the plumbing and permissions only.
- `wss://` through your Caddy block and a real phone or desktop client (needs DNS); the QR code on the `/buzz` card
  opening the Buzz mobile app; whether any public mobile build exists.
- That `opencode` does not need extra files at runtime on a clean machine beyond `OPENCODE_CONFIG` and an API key.
- Behaviour of the relay under real use and upgrades. To upgrade: take a backup, change `BUZZ_IMAGE` in `.env` to a newer
  digest, `./run.sh upgrade`; the binaries in `rupert` should then be rebuilt from the matching source revision.

## Build record

Rust 1.95 (rustup) in a throwaway Ubuntu 24.04 container (`buzz-build`, deleted afterwards) on the `buzz` pool;
`cargo build --release -p buzz-acp -p buzz-cli -p buzz-admin` at block/buzz `c37d6b8e`. Binary sha256:
`buzz` `37624a48…be7850`, `buzz-acp` `7aef093d…dc54763`, `buzz-admin` `b3ab54ca…fe8e33`. The host is Ubuntu 26.04 (glibc 2.43)
and the containers are 24.04 (glibc 2.39), which is why the binaries were not built on the host.
