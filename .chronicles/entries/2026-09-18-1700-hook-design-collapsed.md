# 2026-09-18 1700 — The Claude Code integration collapsed to one hook and one verb, because release can never be the mechanism

Keep-awake ends when Claude Code goes quiet. The entire integration is one `PreToolUse` hook
calling `sleepless extend`. Reasoning: [docs/LEASE-DESIGN.md](../../docs/LEASE-DESIGN.md).

**Why:** a manual timer fails in both directions — set 1h and a 90-minute build dies at minute
60; set 2h and a 10-minute task holds the Mac awake for 110 minutes on battery.

**Two wrong designs came first, and the why-nots matter more than the answer:**

- **`SessionStart` → on, `Stop` → off.** Wrong twice over: `Stop` fires at the end of *every
  assistant turn*, not at session end, so it would release after every response. `SessionEnd` is
  the session-level event — and it is unreliable anyway, because sessions linger and terminals
  get closed.
- **Reference-counted per-session holders** (`leases.d/<session_id>`), to stop the first session
  finishing from killing the others. This was over-engineering, and the unreliability of
  `SessionEnd` is what proves it: **if release is never the mechanism, refcounting is not
  needed.** When holders only ever *extend*, the `max()` floor semantics already in `leaselib.sh`
  compose across any number of writers on one file — whoever is active keeps the lease alive, and
  it lapses after the last one goes quiet. No holder ids, no locking, no races.

**Expiry is the mechanism; release is only a courtesy.**

**`extend` must never arm keep-awake, only prolong it.** Otherwise any Claude session anywhere
silently disables this Mac's sleep. The hook replaces the **timer**, not the **switch**.

**Subagents were a worry and are not one:** their tool calls fire the same configured hooks, with
`agent_id`/`agent_type` added to the input.

**The one gap that remains:** `PostToolUse` fires when a background command is *started*, not
while it runs, so a long background job with the main loop waiting on it produces no hooks and no
transcript writes. There is no "still running" event to hang a heartbeat on. The answer is the
CLI's manual escape hatch (`sleepless extend 2h`), not more machinery.

**A transcript fallback sits under the hook**, borrowed from the sibling claude-tracker project:
Claude Code writes a transcript per session under `~/.claude/projects`, so their mtimes say when
it last did anything, with nothing to install and no way to fail silently. The hook is a
precision upgrade, not a prerequisite — which is why the UI never treats its absence as an error.
