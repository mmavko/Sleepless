# 2026-09-18 1520 — A greedy sed read `usec` as `sec`: cross-language contracts must be tested, never assumed

The lease is keyed on boot time. `watchdog.sh` and `lease.sh` both parsed
`sysctl -n kern.boottime` with `.*sec = `, which is greedy and therefore matches **`usec = `** —
so both read the microseconds field (`480767`) instead of the epoch seconds. They agreed with
each other, so all 21 tests passed. `App.swift`'s `sysctlbyname("kern.boottime")` did not agree.

**Why it mattered:** the watchdog would have rejected every lease the app writes and cleared the
flag ~30 seconds after arming. The app would have looked simply broken, with nothing in any log
explaining it.

**How it was caught:** by testing the Swift↔shell value directly rather than assuming the two
parses agreed. Nothing else would have found it — the shell side was self-consistent.

**What was decided:**
- Root cause was duplication: the same parser lived in two files and had to be fixed twice. The
  shared primitives (`boot_time`, `lease_field`, `lease_state`) now live in `leaselib.sh`,
  sourced by both and installed alongside the watchdog so the installed pair is self-contained.
- Two assertions in `tests/watchdog-selftest.sh`: boot time must be a plausible epoch, and must
  equal what Swift computes. Both are mutation-verified.

**The general rule this established:** every value that crosses the Swift/shell boundary gets a
test, not an assumption. It caught a second one later — `sleepless extend` reads the app's
idle-timeout setting from `UserDefaults`, and a mutation making the CLI ignore it now fails the
suite.

**Why not just fix the regex:** a self-consistent wrong answer is the failure mode here. Fixing
the symptom in two places leaves the next divergence undetectable.

**A test can be wrong in the same way.** The first version of the boot-time test inlined its own
copy of the regex, so it validated the copy rather than the shipped code and passed against a
reintroduced bug. It now sources `leaselib.sh` directly.
