# Domain lens: risk-report suppression + sole remaining human-facing recovery report

This branch does two related things:
1. Reroutes `AlertOnBlockedEstablishedBuyersJob` / `AlertOnBlockedEstablishedSubscribersJob` from the human `risk` room to a new `agent_reports` room (agent inbox only).
2. At `91c9fa889041661a657a7d7b74dbeb403e26c721`, names buyers withheld for `:shared_identifier_needs_human_review` in `RecoverStrandedBuyersJob`'s still-human `risk` report, claiming that with the detail reports now agent-only this is the sole human-facing surface that identifies who is waiting.

Prior review at `cf6eb350` was clean (P0 bar) on the room reroute only. Grade the COMBINATION, especially the new commit.

Answer each item as a question. Quote file:line. Do not assume the PR body or comments are true.

1. **Completeness of the human-decision class.** Enumerate every reason `Risk::StrandedBuyerRecoveryService` can leave a buyer blocked and needing a human (`:authored_block` escalate, `:shared_identifier_needs_human_review`, `:card_still_declining_at_issuer`, `:nothing_clearable` with only withheld rows, skip reasons). For each: does the still-human recovery report name the buyer, only count them, or drop them? The new comment claims shared-radius "only ever clears when a human reads this line." Is that true for every member of the class, or only the token the diff named?

2. **Header vs named-line contradiction.** `message_for` still prints `"#{withheld} withheld for a human"` from `result.skipped.size` (all skip reasons). The new WITHHELD lines count only `:shared_identifier_needs_human_review`. A buyer with 1 shared-radius + 1 still-declining card produces "2 withheld for a human" and "1 shared-radius block(s)". Is that a false rationale in the same message? Which example would redden if the header kept counting issuer-declines as human holds?

3. **`:nothing_clearable` / non-`:cleared` verdicts.** `partition_blocks` can return empty `clearable` and a withheld list; `#call` then returns `:noop, :nothing_clearable, skipped: withheld`. Does `recover` still populate `withheld_for_human` on that path? What about `:escalate` (skipped reasons are `:authored`, not the shared-radius token) — do those buyers still appear via the existing ESCALATE lines, or can a shared-radius hold hide behind an authored escalate and never be named as WITHHELD?

4. **Cap reuse.** Named WITHHELD lines reuse `MAX_REPORTED_ESCALATIONS` (15) independently of the ESCALATE list. `MAX_RECOVERIES_PER_RUN` is 25. If this report is now the sole human identifier, what happens to withheld buyers 16–25? Is the overflow line enough, or is a name dropped that used to live in the (now agent-only) detail report?

5. **Room / reach claims.** `agent_reports` recipient is `INTERNAL_NOTIFICATION_ALWAYS_CC`. The recovery job still sends to `"risk"`. Grep every `InternalNotificationWorker.perform_async` / `CHAT_ROOMS` reader: after this diff, which blocked-established / stranded-buyer surfaces still reach a human inbox, and which do not? Is the comment "sole human-facing surface that identifies who is waiting" true, or does another live report/CLI/admin path still name them?

6. **Token fidelity / value-space dispatch.** Shared-radius withholding is keyed on `identifier_ips.include?(block.object_value) || SHARED_RADIUS_TYPES.include?(block.object_type)` but reported as "shared-radius block(s) (domain/IP)". An IP stored under `browser_guid` still gets `:shared_identifier_needs_human_review`. Does the report copy overclaim the type? Would a mutant that counted all `result.skipped` still pass the new examples?

7. **Specs load-bearing?** The new examples stub the recovery service. Which example uniquely dies if (a) the token check is deleted (count all skipped), (b) the WITHHELD stanza is deleted, (c) the header string is left claiming every skip is a human hold? Name any mutation nothing catches.

8. **Suppression completeness.** After moving the two alert jobs off `risk`, is any sibling report still pushing the same population at a human (stale-blocks-holding-established, subscribers vs buyers, a third scanner)? If the root cause is "humans should not get the autonomous-recovery population as a push mail," is the fix complete over that class?
