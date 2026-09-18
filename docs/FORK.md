# What this fork changes, and why

Forked from [Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless) at **v1.2.7**
(`2a690e5`). Upstream is a polished public product; this is a personal tool. That single
difference explains most of what follows — a personal build can make choices a public one
can't, starting with "the user will happily run one command in Terminal".

Where a change came from another fork, it's credited. Upstream's fork tree turned out to be
where the real bug reports live: nine forks, six with commits, and three of them independently
fixed the same unreported bug.

---

## 1. The app never runs code as root

**Removed:** `installGrantViaAuth()` — upstream's one-click setup, which ran the bundled
`grant.sh` as root through `osascript`'s `do shell script … with administrator privileges`.

**Why:** a `.app` bundle is user-writable. Executing a script out of `Contents/Resources` as
root is a substitution/TOCTOU surface for the one privilege escalation the app has. Upstream's
own [SECURITY.md](../SECURITY.md) and [AUDIT.md](AUDIT.md) describe the `pmset` call in detail
and never mention this path at all.

Two concrete bugs lived in it, both found by [bagbag](https://github.com/bagbag/Sleepless):

- **Quoting.** The AppleScript was built by string interpolation, escaping only `\` and `"`.
  The username and bundle path sat inside *single* quotes that were never escaped, so a path
  containing an apostrophe (`/Users/me/Bob's Apps/`) broke out of the shell string — inside a
  command running with administrator privileges.
- **Cancel detection.** It treated exit `128` as "user cancelled". `osascript` exits **1** on
  AppleScript error `-128`, so cancelling the Touch ID sheet showed a failure alert.

bagbag fixed both. This fork deletes the feature instead, which is cheaper and strictly safer,
and costs a personal user one `./grant.sh` per machine. The argument is
[zallennnn](https://github.com/zallennnn/Sleepless)'s; the bug evidence is bagbag's.

Consequently `build.sh` no longer copies `grant.sh` and `uninstall.sh` into the bundle. Nothing
executes them from there any more, and shipping a privileged-install script inside a writable
bundle would just rebuild the surface.

## 2. The UI no longer lies about state

`switchToggled` forced the switch to `.off` after *any* failed toggle. A failed turn-**off**
therefore displayed "asleep" while the Mac was still being kept awake — the one direction where
being wrong is dangerous. It now resyncs to the real system state, and `performToggle` surfaces
the `.failed` case in both directions instead of swallowing it.

Credit: bagbag.

## 3. Every safety net fails closed

The battery floor, Low Power Mode auto-off and auto-off timer all called `setDisableSleep(false)`,
**discarded the result**, and notified "turned off" unconditionally. If the privileged call
failed, the Mac stayed awake and the app said the opposite. That's upstream issue
[#3](https://github.com/Aboudjem/Sleepless/issues/3).

All three now route through one `turnOffForSafety()` that reports failure and stays armed. The
battery and LPM nets re-evaluate on the 60s poll; the auto-off timer, being one-shot, explicitly
reschedules itself — without that, a single transient `pmset` failure defeated it permanently.

Credit for the timer case: bagbag. The shared helper and the battery/LPM cases are this fork's.

## 4. The display goes off when the lid closes

**The best find in the fork tree.** With `SleepDisabled` set, closing the lid skips the normal
sleep path, so the built-in panel can stay powered: a lit screen in a closed bag, burning
battery and making heat — in the exact scenario the app exists for. A second consequence
nobody wrote down: **the Mac never locks**, because the password prompt hangs off sleep or
display-off. You carry an unlocked laptop around.

Three forks fixed this independently — bagbag, [michalekmatej](https://github.com/michalekmatej/Sleepless),
zallennnn — and **no issue was ever filed**. Their approaches differ, and the differences matter:

| Fork | Approach | Verdict |
|---|---|---|
| michalekmatej | unprivileged `pmset displaysleepnow`, polled at 1 Hz | right call, crude trigger |
| bagbag | unprivileged `displaysleepnow`, clamshell darwin notification; plus private `DisplayServices` dlopen to dim the panel when an external display is attached | best trigger, private API is too much |
| zallennnn | `sudo pmset displaysleepnow`, added a **third** sudoers entry | unnecessary privilege |

`displaysleepnow` is an *action*, not a setting, and `pmset(1)` requires root only for settings.
So this fork takes the unprivileged call (michalekmatej, bagbag) on the darwin notification
(bagbag), with no sudoers change and no private frameworks. Skipped when an external display is
attached — that's ordinary clamshell mode and macOS already handles it.

> **Unverified.** The notification registration and `AppleClamshellState` were confirmed to work
> on macOS 27.0 (26A428), but the actual lid-close behaviour has not been tested on hardware.
> Test it before trusting it in a bag.

## 5. The sudoers grant is harder to trick

From bagbag's `grant.sh`:

- The username is validated (`[A-Za-z0-9._-]+`, must resolve to an existing non-root account)
  **before** being `sed`-substituted into a sudoers file.
- An explicit `SLEEPLESS_USER=root` is refused rather than silently replaced by a guess.
- The inline fallback grant string is gone. It duplicated the template, so the two could drift —
  upstream issue [#4](https://github.com/Aboudjem/Sleepless/issues/4).
- The temp file is `trap`ped on EXIT instead of leaking on failure paths.
- Absolute binary paths while running as root.

`install.sh` also stops writing its own LaunchAgent, so the app's `SMAppService` switch is the
only owner of the login item instead of two competing sources of truth (also issue #3).

## 6. Menu-bar icon stability

Cherry-picked verbatim from [g150446](https://github.com/g150446/Sleepless) (`ffd7dad`, open
upstream as PR [#5](https://github.com/Aboudjem/Sleepless/pull/5)). SF Symbols carry alignment
insets, so swapping `cup.and.saucer` ↔ `cup.and.heat.waves.fill` shifted and could clip the
glyph; the fix rasterizes every state onto one fixed canvas and pins the item with
`squareLength` + an `autosaveName`. Addresses upstream issue
[#2](https://github.com/Aboudjem/Sleepless/issues/2).

## 7. Product scaffolding removed

Deleted: five translated READMEs, the `docs/` site, the release workflow, issue and PR
templates, the code of conduct, and the marketing assets. Kept: `SECURITY.md`, `docs/AUDIT.md`,
and the CI workflow — CI's zero-warning gate is genuinely useful.

Upstream's README is preserved verbatim as [README.upstream.md](../README.upstream.md).

---

## Deliberately NOT taken

| From | Change | Why not |
|---|---|---|
| bagbag | `DisplayServices` dlopen to dim the built-in panel under an external display | private framework; the unprivileged `displaysleepnow` covers the case that matters |
| zallennnn | battery-floor auto-**resume** above the floor | upstream's "never auto re-arm" is the safer default; re-arming on its own is how you end up flat |
| zallennnn | third sudoers entry for `displaysleepnow` | unnecessary — the command needs no root |
| michalekmatej | revert v1.2.7's steam icon to the filled cup | taste, not a fix |
| michalekmatej | in-binary CLI (`on/off/toggle/status/timer`) | **wanted**, but to be written here rather than cherry-picked — see [LEASE-DESIGN.md](LEASE-DESIGN.md) |
| g150446 | 15m / 30m timer choices + vertical segmented layout | fine, but upstream closed PR #6; revisit once the lease lands and the timer UI changes anyway |
| theshaneyu | "Claude Remote Control" server (+568 lines) | a feature, not a fix |

## Open decisions

- **Bundle ID** is still `com.aboudjem.Sleepless`. Fine while only one build is installed;
  change it if upstream's is ever installed alongside.
- **`SECURITY.md:113`** says Sleepless is "direct-download / Homebrew only". There is no
  Homebrew cask for this fork.
- **`CHANGELOG.md`** still ends at upstream's v1.2.7. This fork's history is the git log.
