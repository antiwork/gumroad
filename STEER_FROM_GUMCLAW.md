# STEER — gp#2842 / antiwork/gumroad#7844: HOLD, do not merge

Placed 2026-09-21 by the gumclaw coordination lane. Read before touching this worktree.

- **HOLD:** no further branch edits, no ready flip, **no `--auto` / no `gh pr merge`** on #7844.
  Merge is explicitly forbidden for this work. Desk assigned the engineering follow-through to
  Gumroad Dev (execution `3da0a461`, Desk parent `t_ebd5fd44`); scoped corrections are owned there.
- **#7844 is the carrier PR** — do not open a duplicate; Gumroad Dev will reuse it.
- **Verified state at handoff:** head `fa61f382357993900120954bf215d47911ec3c03`, draft, `autoMerge=null`,
  branch `gumclaw/creator-cancellation-email-on-first-failure`, origin == local, worktree clean,
  no unpushed commits. The product-dev lane (pid 10110, session `20260921_153041_905d0f`) exited
  without merging; its ci_watch and premerge panel are gone.
- **Stale marker:** the PR body's "premerge clean @ `850f17aab0`" does not cover the current head
  `fa61f382` — re-verify before any readiness claim.
- Implementation shape is contested (expiring `SentEmailInfo` marker vs the branch's
  `Subscription#unsubscribe_and_fail!` window change). Do not resolve by merging — hand back.
