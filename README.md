# Sleepless (personal fork)

A macOS menu-bar toggle that keeps the Mac running with the lid closed, on battery, with no
external display — by flipping the kernel's `SleepDisabled` flag via `pmset disablesleep`.

This is a personal fork of **[Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless)** by
Adam Boudjemaa (MIT). All the hard-won mechanism is his. This fork trades the polished public
product for a smaller, stricter personal tool.

- **What's different, and why:** [docs/FORK.md](docs/FORK.md)
- **Upstream's original README**, kept verbatim: [README.upstream.md](README.upstream.md)
  (its Homebrew install, badges and comparison table apply to upstream, not here)

## Why this exists at all

`disablesleep` is only *needed* for one narrow case: **lid closed, on battery, no external
display**. Plug in power or attach a display and macOS clamshell mode already does the job.
Keeping that scope explicit is what stops the app growing into a power manager.

## Install

```bash
./build.sh /Applications && ./grant.sh
```

`build.sh` compiles `App.swift` with `swiftc` and hand-assembles an ad-hoc-signed bundle —
no Xcode project, no downloaded blobs.

`grant.sh` installs one `/etc/sudoers.d` drop-in (root:wheel, 0440) permitting exactly two
fully-specified commands and nothing else:

```
<you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 0, /usr/bin/pmset -a disablesleep 1
```

Run it yourself, once per machine. **The app never installs it** — see
[docs/FORK.md](docs/FORK.md) for why that path was deleted rather than fixed.

`./uninstall.sh` removes the app, the login item and the grant, then proves the grant is gone.

## Safety nets

`disablesleep` is global kernel state that no process owns. If nothing turns it off, nothing
turns it off. So:

| Net | Behaviour |
|---|---|
| Battery floor | Turns off at 5–50% on battery (default 15%). Beats a deliberate turn-on. |
| Low Power Mode | Steps aside when LPM is on and discharging, unless you deliberately turned it on. |
| Auto-off timer | 1h / 2h with a live countdown. Retries if the privileged call fails. |
| Lid close | Puts the built-in display to sleep, so a closed laptop isn't lit, hot and unlocked. |
| Reboot | macOS resets `disablesleep` to 0. This is the only net that survives the app dying. |

Every net now **fails closed**: if the privileged call fails, the app says so and stays armed
rather than announcing a turn-off that never happened.

## Known gaps

- **No dead-man switch.** Quit or crash the app while it's ON and `disablesleep` stays 1 until
  you reboot or run `sudo pmset -a disablesleep 0`. This is upstream issue
  [#8](https://github.com/Aboudjem/Sleepless/issues/8) and the main thing this fork is for —
  design in [docs/LEASE-DESIGN.md](docs/LEASE-DESIGN.md), not yet built.
- **No CLI.** Planned, so a Claude Code `Stop` hook can release the lease.
- **No thermal awareness.** Deliberately last; see the design note.
- **Lid-close display sleep is untested on hardware.** Verify before trusting it in a bag.

## Verify it yourself

The whole app is one 750-line file. [SECURITY.md](SECURITY.md) explains why the design is
safe; [docs/AUDIT.md](docs/AUDIT.md) shows how to confirm it. Both are upstream's, and both
became *more* accurate in this fork — the code path they never mentioned is the one that's
now gone.

## License

MIT, © 2026 Adam Boudjemaa. See [LICENSE](LICENSE).
