# Petdex architectural review for an Ajman-only fork

## Executive verdict

**Petdex is a viable source-mining target, but a poor whole-app fork target for Ajman.**

The useful parts are:

- The Claude Code and Codex hook event definitions.
- The localhost token-gated state protocol.
- The state queue and event-to-animation vocabulary.
- The verified classic hatch-pet 8×9 animation mapping.

The parts that make a direct fork unattractive are:

- A 3,724-line Zig desktop god file.
- A 1,522-line Node sidecar required at runtime.
- A non-vendored fork of an experimental Zig/WebKit framework.
- Gallery installation, deep links, telemetry, GitHub update checks, and Petdex branding intertwined with the desktop.
- Default network activity even when the mascot itself uses only local assets.
- Incomplete uninstall behavior.
- No direct observation of Codex Desktop activity.
- No native frame-grid detection in the desktop; the new 8×11 support applies only to the website.

**Recommendation:** build a small native Swift/AppKit menu-bar/accessory app and port only the hook schemas, state protocol, and animation table. This should produce a smaller, more local, more maintainable Ajman application than stripping Petdex down.

Confidence: **high** on the architecture, locality, format, hooks, and security conclusions; **medium** on runtime overlay behavior because the app could not be built or launched in this environment.

Repository reviewed at commit `c39cc3d1a3a81ab6668ca4dbe9812e966e85416c`, dated 2026-07-11. The working tree remained clean.

---

## 1. Actual structure, languages, and licensing

### 1.1 Repository structure

The ChatGPT handoff was broadly correct about the two important packages, but “monorepo” needs qualification:

1. Root web application

   - Next.js 16 / React / TypeScript.
   - Application routes: `src/app/[locale]`.
   - API routes: `src/app/api`.
   - Drizzle/Postgres schema: `src/lib/db/schema.ts`, migrations in `drizzle/`.
   - Clerk, Cloudflare R2, Redis/Upstash, email, AI Gateway and other hosted services are part of this web product.
   - Root dependencies are defined in `package.json`.

2. macOS desktop

   - Zig application: `packages/petdex-desktop/src/main.zig`.
   - Zig/WebKit runner: `packages/petdex-desktop/src/runner.zig`.
   - Zig build: `packages/petdex-desktop/build.zig`.
   - Node sidecar source: `packages/petdex-desktop/sidecar/server.ts`.
   - Bundled sidecar artifact: `packages/petdex-desktop/sidecar/server.js`.
   - Release packaging: `packages/petdex-desktop/scripts/build-release.sh`.

3. Petdex CLI

   - TypeScript, bundled into a Node CLI with Bun.
   - Manifest: `packages/petdex-cli/package.json:1-40`.
   - Entry point: `packages/petdex-cli/bin/petdex.ts`.
   - Hook integration: `packages/petdex-cli/src/hooks/`.
   - Desktop install/update management: `packages/petdex-cli/src/desktop/`.

4. Other packages

   - Discord bot: TypeScript in `packages/discord-bot`.
   - Windows prototype: Rust/Tauri in `packages/petdex-desktop-windows`.

These packages are not configured as root workspaces; the project instructions explicitly describe the CLI and Discord bot as independent packages.

### 1.2 Is desktop really Zig/WebKit with a Node sidecar?

**Confirmed.**

- The executable is compiled from Zig: `packages/petdex-desktop/build.zig:78-90`.
- The system-WebKit backend links Apple WebKit and AppKit: `packages/petdex-desktop/build.zig:180-205`.
- `main.zig` embeds HTML/CSS/JavaScript and gives it to zero-native: `packages/petdex-desktop/src/main.zig:52-246`, `3078-3084`, `3314-3328`.
- A Node sidecar is spawned at startup: `packages/petdex-desktop/src/main.zig:1396-1442`, called from `3267-3272`.
- The sidecar requires Node ≥18: `packages/petdex-desktop/sidecar/package.json:5-11`.
- The `.app` bundles `sidecar/server.js`, but not Node itself: `packages/petdex-desktop/scripts/build-release.sh:47-54`.
- The app searches PATH, Homebrew, Volta, fnm, asdf, n, and nvm for Node: `packages/petdex-desktop/src/main.zig:1445-1544`.

Therefore the shipping desktop is not a self-contained native executable. It is a Zig/AppKit/WKWebView host plus an external Node runtime and JavaScript HTTP process.

### 1.3 Framework dependency

The desktop does not obtain zero-native from `build.zig.zon`; that manifest has no dependencies: `packages/petdex-desktop/build.zig.zon:1-7`.

Instead, the build requires a separate checkout of `Railly/zero-native`:

- Resolution: CLI option, environment variable, or `../../zero-native`: `packages/petdex-desktop/build.zig:24-31`, `311-329`.
- Required branch documented as `feature/window-resize`: `packages/petdex-desktop/README.md:10-14`, `28-34`.
- Compile-time API check requires commit `c85ec92` or newer: `packages/petdex-desktop/src/main.zig:9-14`.

The audited dependency branch currently resolves to exactly `c85ec92a170c5b1304543ffcbf0c1d6d3e413498`.

This makes fresh builds reproducible only if the external checkout is acquired and pinned manually. It is an important maintenance liability.

