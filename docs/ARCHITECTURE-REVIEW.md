# Ajman — Architectural Review and Verdict

**Date:** 2026-07-11
**Reviewed by:** Claude (Fable) synthesizing three Codex gpt-5.6-sol repository investigations
**Evidence:** [masko-report.md](research/masko-report.md) · [petdex-report.md](research/petdex-report.md) · [codex-claude-surfaces-report.md](research/codex-claude-surfaces-report.md)

---

## Verdict

**Build a small native Swift/AppKit app (Route C). Use Masko and Petdex as parts donors and behavioral specs, not as fork bases. Confidence: high — all three independent investigations converge on this.**

| Route | Verdict | Killing reason |
|---|---|---|
| A. Fork Masko Code | **Rejected** | Its renderer plays transparent HEVC videos via AVPlayer — it *cannot render a spritesheet at all*. Plus: unauthenticated non-loopback HTTP server, 19-event hook installer with no backup, global Cmd-key event tap, private SkyLight APIs, Sparkle pointed at Masko's appcast, 1,400-line UI files. |
| B. Fork Petdex Desktop | **Rejected** | 3,724-line Zig god file + required Node sidecar + non-vendored experimental Zig/WebKit framework checkout + telemetry-on-by-default + gallery/OAuth/updater coupling. Estimated 2–6 weeks to strip vs 1–2 weeks to build fresh. |
| C. New native Swift app | **Recommended** | ~1–2 engineer-weeks to a polished v1. No Node, no WebView, no Accessibility permission for passive operation, public AppKit APIs only. |
| D. Drive Codex's built-in pet | **Confirmed impossible** | No IPC, no app-server pet method, no URL scheme, no writable state file. The TUI pet state is crate-private Rust. Ajman's companion renders its own copy of the sheet. |

---

## What we now know about Ajman's asset (decisive, fully verified)

Ajman's `~/.codex/pets/ajman/` package is **the standard hatch-pet atlas, exactly**:

- 1536×1872 WebP = **8 columns × 9 rows of 192×208 px** cells; 57 used frames, 15 transparent padding cells.
- The minimal 4-field `pet.json` is *valid by design* — `frame` and `animations` are optional; Codex supplies defaults (verified in `codex-rs/tui/src/pets/model.rs`).
- Full recovered animation table (row → state → per-frame ms):

| Row | State | Frames | Timing |
|---:|---|---:|---|
| 0 | `idle` | 6 | 280,110,110,140,140,320 ms (TUI plays ×6 slower) |
| 1 | `running-right` | 8 | 120 ms, last 220 |
| 2 | `running-left` | 8 | 120 ms, last 220 |
| 3 | `waving` | 4 | 140 ms, last 280 |
| 4 | `jumping` | 5 | 140 ms, last 280 |
| 5 | `failed` | 8 | 140 ms, last 240 |
| 6 | `waiting` | 6 | 150 ms, last 260 |
| 7 | `running` (= agent working) | 6 | 120 ms, last 220 |
| 8 | `review` (= work ready) | 6 | 150 ms, last 280 |

**No asset regeneration needed.** The existing sheet already covers every semantic state v1 requires. (Cross-validated: Petdex Desktop hardcodes the identical 8×9/192×208 grid — Ajman would render there unmodified.)

Codex Desktop's active-pet selection: `[desktop] selected-avatar-id = "custom:ajman"` in `~/.codex/config.toml` (confirmed on this machine). The TUI pet is a separate `[tui] pet` key.

---

## The headline correction to the ChatGPT handoff

**The handoff's central limitation is stale.** Issue openai/codex#15311 ("Codex is observable but not externally approvable") was **closed as completed 2026-04-22** (PR #17563). Codex now has:

- A **blocking `PermissionRequest` hook** returning `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"|"deny"}}}` — any deny wins, allow skips the prompt, no decision falls through to normal UI.
- Ten lifecycle hooks total: `SessionStart`, `UserPromptSubmit`, `PreToolUse`, `PermissionRequest`, `PostToolUse`, `PreCompact`, `PostCompact`, `SubagentStart`, `SubagentStop`, `Stop`.
- App-server approval RPC (for sessions a client owns — not for hijacking Desktop's own prompts).

**Consequence:** Ajman can eventually answer permission prompts for *both* Claude Code *and* Codex — something Masko never shipped. (Codex's hook is allow/deny only; Claude's also supports `updatedInput`/`updatedPermissions`.)

Other handoff claims that fell:
- `RousselPaul/masko-code` is dead; surviving source: **`MaTriXy/masko-code`** (MIT, 127 commits, v0.13.13, 2026-03-30). Later private development (current Masko is 0.31.0) cannot revoke MIT on published commits.
- Masko's port is **45832**, not 49152 (explicitly `legacyDefaultServerPort`).
- Petdex hooks uninstall is *selective removal with backups*, *not* full rollback (leaves `~/.petdex/bin`, token, Codex `[features] codex_hooks` flag).
- Petdex's "codex" integration is **Codex CLI only** — no Codex Desktop observation.

---

## Integration surfaces (verified)

### Claude Code — first-class
- Hooks provide `session_id`, `cwd`, `transcript_path`, tool name/input, notification type, subagent ids, end reason on every event; enormous event surface including blocking `PermissionRequest`/`PreToolUse`.
- Transcripts: `~/.claude/projects/<encoded-path>/<session-id>.jsonl` (prefer the hook-provided path).

### Codex — hooks primary, rollout tail fallback
- **Hooks** (the ten above): `session_id`, `cwd`, `transcript_path`, `turn_id` on turn-scoped events.
- **Rollout JSONL** (`~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl`): richest signal (turn start/complete/abort, exec begin/end, approval requests, errors, `ShutdownComplete`) but explicitly not a stable API — tail defensively (partial lines, new variants, archives).
- **`notify`**: fires only on turn-complete; insufficient alone; fine as belt-and-braces.
- **Surface classification:** use `session_meta.originator` (`"Codex Desktop"`) first; note Desktop may serialize `source: "vscode"` — do not trust `source` alone.
- **Focus limits:** Codex exposes no TTY/PID/window identifiers → v1 does generic app activation for Codex. Claude sessions *can* get exact terminal targeting later (Masko's hook script captures terminal/shell PIDs; its `IDETerminalFocus.swift` catalogs per-app strategies).

### Unified event model (adopted from the codex-surfaces report)
Five semantic states, keyed by `provider + sessionId`:

`idle` · `running` · `waiting` · `review` · `failed`

Priority: `waiting` > `failed` > `review` > `running` > `idle`. Accents: prompt-submitted → `jumping`; turn-complete → `waving` → `review`. Rows 1–2 reserved for drag physics.

---

## v1 architecture

```
Ajman.app  (Swift/AppKit, LSUIElement menu-bar accessory)
├── Overlay        non-activating borderless NSPanel; transparent; .floating;
│                  .canJoinAllSpaces + .fullScreenAuxiliary + .ignoresCycle
│                  (public APIs only — no SkyLight; validated by Petdex/zero-native)
├── Renderer       CGImageSource WebP decode → slice 8×9 @192×208 →
│                  CALayer frame animation with the per-frame ms table
├── EventCore      AgentEvent (normalized) · SessionRegistry · priority reducer
├── Transport      Unix domain socket (no TCP port, immune to browser POSTs);
│                  hook helpers post via curl --unix-socket
├── ClaudeAdapter  settings.json hook install: merge + timestamped backup +
│                  true uninstall; tiny helper binary (no sed-JSON, no PATH tricks)
├── CodexAdapter   hooks config + rollout tailer (offset-based, from Masko's
│                  CodexSessionMonitor pattern) + notify registration
└── Bubble/Focus   speech bubble w/ session + message; click → activate owning app
```

### Menagerie runtime (implemented 2026-07-12)

`AppDelegate` owns the shared observation layer (`SessionRegistry`, Claude UDS server, and
Codex monitor) plus zero or more `PetInstance` objects. Each `PetInstance` owns one loaded
pet, `OverlayPanel`, `PetView`, `Animator`, `PetMode`, and `BubbleController`; it has no
shared animation timer with another pet. Its provider binding is Claude, Codex, or `nil`
(`Both`). Registry reduction filters its provider-keyed sessions for each instance, while a
Both-bound instance retains the original global priority reduction.

Shown pet ids persist in `AjmanShownPets`; bindings persist in
`AjmanPetBinding.<petID>`. An absent shown-pets key is the versioned first-run signal: show
Ajman bound to Claude and Winnie bound to Codex. Panel origins persist independently under
`AjmanPanelOrigin.<petID>` and use stable stagger slots; a lone pet may migrate the legacy
`AjmanPanelOrigin`. Global size, steady-size, playful-idle, and debug controls fan out from
the status menu to every live instance. Removing an instance explicitly invalidates its
PetMode timers, cancels its Animator timer, removes bubble observers/expiry timers, and
closes both panels before releasing it.

**Explicitly out of v1:** answering permissions (v2 — both agents support it now), exact terminal-tab focus (v2, Claude first), global hotkeys, Accessibility permission, auto-update, any network egress, Claude Desktop/ChatGPT adapters.

## Parts to lift (with MIT attribution headers)

From **Masko** (`MaTriXy/masko-code`): `AgentEvent.swift` + `HookEventType.swift` + `AnyCodable.swift` (normalized envelope), `ResponseTransport.swift` + `HookConnectionTransport.swift` (blocking-response shapes, for v2), `CodexSessionMonitor.swift` (JSONL tailing), `CodexEventMapper.swift` **as reference + its tests as fixtures**, `IDETerminalFocus.swift` as a targeting catalog (strip AppleScript interpolation).

From **Petdex**: `hooks/agents.ts` (verified hook→state mappings), `state-queue.ts` (dwell/coalescing so rapid tool calls don't cause animation thrash), the state allowlist/rate-limit/size-cap protocol design, `build-release.sh` as a signing/notarization checklist.

**Never reuse:** Masko's LocalServer (unauthenticated, non-loopback, CORS `*`), HookInstaller (sed-JSON, no backup), GlobalHotkeyManager, SkyLightOperator, HEVC renderer/VideoCache, fonts (unlicensed), any `assets.masko.ai` media; Petdex's sidecar/updater/telemetry/gallery/CLI persistence.

## Security posture

Learn from Masko's failures: UDS transport (no port, no browser reachability, no LAN exposure); hook payloads size-capped and schema-validated; state allowlisted; settings.json edits = parse-merge-backup-write with restore-on-uninstall; no remote asset fetching; no metered APIs (house rule); signing via the machine's `notary` keychain profile when we get there.

## Licensing

Masko public commits: MIT (© 2026 Masko) — valid regardless of later private development; retain notice on lifted files. Petdex: MIT; zero-native: Apache-2.0 (reimplement AppKit concepts natively instead of copying). Ajman's own asset: Kazys's. No Masko/Petdex branding or hosted media.

## Staged plan

1. **Renderer spike** — panel + sheet + all 9 animations cycling. *Proves the fun part in a day.*
2. **EventCore + UDS + Claude hooks (observe-only)** — Ajman reacts to real Claude sessions.
3. **Codex hooks + rollout tailer + session registry** — multi-agent priority; Desktop vs CLI badges.
4. **Bubbles + click-to-focus + menu-bar controls** (pause, launch-at-login, uninstall hooks). ← *v1 ships here*
   - **Bubble design (locked 2026-07-12, modeled on Codex's native pet cards):** each card = **bold title** (short turn summary) · **truncated preview** of the message (~first sentence / ~120 chars, ellipsis-cut wherever it lands — a length cap, NOT first-line-only) · **⌄ expand** to read the full text · **status dot** (green ✓ done / spinner running / attention for waiting). **Stack one card per active session, newest on top.** A provider-bound pet shows only that provider's cards; a Both-bound pet retains the original cross-agent stack. Click a card → focus that session's app/terminal. Title source: reuse the agent's own turn summary where exposed (Codex `notify`/rollout), else derive from the first line of the last assistant message.
   - **Dismissal (Codex parity, locked 2026-07-12):** a card clears three ways — (1) explicit **✕** on the card; (2) **click the card** → focus that session (counts as seen); (3) **implicit — the user visits the thread by any route**, including opening it directly in the underlying app *without touching the card*. Path (3) is the hard one: Codex dismisses for free because it owns the thread view; we're external and get no "thread opened" signal. So we **approximate presence from our own event stream** — a fresh `UserPromptSubmit` on that session (user is typing there now), or the session leaving its attention state (e.g. `waiting`→`running` because a permission was answered elsewhere) — and clear the card then. Belt-and-suspenders: auto-expire a stale card after a timeout so a missed signal never leaves it stuck.
   - **Reuse Masko's proven, permission-free clearing (verified in `MaTriXy/masko-code` `AppStore`/`PendingPermissionStore`):** cache the `tool_use_id` from `PreToolUse` (the `PermissionRequest`/attention event lacks it); then clear the card when **any later event carries that same `tool_use_id`** (the tool ran → the user answered elsewhere), OR on `Stop`/`UserPromptSubmit` for that session, OR when the hook connection goes silent (a ~1 s liveness timer), OR on a timeout. Finished-toasts auto-dismiss on an ~8 s timer and are suppressed while a permission is pending. Our Stage 2 EventCore already receives all these signals. **Accessibility is now owner-approved (2026-07-12)** as an *optional* refinement for the pure silent-glance case (user eyeballs the thread without typing) and — more valuably — to power precise click-to-focus targeting; the event-inference path stays primary and works with no permission.
5. **v2** — answer permissions from the bubble (Claude rich, Codex allow/deny), exact terminal-tab focus, more agents.

## Backlog (unscheduled)

- **Multiple pets — Winnie is next** (owner-confirmed 2026-07-12). The renderer already handles any hatch pet (v1 8×9 / v2 8×11), so the lift is small: (a) stop hardcoding `~/.codex/pets/ajman/` — load any `~/.codex/pets/<id>/`; (b) a menu picker to switch the active pet, persisted in UserDefaults; (c) optionally follow Codex's own `[desktop] selected-avatar-id` from config.toml, or keep an independent selection. Bundle Winnie's package (own pet.json + spritesheet) and back up her source imagery under `assets/imports/` on arrival, exactly as Ajman's. Not yet scheduled.
  - **Direction (owner 2026-07-12):** Ajman *stays* the Codex/ChatGPT pet, untouched — the app only *adds* the picker (additive, nothing undone). Winnie is pet #2 and is a **smaller animal** — preserve that: do NOT apply the compose height-normalization to her (it would blow her up to Ajman's size). Each pet keeps its own scale; Winnie fills less of the 192×208 cell so she renders smaller than Ajman on-screen at the same half-cell treatment (our app draws Ajman at 96×104 pt; the Codex pet draws him larger — relative pet-to-pet size is what we protect). Canonical Ajman handed to Gemini as the style example: `assets/imports/2026-07-12 canonical-v2-hatch/references/canonical-base.png` (1078×1460).

- **Liveliness / interactivity (owner-noticed 2026-07-12).** Codex's pet is *expressive* — it reacts to the cursor (runs from it) and idles playfully. Ours is currently a faithful but *passive* agent-activity mirror: it only animates on Claude/Codex events, so with no agent running it just idles. Consider optional, toggleable cosmetic behaviors: occasional idle wander/blink/look-around (reuse the look rows), and cursor-proximity reactions (flee/approach) via a local `NSEvent` mouse monitor — **no Accessibility needed** for mouse position. Keep it off-by-default-able so the pet can stay calm. This is presentation only; it must never interfere with the agent-state animation when an agent is actually active (agent state wins over idle play).

- **Winnie's default posture → sitting, like Ajman (owner 2026-07-12).** Her hatch drew idle/stationary rows *standing*; owner wants her to mostly **sit** (Ajman's convention). Regenerate her stationary rows (idle, waiting, review, failed, working) as sitting poses; keep the charming standing pose as an occasional Pet-Mode "fun" beat, not the default. Bonus: sitting-vs-sitting makes the "Winnie smaller than Ajman" size comparison apples-to-apples. Art-regen task (Codex hatch / Gemini) — set the sitting posture in her row prompts when regenerating.
- **Sleep state for both pets (owner 2026-07-12).** A sleep/deep-rest animation (curled up, eyes closed). NOT in the standard 8×9 / 8×11 hatch format → design decision needed: an extra row beyond the format vs a separate small sheet/frames. Needs new art for **both** Ajman and Winnie. Ties into Pet Mode: doze off after a long calm stretch, wake on click or any agent activity.

- **Simultaneous pets, one per agent — implemented 2026-07-12.** See “Menagerie runtime” above. The status menu can show zero or more discovered pets and bind each to Claude, Codex, or Both; first-run defaults are Ajman ↔ Claude and Winnie ↔ Codex.

- **Keep the old (pre-tip, standing) Winnie — as an easter egg (owner 2026-07-12).** The original hatched Winnie (un-tipped, standing idle) is preserved byte-for-byte at `assets/winnie/GOLDEN-winnie-pet-2026-07-12/` (tracked in git; = the pre-install live pet). Do NOT discard her. Optionally expose her as a selectable bonus/easter-egg pet — e.g. install to `~/.codex/pets/winnie-classic/` so the multi-pet picker lists "Winnie (classic)" beside the tipped Winnie, or gate her behind a fun trigger. She is her own preserved snapshot regardless of what the live `winnie` pet becomes.

## Open questions (tracked, non-blocking)

- Do Codex **Desktop** sessions fire user-configured hooks, or only CLI/TUI? (Unverified — rollout tailing covers Desktop either way; test empirically in stage 3.)
- Ajman's actual row artwork assumed to follow standard row semantics (dimensions verified; pixels not inspected).
- Whether `[desktop] selected-avatar-id` spelling is stable long-term (only matters if we ever read the selection).
- Rollout JSONL schema drift — mitigate with fixtures from Masko's test suite.
- Implicit bubble dismissal (Stage 4 path 3): **resolved — use Masko's permission-free `tool_use_id` correlation** (clear on the tool proceeding / `Stop` / `UserPromptSubmit` / hook-connection death / timeout). Accessibility is now owner-approved (2026-07-12) as an optional add-on for the silent-glance case and — its bigger payoff — precise click-to-focus window/tab targeting; the pet stays fully functional without it.
