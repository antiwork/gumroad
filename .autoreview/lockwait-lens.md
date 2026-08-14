Review antiwork/gumroad PR #7220 branch fix/audience-member-lockwait at 4c9eadb962685556714f5ac66026ad188fab4436 vs origin/main.

This tip is 9f3b58d8c0 plus a one-line rubocop fix (remove blank line after `private` in AudienceMember). 9f3b58d8c0 panel was clean (both engines, 0 findings). Re-review the same money-path diff; do not invent findings from the whitespace-only commit.

Claims still in force:
- Enqueues AfterCommitEverywhere / after_commit
- Watched changes accumulated after_save, consumed after_commit
- refresh! is `persisted? ? with_lock { apply_refresh } : apply_refresh` (not bare lock!)
- :until_executing kept for mid-run follow-ups

Residual accepted: new-record creates have no row to lock.

Do not run the suite. Read-only. Do not modify files. Verdict READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
