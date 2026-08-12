# Domain lens: chargeback-lost mailer nil-product guard

`ContactingCreatorMailer#chargeback_lost_no_refund_policy` is enqueued when the caller's own
snapshot found a disputable with a product lacking a refund policy. The job can run well after
enqueue. This diff adds:

```ruby
return do_not_send if @disputable.first_product_without_refund_policy.nil?
```

before assigning `@seller`/`@subject`, to guard against the seller having added a refund policy
(or the product changing) between enqueue and job execution, which previously 500'd mail delivery
because the view calls `first_product_without_refund_policy` twice more, unguarded.

Review with these numbered checks:

1. **Does `do_not_send` actually suppress delivery cleanly?** Confirm `ApplicationMailer#do_not_send`
   (or wherever it's defined) returns a `NullMail`/no-op that Sidekiq/ActionMailer treats as success,
   not as a raised error or a silently-broken delivery job retry loop.
2. **Money/notification-loss check**: is silently dropping this email the right behavior, or does
   the seller/support team lose a legitimate "you lost this dispute" notice they'd otherwise have
   gotten? If the product now HAS a refund policy, is a *different* mailer/template supposed to
   fire instead (e.g. a "chargeback lost, but you had a policy" variant), or is total silence
   correct because the underlying business event (dispute lost) still happened but this specific
   "no refund policy" framing no longer applies?
3. **Race/staleness direction**: enumerate every other caller of `chargeback_lost_no_refund_policy`
   and confirm none synchronously expects the mail object to have `@seller`/`@subject` populated
   even when `do_not_send` fires (e.g. mailer previews, other view helpers).
4. **Regression coverage**: does the new/existing spec actually exercise the nil branch (product's
   refund policy present at execution time but not at enqueue time) via a real DB state change, not
   just a stubbed `nil?`? Mutate the guard (delete it) and confirm the spec reddens with the
   previous nil-product 500 symptom, not a vacuous pass.
5. **Sibling surfaces**: grep other mailers/views for the same
   `first_product_without_refund_policy` (or similar "snapshot-at-enqueue-time" pattern) called
   unguarded more than once — is this the only place with the double-call nil-crash risk, or does
   the same bug class exist elsewhere in `ContactingCreatorMailer` or sibling dispute mailers?
