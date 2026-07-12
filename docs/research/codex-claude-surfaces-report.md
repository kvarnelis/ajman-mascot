# Ajman mascot integration research

Research date: 2026-07-11  
Upstream Codex source examined: commit [`9e552e9`](https://github.com/openai/codex/commit/9e552e9d15ba52bed7077d5357f3e18e330f8f38)  
Local clone: [codex-upstream](/private/tmp/claude-502/-Users-kazys-Developer-ajman-mascot/ccff6380-1623-4c80-a619-69c9d596f024/scratchpad/codex/codex-upstream)

## Executive conclusion

Ajman’s existing `1536×1872` WebP is exactly the standard Codex pet atlas:

- 8 columns × 9 rows
- 192×208 pixels per cell
- 72 physical cells
- 57 semantically used cells
- 15 required transparent padding cells
- Nine states: `idle`, `running-right`, `running-left`, `waving`, `jumping`, `failed`, `waiting`, `running`, `review`

The manifest may contain only identity and spritesheet fields because Codex supplies this layout as the default. Current Rust also permits an optional custom `frame` and `animations` section, but Ajman correctly relies on defaults.

For the external mascot:

- The cleanest cross-Codex observation mechanism is Codex lifecycle hooks, not `notify`.
- `notify` fires only after completed agent turns.
- Rollout JSONL files expose much more—turns, tools, approvals, errors—but are explicitly less stable than hooks/app-server.
- Contrary to the old handoff, Codex now has a blocking `PermissionRequest` hook that can approve or deny an approval request.
- Codex app-server also has full bidirectional approval RPC, but only for a client participating in/owning that app-server session. It is not a general API for taking over the UI of an unrelated Codex Desktop conversation.
- No supported pet-state IPC, pet protocol message, deep link, or app-server pet method was found.
- Claude Code has a substantially broader hook surface and gives every hook a `session_id`, `cwd`, and `transcript_path`.

---

# 1. Codex pet format

## 1.1 Fixed atlas geometry

**CONFIRMED — high confidence.**

The public OpenAI `hatch-pet` skill describes a full `8×9` atlas and says cells are `192×208`. Its animation reference gives the exact row order and timing. The Rust implementation independently defines:

```text
frame width  = 192
frame height = 208
columns      = 8
rows         = 9
sheet width  = 1536
sheet height = 1872
```

Sources:

- [Official hatch-pet skill](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/SKILL.md)
- [Official animation-rows reference](https://raw.githubusercontent.com/openai/skills/main/skills/.curated/hatch-pet/references/animation-rows.md)
- [Rust catalog constants](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/pets/catalog.rs)
- [Rust pet manifest loader](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/pets/model.rs)
- Local copies: [animation-rows.md](/Users/kazys/.codex/vendor_imports/skills/skills/.curated/hatch-pet/references/animation-rows.md), [model.rs](/private/tmp/claude-502/-Users-kazys-Developer-ajman-mascot/ccff6380-1623-4c80-a619-69c9d596f024/scratchpad/codex/codex-upstream/codex-rs/tui/src/pets/model.rs)

Rust rejects a spritesheet whose physical dimensions are not exactly `1536×1872`. If a custom `frame` block is supplied, its cell dimensions and grid counts must still cover the sheet exactly.

## 1.2 Row/state mapping for Ajman

| Row | Atlas indices | State | Used columns | Frames | Base durations |
|---:|---:|---|---:|---:|---|
| 0 | 0–5 | `idle` | 0–5 | 6 | 280, 110, 110, 140, 140, 320 ms |
| 1 | 8–15 | `running-right` | 0–7 | 8 | 120 ms; final 220 ms |
| 2 | 16–23 | `running-left` | 0–7 | 8 | 120 ms; final 220 ms |
| 3 | 24–27 | `waving` | 0–3 | 4 | 140 ms; final 280 ms |
| 4 | 32–36 | `jumping` | 0–4 | 5 | 140 ms; final 280 ms |
| 5 | 40–47 | `failed` | 0–7 | 8 | 140 ms; final 240 ms |
| 6 | 48–53 | `waiting` | 0–5 | 6 | 150 ms; final 260 ms |
| 7 | 56–61 | `running` | 0–5 | 6 | 120 ms; final 220 ms |
| 8 | 64–69 | `review` | 0–5 | 6 | 150 ms; final 280 ms |

Unused transparent cells:

- Row 0: columns 6–7
- Row 3: columns 4–7
- Row 4: columns 5–7
- Rows 6–8: columns 6–7

Therefore Ajman contains:

- 72 physical atlas slots
- 57 animation frames
- 15 transparent unused slots

Semantic distinction:

- `running-right` and `running-left` mean directional locomotion/dragging.
- `running` means Codex is actively working; it is deliberately not literal foot-running.
- `waiting` means blocked on approval, help, or user input.
- `review` means work is ready/being inspected.
- `failed` is the blocked/error reaction.

## 1.3 FPS and loop behavior

There is no single global FPS.

The public format specifies per-frame millisecond durations. For custom animation entries, the Rust manifest accepts `fps`, defaulting to 8 FPS when omitted, and rejects values over 60 FPS.

For the default atlas:

- All tracks are looping.
- The Rust TUI’s current playback differs slightly from the bare animation table:
  - `idle` uses the same relative timing but multiplies the published durations by six.
  - Non-idle states play their primary row three times.
  - They then enter an embedded idle sequence and loop from that idle section until the displayed notification/state changes.
- If custom animation metadata sets `"loop": false`, the animation eventually falls back to its named `fallback`, defaulting to `idle`.

That TUI-specific sequencing is implemented in `idle_animation()` and `app_state_animation()` in [model.rs](/private/tmp/claude-502/-Users-kazys-Developer-ajman-mascot/ccff6380-1623-4c80-a619-69c9d596f024/scratchpad/codex/codex-upstream/codex-rs/tui/src/pets/model.rs).

## 1.4 Why Ajman’s four-field manifest works

The Rust `PetFile` format accepts:

```json
{
  "id": "...",
  "displayName": "...",
  "description": "...",
  "spritesheetPath": "...",
  "frame": {
    "width": 192,
    "height": 208,
    "columns": 8,
    "rows": 9
  },
  "animations": {}
}
```

But `frame` and `animations` are optional:

- Missing `frame` → the standard 192×208, 8×9 geometry.
- Empty/missing `animations` → all default state mappings and timings.

Thus the known four-field Ajman manifest is valid and intentionally compact.

Custom pets resolve from:

```text
$CODEX_HOME/pets/<pet-id>/pet.json
```

Normally that is:

```text
~/.codex/pets/<pet-id>/pet.json
```

The selector can be either `ajman` or explicitly `custom:ajman`, depending on the calling surface. Source: [model.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/pets/model.rs).

## 1.5 Active pet selection

### Codex Desktop

**CONFIRMED locally and from source tests — high confidence.**

Codex Desktop stores the chosen avatar/pet in `~/.codex/config.toml` under:

```toml
[desktop]
selected-avatar-id = "custom:ajman"
```

The current machine has exactly that value. No unrelated config values were read into this report.

The Rust config layer deliberately preserves `[desktop]` as opaque nested JSON-compatible data; its tests explicitly round-trip `selected-avatar-id`. Sources:

- [core config test](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/core/src/config/config_tests.rs)
- [app-server config RPC test](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/app-server/tests/suite/v2/config_rpc.rs)

Desktop also stores overlay/layout bookkeeping in `~/.codex/.codex-global-state.json`. Locally that file knows Ajman has received its first-awake notification, but the authoritative active selection found here is `[desktop].selected-avatar-id`, not that notification list.

### Codex TUI

The new terminal pet uses a separate key:

```toml
[tui]
pet = "custom:ajman"
pet_anchor = "composer" # or "screen-bottom"
```

Source: [config types](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/config/src/types.rs) and [TUI persistence](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/app/pets.rs).

These are separate selections. Choosing Ajman in Desktop does not prove that the TUI is configured to show Ajman.

---

# 2. Can another process drive Codex’s built-in pet?

## Result

**No supported pet-state control or observation API was found. High confidence for the open-source surface; Desktop-private implementation remains unverified.**

The source searches found:

- Pet loading and frame extraction
- TUI pet selection
- TUI internal state notifications
- App-server lifecycle and tool protocol
- No pet method in app-server protocol/schema
- No pet event in app-server notifications
- No local pet socket
- No pet-related URL/deep-link scheme
- No plugin API for setting the currently displayed pet animation
- No externally writable “current pet state” file

The TUI maps internal UI events directly to its private `AmbientPet`:

- turn begins → `Running`
- approval/user input requested → `Waiting`
- turn completes → `Review`
- failure → `Failed`

Sources:

- [turn_runtime.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/chatwidget/turn_runtime.rs)
- [tool_requests.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/chatwidget/tool_requests.rs)
- [ambient.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/tui/src/pets/ambient.rs)

`set_notification()` is crate-private Rust state, not IPC.

### Practical implication

Ajman’s companion app should render its own copy of the spritesheet and independently derive states from Codex/Claude signals. It should not attempt to remote-control Codex Desktop’s own mascot.

---

# 3. Observing Codex CLI and Desktop

## 3.1 Legacy `notify` program

Configuration:

```toml
notify = ["/absolute/path/to/ajman-notifier"]
```

Codex launches the configured argv after each completed agent turn and appends one JSON string as the final argument.

Current payload:

```json
{
  "type": "agent-turn-complete",
  "thread-id": "...",
  "turn-id": "...",
  "cwd": "...",
  "client": "codex-tui",
  "input-messages": ["..."],
  "last-assistant-message": "..."
}
```

Sources:

- [config documentation in source](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/core/src/config/mod.rs)
- [legacy_notify.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/hooks/src/legacy_notify.rs)

Reliability:

| Signal | Available from `notify`? |
|---|---|
| Turn complete | Yes |
| Thread/session id | Yes, as `thread-id` |
| Turn id | Yes |
| CWD/project | Yes |
| Client/surface | Usually; optional |
| User input/final answer | Yes |
| Session start/end | No |
| Tool begin/end | No |
| Approval requested | No |
| Error/abort | Not as a dedicated event |

Therefore `notify` alone is insufficient for a reactive mascot.

## 3.2 Codex lifecycle hooks

Codex currently documents ten hook events:

- `SessionStart`
- `UserPromptSubmit`
- `PreToolUse`
- `PermissionRequest`
- `PostToolUse`
- `PreCompact`
- `PostCompact`
- `SubagentStart`
- `SubagentStop`
- `Stop`

Every command hook receives common fields including:

- `session_id`
- `transcript_path`, when available
- `cwd`
- `hook_event_name`
- `model`
- turn-scoped hooks additionally expose `turn_id`

Official source: [Codex Hooks documentation](https://developers.openai.com/codex/hooks), especially its common-input and event sections.

For Ajman, a global hook configuration can cleanly emit:

| Ajman state | Recommended Codex hook |
|---|---|
| Initial idle/wake | `SessionStart` |
| Running | `UserPromptSubmit`, `PreToolUse` |
| Tool finished | `PostToolUse` |
| Waiting for permission | `PermissionRequest` |
| Reviewing/ready | `Stop` |
| Subagent activity | `SubagentStart`, `SubagentStop` |
| Compacting | `PreCompact`, `PostCompact` |

Caveats:

- Hook commands must be reviewed/trusted unless managed or deliberately bypassed.
- Current `PreToolUse` coverage includes Bash, `apply_patch`, and MCP, but is not a complete enforcement boundary. Official docs specifically say interception is incomplete for richer `unified_exec` shell paths and does not cover every non-shell tool.
- Hooks are the best supported event feed, but not every internal event has a hook.

## 3.3 Rollout JSONL files

Path:

```text
~/.codex/sessions/YYYY/MM/DD/
  rollout-YYYY-MM-DDThh-mm-ss-<thread-uuid>.jsonl
```

Archived threads may be under:

```text
~/.codex/archived_sessions/
```

Sources:

- [rollout list layout](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/rollout/src/list.rs)
- [rollout filename construction](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/rollout/src/recorder.rs)
- [RolloutItem schema](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/protocol/src/protocol.rs)

Each line is a tagged object such as:

```json
{"type":"session_meta","payload":{...}}
{"type":"turn_context","payload":{...}}
{"type":"response_item","payload":{...}}
{"type":"event_msg","payload":{...}}
```

`session_meta` includes:

- thread/session identifiers
- timestamp
- cwd
- `originator`
- CLI/runtime version
- `source`
- optional parent/fork identifiers
- model provider and related metadata

The persisted `EventMsg` enum includes, among many others:

- `TurnStarted`
- `TurnComplete`
- `TurnAborted`
- `Error`
- `StreamError`
- `ExecCommandBegin` / `ExecCommandEnd`
- `McpToolCallBegin` / `McpToolCallEnd`
- `WebSearchBegin` / `WebSearchEnd`
- `ImageGenerationBegin` / `ImageGenerationEnd`
- `PatchApplyBegin` / `PatchApplyEnd`
- `ExecApprovalRequest`
- `ApplyPatchApprovalRequest`
- `RequestPermissions`
- `RequestUserInput`
- `ElicitationRequest`
- `ShutdownComplete`

The session sends events through a persistence path that wraps them as `RolloutItem::EventMsg`; see [session/mod.rs](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/core/src/session/mod.rs).

### Reliability assessment

| Desired signal | Rollout evidence | Reliability |
|---|---|---|
| Session/thread creation | File creation + first `session_meta` | High |
| Turn start | `event_msg/task_started` | High |
| Turn complete | `event_msg/task_complete` | High |
| Turn interruption | `turn_aborted` | High |
| Shell/tool begin/end | Begin/end events or response items | High, but tool-specific |
| Approval request | Approval/request event variants | High |
| User input request | `RequestUserInput` | High |
| Errors/retries | `Error`, `StreamError` | High |
| Process/session exit | `ShutdownComplete` when graceful | Medium |
| Definitive “window closed” | Not guaranteed | Low |

Two cautions:

1. The official Hooks documentation says `transcript_path` is convenient but the transcript format is not a stable hook interface and may change.
2. Tailing active JSONL needs partial-line handling, rotation/archive handling, deduplication, and tolerance for newly added variants.

Recommended architecture: use hooks as the primary live feed; use rollout tailing only as enrichment or fallback.

---

# 4. Distinguishing Codex Desktop, CLI, exec, and subagents

## Supported identifiers

### `notify`

The optional `client` field distinguishes clients when populated. The source test uses `codex-tui`.

### Hooks

Hooks expose the session and CWD, but the documented common schema does not promise a `client` field. The underlying legacy hook payload does carry an optional client internally, but Ajman should not assume every hook event exposes it unless verified in the installed version.

### Rollout metadata

`session_meta` is the strongest passive discriminator:

- `originator`: locally observed values include `Codex Desktop`.
- `source`: Rust supports `cli`, `vscode`, `exec`, `mcp`, custom, internal, and subagent forms.
- parent/subagent metadata distinguishes child agents.
- `cwd` identifies the project/worktree.

Source: [SessionSource and SessionMeta](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/protocol/src/protocol.rs).

Important nuance: Desktop sessions may currently serialize `source: "vscode"` while `originator` says `Codex Desktop`. Therefore do not equate `source == vscode` with the VS Code extension. Use `originator` first, then `source`, then client metadata.

Recommended classification:

```text
if originator == "Codex Desktop" -> Desktop
else if notify.client == "codex-tui" or source == "cli" -> CLI/TUI
else if source == "exec" -> codex exec/non-interactive
else if source is subagent/internal -> child/internal
else -> unknown Codex surface
```

Confidence: high for the fields; medium for exact string values, which are not a frozen public taxonomy.

---

# 5. Focusing the correct conversation, project, terminal, or window

## What is exposed

| Identifier | Available? | Source |
|---|---:|---|
| Codex thread/session id | Yes | hooks, notify, rollout, app-server |
| Turn id | Yes | notify, turn-scoped hooks, app-server |
| CWD/project path | Yes | hooks, notify, rollout, app-server |
| Parent/fork/subagent id | Often | rollout/app-server |
| Client/originator | Sometimes | notify/rollout |
| Terminal TTY path | No supported field found | — |
| Terminal PID/window id | No supported field found | — |
| macOS window identifier | No supported field found | — |
| Desktop sidebar/project identifier | Private UI state only | — |
| Supported “focus thread” deep link | Not found | — |

## App-server is not a UI-focus API

App-server supports:

- `thread/start`
- `thread/resume`
- `thread/read`
- `thread/list`
- `turn/start`
- live turn/item notifications
- bidirectional approval requests

It also supports stdio, a local Unix control socket, and an experimental WebSocket transport. Sources:

- [app-server README](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/app-server/README.md)
- [official App Server documentation](https://developers.openai.com/codex/app-server)

But `thread/resume` means “attach/resume this logical Codex thread,” not “make Codex Desktop select and front this conversation window.” No app-server `focus`, `activate`, `navigate`, or window-selection method was found.

A companion can safely:

- activate the Codex application generically through macOS APIs;
- activate a known terminal application generically;
- show the user the CWD/thread id;
- maintain its own mapping when it launched the terminal or app-server client.

It cannot reliably focus an arbitrary existing Codex conversation or exact terminal tab from Codex’s documented identifiers alone.

Confidence: high for absence from current public protocol; Desktop may have private deep links not represented in the open repository, so those remain unverified rather than disproved.

---

# 6. Codex approvals and issue #15311

## Issue status

**CONFIRMED — issue exists.**  
**FALSE — it is not currently open.**  
**FALSE — Codex is no longer merely observable-but-not-externally-approvable.**

[openai/codex#15311](https://github.com/openai/codex/issues/15311):

- Title: “Add blocking PermissionRequest hook for external approval UIs”
- Created: 2026-03-20
- Requested by Masko Code’s developer
- Closed: 2026-04-22
- State reason: completed
- OpenAI contributor response: implemented in [PR #17563](https://github.com/openai/codex/pull/17563)
- Current status at research time: closed/completed

The original issue accurately described the earlier state: rollout ingestion was possible, but an external overlay could not return an allow/deny approval decision. That statement is historically true, not currently true.

## Current Codex blocking mechanisms

### 1. `PermissionRequest` hook

This runs only when Codex is about to surface an approval request. It can return:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
```

or:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "deny",
      "message": "Blocked by policy"
    }
  }
}
```

Resolution rule:

- Any deny wins.
- Otherwise an allow proceeds without showing the normal prompt.
- No decision falls through to normal UI approval.

Official evidence: [Codex Hooks: PermissionRequest](https://developers.openai.com/codex/hooks#permissionrequest).

This is the direct answer to #15311.

Limitations relative to Claude Code:

- Codex currently rejects `updatedInput`, `updatedPermissions`, and `interrupt` for `PermissionRequest`.
- It supports allow/deny, not Claude’s richer mutation/persistent-permission output.
- Coverage applies to approval-producing Bash, `apply_patch`, and MCP paths.
- Hook trust/configuration is required.

### 2. `PreToolUse`

This can deny supported tool calls before execution, even if they would not otherwise request permission. It is a guardrail, not a complete approval UI, and current official docs warn that its interception coverage is incomplete.

### 3. App-server approval RPC

A client that starts/resumes and drives an app-server thread receives blocking JSON-RPC requests such as:

- `item/commandExecution/requestApproval`
- `item/fileChange/requestApproval`
- `item/permissions/requestApproval`

It responds with decisions such as `accept`, `acceptForSession`, `decline`, or `cancel`. Source: [app-server approvals](https://github.com/openai/codex/blob/9e552e9d15ba52bed7077d5357f3e18e330f8f38/codex-rs/app-server/README.md#approvals).

This is full client-owned approval control. However, it should not be treated as a supported method to intercept and answer approvals belonging to an unrelated active Desktop/TUI client. Approval requests are routed through the app-server connection/thread listener participating in that session.

### Recommended Ajman approach

Use a global trusted `PermissionRequest` hook that calls a local Ajman helper synchronously and returns allow/deny JSON. Do not tail rollouts and then attempt to inject an approval response into someone else’s Desktop connection.

---

# 7. Claude Code hooks

Official current reference: [Claude Code Hooks](https://code.claude.com/docs/en/hooks).

Claude Code defines the following lifecycle events:

| Event | When it fires | Blocking/control capability |
|---|---|---|
| `SessionStart` | Session begins or resumes | Notify/context only |
| `Setup` | `--init-only`, or init/maintenance print mode | Notify/context only |
| `UserPromptSubmit` | Before prompt processing | **Blocks prompt** |
| `UserPromptExpansion` | Before typed command expands | **Blocks expansion** |
| `PreToolUse` | Before every tool call | **Blocks tool**; structured allow/deny/ask |
| `PermissionRequest` | Before permission dialog | **Allow or deny for user** |
| `PermissionDenied` | Auto-mode classifier denied tool | Cannot reverse denial; may request model retry |
| `PostToolUse` | Tool succeeded | Notify/feedback only; side effect already happened |
| `PostToolUseFailure` | Tool failed | Notify/feedback only |
| `PostToolBatch` | Parallel tool batch finished | **Stops loop before next model call** |
| `Notification` | Claude emits notification | Notify-only |
| `MessageDisplay` | Assistant text is displayed | Observe/transform display behavior; original text not blocked by exit 2 |
| `SubagentStart` | Subagent starts | Notify-only |
| `SubagentStop` | Subagent finishes | **Prevents stop; continues subagent** |
| `TaskCreated` | Task creation | **Rolls back creation** |
| `TaskCompleted` | Task completion | **Prevents completion** |
| `Stop` | Claude finishes response | **Prevents stop; continues conversation** |
| `StopFailure` | Turn ends from API error | Output/exit ignored |
| `TeammateIdle` | Team member about to idle | **Prevents idle** |
| `InstructionsLoaded` | CLAUDE.md/rules loaded | Observe-only |
| `ConfigChange` | Settings/skill config changes | **Blocks change**, except managed policy settings |
| `CwdChanged` | Working directory changes | Notify/environment management only |
| `FileChanged` | Watched file changes | Notify/environment management only |
| `WorktreeCreate` | Worktree about to be created | **Any nonzero exit aborts** |
| `WorktreeRemove` | Worktree removal | Notify/log only |
| `PreCompact` | Before compaction | **Blocks compaction** |
| `PostCompact` | After compaction | Notify-only |
| `Elicitation` | MCP server asks user for input | **Accept/decline/cancel programmatically** |
| `ElicitationResult` | Before user’s elicitation response reaches MCP | **Modify or block response** |
| `SessionEnd` | Session terminates | Cleanup/notify only |

Anthropic’s definitive exit-code table is at [Hooks reference: exit code 2 behavior](https://code.claude.com/docs/en/hooks#exit-code-2-behavior-per-event).

### PermissionRequest richness

Claude Code’s `PermissionRequest` decision may include:

- `behavior: "allow" | "deny"`
- `updatedInput`
- `updatedPermissions`
- denial `message`
- denial `interrupt`

It can therefore grant permission, modify the pending call, and apply persistent/session permission updates. [Official PermissionRequest specification](https://code.claude.com/docs/en/hooks#permissionrequest).

Codex’s new hook covers the central allow/deny use case but not all of those richer fields.

## Claude session/transcript data

Every Claude hook receives common input including:

```json
{
  "session_id": "...",
  "transcript_path": "/Users/.../.claude/projects/.../<session-id>.jsonl",
  "cwd": "...",
  "permission_mode": "...",
  "hook_event_name": "..."
}
```

Claude Code stores project session transcripts under encoded project directories:

```text
~/.claude/projects/<encoded-project-path>/<session-id>.jsonl
```

Subagent transcripts are nested below the main session:

```text
~/.claude/projects/<project>/<session-id>/subagents/agent-<id>.jsonl
```

The hook-provided `transcript_path` is preferable to reconstructing the encoded path manually.

For Ajman, Claude hooks supply all necessary correlation:

- session id
- exact transcript path
- CWD
- permission mode
- tool name/input/id
- notification type
- subagent id/type
- end reason

---

# 8. Recommended unified Ajman event model

Use one normalized local event schema:

```json
{
  "provider": "codex|claude",
  "surface": "desktop|cli|exec|unknown",
  "sessionId": "...",
  "turnId": "...",
  "cwd": "...",
  "state": "idle|running|waiting|review|failed",
  "event": "...",
  "timestamp": "..."
}
```

Suggested normalization:

| Normalized state | Codex | Claude Code |
|---|---|---|
| `idle` | `SessionStart`; inactivity after review | `SessionStart`; idle notification |
| `running` | `UserPromptSubmit`, tool begin, `PreToolUse` | `UserPromptSubmit`, `PreToolUse`, `SubagentStart` |
| `waiting` | `PermissionRequest`, user-input/elicitation rollout event | `PermissionRequest`, permission notification, `Elicitation` |
| `review` | `Stop`, turn complete, `notify` | `Stop`, `TaskCompleted`, agent-completed notification |
| `failed` | `Error`, `StreamError`, `TurnAborted`, failed tool end | `StopFailure`, `PostToolUseFailure`, denied permission |

Priority order:

1. Native hook event
2. App-server event, if Ajman owns that session
3. Rollout/transcript tail
4. `notify` completion fallback
5. Process polling only for coarse liveness

Ajman should maintain state per `provider + sessionId`, then choose which session to display using recency and waiting-state priority. A waiting session should override a merely running one so the mascot attracts attention to the actionable request.

---

# 9. Handoff claim audit

| Handoff claim | Verdict | Evidence |
|---|---|---|
| Official pet skill is at `github.com/openai/skills/skills/.curated/hatch-pet/SKILL.md` | **CONFIRMED** | [Public file](https://github.com/openai/skills/blob/main/skills/.curated/hatch-pet/SKILL.md) |
| A verbatim local `hatch-pet` skill exists | **CONFIRMED** | `/Users/kazys/.codex/vendor_imports/skills/skills/.curated/hatch-pet/SKILL.md` |
| Pets are stored at `~/.codex/pets/<name>/` | **CONFIRMED** | Rust loader joins `CODEX_HOME/pets/<id>` |
| Codex source is `github.com/openai/codex`, Rust under `codex-rs` | **CONFIRMED** | Current upstream clone |
| Ajman’s four-field manifest relies on a default grid convention | **CONFIRMED** | `frame` and `animations` are optional; Rust supplies defaults |
| Ajman’s `1536×1872` sheet is valid Codex geometry | **CONFIRMED** | Exactly 8×9 cells of 192×208 |
| Issue `openai/codex#15311` exists | **CONFIRMED** | [Issue](https://github.com/openai/codex/issues/15311) |
| It was filed by Masko’s developer seeking an external blocking approval hook | **CONFIRMED** | Issue body explicitly names Masko Code |
| Issue #15311 is currently open | **FALSE** | Closed 2026-04-22 as completed |
| “Codex is observable but cannot be externally approved” is still true | **FALSE** | `PermissionRequest` hooks now allow or deny |
| `PreToolUse` is Codex’s only blocking external hook | **FALSE** | `PermissionRequest`, prompt/stop hooks, and app-server approval RPC now exist |
| Another process can control Codex’s built-in pet state | **UNVERIFIED / no supported mechanism found** | No pet IPC or app-server pet method in current source |
| Desktop active pet is stored only in global state | **FALSE** | Active selection is `[desktop].selected-avatar-id` in `config.toml`; global state contains ancillary overlay/notification data |
| Desktop and CLI can always be distinguished by `source` alone | **FALSE** | Desktop may use `source: vscode`; use `originator` and client too |
| An external app can focus an exact Codex thread/window from session id | **UNVERIFIED / unsupported in current public protocol** | No focus/deep-link/window method found |
| Claude Code supports blocking approval hooks | **CONFIRMED** | `PermissionRequest` and `PreToolUse` |
| Claude transcripts live under `~/.claude/projects/...` | **CONFIRMED** | Official hook inputs expose exact paths there |

---

# 10. Could not verify

- The private Codex Desktop implementation that selects animation rows is not included in the open-source repository. The public pet skill calls this the “Codex app contract,” and the Rust TUI ports the same atlas, but Desktop’s exact internal animation sequencing could not be inspected.
- No public guarantee was found that Desktop’s `[desktop].selected-avatar-id` spelling is permanently stable. It is confirmed by current local state and current source tests.
- No supported Codex Desktop deep-link scheme for selecting a thread was found. A private scheme may exist in the packaged application.
- No stable TTY, terminal-tab, or macOS window identifier is recorded in the hook, notify, rollout, or app-server contracts examined.
- Rollout JSONL is rich but not documented as a frozen third-party API. Consumers must be forward-compatible.
- App-server can answer approvals for sessions routed through its client connection, but taking over an approval already owned by an unrelated Desktop/TUI connection was not verified and should not be relied upon.
- Codex hook coverage for every possible tool execution path remains incomplete by OpenAI’s own current documentation.