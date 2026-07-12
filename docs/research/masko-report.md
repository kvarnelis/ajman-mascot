# Masko Code architectural review

## Executive verdict

**Recommendation: use Masko as a parts donor, not as the base fork. Confidence: high.**

The public source survived at [MaTriXy/masko-code](https://github.com/MaTriXy/masko-code). It contains the original 127-commit history through commit `234fd8f` (“v0.13.13”), predominantly authored by Paul/RousselPaul.

Masko contains useful agent-ingestion, Claude hook-response, session-tracking, and terminal-focusing code. Its application shell, overlay, global keyboard interception, updater, private SkyLight integration, and especially its mascot animation system are too tightly coupled to Masko’s design and hosted assets to make a clean foundation for Ajman.

The decisive incompatibility is animation:

- Masko expects a state graph whose edges reference transparent **HEVC `.mov` videos**.
- Its renderer is `AVPlayer`/`AVPlayerLayer`.
- Ajman is one **1536×1872 gridded WebP spritesheet** with only a minimal `pet.json`.
- Masko has no spritesheet decoder, frame-grid description, or sprite animation renderer.

Ajman therefore needs a new renderer even if other Masko modules are reused.

---

# 1. Repository identity, provenance, and public history

## 1.1 Real surviving repository

The original URL is dead:

- `https://github.com/RousselPaul/masko-code` returns GitHub API HTTP 404.
- The Wayback availability API returned no archived snapshot.
- RousselPaul’s current public repository list does not contain Masko.

The surviving source is:

- [github.com/MaTriXy/masko-code](https://github.com/MaTriXy/masko-code)
- Current commit: `234fd8ffec5381393837271f98c7dac3177599ca`
- Commit date: 2026-03-30
- Commit subject: `v0.13.13: support download tokens for paid skins`
- Total reachable commits: **127**
- GitHub currently reports approximately **50 forks**, but no stars on this surviving copy.

GitHub does not mark this repository as a fork. Nevertheless, the evidence strongly indicates that it is a detached surviving copy of the deleted upstream:

- Its README still links to `RousselPaul/masko-code`.
- The history is authored principally by Paul’s GitHub noreply identity.
- The earliest commit is dated 2026-03-01, before the MaTriXy repository’s GitHub creation date of 2026-03-05.
- Its fork network survives even though GitHub reports no current parent.

This is enough to use the source for architectural and licensing analysis.

## 1.2 Public version versus current private product

There are no Git tags and no GitHub Releases on the surviving repository. “v0.13.13” is established by:

- The final commit subject.
- `CFBundleShortVersionString` in `Info.plist:15-16`.
- The source’s `CFBundleVersion` of 52 at `Info.plist:13-16`.

The public source is not the current shipping product. The live Sparkle appcast now advertises Masko **0.31.0**, published 2026-07-06, while public source stops at 0.13.13. The appcast also describes changes absent from this checkout, including a later change that “locks” the local server to the Mac.

This proves later non-public development exists. It does **not** prove that the move happened specifically in April 2026; that date remains unverified.

Later private development cannot revoke the MIT grant already attached to publicly distributed commits. A valid MIT license permits copying, modification, sublicensing, and redistribution, provided its copyright and permission notice remain included.

## 1.3 License

`LICENSE:1-21` is the standard MIT License:

- Copyright: `Copyright (c) 2026 Masko`
- Redistribution condition: retain the copyright and permission notice.
- No warranty.

`CONTRIBUTING.md:49` also says contributions are licensed under MIT.

Legal caveat: this is an engineering license review, not legal advice. Preserve the entire license and add clear attribution for copied files.

## 1.4 Languages

GitHub’s language calculation for the surviving source reports:

- Swift: 855,981 bytes
- Shell: 11,392
- Kotlin: 6,190
- Python: 1,119
- JavaScript: 765

The macOS application itself is Swift/SwiftUI/AppKit. Kotlin and JavaScript belong mainly to the JetBrains and VS Code terminal-focus extensions.

---

# 2. Actual source layout

The handoff’s broad layout was mostly correct but incomplete.

```text
Sources/
├── Adapters/
│   ├── AgentAdapter.swift
│   ├── ClaudeCode/
│   ├── Codex/
│   └── Copilot/
├── App/
├── Debug/
├── Models/
├── Resources/
│   ├── Defaults/
│   ├── Extensions/
│   ├── Fonts/
│   └── Images/
├── Services/
├── Stores/
├── Utilities/
├── Views/
│   ├── ActivityFeed/
│   ├── Approvals/
│   ├── Masko/
│   ├── MenuBar/
│   ├── Notifications/
│   ├── Onboarding/
│   ├── Overlay/
│   ├── Sessions/
│   ├── Settings/
│   └── Shared/
└── masko-desktop.entitlements

Tests/
extensions/
├── jetbrains/
└── vscode/
scripts/
docs/
```

The source is not especially modular despite the directory names. It contains several large mixed-responsibility files:

- `Views/Overlay/PermissionPromptView.swift`: 1,398 lines
- `Views/Overlay/OverlayManager.swift`: 1,372
- `Services/CodexEventMapper.swift`: 1,075
- `Views/Overlay/PermissionContentView.swift`: 894
- `Views/Masko/MaskoDashboardView.swift`: 840
- `Views/Settings/SettingsView.swift`: 698
- `Stores/PendingPermissionStore.swift`: 653
- `Services/GlobalHotkeyManager.swift`: 554
- `Services/OverlayStateMachine.swift`: 542
- `Stores/SessionStore.swift`: 527
- `Services/ExtensionInstaller.swift`: 514
- `Stores/AppStore.swift`: 491

That increases the risk and cost of a wholesale fork.

---

# 3. Local HTTP server and security

## 3.1 Implementation and port

Implementation:

- `Sources/Services/LocalServer.swift:4-304`
- Port configuration: `Sources/Utilities/Constants.swift:17-35`

The inherited claim that the public source uses port 49152 is outdated/false:

- `49152` is named `legacyDefaultServerPort` at `Constants.swift:18`.
- The actual default is **45832** at `Constants.swift:19`.
- A saved 49152 setting is automatically migrated to 45832 at lines 26-31.
- If occupied, the server tries ten sequential ports; see `LocalServer.swift:18-21,76-97`.

## 3.2 Binding

`LocalServer.swift:29-34` creates `NWParameters.tcp` and constructs:

```swift
NWListener(using: params, on: nwPort)
```

It does not constrain the listener to `127.0.0.1`, `::1`, or a required loopback endpoint.

Therefore the public implementation should be treated as listening on available interfaces, not loopback-only. This is reinforced by the later 0.30.0 appcast note saying the newer private product “locks” the local server to the Mac—implying that this was subsequently fixed.

## 3.3 Authentication

No authentication, shared secret, bearer token, origin validation, peer validation, or request signature was found.

The `token` in `MaskoDesktopApp.swift:235-249` is a download token for paid mascot configuration, not local-server authentication.

## 3.4 Endpoints

Defined in `LocalServer.swift:164-258`:

- `GET /health`
  - Returns `ok`.
- `POST /hook`
  - Decodes an `AgentEvent`.
  - Ordinary events are acknowledged immediately.
  - `PermissionRequest` holds the TCP connection open for a later allow/deny response.
- `POST /input`
  - Accepts `{"name": "...", "value": bool-or-number}`.
  - Directly changes state-machine inputs.
- `POST /install`
  - Accepts a complete `MaskoAnimationConfig`.
  - Installs it through the callback.
- `OPTIONS /install`
  - Provides browser preflight support.

`/install` explicitly returns:

- `Access-Control-Allow-Origin: *`
- `Access-Control-Allow-Methods: POST, OPTIONS`
- `Access-Control-Allow-Headers: Content-Type`

See `LocalServer.swift:268-280`.

## 3.5 Browser and local-process exposure

**Yes: arbitrary local processes can POST commands/events.**

There is no authentication, and all three POST endpoints accept untrusted data.

**Yes: a malicious browser page can cause state changes.**

Important details:

- `/install` deliberately allows every web origin.
- `/hook` and `/input` do not provide CORS preflight responses, but the server ignores `Content-Type`.
- A page can issue a “simple” `text/plain` POST containing JSON without preflight. The browser may prevent JavaScript from reading the response, but the POST side effect still occurs.
- If the listener is externally reachable, another LAN host may also be able to send these requests.

Potential consequences include:

- Injecting fake session, tool, notification, or permission events.
- Holding fake permission connections open.
- Driving state-machine inputs.
- Installing attacker-supplied mascot configurations.
- Causing downloads from attacker-chosen video/audio URLs through the installed configuration.

The server does not directly execute shell commands. The immediate risk is spoofing, state manipulation, remote-resource installation, privacy leakage through injected UI, and denial of service—not direct arbitrary code execution.

## Security verdict

The public server must not be reused unchanged.

Minimum redesign:

1. Bind only to IPv4 and IPv6 loopback.
2. Generate a per-install random secret stored in Keychain.
3. Require the secret on every non-health request.
4. Reject browser origins by default.
5. Remove `Access-Control-Allow-Origin: *`.
6. Use exact method/path parsing rather than `firstLine.contains(...)`.
7. Enforce size limits and timeouts.
8. Separate public mascot installation from agent-event ingestion.
9. Validate media URL schemes and optionally trusted hosts.

---

# 4. Claude Code hook installation and responses

## 4.1 Files and paths

Hook installation is in:

- `Sources/Services/HookInstaller.swift`
- Claude settings: `~/.claude/settings.json`, lines 8 and 37-123
- Generated script: `~/.masko-desktop/hooks/hook-sender.sh`, lines 9 and 125-217

No user files were changed during this review.

## 4.2 Merge or overwrite

Installation merges at the JSON-object level:

- Reads existing settings at lines 62-67.
- Reads the existing `hooks` dictionary at line 70.
- Appends one Masko entry per event only when absent at lines 76-87.
- Writes the entire reconstructed settings object at lines 89-92 and 221-233.

It therefore preserves conventional existing hook entries and unrelated top-level settings.

However:

- There is **no backup**.
- JSON formatting and key ordering are replaced.
- If parsing the existing file fails, installation begins from an empty dictionary, which could overwrite malformed or unsupported settings content.
- Writes are not guarded by a file lock, so concurrent writers can race.

## 4.3 Uninstall behavior

`HookInstaller.uninstall()` at lines 95-123:

- Removes entries containing Masko’s exact hook command.
- Preserves other entries for the same events.
- Removes empty event arrays and, if necessary, the empty top-level `hooks` key.

It does **not** restore an original file byte-for-byte and does not remove the generated script directory. There is no original-settings backup to restore.

## 4.4 Registered Claude events

`HookInstaller.swift:13-33` registers:

1. `PreToolUse`
2. `PostToolUse`
3. `PostToolUseFailure`
4. `Stop`
5. `StopFailure`
6. `Notification`
7. `SessionStart`
8. `SessionEnd`
9. `TaskCompleted`
10. `PermissionRequest`
11. `UserPromptSubmit`
12. `SubagentStart`
13. `SubagentStop`
14. `PreCompact`
15. `PostCompact`
16. `ConfigChange`
17. `TeammateIdle`
18. `WorktreeCreate`
19. `WorktreeRemove`

## 4.5 Blocking permission flow

The generated shell script:

- Reads the hook JSON from stdin.
- Extracts `hook_event_name`.
- Walks the process tree to infer terminal and shell PIDs.
- Injects those PIDs into the JSON using `sed`.
- For `PermissionRequest`, POSTs to `/hook` and waits.
- Prints the response body to stdout.
- Exits 2 on an HTTP 403 denial.

See `HookInstaller.swift:145-207`.

The app’s blocking path is:

1. `LocalServer.swift:187-203` decodes the event and holds the connection.
2. `Adapters/ClaudeCode/HookConnectionTransport.swift:4-95` wraps that connection.
3. `PendingPermissionStore.swift:540-623` sends the selected decision.
4. `PendingPermissionStore.swift:635-652` creates Claude’s response JSON.

Allow:

```json
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": { "behavior": "allow" }
  }
}
```

Deny changes `behavior` to `deny`, uses HTTP 403, and makes the script exit 2.

Updated inputs and persistent permission suggestions use:

- `updatedInput`: `HookConnectionTransport.swift:35-41`
- `updatedPermissions`: lines 43-49

## 4.6 Hook implementation risks

- The script modifies JSON through textual `sed "s/}$/.../"`, not a real JSON tool. This is fragile for unexpected trailing whitespace or unusual payloads.
- It uses unqualified `curl`, `grep`, `head`, `cut`, `ps`, `tr`, `sed`, and `mktemp`, inheriting the user’s hook environment and `PATH`.
- The local HTTP channel is unauthenticated.
- The app installs 19 global hook entries—substantial configuration surface.
- No file locking or rollback exists for settings edits.

The conceptual response transport is reusable; the installer should be rewritten.

---

# 5. Claude event parsing

The expected event model is:

- `Sources/Models/AgentEvent.swift:3-217`
- Event enum: `Sources/Models/HookEventType.swift:3-91`

Expected snake-case fields include:

- `hook_event_name` — required
- `session_id`
- `cwd`
- `permission_mode`
- `transcript_path`
- `tool_name`
- `tool_input`
- `tool_response`
- `tool_use_id`
- `message`
- `title`
- `notification_type`
- `source`
- `reason`
- `model`
- `stop_hook_active`
- `last_assistant_message`
- `agent_id`
- `agent_type`
- `task_id`
- `task_subject`
- `permission_suggestions`
- injected `terminal_pid`
- injected `shell_pid`

Only `hook_event_name` is required by decoding at `AgentEvent.swift:134-161`.

This model is one of the cleaner reusable seams, though it is not strictly Claude-specific anymore: Codex events are normalized into the same structure.

---

# 6. Codex integration

## 6.1 Ingestion method

Codex requires no hook or plugin installation:

- `Sources/Adapters/Codex/CodexAdapter.swift:32-42`

The monitor tails session JSONL files under:

- `$CODEX_HOME/sessions`, or
- `~/.codex/sessions`

See `Sources/Services/CodexSessionMonitor.swift:11-19`.

It recursively finds every `.jsonl`, polls once per second, tracks byte offsets and partial lines, and bootstraps recently modified files. Relevant code:

- Discovery: lines 91-103
- Offset/tail reading: lines 144-193
- Mapping: lines 195-212
- Recent bootstrap: lines 220-245

## 6.2 Parsed Codex records

`Sources/Services/CodexEventMapper.swift` handles at least:

- `session_meta`
- `turn_context`
- `event_msg`
- `response_item`

Mapped event-message types include:

- `task_started`
- `task_complete`
- `turn_aborted`
- `request_user_input`
- `agent_message`
- `user_message`
- `agent_reasoning`
- `token_count`
- `request_permissions`
- `exec_command_begin`
- `exec_command_end`
- `exec_approval_request`

Context normalization begins at `CodexEventMapper.swift:62-121`; major event mapping begins at lines 123 onward.

This parser is extensive but very large—1,075 lines—and depends on Codex’s internal session-log schema. It will require fixtures and ongoing compatibility tests.

## 6.3 Observe versus act

The public Codex integration is effectively **observe-only plus focus**.

`CodexAdapter.swift:55-64` converts apparent Codex permission requests into `TerminalFallbackTransport`.

`Sources/Adapters/Codex/TerminalFallbackTransport.swift:3-58` advertises only:

```swift
[.openTerminal]
```

Every allow/deny/answer method merely focuses the terminal.

The code explicitly says background replies are unsupported:

- `CodexInteractiveBridge.swift:12-13`

This matches Paul’s public OpenAI issue explaining that Masko could ingest Codex logs but could not send approvals back to Codex. [OpenAI Codex issue #15311](https://github.com/openai/codex/issues/15311)

Therefore claims that this public version approves Codex commands directly are false. It shows the prompt and sends the user to Codex.

---

# 7. Session tracking, permissions, questions, and plan review

## 7.1 Session registry

Primary files:

- `Sources/Stores/SessionStore.swift`
- `Sources/Models/AgentSource.swift`
- `Sources/Services/EventProcessor.swift`
- `Sources/Stores/EventStore.swift`
- `Sources/Stores/SessionSwitcherStore.swift`
- `Sources/Stores/SessionFinishedStore.swift`

`AgentSession` is defined at `SessionStore.swift:4-114` and stores:

- Session ID
- Project directory/name
- Agent source
- Active/ended status
- Idle/running/compacting phase
- Event count and timestamps
- Last tool
- Active subagent count
- Terminal and shell PIDs
- Transcript path

The store persists sessions to `sessions.json`, reconciles process liveness every two minutes, and checks transcripts every three seconds for interruption markers; see `SessionStore.swift:116-170`.

## 7.2 Permissions

Core files:

- `Sources/Stores/PendingPermissionStore.swift`
- `Sources/Models/ResponseTransport.swift`
- `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift`
- `Sources/Adapters/Codex/TerminalFallbackTransport.swift`
- `Sources/Views/Overlay/PermissionPromptView.swift`
- `Sources/Views/Overlay/PermissionContentView.swift`
- `Sources/Views/Overlay/ExpandedPermissionView.swift`
- `Sources/Views/Approvals/ApprovalRequestView.swift`

The transport/capability abstraction in `ResponseTransport.swift:3-32` is a good reusable concept. The presentation and store are substantially entangled with Masko overlay behavior.

## 7.3 Question handling

`PendingPermissionStore.swift:107-164` parses `AskUserQuestion`:

- Question text
- Header
- Options and descriptions
- Multi-select flag
- Custom answer path

Responses are returned by copying original tool input and adding an `answers` dictionary at lines 557-580.

## 7.4 Plan review

Plan review is handled as the `ExitPlanMode` permission/tool case in the permission views and pending store.

User feedback is inserted as `userFeedback` and returned through `updatedInput`; see `PendingPermissionStore.swift:583-605`.

This is functional but not an independent module. It is embedded in very large permission UI files.

---

# 8. Terminal and editor focusing

## 8.1 Implementation

Primary files:

- `Sources/Utilities/IDETerminalFocus.swift`
- `Sources/Utilities/CodexInteractiveBridge.swift`
- `Sources/Services/ExtensionInstaller.swift`
- `extensions/vscode/`
- `extensions/jetbrains/`

## 8.2 Supported targeting mechanisms

Exact or near-exact targeting:

- VS Code, VS Code Insiders, Cursor, Windsurf, Antigravity:
  - Bundled VSIX.
  - Custom URI containing shell PID.
- JetBrains applications:
  - App activation plus `http://localhost:63342/api/masko/focus?pid=...`.
- iTerm2 and Terminal.app:
  - AppleScript loops through tabs/sessions and compares TTY.
  - `IDETerminalFocus.swift:170-229`.

Fallback app activation supports:

- Terminal
- iTerm2
- WezTerm
- Kitty
- Ghostty
- Alacritty
- Warp
- VS Code variants
- Windsurf
- Zed
- Antigravity
- PyCharm/IntelliJ/WebStorm/GoLand/CLion/PhpStorm/RubyMine/Rider
- Claude Desktop

See `IDETerminalFocus.swift:118-149`.

Target selection uses:

- Captured terminal PID
- Captured shell PID
- TTY
- Project directory
- Saved bundle ID
- Process-tree traversal for Codex
- Newest matching PID as an ambiguity fallback

## 8.3 AppleScript, Accessibility, and private APIs

Masko uses all of the following:

- `NSRunningApplication.activate`
- `NSWorkspace.open`
- `open -b bundleID projectPath`
- `NSAppleScript`
- `/usr/bin/osascript`
- System Events Accessibility window raising
- A global CGEvent tap
- Private SkyLight framework calls

`Sources/Utilities/SkyLightOperator.swift:1-7` states that it uses private SkyLight APIs to pin overlay windows across Spaces. Private framework usage is brittle and unsuitable for Mac App Store distribution.

## 8.4 Command-injection analysis

Most subprocess arguments use `Process.arguments`, not shell interpolation. This substantially reduces shell-command injection risk.

Two AppleScript paths interpolate strings:

- Bundle IDs: `IDETerminalFocus.swift:290-296`
- Process/window title strings: lines 262-277

The process name and title are escaped only by replacing `"` with `\"`. AppleScript escaping is not a robust general-purpose sanitizer. A maliciously crafted project-folder/window title could potentially alter generated AppleScript. The risk is limited by how the values are sourced, but it should be eliminated in reused code.

TTY insertion is lower risk because it is derived from `ps` and used as a quoted comparison.

Recommended replacement:

- Prefer PID/TTY-based native APIs or extension messages.
- Avoid dynamically generated AppleScript where possible.
- If AppleScript remains necessary, pass values through `argv` to an `osascript` program instead of embedding them in source.

---

# 9. Overlay and mascot animation system

## 9.1 Expected asset format

Models:

- `Sources/Models/MaskoCollection.swift:37-153`

The configuration is a proprietary Masko canvas/state-graph export:

```text
MaskoAnimationConfig
├── version
├── name
├── initialNode
├── autoPlay
├── nodes[]
├── edges[]
└── inputs[]
```

Each edge contains:

- Source and target node IDs
- Loop flag
- Duration
- Conditions
- Priority
- Playback speed
- Optional sound
- `videos.webm`
- `videos.hevc`

See `MaskoCollection.swift:39-72,150-153`.

## 9.2 Renderer

`Sources/Views/Shared/MascotVideoView.swift:18-97`:

- Calls itself an HEVC transparent-video view.
- Creates `AVPlayer(url:)`.
- Places it in `AVPlayerLayer`.
- Loops through `AVPlayerItemDidPlayToEndTime`.

`Sources/Services/VideoCache.swift:3-90`:

- Extracts only `edge.videos.hevc`.
- Downloads and caches those files.
- Does not preload or render the WebM alternative.

`Sources/Services/OverlayStateMachine.swift`:

- Drives nodes, conditional transitions, Any-State edges, loop counters, timers, click/hover triggers, and agent state inputs.
- Requires transition edges with HEVC URLs in several routing paths, e.g. lines 271-315 and 348-352.

Default mascot JSON files point to hosted assets at `https://assets.masko.ai/...`, generally:

- PNG thumbnails
- WebM videos
- Transparent HEVC `.mov` videos
- Optional remote audio

## 9.3 Ajman compatibility

**Ajman’s existing spritesheet cannot be rendered by this system.**

Missing capabilities include:

- WebP image loading path
- Grid row/column metadata
- Per-state frame ranges
- Frame duration/FPS metadata
- Sprite cropping
- Timer/display-link frame stepping
- State-to-animation mapping from Codex pet metadata
- Static or sprite fallback when HEVC is unavailable

Ajman would need either:

1. Conversion into Masko’s graph plus multiple transparent HEVC loop/transition videos, or
2. A new spritesheet renderer and a new Ajman-specific animation manifest.

Option 2 is preferable. It retains the original asset, removes dependence on Masko’s hosted animation service, and makes future pets easier to define.

## 9.4 Hosted-asset dependency

The state-machine algorithm itself is local, but bundled default manifests point to `assets.masko.ai`. Remote mascot installation also uses `masko.ai`.

The graph format is source-visible but product-specific. It is not necessary for Ajman unless Kazys wants Masko’s editor/export pipeline.

---

# 10. Global shortcuts and Command-key interception

Implementation:

- `Sources/Services/GlobalHotkeyManager.swift`

The manager creates a session-level CGEvent tap at the head of the event stream:

- `GlobalHotkeyManager.swift:229-267`

It requires Accessibility permission and observes:

- Key-down events
- Modifier-flag changes

It tracks solitary Command presses and uses a sub-400 ms double-Command gesture for session switching; lines 374-417.

It globally consumes recognized shortcuts by returning `nil`:

- Configurable default Command-M: lines 435-444
- Arrow keys and Tab while switcher active: lines 446-467
- Escape: lines 469-478
- Command-1 through Command-9: lines 480-494
- Command-Enter: lines 496-500
- Command-L: lines 502-506
- Command-P: lines 508-512
- Command-Escape: lines 514-518

This is invasive:

- It monitors all key-down and modifier events.
- It consumes shortcuts from the frontmost app whenever Masko considers a card active.
- It globally reserves Command-M by default, conflicting with macOS’s standard Minimize command.
- Double-tapping Command can conflict with user habits or accessibility/input methods.

For Ajman, global interception should be opt-in and substantially reduced. A passive mascot should not require Accessibility permission merely to animate.

---

# 11. Auto-updater

The handoff’s Sparkle claim is verified.

## Files

- Dependency: `Package.swift:8-13`
- Appcast and public key: `Info.plist:29-32`
- Updater wrapper: `Sources/App/MaskoDesktopApp.swift:89-129`

## Configuration

- Sparkle feed:
  - `https://masko.ai/api/desktop/appcast`
- Ed25519 public key:
  - `/BVYK9Q4hZORSn/xfhu4BCCLrug5zEA5WkwXG2lgdiw=`

The updater only starts for a validly signed app.

It is cleanly removable:

1. Remove Sparkle from `Package.swift`.
2. Remove `SUFeedURL` and `SUPublicEDKey` from `Info.plist`.
3. Remove `AppUpdater`.
4. Remove its environment injection and settings UI.

A fork must remove or replace it immediately. Retaining Masko’s appcast could cause a fork to attempt installation of official Masko binaries over the fork.

---

# 12. Dependencies and licenses

## Swift Package Manager

`Package.swift` declares two direct dependencies:

1. [Sparkle](https://github.com/sparkle-project/Sparkle), from 2.5.0
   - Sparkle’s main license is MIT-like.
   - Its distribution includes several separately attributed permissive components.
   - Preserve Sparkle’s full license/notices if retained.

2. [swift-markdown-ui](https://github.com/gonzalezreal/swift-markdown-ui), from 2.4.0
   - MIT
   - Copyright © 2020 Guillermo Gonzalez.

There is no committed `Package.resolved`, so exact resolved versions cannot be established from this checkout alone.

## Other copied/bundled components

- `Sources/Utilities/SkyLightOperator.swift:1-2` says it was adapted from Lakr233/SkyLightWindow under MIT.
- Bundled VSIX and JetBrains extension artifacts have source in `extensions/`, but no separate extension license file was found.
- Fredoka and Rubik font binaries are bundled under `Sources/Resources/Fonts/`.
- No bundled font license files were found.

The font provenance/license omission is a distribution-compliance item that must be resolved before reusing them. They are unnecessary for Ajman and should be omitted.

The default mascot JSON files contain remote Masko asset URLs. The repository’s MIT license covers the source repository, but it does not independently establish ownership or redistribution terms for every hosted mascot video. Do not redistribute those hosted assets without separate confirmation.

---

# 13. Module liftability ranking

## Tier A — cleanest parts to reuse

These have useful boundaries and limited Masko branding:

1. **Generic normalized event model**
   - `Sources/Models/AgentEvent.swift`
   - `Sources/Models/HookEventType.swift`
   - `Sources/Models/AnyCodable.swift`

2. **Adapter protocol**
   - `Sources/Adapters/AgentAdapter.swift`
   - `Sources/Models/AgentSource.swift`
   - `Sources/Models/ResponseTransport.swift`

3. **Claude blocking response transport**
   - `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift`
   - The JSON response behavior is valuable and relatively self-contained.

4. **Codex session tailer**
   - `Sources/Services/CodexSessionMonitor.swift`
   - Reuse with fixtures and schema-drift tests.

5. **Basic local persistence helper**
   - `Sources/Utilities/LocalStorage.swift`
   - Review storage paths and naming before adoption.

## Tier B — reusable after extraction or hardening

1. **Codex event mapper**
   - `Sources/Services/CodexEventMapper.swift`
   - Valuable coverage but oversized and coupled to a normalized Claude-like event model.
   - Needs versioned fixture tests and decomposition.

2. **Session model and registry**
   - `Sources/Stores/SessionStore.swift`
   - Useful behavior, but persistence, process polling, transcript watching, state mutation, and process matching should be separated.

3. **Permission/question parsing**
   - `Sources/Stores/PendingPermissionStore.swift`
   - Lift only parsing and response-construction portions.
   - Do not lift the entire 653-line store unchanged.

4. **Terminal focusing**
   - `Sources/Utilities/IDETerminalFocus.swift`
   - Valuable targeting knowledge.
   - Remove dynamic AppleScript interpolation and optional extension installation.

5. **VS Code/JetBrains terminal extensions**
   - `extensions/vscode/`
   - `extensions/jetbrains/`
   - Potentially reusable if exact-tab focusing is a requirement.
   - Installation must be explicit, not automatic.

6. **Animation state concepts**
   - `Sources/Services/OverlayStateMachine.swift`
   - Reuse conceptual input/state mapping, not the HEVC-specific implementation.

## Tier C — too entangled or risky

- Whole application shell
- Whole overlay subsystem
- Masko dashboard/settings/onboarding
- Video graph renderer and hosted manifests
- Global keyboard manager
- Current local server
- Hook installer
- Private SkyLight pinning
- Extension auto-installer
- Sparkle feed configuration
- Bundled fonts and Masko branding/assets

---

# 14. Concrete REUSE list

Use these as references or selectively copied MIT files, retaining attribution:

- `Sources/Models/AgentEvent.swift`
  - Shared normalized event envelope.
- `Sources/Models/HookEventType.swift`
  - Common lifecycle vocabulary.
- `Sources/Models/AnyCodable.swift`
  - Decoding heterogeneous tool payloads.
- `Sources/Models/AgentSource.swift`
  - Agent/source normalization.
- `Sources/Models/ResponseTransport.swift`
  - Good capability-based response abstraction.
- `Sources/Adapters/AgentAdapter.swift`
  - Useful adapter boundary for Claude, Codex, and future agents.
- `Sources/Adapters/ClaudeCode/HookConnectionTransport.swift`
  - Correct Claude PermissionRequest response shapes.
- `Sources/Services/CodexSessionMonitor.swift`
  - Offset-based JSONL tailing and recent-session bootstrap.
- `Sources/Services/CodexEventMapper.swift`
  - Use as a behavior reference and fixture source; split before production use.
- `Sources/Adapters/Codex/CodexAdapter.swift`
  - Correctly distinguishes observation from unsupported background replies.
- `Sources/Adapters/Codex/TerminalFallbackTransport.swift`
  - Honest fallback behavior.
- `Sources/Utilities/CodexInteractiveBridge.swift`
  - Process/CWD/TTY matching logic.
- `Sources/Stores/SessionStore.swift`
  - Reuse the `AgentSession` model and reconciliation ideas, not the monolithic store.
- `Sources/Stores/PendingPermissionStore.swift`
  - Reuse `ParsedQuestion`, permission-suggestion decoding, and response-construction logic.
- `Tests/CodexEventMapperTests.swift`
- `Tests/CodexSessionMonitorTests.swift`
- `Tests/CodexInteractiveBridgeTests.swift`
- `Tests/PendingPermissionStoreTests.swift`
  - These are especially valuable as characterization material.

---

# 15. Concrete AVOID list

Do not import these unchanged:

- `Sources/Services/LocalServer.swift`
  - Unauthenticated, not demonstrably loopback-only, browser-postable.
- `Sources/Services/HookInstaller.swift`
  - Writes global Claude settings without backup/locking; fragile shell JSON injection.
- `Sources/Services/GlobalHotkeyManager.swift`
  - Global key monitoring, Accessibility requirement, standard shortcut collisions.
- `Sources/Utilities/SkyLightOperator.swift`
  - Private macOS framework dependency.
- `Sources/Services/ExtensionInstaller.swift`
  - Automatic IDE mutation is too invasive for a mascot.
- `Sources/Models/MaskoCollection.swift`
  - Proprietary Masko graph/video configuration, not Ajman’s format.
- `Sources/Services/OverlayStateMachine.swift`
  - Strongly bound to HEVC edge videos and Masko graph semantics.
- `Sources/Services/VideoCache.swift`
  - Downloads only HEVC graph media into Masko-specific cache paths.
- `Sources/Services/EdgeAudioService.swift`
  - Permits arbitrary remote audio URLs; Masko-specific.
- `Sources/Views/Shared/MascotVideoView.swift`
  - HEVC `AVPlayer` renderer, incompatible with spritesheets.
- `Sources/Views/Overlay/OverlayManager.swift`
  - 1,372-line hub object.
- `Sources/Views/Overlay/PermissionPromptView.swift`
  - 1,398-line, heavily branded and coupled presentation.
- `Sources/Views/Overlay/PermissionContentView.swift`
  - 894-line mixed UI/parser/control surface.
- `Sources/Views/Masko/`
- `Sources/Views/Onboarding/`
- `Sources/Views/Settings/`
- `Sources/Utilities/BrandStyles.swift`
- `Sources/Resources/Defaults/*.json`
- `Sources/Resources/Fonts/*`
- `Sources/Resources/Images/*`
  - Branding, uncertain font notices, and hosted proprietary assets.
- `Info.plist` updater fields
  - Never point an Ajman fork at Masko’s appcast.
- `Sources/App/MaskoDesktopApp.swift`
  - Product shell, branding, updater, deep-link installation, and UI wiring are tightly coupled.

---

# 16. Recommended fresh-app architecture

A fresh Ajman application should retain Masko’s useful separation at the adapter boundary while replacing its shell:

```text
AjmanApp
├── AgentCore
│   ├── AgentEvent
│   ├── AgentAdapter
│   ├── SessionRegistry
│   └── AgentActivityReducer
├── ClaudeAdapter
│   ├── HookManifestMerger
│   ├── LocalAuthenticatedTransport
│   └── ClaudePermissionResponse
├── CodexAdapter
│   ├── SessionLogMonitor
│   └── CodexEventMapper
├── AjmanRenderer
│   ├── SpritesheetManifest
│   ├── WebPSpritesheetLoader
│   ├── FrameAnimator
│   └── ActivityToAnimationMapping
├── Overlay
│   └── Minimal nonactivating NSPanel
└── OptionalInteraction
    ├── PermissionBubble
    └── TerminalFocus
```

Key product boundary:

- Passive activity reaction should work without Accessibility permission.
- Permission handling, global shortcuts, and exact terminal focus should be separately enabled features.
- The renderer should accept local assets and never require a hosted mascot service.
- Agent adapters should emit semantic states such as idle, thinking, working, waiting, success, and error. The Ajman renderer should not know Claude/Codex wire formats.

---

# 17. Security summary

## Critical/high findings

1. **Unauthenticated local HTTP ingestion**
   - Any process can inject events, inputs, and mascot configurations.

2. **Listener not restricted to loopback in public source**
   - Potential LAN exposure.

3. **Browser-triggerable POSTs**
   - `/install` explicitly allows every origin.
   - Other endpoints can receive simple `text/plain` POSTs.

4. **Global Claude settings mutation without backup or locking**
   - Merge behavior is reasonably respectful, but failure recovery is weak.

5. **Remote media URLs accepted from mascot configurations**
   - The app downloads videos and audio from configuration-selected URLs.

6. **Global keyboard interception**
   - Requires Accessibility access and consumes systemwide shortcuts.

## Medium findings

7. **Dynamic AppleScript construction**
   - Incomplete escaping of project/window-derived text.

8. **Private SkyLight APIs**
   - Compatibility and distribution risk.

9. **Unpinned dependency resolution**
   - No committed `Package.resolved`.

10. **Codex log-schema coupling**
    - Silent degradation is possible after Codex format changes.

## Positive findings

- No metered AI API usage was found.
- No cloud upload of Codex/Claude session logs was found in the public source.
- Most subprocesses use argument arrays, not shell command strings.
- Codex replies are not falsely implemented: unsupported actions fall back to focusing the terminal.
- Sparkle uses a public signing key and signed appcast enclosures.
- Claude uninstall preserves non-Masko hook entries.

---

# 18. Licensing summary

- Public source: MIT, copyright 2026 Masko.
- Existing MIT permissions remain valid for the published commits even if development later became private.
- Preserve the Masko MIT notice in copied substantial portions.
- Prefer file-level attribution for lifted modules.
- Sparkle and MarkdownUI are permissively licensed; retain their notices.
- SkyLightOperator carries an in-file MIT attribution to another project.
- Bundled font licenses were not included in the repository: do not reuse those fonts until provenance is resolved.
- Hosted mascot videos/audio have no independently verified redistribution terms: do not redistribute them.
- Masko names, logos, and mascot branding may involve trademark or non-code rights not granted merely by the source license. Rebrand a fork completely.

---

# 19. Claims that proved false or materially misleading

1. **FALSE:** `https://github.com/RousselPaul/masko-code` is the usable repository.  
   It is dead. The surviving source is `MaTriXy/masko-code`.

2. **FALSE for the final public source:** the HTTP server’s default port is 49152.  
   The final source uses 45832; 49152 is explicitly legacy.

3. **FALSE:** the source tree is only `Sources/{App,Models,Services,Stores,Views,Utilities,Resources}`.  
   It also contains `Adapters` and `Debug`, plus extensions, tests, scripts, and docs.

4. **FALSE if interpreted as direct Codex control:** Masko can approve/deny Codex permissions from the overlay.  
   The public source only observes the request and focuses Codex’s terminal.

5. **FALSE:** the latest public version is available as a release/tag `v0.13.13`.  
   The source and final commit identify 0.13.13, but the surviving repository has no Git tag and no GitHub Release.

6. **FALSE as an exact metric:** approximately 320 stars.  
   Archived third-party indexes disagree: one recorded 223 stars, another 321. No authoritative exact snapshot was found.

7. **MISLEADING:** the server is a “local HTTP service,” implying loopback-only.  
   The public implementation does not explicitly bind to loopback.

8. **MISLEADING:** hook installation merely “installs Claude hooks.”  
   It registers 19 global events, writes an executable script, rewrites the JSON file, and has no backup.

9. **MISLEADING:** “custom mascot” suggests an ordinary image/spritesheet can be loaded.  
   The renderer expects a Masko graph of transparent HEVC videos.

---

# 20. Could not verify

The following remain **UNVERIFIED**:

- The exact date development became private.
- A public statement saying “moved to private development around April 2026.”
- The original repository’s exact star count immediately before deletion.
- Whether the original repository had exactly 50 forks at deletion; surviving/public indexes show approximately 49–50.
- Original GitHub Release metadata and downloadable 0.13.13 release assets.
- Any original annotated or lightweight tags; none survive in the inspected Git history.
- The original repository’s archived GitHub page; Wayback’s availability API returned no snapshot.
- Complete licenses for bundled Fredoka and Rubik font files.
- Redistribution rights for hosted `assets.masko.ai` mascot media.
- Whether every contribution was submitted under authority sufficient for the repository-wide MIT declaration.
- Architecture of current private Masko 0.31.0 beyond public appcast descriptions and the separate public Claude plugin.
- Whether the current private version has fully corrected every local-server vulnerability.
- Runtime/build success of this historical source on the present machine; this was a source-only, read-only architectural audit.

---

# Final decision

## Fork Masko

**Rejected.**

A fork inherits an oversized UI shell, private APIs, global keyboard interception, branded assets, hosted video assumptions, an unsafe local server, and an updater pointing at Masko. Most importantly, it still cannot render Ajman’s existing spritesheet.

## Masko as parts donor

**Recommended.**

Lift the normalized event types, Claude permission-response transport, Codex JSONL monitor/mapper, session concepts, question parsing, terminal-identification knowledge, and their tests. Harden or rewrite every boundary that writes user configuration, listens on a port, installs extensions, or intercepts input.

## Masko unusable because source is gone

**Rejected.**

The original repository is gone, but a complete surviving public source copy and original history remain available.

**Final confidence: high on the parts-donor verdict; high on spritesheet incompatibility and public-source security findings; medium on historical popularity and private-development chronology.**