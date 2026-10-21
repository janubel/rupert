# Buzz and Ask Rupert: design and recommendation

Written 2026-10-21. Status: **phases 1 and 2 built** (linking and help-only replies, behind a switch that is off by default; see `ask-rupert.md`, "In Buzz"). Phase 3 (data tools in direct messages) and phase 4 (history tag, sharing) are **not built** and need the owner's decision on the relay. Differences from the proposal below: the team channel keeps the agent's own replies (only link codes are handled there), and unlinked people get a link hint instead of lessons. It answers: how can Buzz (the Nostr chat with the `@rupert` agent) use Ask Rupert's brain, and where should chat history, sharing and group chats live? Read `ask-rupert.md` and `buzz.md` first.

## Facts this rests on

About Rupert (from `main` at PR #282):

- Every Ask Rupert tool runs as one **signed-in Rupert user**, in-process, with that user's current permissions (`AskRupert::Tools`, `ScopedToken`). There is no broad or stored token, and that must stay true.
- Chats (`ask_rupert_conversations`, `ask_rupert_messages`) are private to their owner. Clear deletes them; an optional retention job expires them. Typed text and tool results pass through `Redactor` before reaching a model. Limits and the usage ledger are keyed on the Rupert user.
- The Buzz agent today is a **separate path**: `OpencodeChatAgent` runs `opencode run --agent chat` with its own prompt, an in-memory window of the last 24 channel messages and a one-line operations snapshot. It has no Rupert user, no tools and no persistence. `BuzzListener` and `BuzzResponder` are a rule-based legacy fallback.
- **Buzz is not configured in production and no agent process runs on SER8** (`buzz.md`). Anything built now is exercised with stubs only until a relay and an agent unit exist.

About Buzz (from `block/buzz` `NOSTR.md`, `scope.rs`, read 2026-10-21):

- A sender is a **Nostr public key**. Events are signed, and the relay checks signatures and authenticates connections (NIP-42), so a pubkey on an event is proof that its holder wrote it. Nothing in Buzz knows about Rupert users.
- Channels are `open` or `private`. The relay enforces who can read a private channel or DM. DMs (one-to-one and groups) are channels of their own, and members of a channel are visible to members (kind 39002). Authors can delete their own messages; owners and admins can delete others'. Channels can have a TTL. A target's `channel_add_policy` (`owner_only` / `nobody`) can stop others adding it to a channel, so the agent can be made invitable by its owner only.
- Channel messages are stored on the relay in the clear for the relay operator (the access rules are enforced by the relay, not by encryption). The `buzz-acp` harness scopes an agent session per DM conversation or per channel thread.

## Decisions

### 1. A Buzz identity maps to a Rupert user only by explicit, confirmed linking

- New table `buzz_identities` (tenant, user, pubkey, linked_at, last_used_at, revoked_at). One pubkey belongs to exactly one user per workspace; a user may link more than one pubkey (a phone and a laptop have separate keys only if the person made two).
- **Linking is started in Rupert, by the signed-in person.** They need `chat.use` at that moment. Rupert shows a short single-use code (about 8 characters, 10 minutes) on the Ask Rupert settings page.
- The person sends `link <code>` to `@rupert` **in a direct message**. The agent takes the pubkey from the signed event (it re-verifies the signature), looks up the code, and records a *pending* link. A link sent in a channel is refused and the code is burned, with a reply telling the person to message the agent privately and generate a new one. A code posted in a room must not be usable by whoever reads it first.
- **The link becomes active only when the person confirms it back in Rupert**, where the page shows the pubkey's fingerprint and the Buzz display name (the same value their Buzz client shows). If a stranger got hold of a code, the real owner sees an unknown fingerprint and declines. Both sides must act, so neither a Rupert session alone nor a Buzz key alone can create a link.
- Links are checked **live on every message**, not at link time: the user must still be active, not an employee-app account, in a matching tenant, and still hold `chat.use` (the same gate as the drawer, `AskRupertController#require_available`). Removing the permission, deactivating the user, or revoking the link (Rupert or an admin) takes effect on the next message. Linking, confirming, revoking and refused attempts go to the Activity log with pubkey fingerprint only.
- An unlinked pubkey is not an error: it gets the help-only room behaviour below, plus a hint on how to link.
- Pubkey spoofing is not a concern given relay-checked signatures, but the agent verifies the signature itself before acting on a link or a tool call, so a compromised relay cannot forge a sender.

### 2. Which tools Buzz replies may use: it depends on who can read the reply

The rule: **a reply may contain only what every reader of that Buzz channel is entitled to**. Rupert cannot know that for a Buzz channel (members are not Rupert users, and a member who is a Rupert user may have fewer permissions than the asker). So tools split by audience:

| Where the question is asked | Who may be answered | Tools | Why |
| --- | --- | --- | --- |
| **One-to-one DM** with `@rupert` | A linked, currently permitted user | The full Ask Rupert set (`where_is`, `how_do_i`, `search`, `run_report`, `system_status`) as that user | Only the asker reads the reply. Same data the drawer would show them |
| Channel, group DM or any room with more than one human | Anyone, linked or not | `where_is` and `how_do_i` only. Never `search`, `run_report`, `system_status`, never anything that returns records, figures or settings | The reply is read by people whose permissions Rupert does not know |
| Anywhere | - | `file_report` returns a link to the drawer draft; nothing is filed from Buzz | The review-and-press-Send step stays in Rupert, where the draft is shown with its attachment |

Details that matter:

- In a room, a linked asker's `where_is` / `how_do_i` still use their own navigation, but the "exists, ask an administrator" lines are dropped (they would reveal the shape of one person's access to the room). An unlinked asker gets lessons and definitions only, from a user-less view of the learning catalog, and no page links.
- The existing ops snapshot (last sync, pending counts, open alerts) that `OpencodeChatAgent` already posts into the channel stays as is; the channel was already told it is "wider than Rupert permissions" (`config/buzz_agent/core.md`). That is a decision about the channel, not new exposure from this work, and a channel that must not see it should not contain the agent.
- Text in a room is attacker-controllable (any member can write to the model). That is acceptable only because rooms have no data tools: a successful injection can at most make the help text odd. One-to-one DMs contain only the linked person's own words.
- Sending DM data to a cloud model is governed by the existing Ask Rupert provider mode and disclosure. The DM adapter must show the same disclosure once, on the first reply to a linked person, and must respect `local_only`.

