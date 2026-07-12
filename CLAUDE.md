# Ajman (desktop mascot) — project rules

One persistent macOS mascot (Ajman the tuxedo cat) reacting to AI coding agents.
Architecture and staged plan: docs/ARCHITECTURE-REVIEW.md. Evidence: docs/research/.

## Build (canonical — house rule: ONE build location)
- Canonical build output: `build/` (app bundle at `build/Ajman.app`); SPM intermediates in `.build/`.
- Build command: `scripts/build-app.sh` (release build + bundle assembly + root symlink refresh).
- Launchable app: `Ajman.app` symlink at repo root → `build/Ajman.app`. Keep it working.
- Dev loop: `swift build` / `swift run` (runs as accessory app without a bundle).

## Constraints
- Swift/AppKit only, zero SPM dependencies, macOS 14+.
- No metered AI APIs at runtime — ever (see ~/Developer/CLAUDE.md).
- Passive operation (animation, hearing agents) requires NO Accessibility permission and no network egress. Accessibility is owner-approved (2026-07-12) for opt-in features that benefit — precise window/tab focus targeting, and focus-based alert dismissal — but keep it optional: the pet must still work fully without it.
- The pet asset is the user's: read from `~/.codex/pets/ajman/`, bundle-copy as fallback, never regenerate or modify it.
- Ajman canon (owner-confirmed 2026-07-11): tuxedo cat, yellow-green eyes, white paws/bib, and a NOTCHED/tipped LEFT ear (rescue tip; the cat's OWN left ear = the viewer's right when he faces forward) — match the reference portrait in `assets/imports/2026-06-30 original/`. Art without the ear-tip is draft-only and must be labeled DRAFT.
- Winnie canon (owner-confirmed 2026-07-12): brown mackerel tabby, yellow-green eyes, pink collar with a round tag, forehead "M" + cheek stripes, ringed tail, and — like Ajman, and on the SAME ear — a REAL TIPPED LEFT ear (rescue TNR ear-tip on the cat's OWN left ear = the viewer's right when she faces forward). The tip is authentic and MUST appear in her art; do NOT "correct"/remove it. Her current hatch sheet is MISSING the ear-tip and is therefore wrong on that point; art of Winnie without the ear-tip is a defect to fix, not preserve.
- Any code lifted from Masko (MaTriXy/masko-code) or Petdex (crafter-station/petdex) keeps an MIT attribution header and a line in NOTICE.
