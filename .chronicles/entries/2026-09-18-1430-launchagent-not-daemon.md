# 2026-09-18 1430 — The dead-man switch is a LaunchAgent, not a root daemon, so it costs no new privilege

`disablesleep` is global kernel state no process owns, and every safety net in the app was an
in-memory `Timer`, so killing the app killed all of them while the flag stayed set. The fix is a
lease the app must renew plus a `launchd` watchdog that clears the flag when nobody does. Design
and timings: [docs/LEASE-DESIGN.md](../../docs/LEASE-DESIGN.md).

**Why:** upstream's honest answer to "the app crashed while ON" was "the Mac stays awake until
you reboot" (their issue #8). That is the absence of a dead-man switch, not one.

**What was decided:** a user-level LaunchAgent, ticking every 30s, clearing the flag through the
*existing* sudoers grant.

**Why not a root LaunchDaemon:** it would cover the login window too, but it needs a root daemon
installed and kept correct. The agent needs **zero** new privilege — the grant the app already
has is exactly the capability the watchdog needs. The only gap is being logged out, and if you
are logged out you are not running Claude Code. This is the load-bearing decision in the whole
design: it is what keeps this a small tool.

**Safety property worth preserving:** the watchdog can only ever make the Mac *sleepier*. There
is no code path in it that sets the flag to 1. A bug there costs a keep-awake session; it can
never silently keep the Mac awake.