### 3. History: Rupert stays the system of record for its own chats; Buzz holds the Buzz transcript. No mirroring.

Three options were weighed:

- **Buzz as the only store** (the drawer reads history from the relay). Rejected. It makes the in-app chat depend on a relay that is not running, would need a Nostr reader in Rails, loses Clear and retention semantics (a Rupert admin cannot delete another person's DM on the relay), and puts the per-user usage ledger, Redactor and audit on the wrong side of a network hop.
- **Mirror every drawer chat into Buzz and every Buzz DM into Rupert.** Rejected. Two copies of sensitive content that drift, and mirrored data lands on the relay with whatever readers that channel has.
- **Recommended: each surface keeps its own transcript.** Drawer chats live in `ask_rupert_*` exactly as now. A linked one-to-one DM with `@rupert` is *also* an `AskRupert::Conversation` (new nullable `source` = `buzz`, `buzz_channel_id`), because the brain needs its own context window, rate limits, redaction and usage ledger, and the person's permission-checked tools need the same audit. The Buzz message log is what Buzz keeps for the Buzz side; the person sees their normal DM history in Buzz. Room conversations create **no Rupert rows** (context stays an in-memory window, as the agent has now) except the usage counter.
- The Ask Rupert **History** rail may list Buzz DM conversations with a "From Buzz" tag, openable for reading. Continuing one in the drawer continues in the drawer only (nothing is echoed to Buzz). This is optional polish for a later phase.

Honest limits:

- **Clear in Rupert cannot delete the Buzz copy.** The Buzz side is the person's DM, which they can delete message by message in Buzz; the relay operator can read it regardless (see "What Buzz changes about confidentiality" below). The docs and the first DM reply must say so.
- A secret pasted into Buzz is already in Buzz. Rupert redacts its own stored and model-bound copy and tells the person to delete the message and replace the secret, as the room prompt already does.
- Retention: the nightly Ask Rupert retention job covers the Rupert copy only. A DM's TTL is the Buzz owner's setting, not Rupert's.

### 4. Sharing: copy-out of navigation-only chats, by an explicit action, to channels the sharer is really in

- Sharing is a **snapshot**, not a live link, so the Rupert copy stays private and revocable (deleting your chat does not delete the post, which the share dialog says).
- v1 sharing is allowed only for chats whose assistant turns used **no data tools** (`where_is` / `how_do_i` only; needs a per-message `data_tools` flag recorded by `Brain`, which today stores only a count). Those chats carry how-to content, not figures or records. Anything else is **not shareable**: Rupert cannot know that every reader of the destination may see the figures, and "the sharer is permitted" is not enough.
- The sharer chooses the destination from channels where **the agent is a member and the sharer's linked pubkey is a member** (from the relay's member list). This stops Rupert being used to post into a channel the sharer cannot read. The agent posts "Sam shared an Ask Rupert chat" and the Q&A text, with same-site links removed (they would be dead outside Rupert and some paths reveal structure). Preview before posting; one confirmation.
- Chats with data are shared by **copy and paste by the person**, which is their call and the same as today.
- No share link into Rupert exists. Sharing never grants anyone access to the owner's Rupert conversation.

