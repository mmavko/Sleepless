# Chronicles — Digest
Last updated: 2026-09-18
Last reconciled: 2026-09-18

## Current State

Personal fork of [Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless) (macOS menu-bar app
that keeps the Mac awake with the lid closed, on battery, via `pmset disablesleep`). 27 commits
ahead of upstream v1.2.7, CI green, 66 tests.

**Two docs are the source of truth and this digest deliberately does not repeat them:**
- [docs/FORK.md](../docs/FORK.md) — every difference from upstream, with its source and reasoning.
- [docs/LEASE-DESIGN.md](../docs/LEASE-DESIGN.md) — the lease/watchdog design, all five steps.

All five planned steps have landed: lease format + watchdog agent, GUI renewal, `sleepless` CLI,
Claude Code hook integration, and thermal as instrumentation. Installed and running on Myron's
machine with the grant, the watchdog and the hook all live.

Build: `./build.sh <dest>` (swiftc, no Xcode project); install: `./install.sh`; tests:
`./tests/watchdog-selftest.sh`. CI runs the shell syntax check and the self-test.

**Next, when it comes up:** thermal has a corpus but no lid-closed sessions yet, so it cannot yet
say anything. `sleepless report` will keep saying *untested* until the app is actually used with
the lid shut.

## Invariants & Locked Decisions

- The app never runs bundled code as root. Privilege setup is a reviewed `./grant.sh` in Terminal;
  upstream's one-click auth sheet is deleted, not hardened. → entries/2026-09-18-1310-fork-and-strip-upstream.md
- The dead-man switch is a user LaunchAgent, not a root daemon: it clears the flag through the
  grant the app already has, so it adds **zero** new privilege. → entries/2026-09-18-1430-launchagent-not-daemon.md
- The watchdog can only ever make the Mac sleepier. No code path in it sets `disablesleep` to 1.
  → entries/2026-09-18-1430-launchagent-not-daemon.md
- `disablesleep` is held by a renewed **lease**, never latched. Expiry is the mechanism; release is
  only a courtesy. → entries/2026-09-18-1700-hook-design-collapsed.md
- Lease `extend` is a floor (`max`), never an assignment. This is what lets parallel Claude
  sessions share one lease file with no holder ids and no locking. → entries/2026-09-18-1700-hook-design-collapsed.md
- The Claude Code hook `extend`s only; it never arms keep-awake. It replaces the *timer*, not the
  *switch*. → entries/2026-09-18-1700-hook-design-collapsed.md
- The switch is the single source of "is it on". Configuration must never imply state: macOS
  resets `disablesleep` on every boot, so a config that meant "on" would have to re-arm at login.
  → entries/2026-09-18-1700-hook-design-collapsed.md
- Thermal is measured, not enforced; the session summaries are never rotated, and `uninstall.sh`
  keeps them. → entries/2026-09-18-1810-thermal-instrument-not-enforce.md
- Every value crossing the Swift/shell boundary has a test, not an assumption. Shared shell
  primitives live in `leaselib.sh` — one copy to get wrong. → entries/2026-09-18-1520-boot-time-greedy-sed.md
- Safety nets fail **closed**: a failed privileged call is reported and stays armed, never
  announced as success. → docs/FORK.md §3

## Gotchas (still bite)

- **`defaults` ignores `HOME`** (it goes through `cfprefsd`), so tests need a throwaway domain and
  must delete the plist, not just the domain. → entries/2026-09-18-1930-facts-that-resist-verification.md
- **macOS names a login item after launchd's `program`.** Keep the interpreter out of
  `ProgramArguments` or System Settings says "bash". `sfltool dumpbtm` needs admin, so check with
  `launchctl print` instead. → entries/2026-09-18-1930-facts-that-resist-verification.md
- **The agent cannot see the popover.** Layout and visual state are Myron's to verify; the agent
  checks the arithmetic and states plainly what it could not confirm. → entries/2026-09-18-1930-facts-that-resist-verification.md
- **UI lifecycle bugs are unreachable from shell tests.** The suite greps `App.swift` for shape
  instead (ticker ownership, journal keys, uninstall behaviour), mutation-verified.
  → entries/2026-09-18-1930-facts-that-resist-verification.md
- **A self-consistent wrong answer is the failure mode here** — two shell scripts agreeing with
  each other proved nothing. A test that inlines a copy of the code under test is the same trap.
  → entries/2026-09-18-1520-boot-time-greedy-sed.md
- **`PostToolUse` fires when a background command *starts*, not while it runs**, so a long
  background job looks idle to both the hook and the transcript fallback. Manual
  `sleepless extend 2h` is the answer. → entries/2026-09-18-1700-hook-design-collapsed.md

## Open Questions

- Lid-close display sleep (`pmset displaysleepnow` on the clamshell notification) has never been
  tested on hardware. The clamshell notification and `AppleClamshellState` were confirmed to work;
  the actual lid-close behaviour was not.
- Whether the Low Power Mode stop condition is wanted at all now that it is opt-in and off by
  default — nobody has turned it on yet.
- Whether the login item should read "Sleepless" rather than "SleeplessWatchdog". That needs
  `SMAppService.agent(plistName:)` with the plist inside the app bundle, and depends on signing
  behaviour that has not been tested.
