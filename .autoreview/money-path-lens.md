# Reviewing your OWN fix on a money path

> **Fix shaped as "extract a helper + update N call sites"?** The helper's unit tests + mutation check
> prove the helper, not the fix: reverting the call sites usually leaves the whole suite green, so the
> behaviour ships unpinned. Revert ONE call site and run everything — if nothing reddens, add a
> call-site pin and mutation-verify it too.
> → [pin-the-call-sites-not-just-the-helper.md](pin-the-call-sites-not-just-the-helper.md)

An audit fix needs the same adversarial scrutiny as the code it audits. Proven expensively on
2026-07-28: the fix for a cross-currency audit item (gumroad-private#1328 A2) shipped with **the
exact class of bug the audit existed to find**, and the adversarial review caught it before merge.
Three distinct defects in one small change — each one a reusable review lens.

## 1. A field name is not a field definition — read the validation

The fix computed Gumroad's share on a won dispute as:

```ruby
chargeable.presentment_amount_cents - chargeable.presentment_gumroad_amount_cents
```

That subtraction yields the **seller's** share, then books it as Gumroad's. Roughly **9x the
correct amount** at a 10% fee. The neighbouring branch subtracts the *seller* figure and is
correct, which is what made the wrong one look plausible by symmetry.

`presentment_gumroad_amount_cents` **is** Gumroad's cut — validated never to exceed the presentment
total, and it feeds Stripe's application fee. The name reads like "the presentment amount, from
Gumroad's perspective"; it means "Gumroad's take".

**Lens:** for any `x - y` on a money path, find where `y` is WRITTEN and what validates it. Do not
infer the semantics from the identifier, and do not trust that a parallel branch implies your
branch's polarity. Ask out loud: *whose money is this number?*

## 2. A fail-closed guard that cannot fire is worse than none

The change added a defensive raise for a state that **cannot occur** — both snapshot columns are
`NOT NULL`, so the guarded condition is unreachable. Meanwhile the genuinely dangerous case, a
non-USD charge with a **missing** snapshot row, fell straight through to the original
mixed-currency arithmetic.

Net effect: the diff *looked* hardened, reviewers see a raise and relax, and the real hazard is
untouched.

**Lens:** for every guard added, ask (a) can this condition actually occur — check the schema's
`NOT NULL`/defaults, not just the model, and (b) what is the nearest state that IS dangerous, and
does this guard cover it? A guard on an impossible state is a false signal of safety.

## 3. Where the raise sits relative to the money movement

The raise fired **after** the creator transfer had already executed, in a Sidekiq worker with
`retry: 10`, calling a transfer helper with **no idempotency key**. A raise there meant up to
**11 duplicate transfers** of real money — the guard intended to prevent one bad transfer instead
caused eleven.

**Lens:** on any path that moves money, locate the side effect and the raise, then ask which comes
first. Validate and resolve every amount **before** the irreversible call. Check the worker's
`retry:` setting and whether the external call carries an idempotency key — the combination of
"raise after side effect" + "retries" + "no idempotency key" is a money-duplication bug regardless
of how correct the validation itself is.

## 4. Load-bearing proof, not just green

Prove each specific finding is pinned. Reintroduce the bug and confirm **exactly** the specs that
should fail do:

```
reintroduce the P1  -> 1 failed  (the inversion spec)
drop the guard      -> 1 failed  (the ordering spec)
```

Four new specs passing tells you nothing on its own. A spec that stays green when you put the bug
back is decoration.

## 5. Comment claims are review surface too

The same review caught a comment asserting the disputed-amount string is "read by the card network
and the issuing bank". Grepping every consumer showed it goes only to seller emails and a
seller-facing page — never submitted to Stripe as dispute evidence. A confidently wrong comment
about who consumes a value misleads the next reader more than no comment.

**Lens:** verify a comment's factual claims by grepping the actual consumers, exactly as you would
verify code.

## Pitfall: a VALID finding does not mean your fix for it is right

On a sibling PR the reviewer raised a real gap (pay-what-you-want items listed at 1-49c still fell
back to the legacy card form). Two attempted guards broke **17 then 11** previously-green specs,
because the blanket condition also swallowed carts whose sub-minimum total was real and known.

The correct move was to **revert**, report the finding plus the failed attempts honestly, and leave
it with a human who knows the eligibility rules — not to keep guessing or push red. Capture the
clean baseline first (`git stash` your edits, re-run the suite) so you can prove whether failures
are yours or pre-existing; that is also how a random-order VCR flake gets distinguished from a real
regression, by running the same seed on untouched `main`.
