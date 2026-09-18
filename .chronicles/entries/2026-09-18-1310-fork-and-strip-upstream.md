# 2026-09-18 1310 — Forked Aboudjem/Sleepless and stripped it, rather than rewriting or adopting a fork wholesale

This repo is a public fork of [Aboudjem/Sleepless](https://github.com/Aboudjem/Sleepless) at
v1.2.7 (`2a690e5`), MIT. Upstream's mechanism was kept; its product scaffolding was deleted and
several fixes were cherry-picked from other forks. The full difference list is
[docs/FORK.md](../../docs/FORK.md) — that file is the source of truth, not this entry.

**Why:** the goal was a personal tool, and the question was where to start. Upstream's fork tree
turned out to be where the real bug reports live: nine forks, six with commits, and three of them
had independently fixed the same unreported bug (the built-in display staying lit with the lid
closed).

**What was decided:** start from upstream `main`, cherry-pick, then strip. The hard-won value is
not the `pmset` call — it is three lines — but the sudoers grant shape, the `sudo -n` exit-status
discipline, and the accumulated v1.2.3–1.2.7 field fixes.

**Why not rewrite from scratch:** those field fixes would have to be rediscovered painfully, and
900 lines of Swift is small enough to read.

**Why not base on bagbag's fork** (the best of them): its two good commits arrive bundled with a
private `DisplayServices` dlopen, CI changes and six translated READMEs. Its security commit is
separable; the rest is someone else's opinions.

**Why delete upstream's one-click privilege setup rather than fix it:** running a script from a
user-writable `.app` bundle as root is an avoidable substitution/TOCTOU surface. For a personal
build the fix is to remove the path, not harden it — it costs one `./grant.sh` per machine.
bagbag found two real bugs in that code (a quoting break on an apostrophe in the bundle path,
and a wrong cancel exit code); deleting it resolves both.
