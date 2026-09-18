# 2026-09-18 1930 — Environment facts that had to be probed, because the obvious check is wrong or unavailable

A collection of things this project cannot verify the intuitive way. Each cost real time; each is
cheap to re-probe if in doubt.

**`defaults` ignores `HOME`.** It talks to `cfprefsd`, so a test cannot sandbox a preference
domain with a fake home the way it sandboxes the lease file. Verified: `HOME=/tmp/x defaults write
com.example k 1` lands in the *real* `~/Library/Preferences`. The self-test uses a throwaway
domain name plus a `SLEEPLESS_DEFAULTS_DOMAIN` seam honoured only under `SLEEPLESS_SELFTEST=1`,
and deletes the plist afterwards — `defaults delete` empties the domain but leaves the file.

**macOS names a background login item after the program launchd was handed.** With
`ProgramArguments = ["/bin/bash", "watchdog.sh"]`, System Settings offered to add **"bash"** —
meaningless, and it looks exactly like something to turn off, which would silently kill the
dead-man switch. Installing the script as `SleeplessWatchdog` with a `/bin/bash` shebang and no
interpreter in the argv fixes it; confirmed by the macOS notification reading
*"SleeplessWatchdog can run in the background"*.
**Why not verify it from a script:** `sfltool dumpbtm` requires admin rights and raises a Touch ID
prompt. `launchctl print gui/$UID/<label>` shows the `program` value instead, which is what BTM
reads from.

**`PreToolUse` hooks DO fire in the Claude desktop app**, and a hook config change is picked up
**mid-session**, no restart. Probed directly with a hook that appended to a file. This matters
because the sibling claude-tracker project found the *statusline* command never runs there and
left hooks as an untested fallback — the two are not the same mechanism.

**The agent cannot see the popover.** There is no way to click a menu-bar extra from a script, so
layout and visual state are verified by Myron. The agent's part is to check the arithmetic — every
element inside its card, the quit button keeping its 6pt bottom margin — and to say explicitly
what it could *not* confirm. Several bugs this session were caught only because he looked.

**Shape guards for things shell tests cannot reach.** Two UI regressions came from the 1 Hz
ticker still being owned by the auto-off timer after it started driving the whole status block.
Neither is reachable from a shell test, so the suite greps `App.swift` instead:
`cancelKeepAwakeTimer` must not mention `countdownTicker`, and `applyUI` must start it. Both
mutation-verified. The same technique guards the journal key contract and the uninstall behaviour.
