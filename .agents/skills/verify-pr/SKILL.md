---
name: verify-pr
description: >
  Produce the verification record a pull request carries — what was run, what it showed, at the head
  commit. Use when opening or updating a PR, when `verification/ready` is red, or when someone asks
  "what did you actually check".
---

# Verifying a change

The reviewer reads the verification before the diff. So the record has to be worth more than the diff
would cost, which means it names an execution and an observation — not a category.

## The marker

One line in the PR description, pinned to the head commit:

```
Verification: verified @ <head-sha> (ran: <command or flow>; saw: <what it printed or showed>)
Verification: exempt (<reason>) @ <head-sha>     # documentation- and agent-skill-only diffs
```

Sha-pinned because a push moves the code: evidence gathered at commit A does not vouch for commit B.
Re-run and re-pin after every push, in the same edit that fixes anything else.

`ran:` and `saw:` are both required. The checker only sees two non-empty values, so
"ran: specs; saw: passed" passes it and tells the reviewer nothing — that is the failure mode this
whole record exists to avoid.

## What to run, by change

- **Ruby behaviour** — `bin/rspec spec/<the changed path>_spec.rb`, and the model/request spec one
  directory up if the change crosses a boundary. `saw:` is the tally (`12 examples, 0 failures`),
  and for a fix, the same spec failing before the change.
- **JS/CSS behaviour** — `bin/vitest-ci` for the changed package; `saw:` the tally.
- **Anything a user can see** — boot the branch, walk the flow, capture desktop + mobile and light +
  dark (video preferred). `ran:` names the flow ("checkout with a 0-price product"), `saw:` names
  what the page showed, and the media is attached with `gh pr comment <n> --attach <file>`. A preview
  app exists per push, but local-app evidence is what CONTRIBUTING.md asks for.
- **Data or money** — `rails runner` against a local or preview database to show the row, the amount,
  or the ledger entry that moved. `saw:` is the value, not "it worked".
- **Config, CI, docs** — the command that consumed the config and the line it printed.

## Not covered

Say what you did not exercise: platforms, plans, currencies, states. A verification that claims
everything is a verification nobody reads. An honest gap is the strongest thing in the block.

## Traps

- **Attest the head, not the branch.** `git log --oneline origin/main..HEAD` before writing: if there
  is more than one commit, every quoted number belongs to an older one until you re-derive it.
- **A green run is not a run.** A reused or skipped suite reports `success`; count the jobs before
  calling it green, and say "suite reused" when it was.
- **The marker is read from the body now.** Editing the description re-runs `verification/ready` with
  no push, so a body edit is the whole fix when only the marker is wrong.