### 1.4 Licenses

- Petdex is MIT: `LICENSE:1-20`; GitHub also reports MIT.
- zero-native is Apache-2.0.
- CLI declared dependencies: `packages/petdex-cli/package.json:28-39`.

Registry metadata reported:

| Dependency | License |
|---|---|
| `@clack/prompts` | MIT |
| `jszip` | MIT OR GPL-3.0-or-later |
| `picocolors` | ISC |
| `@napi-rs/keyring` | MIT |
| zero-native | Apache-2.0 |

Sources: [Petdex repository](https://github.com/crafter-station/petdex), [zero-native license](https://github.com/Railly/zero-native/blob/main/LICENSE), [@clack/prompts](https://www.npmjs.com/package/@clack/prompts), [JSZip](https://www.npmjs.com/package/jszip), [picocolors](https://www.npmjs.com/package/picocolors), [@napi-rs/keyring](https://www.npmjs.com/package/@napi-rs/keyring).

No per-dependency third-party-notices file was found in the desktop or CLI package. A redistributed fork should add one, particularly because the desktop compiles external Apache-2.0 zero-native code directly.

---

## 2. Claude and Codex hook installers

## 2.1 Files and destinations

The main definitions are in `packages/petdex-cli/src/hooks/agents.ts`.

Claude Code:

- Config: `~/.claude/settings.json` — `agents.ts:181-185`.
- Slash command: `~/.claude/commands/petdex.md` — `agents.ts:185`.
- Events: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `Notification`, `Stop` — `agents.ts:187-198`.
- Generated hook bodies: `agents.ts:199-272`.

Codex CLI:

- Hook config: `~/.codex/hooks.json`, **not** `config.toml` — `agents.ts:276-280`.
- Slash prompt: `~/.codex/prompts/petdex.md` — `agents.ts:280`.
- Events: `UserPromptSubmit`, `PreToolUse`, `PostToolUse`, `PermissionRequest`, `Stop` — `agents.ts:282-288`.
- Generated hooks: `agents.ts:383-450`.
- `~/.codex/config.toml` is separately inspected or edited to enable `[features] codex_hooks = true`: `agents.ts:289-380`.

Shared files written:

- Persistent bundled CLI snapshot: `~/.petdex/bin/petdex.js` — `packages/petdex-cli/src/hooks/persist-binary.ts:23-50`.
- Runtime token: `~/.petdex/runtime/update-token`, created by the sidecar — `packages/petdex-desktop/sidecar/server.ts:47-58`, `143-151`.
- Optional hook killswitch: `~/.petdex/runtime/hooks-disabled` — `packages/petdex-cli/src/hooks/killswitch.ts:2-26`.

The slash-command files instruct the agent to run the persisted JavaScript CLI: `packages/petdex-cli/src/hooks/slash-command.ts:22-49`, installed at `87-96`.

## 2.2 What is placed inside hook configuration?

Generated hooks run a shell fragment that:

1. Exits if `~/.petdex/runtime/hooks-disabled` exists.
2. Runs:

   ```text
   node "$HOME/.petdex/bin/petdex.js" bubble <phase> <agent>
   ```

3. If the persisted CLI is absent, falls back to a token-authenticated `curl` POST to `http://127.0.0.1:7777/state`.

Exact construction: `packages/petdex-cli/src/hooks/agents.ts:563-623`.

The persisted runner reads up to 64 KiB of hook JSON from stdin, derives a state and a short human-readable activity bubble, then POSTs both to localhost: `packages/petdex-cli/src/hooks/bubble-runner.ts:25-31`, `38-59`, `61-101`, `151-175`, `178-214`.

## 2.3 Preservation of existing user configuration

For JSON settings, preservation is reasonably careful:

- Existing invalid or unreadable JSON is refused rather than overwritten: `packages/petdex-cli/src/hooks/install.ts:249-258`.
- Existing files are backed up before writing: `install.ts:260-268`, `300-306`.
- Top-level keys are preserved.
- Existing hooks for the same event are retained.
- Previously recognized Petdex hooks are filtered before the current Petdex entries are appended: `install.ts:309-343`.

Caveats:

- Files are parsed and reserialized with `JSON.stringify`, so original formatting, key ordering, and comments are not preserved.
- JSON comments were invalid already, but JSONC-style settings would be refused.
- The slash-command path is overwritten unconditionally on install because the project assumes ownership of that filename: `packages/petdex-cli/src/hooks/slash-command.ts:80-96`.
- The Codex `config.toml` edit is not a full TOML round-trip. It applies a focused textual change after creating a timestamped backup: `packages/petdex-cli/src/hooks/agents.ts:316-364`.

## 2.4 Reversibility verdict

The earlier claim that install/uninstall is “clean and reversible” is **FALSE as stated**.

What is reversible:

- Claude/Codex JSON hook entries are selectively removed by recognizing embedded `:7777/state` URLs: `packages/petdex-cli/src/hooks/uninstall.ts:200-233`, `236-286`.
- The installer’s current shell commands contain that URL in their fallback branch, so they remain discoverable.
- Empty Petdex-created event arrays and the resulting empty `hooks` object are removed: `uninstall.ts:252-276`.
- Slash-command files are deleted: `uninstall.ts:74-82`; `slash-command.ts:99-111`.
- Uninstall backs up JSON configuration before rewriting it: `uninstall.ts:227-233`, `307-313`.

What is not reversed:

- It does not remove or restore `[features] codex_hooks = true` in `~/.codex/config.toml`.
- It does not restore the timestamped original wholesale; it performs a selective rewrite.
- It retains `~/.petdex/bin/petdex.js`.
- It retains the runtime directory and killswitch.
- It retains `update-token` unless `--remove-token` is explicitly supplied: `uninstall.ts:92-106`.
- It retains timestamped backups.
- It only removes slash-command files, rather than restoring any previous file that happened to occupy the same path.

**Narrower supported conclusion:** hook installation is configuration-preserving and hook-entry removal is selective. It is not a complete rollback to the pre-install filesystem/configuration state.

---

## 3. Locality audit

## 3.1 Can the desktop display a pet with no Petdex backend?

**Yes, with qualifications.**

The renderer reads pets directly from:

- `~/.petdex/pets`
- `~/.codex/pets`

Resolution is in `packages/petdex-desktop/src/main.zig:2411-2431`.

It lists local directories, reads `pet.json` only for the display name, and reads a local `spritesheet.webp` or `.png`: `main.zig:2889-2910`, `2924-2956`.

Rendering uses copied local files under `~/.petdex/runtime/webview`: `main.zig:3087-3130`.

No account or login is required merely to render an already-installed pet.

However:

- A Node runtime is required for reactive agent state.
- The sidecar performs GitHub update checks by default.
- Telemetry may be sent after the first received agent state.
- Gallery installation and unknown `petdex://` slugs invoke the cloud-backed CLI.
- Without the sidecar, the pet can remain visible and draggable, but agent hooks cannot control it.

Therefore:

- **Zero Petdex backend:** yes.
- **Zero internet:** the basic renderer can display Ajman, but the stock app will still attempt update/telemetry network calls.
- **Zero Node/backend process:** only static desktop rendering; reactive functionality is lost.

## 3.2 Every desktop network touchpoint

### Localhost protocol

1. Sidecar listener:

   - `127.0.0.1:${PETDEX_PORT}`, default port 7777.
   - `packages/petdex-desktop/sidecar/server.ts:47-58`, `1285-1297`.

2. WebView health probe:

   - `GET http://127.0.0.1:7777/health`.
   - `packages/petdex-desktop/src/main.zig:958-989`.

3. Zig bridge update request:

   - `POST http://127.0.0.1:7777/update` via `curl`.
   - `main.zig:1987-2050`.

4. Zig bridge direct mascot-state request:

   - `POST http://127.0.0.1:7777/state` via `curl`.
   - `main.zig:2054-2132`.

5. Agent hook runner:

   - `POST /bubble` and `/state`.
   - `packages/petdex-cli/src/hooks/bubble-runner.ts:25-30`, `151-175`, `200-214`.

6. Hook fallback:

   - `curl POST /state`.
   - `packages/petdex-cli/src/hooks/agents.ts:606-623`.

7. CLI doctor:

   - `GET /health`.
   - `packages/petdex-cli/src/desktop/doctor.ts:90`.

8. Update handoff:

   - `POST /update/handoff`.
   - `packages/petdex-cli/src/desktop/update.ts:89`.

9. MCP hook server:

   - Local `/state`, `/bubble`, and `/health`.
   - `packages/petdex-cli/src/hooks/mcp-server.ts:72`, `295`.

### External desktop calls

10. GitHub releases check:

   - `https://api.github.com/repos/crafter-station/petdex/releases`
   - Initial check after 30 seconds, then every six hours.
   - `packages/petdex-desktop/sidecar/server.ts:60-75`, `524-560`.

11. Desktop update download:

   - Arbitrary `browser_download_url` returned by the GitHub release.
   - `packages/petdex-desktop/sidecar/server.ts:804-850`.
   - Download implementation: `packages/petdex-desktop/sidecar/update-utils.ts:92-160`.
   - Size and SHA-256 digest are verified, followed by Developer ID team/signature checks: `server.ts:684-698`, `739-789`, `876-913`.

12. Telemetry:

   - Default `https://petdex.dev/api/telemetry/event`.
   - Emitted once per sidecar session after the first accepted hook state, if local telemetry configuration permits.
   - `packages/petdex-desktop/sidecar/server.ts:163-217`.
   - The CLI creates enabled telemetry configuration by default: `packages/petdex-cli/src/telemetry.ts:120-143`.
   - Opt-out is supported through the config or `PETDEX_TELEMETRY=0`.

13. Gallery installation from the desktop:

   - The WebView invokes the persisted CLI for missing/deep-linked pets: `packages/petdex-desktop/src/main.zig:679-773`.
   - Zig spawns `node ~/.petdex/bin/petdex.js install <slug...>`: `main.zig:1688-1761`.
   - The CLI uses `PETDEX_URL`, default `https://petdex.dev`: `packages/petdex-cli/bin/petdex.ts:47-50`.
   - Manifest: `/api/manifest` — `petdex.ts:336`, `534`.
   - Sprite and manifest asset URLs from that manifest — `petdex.ts:370`, `523`.
   - Install counter: `/install/<slug>` — `petdex.ts:394`.

### Other CLI cloud calls

These are not needed by a local Ajman runtime, but are included because the desktop persists and invokes the full CLI bundle:

14. Auth config: `/api/cli/auth-config` — `packages/petdex-cli/bin/petdex.ts:70`.

15. Clerk OAuth:

   - Default issuer `https://clerk.petdex.dev`: `petdex.ts:49`.
   - `/oauth/token`: `packages/petdex-cli/src/cli-auth/lib/token-exchange.ts:87`.
   - `/oauth/userinfo`: `token-exchange.ts:159`.
   - Temporary callback listener on `127.0.0.1`: `packages/petdex-cli/src/cli-auth/lib/auth-server.ts:80`, `159-162`.

16. Pet edit:

   - `/api/pets/<slug>`, `/api/cli/edit-presign`, `/api/my-pets/<id>/edit`.
   - `petdex.ts:817`, `839`, `904`.

17. Submission:

   - `/api/cli/submit`, `/api/cli/submit/register`, `/api/cli/submit/check`.
   - Presigned upload URLs returned by the service.
   - `petdex.ts:1080`, `1127`, `1196`, `1222`.

18. CLI telemetry:

   - Same Petdex telemetry endpoint.
   - `packages/petdex-cli/src/telemetry.ts:37-39`, `204-237`.

19. Desktop binary installer:

   - GitHub releases API: `packages/petdex-cli/src/desktop/install.ts:31-37`, `161`, `312`.
   - Release asset download URLs: `desktop/install.ts:446-493`.
   - Petdex manifest and asset downloads: `desktop/install.ts:690`, `816`, `900`, `1074`.

## 3.3 Locality conclusion

The web/account/gallery coupling does **not** prevent the Zig renderer from loading Ajman locally. It is mostly in separate CLI and sidecar paths.

But a fully local fork must remove or replace:

- Gallery/deep-link install UI and bridge methods.
- The full persisted Petdex CLI.
- OAuth/submission/edit code.
- Telemetry.
- GitHub update polling and updater.
- Pet picker and dual registry.
- The Node sidecar, preferably.
- Petdex URL scheme and branding.

This is a meaningful extraction, not a configuration switch.

---

## 4. Pet format and Ajman compatibility

## 4.1 What the desktop actually reads

A pet is discovered when a child directory contains:

- `spritesheet.webp`, or
- `spritesheet.png`.

Relevant code: `packages/petdex-desktop/src/main.zig:2731-2754`, `2940-2956`.

`pet.json` is optional for rendering. It is parsed only for `displayName`, with malformed or oversized JSON falling back to the directory slug: `main.zig:2889-2910`.

The desktop does **not** read:

- `id`
- `description`
- `spritesheetPath`
- Animation definitions
- Frame size
- State rows
- FPS or per-state timing

Thus Ajman’s existing `pet.json` is acceptable but largely ignored.

## 4.2 Frame grid and state mapping

The desktop hardcodes:

- 8 columns.
- 9 rows.
- Canonical frame size 192×208.
- CSS `background-size: 800% 900%`.

Exact code: `packages/petdex-desktop/src/main.zig:68-75`, `253-264`.

Animation mapping:

| State | Row | Frames/timing |
|---|---:|---|
| `idle` | 0 | columns 0–5; delays 280, 110, 110, 140, 140, 320 ms, then multiplied by `slow: 6` |
| `running-right` | 1 | 8 frames, 120 ms each, last 220 ms |
| `running-left` | 2 | 8 frames, 120 ms each, last 220 ms |
| `waving` | 3 | 4 frames, 140 ms each, last 280 ms |
| `jumping` | 4 | 5 frames, 140 ms each, last 280 ms |
| `failed` | 5 | 8 frames, 140 ms each, last 240 ms |
| `waiting` | 6 | 6 frames, 150 ms each, last 260 ms |
| `running` | 7 | 6 frames, 120 ms each, last 220 ms |
| `review` | 8 | 6 frames, 150 ms each, last 280 ms |

Frame construction and animation loop: `main.zig:373-406`.

The root website has a related but not identical duration table at `src/lib/pet-states.ts:21-94`.

## 4.3 Ajman drop-in verdict

Ajman’s spritesheet is 1536×1872:

- 1536 / 8 = 192.
- 1872 / 9 = 208.

Therefore its image dimensions match the desktop’s hardcoded classic atlas exactly.

Its existing package contains the two required filenames:

- `pet.json`
- `spritesheet.webp`

**Verdict: Ajman should render without modifying either file**, provided his visual rows use the standard hatch-pet row mapping above.

Important limitation: compatibility follows from filenames and dimensions, not from Petdex honoring the schema. `spritesheetPath` is ignored and must still point, in practice, to the conventionally named local file.

## 4.4 8×11 claim

The latest repository commit says it adds hatch-pet v2 8×11 support, but this is **not desktop support**.

That commit modifies:

- `src/app/globals.css`
- `src/components/pets/pet-sprite.tsx`
- web submission validation/tests

It does not modify `packages/petdex-desktop`.

The desktop still hardcodes `ROWS = 9` and `background-size: 800% 900%`: `packages/petdex-desktop/src/main.zig:74`, `253`.

A 1536×2288 8×11 atlas will therefore be vertically rescaled/sliced incorrectly in Petdex Desktop.

**Handoff claim “compatible with Codex-style pet.json + spritesheet”:**

- True for conventional classic 8×9 spritesheets.
- Only partially true as a schema claim because `pet.json` animation/path metadata is ignored.
- False for current hatch-pet v2 8×11 desktop rendering.

---

## 5. Agent events and animation mapping

### Claude Code

Defined at `packages/petdex-cli/src/hooks/agents.ts:181-272`:

| Claude event | State |
|---|---|
| `UserPromptSubmit` | `jumping`, 800 ms |
| `PreToolUse` for Read/Grep/Glob | `review` |
| Other `PreToolUse` | `running` |
| `PostToolUse` | `idle` |
| `Notification` | `waiting` |
| `Stop` | `waving`, 1500 ms |

Read/Grep/Glob classification is performed in the runner: `packages/petdex-cli/src/hooks/bubble-runner.ts:38-59`.

### Codex CLI

Defined at `packages/petdex-cli/src/hooks/agents.ts:276-450`:

| Codex event | State |
|---|---|
| `UserPromptSubmit` | `jumping`, 800 ms |
| `PreToolUse` for Read/Grep/Glob | `review` |
| Other `PreToolUse` | `running` |
| `PostToolUse` | `idle` |
| `PermissionRequest` | `waiting` |
| `Stop` | `waving`, 1500 ms |

### Other supported sources

The registry also contains Gemini CLI, OpenCode and Antigravity integrations beginning at `agents.ts:452`.

Antigravity uses an MCP server and installed skill rather than ordinary hooks: `packages/petdex-cli/src/hooks/install.ts:364-449`.

### State processing

- The localhost protocol accepts `idle`, `running`, `running-left`, `running-right`, `waving`, `jumping`, `failed`, `review`, and `waiting`: `packages/petdex-desktop/sidecar/server.ts:78-88`.
- Bare `running` alternates left/right directions: `server.ts:1058-1066`.
- Events go through a bounded queue with dwell/coalescing behavior: `server.ts:266-296`; implementation in `packages/petdex-desktop/sidecar/state-queue.ts`.
- Non-idle states may carry a duration capped to 30 seconds: `server.ts:1050-1053`.

### Missing observation

There is no integration for the **Codex Desktop application itself** in the reviewed hook registry. The “codex” agent is explicitly labeled “Codex CLI”: `agents.ts:276-281`.

Thus the fork would cover:

- Codex CLI.
- Claude Code.
- Other hook-capable CLIs.

It would not automatically observe the separate Codex desktop pet/session activity. That needs a new integration, likely through supported desktop hooks if available, session-file observation, or another documented local event source.

---

## 6. Maturity and build complexity

### Repository maturity

As of the audit:

- 730 commits.
- Repository created 2026-05-02.
- Oldest commit in this checkout: 2026-05-01.
- Latest commit: 2026-07-11.
- 3,305 stars and 130 forks.
- 18 open issue/PR objects reported by GitHub; 11 were open issues in the fetched issue list.
- 14 published desktop releases from `desktop-v0.1.0` through `desktop-v0.2.2`.
- Latest desktop release: 2026-06-04.
- Latest repository work is more recent than the latest desktop release.

Sources: [repository metadata](https://github.com/crafter-station/petdex), [releases](https://github.com/crafter-station/petdex/releases), [open issues](https://github.com/crafter-station/petdex/issues).

This is a fast-moving, young project rather than a long-stabilized desktop framework.

### Desktop build requirements

- macOS.
- Zig 0.16: `packages/petdex-desktop/build.zig.zon:4-5`.
- Xcode SDK tools through `xcrun`: `packages/petdex-desktop/build.zig:147-179`.
- Separate zero-native checkout.
- Node ≥18 at runtime.
- Bun to rebuild the sidecar.
- Apple signing and notarization credentials for releases.
- `vtool`, `codesign`, `notarytool`, `stapler`, `hdiutil`, `ditto`: `packages/petdex-desktop/scripts/build-release.sh:21-115`.

The release script:

- Builds separate arm64 and x86_64 binaries.
- Sets macOS 13.0 as the minimum.
- Signs binary and `.app`.
- Uses hardened runtime.
- Notarizes and staples the app and DMG.
- Produces architecture-specific DMGs.

Exact packaging: `packages/petdex-desktop/scripts/build-release.sh:36-115`; app metadata: `packages/petdex-desktop/assets/Info.plist.template:17-35`.

### Verification limitation

Zig is not installed in the audit environment. Per the user’s prohibition, no compiler or dependency was installed. Consequently:

- Zig build: not run.
- Zig tests: not run.
- Packaged app: not launched.
- UI behavior: inspected statically only.

---

## 7. macOS overlay quality

Petdex requests:

- 140×180 window.
- Non-resizable.
- Restored frame.
- Frameless.
- Transparent.
- Always on top.

See `packages/petdex-desktop/src/main.zig:3303-3312`.

The bundled app is an accessory app with no Dock icon through `LSUIElement`: `packages/petdex-desktop/assets/Info.plist.template:32-35`.

The actual behavior resides in the external zero-native fork, not the Petdex repository. At audited zero-native commit `c85ec92`:

- Frameless, non-focusable windows become a borderless `NSPanel` with `NSWindowStyleMaskNonactivatingPanel`.
- Transparent windows use `opaque = NO`, clear background, no shadow.
- Always-on-top uses `NSFloatingWindowLevel`.
- It sets:
  - `NSWindowCollectionBehaviorCanJoinAllSpaces`
  - `NSWindowCollectionBehaviorFullScreenAuxiliary`
  - `NSWindowCollectionBehaviorIgnoresCycle`
- It does not hide when Petdex deactivates.

External dependency path and lines:

- `zero-native/src/platform/macos/appkit_host.m:316-361`.

This is good evidence for:

- Always-on-top behavior.
- Appearance on all Spaces.
- Presence beside full-screen apps.
- Nonactivating mascot behavior.

### Multi-monitor behavior

Movement clamping uses:

```text
window.screen ?: NSScreen.mainScreen
```

and clamps to that screen’s `visibleFrame`:

- `zero-native/src/platform/macos/appkit_host.m:1078-1105`.

This is sensible for a window already associated with a display. The Petdex JavaScript passes `clampToVisibleFrame` during momentum movement: `packages/petdex-desktop/src/main.zig:998-1006`.

What static review cannot prove:

- Correct behavior when a high-velocity drag crosses display boundaries.
- Mixed-scale Retina/non-Retina positioning.
- Display unplug/reconfiguration behavior.
- Whether restored coordinates always move to the appropriate display.
- Mission Control and full-screen transitions under real use.

### Quality concern

The production system-WebKit backend enables Web Inspector/developer extras:

- `zero-native/src/platform/macos/appkit_host.m:379-384`.

That is unnecessary for an Ajman production build and should be disabled.

---

## 8. Security review

## 8.1 Localhost listener

- Address: `127.0.0.1`.
- Default port: 7777.
- Bind: `packages/petdex-desktop/sidecar/server.ts:1285-1297`.
- It is not exposed on LAN interfaces.

Unauthenticated read endpoints include:

- `/health`
- `/whoami`
- `/state`
- `/bubble`
- `/update`
- `/init-status`

`/whoami` exposes the sidecar PID and desktop parent PID: `server.ts:977-991`.

State-changing endpoints require `X-Petdex-Update-Token`:

- `/state`: `server.ts:1006-1019`.
- `/bubble`: `server.ts:1107-1117`.
- `/update`: `server.ts:1220-1229`.
- `/update/handoff`: `server.ts:1174-1190`.

The token:

- Is 32 random bytes encoded as hex.
- Is held in memory.
- Is persisted only after successful bind.
- Is written mode 0600.
- Is compared using a timing-safe comparison.

See `server.ts:124-151`, `219-225`.

This substantially mitigates browser-driven localhost CSRF.

## 8.2 Payload handling

Positive controls:

- HTTP bodies are capped at 64 KiB: `server.ts:59`, `354-375`.
- State is allowlisted: `server.ts:78-88`, `1042-1048`.
- Duration is numeric and capped at 30 seconds: `server.ts:1050-1053`.
- `agent_source` is limited to 64 characters: `server.ts:1054-1057`.
- Bubble text is limited to 200 characters: `server.ts:1125-1137`.
- POST state/bubble share a token-bucket rate limiter: `server.ts:92-121`, `1027-1029`, `1116-1117`.
- Hook stdin is capped at 64 KiB: `packages/petdex-cli/src/hooks/bubble-runner.ts:31`, `61-80`.
- Pet sprites are capped at 16 MiB: `packages/petdex-desktop/src/main.zig:24`, `2946-2953`.
- Pet display names are JSON- and script-context escaped: `main.zig:3039-3075`.
- Runtime WebView files are placed under private per-user directories, not predictable shared temp paths: `main.zig:3087-3110`.

## 8.3 Command-injection surface

The deep-link/gallery installer does not construct a shell string. It passes slugs as argv elements to `std.process.spawn`: `main.zig:1727-1757`.

Slugs are restricted to 1–64 ASCII letters, digits, hyphen or underscore: `main.zig:2497-2506`.

That removes ordinary shell injection and path traversal through the slug.

The updater also uses argument arrays rather than a shell: `packages/petdex-desktop/sidecar/server.ts:643-681`.

The principal residual code-execution surfaces are intentional:

- The app runs `node ~/.petdex/bin/petdex.js`.
- Hook configurations execute shell fragments on every agent event.
- The sidecar updater downloads and replaces the app.
- The slash command instructs agents to execute the persisted CLI.

The updater has meaningful protections:

- GitHub-provided SHA-256 digest and exact size.
- `codesign --verify --deep --strict`.
- `spctl`.
- Developer ID Application authority.
- New app team identifier must equal the current app’s team identifier.

See `server.ts:684-698`, `739-789`, `845-913`.

## 8.4 Accessibility and AppleScript

No Accessibility API, `AXUIElement`, `osascript`, or AppleScript usage was found in the relevant desktop or hook packages.

The app does register a custom URL scheme handled through Apple Events, but that is not Accessibility automation: `packages/petdex-desktop/src/main.zig:3188-3197`; URL declaration at `packages/petdex-desktop/assets/Info.plist.template:19-29`.

## 8.5 Security concerns to address in a fork

1. Remove the unauthenticated diagnostic endpoints if not needed, especially PID disclosure.
2. Disable Web Inspector in production.
3. Replace the fixed port with a per-user Unix domain socket or dynamically selected localhost port.
4. Avoid spawning a full persisted gallery CLI from the desktop.
5. Eliminate enabled-by-default telemetry.
6. Remove the automatic updater until the Ajman app has its own signing/release channel.
7. Make hook identity detection structural, not URL-substring-based.
8. Add a complete uninstall manifest and restore behavior.
9. Keep the existing body, state, duration, and rate limits if HTTP remains.

---

## 9. REUSE list

### Reuse directly or port closely

1. `packages/petdex-cli/src/hooks/agents.ts`

   Why: the most valuable source of verified agent event names and mappings for Claude Code and Codex CLI.

   Port only the relevant Claude/Codex definitions, not gallery, Gemini, OpenCode or Antigravity infrastructure unless later required.

2. `packages/petdex-cli/src/hooks/bubble-runner.ts`

   Why: bounded stdin handling, tool classification, and state mapping are good reference behavior.

   Rewrite it as a tiny Ajman notifier rather than persisting the complete Petdex CLI.

3. `packages/petdex-cli/src/hooks/bubble-templates.ts`

   Why: optional concise activity captions. Review privacy expectations before showing command/file-derived text.

4. `packages/petdex-desktop/sidecar/state-queue.ts`

   Why: queue bounding, event coalescing, and minimum dwell avoid animation thrash during rapid tool sequences.

5. `packages/petdex-desktop/src/main.zig:253-264`, `373-406`

   Why: authoritative classic 8×9 row/frame timing reference for Ajman’s current sheet.

6. `packages/petdex-desktop/sidecar/server.ts:78-88`, `1006-1089`

   Why: state allowlist, duration cap, rate limiting, and `running` direction alternation are useful protocol design references.

7. `packages/petdex-desktop/src/main.zig:2497-2506`

   Why: simple safe slug validation if any named local-pet handling remains.

8. `packages/petdex-desktop/src/main.zig:3039-3075`

   Why: careful escaping if any untrusted local metadata is embedded into HTML.

9. `packages/petdex-desktop/scripts/build-release.sh:36-115`

   Why: reference for Developer ID signing, notarization and stapling requirements, although a Swift/Xcode project should implement these through a simpler native archive/export pipeline.

10. External zero-native AppKit behavior at `src/platform/macos/appkit_host.m:316-361`

    Why: it documents the correct AppKit concepts for a nonactivating, transparent, all-Spaces floating mascot. Reimplement these directly in AppKit rather than retaining zero-native.

---

## 10. AVOID list

1. `packages/petdex-desktop/src/main.zig`

   Why: 3,724 lines mix asset loading, HTML/CSS/JS, pet discovery, deep links, process spawning, settings, updater bridging, window physics, file persistence, and security policy. It is expensive to simplify safely.

2. `packages/petdex-desktop/sidecar/server.ts`

   Why: 1,522 lines mix state transport, persistence, telemetry, updates, process supervision, signature verification and diagnostics. Ajman does not need most of it.

3. `packages/petdex-cli/bin/petdex.ts`

   Why: carries gallery browsing, installs, auth, edits, submissions, desktop management and telemetry. Persisting the entire CLI merely to send state events is excessive.

4. `packages/petdex-cli/src/desktop/install.ts`

   Why: Petdex-specific release discovery, gallery manifest, dual pet registries and binary/sidecar installation.

5. `packages/petdex-cli/src/cli-auth/`

   Why: Ajman-only local operation needs no Clerk account or OAuth callback listener.

6. `packages/petdex-cli/src/telemetry.ts`

   Why: a private local mascot should be silent by default.

7. `packages/petdex-desktop/sidecar/update-utils.ts` and updater sections of `server.ts`

   Why: coupled to Petdex’s GitHub release lineage and signing identity.

8. Pet picker/gallery/deep-link sections in `main.zig:624-787`, `1089-1357`, `1688-1775`

   Why: irrelevant to a single immutable Ajman asset and a source of network/process complexity.

9. External zero-native fork as a production dependency

   Why: separate manual checkout, experimental branch, Zig 0.16 coupling, and substantial framework surface for what AppKit can implement directly.

10. Root Next.js application and backend

    Why: no role in an Ajman-only local desktop product.

---

## 11. Fork effort versus a native Swift app

## Option A: strip down Petdex Desktop

Realistic work:

- Extract Ajman loading and animation from `main.zig`.
- Remove pet picker, dual registry and dynamic installs.
- Remove all Petdex deep links.
- Remove settings/update UI.
- Remove GitHub updater and telemetry.
- Replace the full CLI with a dedicated hook notifier.
- Decide whether to retain Node sidecar.
- Vendor/pin zero-native or replace it.
- Rename identifiers, bundle ID, paths and runtime files.
- Build a complete hook uninstall/restore path.
- Add Codex Desktop observation.
- Rebuild signing/notarization infrastructure.
- Add characterization tests before removing intertwined code.

Estimated effort:

- **2–4 experienced engineer-weeks** for a credible, tested local fork if zero-native and Node are retained.
- **4–6 weeks** if the fork also removes Node or replaces zero-native while preserving existing behavior.
- Continued risk from inherited complexity and a less common Zig desktop toolchain.

## Option B: small native Swift/AppKit app

Suggested architecture:

- `NSPanel` or borderless `NSWindow`, transparent and nonactivating.
- `.floating` level.
- `.canJoinAllSpaces`, `.fullScreenAuxiliary`, `.ignoresCycle`.
- `NSImage`/Core Animation sprite rendering from the bundled Ajman sheet.
- One typed `AjmanState` enum.
- One animation table defining row, frames and timing.
- A local Unix socket or authenticated loopback endpoint.
- Tiny standalone Claude/Codex hook helper.
- `LaunchAgent` or normal login-item management only if explicitly wanted.
- Bundled asset, no gallery, no account, no telemetry.
- Native menu for pause, launch at login and quit.
- Direct Xcode signing/notarization.

Estimated effort:

- **About 1–2 engineer-weeks** for a polished first version supporting Claude Code and Codex CLI.
- Add approximately **several days to two weeks** for robust Codex Desktop observation, depending on what documented event surface is available.
- Lower runtime footprint, no Node requirement, no WebView, no extra framework checkout, and much clearer ownership.

### Comparative conclusion

Petdex already solved several hard discovery questions—agent hook names, animation states, all-Spaces window flags—but its implementation is larger than Ajman’s product.

The optimal strategy is therefore:

> Treat Petdex as a behavioral specification and code-reference repository, not as the shipping application base.

---

## 12. Final fork verdict

### Is it fork-able?

**Technically yes. Strategically, not as a whole-product fork.**

The web/account/gallery coupling is separable enough that it can be removed, but the desktop’s internal coupling and external runtime/toolchain dependencies make that extraction costlier than a focused Swift implementation.

### Recommended course

1. Bundle Ajman’s existing `pet.json` and `spritesheet.webp` unchanged.
2. Implement the classic 8×9 animation table natively.
3. Port Claude and Codex hook event definitions.
4. Use a narrow local authenticated transport.
5. Do not include Petdex’s gallery, account, updater, telemetry, pet registry or full CLI.
6. Investigate a supported Codex Desktop event interface separately; do not assume Codex CLI hooks cover it.
7. Retain Petdex’s MIT attribution for any copied code and Apache-2.0 notices if zero-native code is copied rather than merely reimplemented from AppKit concepts.

Overall confidence in this verdict: **high**.

---

## 13. Claims from the handoff that proved false or misleading

1. **“Hooks install/uninstall is clean and reversible.”**

   **False as stated.** Hook entries are selectively removable, but Codex’s feature flag is not reverted, persisted CLI/runtime files remain, the token remains by default, and overwritten slash-command files are deleted rather than restored.

2. **“Desktop is a Zig/WebKit floating mascot.”**

   **Confirmed**, but incomplete: it also requires a separately installed Node runtime and a substantial Node sidecar for reactive operation.

3. **“Node sidecar.”**

   **Confirmed.** It listens on localhost:7777, persists state/bubbles, handles telemetry and performs updates.

4. **“Compatible with Codex-style pet.json + spritesheet.”**

   **Partially true.** Classic 8×9 assets with conventional filenames work, and Ajman’s dimensions match. The desktop ignores almost all of `pet.json`; it is filename/grid compatibility rather than full schema compatibility.

5. **Implicit broad hatch-pet compatibility after the latest commit.**

   **False for Desktop.** The 8×11 change only updates the web viewer and validation. Desktop remains hardcoded to 8×9.

6. **Implicitly fully local desktop.**

   **False for the stock app.** Local rendering works, but the sidecar checks GitHub, telemetry can be sent, missing-pet flows call Petdex services, and agent reactivity requires Node.

7. **Implicit Codex-wide integration.**

   **Misleading.** The implemented hook target is “Codex CLI,” not the Codex Desktop application.

---

## 14. COULD-NOT-VERIFY

1. A successful Zig build: Zig was unavailable and installing it was prohibited.
2. A successful clean build against zero-native: statically inspected only.
3. Visual correctness of Ajman in the running app.
4. Runtime window behavior across real multi-monitor arrangements.
5. Space/full-screen behavior under Mission Control, though the correct AppKit flags are present.
6. Dragging across displays with mixed scale factors.
7. CPU/memory use of the Zig + WebKit + Node combination.
8. Whether current released DMGs exactly match the reviewed source commit.
9. Current notarization validity of published DMGs; the release script performs notarization, but the artifacts were not downloaded and checked.
10. Complete transitive license closure of Bun-bundled CLI dependencies. Direct licenses were verified; no dependency tree was installed.
11. Whether Codex Desktop now exposes a documented hook/event mechanism compatible with the CLI hooks.
12. Whether Ajman’s actual row artwork follows the standard row-to-state convention; dimensions and filenames match, but the image itself was outside the permitted workspace and was not inspected.