### 5. Group chats: use Buzz's own, with the agent as a help-only member

- Group conversation is Buzz's feature and is not rebuilt in Rupert. A "group Ask Rupert chat" is a Buzz channel or group DM that includes `@rupert`.
- **Invitation is the gate.** Set the agent's `channel_add_policy` to `owner_only` so only the human who owns the agent identity can add it to a channel. Rupert then answers only where an administrator put it. Members of that channel are decided in Buzz.
- In a group the agent follows section 2: help-only, replies when mentioned (plus the current rare, rate-spaced proactive replies), thread-scoped context. No new Rupert storage.
- Per-sender abuse limiting in rooms: a small cooldown and an hourly cap per pubkey held in `Rails.cache` (counters, no content), so an unlinked member cannot drain the model budget. Linked senders in a one-to-one DM use the existing per-user `Limits`.

## What Buzz changes about confidentiality (the part to approve)

Putting Ask Rupert in a Buzz DM means answers that include business figures (for a linked, permitted person) are **written to the Buzz relay**, which stores channel content readable by the relay operator and its backups, and in the person's Buzz client(s). Today those answers stay in Rupert's database and, for cloud mode, go to the model provider. This is a new copy in a new system.

Mitigations and a choice for the owner:

- Ship the data tools in DMs behind a **workspace switch, off by default** (`ask_rupert.buzz_dm_tools`), with a visible warning on the switch that the answers are stored in Buzz.
- Or keep DMs help-only (the same two tools as rooms) until the relay's own hosting and retention are settled. This is the safe default if Buzz will be hosted by someone other than the Rupert operator.
- Run the relay with a channel TTL for agent DMs if the platform supports setting it on DMs created by users (not verified).

## Plan and phases

Each phase merges on its own and does nothing until Buzz is configured.

0. **Prerequisite, not code:** stand up the relay, create the channel, install the agent runtime and a unit for `bin/opencode_agent` (`buzz.md`, "Turning it on"). Nothing below can be tried on a live relay before this.
1. **Linking.** `buzz_identities`, the Rupert-side code and confirm screen under Ask Rupert, the agent's DM `link` handling, live permission re-check, revoke, Activity log. Tests: code single-use and expiry, link from a channel refused and burned, unconfirmed link grants nothing, permission removed after linking blocks the next message, a pubkey cannot be linked to two users.
2. **Brain on the agent, help-only.** `AskRupert::BuzzSurface` called from the agent: DM or room decision, linked user lookup, `where_is` / `how_do_i` only, the same `Providers` and `Config` (so mode, disclosure and kill switch apply), per-pubkey cooldown. Replaces the separate `opencode run` prompt for questions about using Rupert; the ops snapshot stays. Tests: tool filter per audience, room never calls a data tool even when the model asks for one, disabled workspace / missing `chat.use` stops replies, unlinked sender gets the link hint.
3. **DM data tools** (only with the owner's approval of the confidentiality choice above): linked one-to-one DMs use the full tool set as the linked user, with per-user `Limits` and `AskRupert::Conversation` rows with `source: buzz`.
4. **History tag and sharing.** "From Buzz" in the History rail; `data_tools` flag on messages; Share to Buzz for navigation-only chats with the destination rule above.

## Not recommended

- Mapping Buzz users to Rupert users by display name, email or any value the sender controls.
- Letting the agent run tools as a system user or with a broad token in any room, or "just this once" with a confirmation: the confirmation would come from the asker, not from the other readers.
- Rebuilding groups, invites or sharing links inside Rupert.
- Moving the drawer's history into Buzz.

## Open questions for the owner

1. Is the Buzz relay going to be run by the same operator as Rupert? That decides whether data answers in DMs (phase 3) are acceptable.
2. Should DMs be help-only first (phases 1, 2 and 4 only)?
3. Is the first goal the help assistant in the team channel (phase 2) or personal DMs with data (phase 3)?

## Not verified

- No live Buzz relay was available. Linking, DM detection and the member-list check are designed from Buzz's source, not tried.
- Whether Buzz lets the agent be added only by its owner through `channel_add_policy` for an agent that has no verified owner relation in this deployment.
- Whether a TTL can be applied to DMs created by users.
- That the agent receives group-DM events with the same filters as channel events; `OpencodeChatAgent` subscribes to kind 9 by `#h` of one channel and kind 1 by `#p`, so DMs and other channels are not subscribed today. The agent needs a membership-driven subscription (kind 44100 notifications) before it can be in more than the one configured channel.
