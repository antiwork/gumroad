# Repair an unapplied Capital deduction

Use `Onetime::RepairCapitalDeduction` for a reconciled USD deduction with an existing Credit and BalanceTransaction.
The service applies that transaction to an explicit unpaid Balance.
It does not create another deduction, change paid balances, or issue a payout.

1. Match the Stripe financing identifier and deduction amount to the Credit and BalanceTransaction.
2. Reconcile the account's obligations and Stripe funds before selecting the target Balance.
3. Run the service through the approved production repair workflow with `dry_run: true`.
4. Review the returned record IDs and before/after amounts.
5. Run the same arguments with `dry_run: false` after the required production approval.
6. Verify the linked records, balance transaction sums, and Stripe reconciliation.
7. Use the normal payout workflow to release eligible funds.

```ruby
arguments = {
  credit_id: credit_id,
  balance_transaction_id: balance_transaction_id,
  balance_id: balance_id,
  stripe_loan_paydown_id: stripe_loan_paydown_id,
  expected_amount_cents: expected_amount_cents,
  expected_balance_cents: expected_balance_cents
}

Onetime::RepairCapitalDeduction.new(**arguments).process
Onetime::RepairCapitalDeduction.new(**arguments, dry_run: false).process
```

`expected_amount_cents` is the negative Capital deduction, not the difference between the ledger and Stripe funds.
`expected_balance_cents` is the target Balance amount before the repair.
Both issued and holding currencies must be USD.

The service locks the records and checks the account, amounts, financing identifier, transaction sums, and duplicate records.
It refuses changed amounts, mismatched records, partial links, and balances that are no longer unpaid.
A completed repair returns `already_applied` on a repeated call.
The live call logs the record IDs and amounts under `RepairCapitalDeduction`.
If any check fails, reconcile the new state before choosing another action.

## Apply a deduction whose Stripe transfer has no source charge

Use `Onetime::ApplySourcelessCapitalDeductions` for the listed automatic withholdings whose Stripe transfer has no `source_transaction`.
Older code linked these credits to a seller purchase with no charge ID, which never succeeded, so `RepairCapitalDeduction` refuses them.
The task only accepts unique credit IDs from its `CREDIT_IDS` list.

```ruby
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch).process
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch, dry_run: false).process
# Optional: leave a credit alone when it would end the seller's unpaid ledger below zero.
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch, skip_negative: true).process
# Optional: judge the ledger at one payout date instead of every date from the deduction's balance on.
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch, skip_negative: true, payout_date: Date.current).process
```

For each credit it:

1. Reads the Stripe financing transaction, its linked payment, and that payment's source transfer.
   The financing transaction must be an automatic withholding in USD for the credit's amount and account, and the transfer must have no `source_transaction`.
2. Locks the credit and checks the USD Stripe merchant account, the never-charged purchase link, and any existing balance transaction.
3. In a dry run, returns the balance the deduction would land on (the earliest unpaid balance, or a new one dated to the Stripe deduction, which starts at 0) with before/after amounts.
   A transaction that an interrupted run already applied reports its own balance and `links_applied_transaction: true`.
4. Refuses if the credit already stores a deduction time, payment ID, or transfer ID that differs from Stripe's, and never overwrites one.
   A credit cleared by an interrupted run must store all three.
5. In a live run, clears the purchase link, records the Stripe payment and transfer IDs, and applies the deduction with `Credit#apply_financing_paydown!`.
   That reuses the existing balance transaction, or creates the missing one in USD.
   A transaction already applied to the seller's USD balance is only linked to the credit; the balance is not changed again.

Each credit returns `dry_run`, `applied`, `already_applied`, `skipped`, or `refused` with the reason; one refusal does not stop the batch.
A credit that already has a balance returns `already_applied`, and a credit left unlinked by an interrupted run resumes.
Run batches small enough to finish inside the console time limit, with the IDs written inline.

Read a dry run like this:

- `before_cents` and `after_cents` are cumulative per target balance across the batch, in the order of `credit_ids`.
  A later credit on the same balance starts from the earlier credit's `after_cents`, so the last row shows the balance a live run of the same batch leaves.
  A credit whose transaction is already applied adds nothing itself, but its row still includes the earlier credits of the batch.
  Run the dry run and the live run with the same IDs in the same order.
  A credit's own effect is `deduction_cents`.
- Payouts judges only the unpaid balances dated up to the payout date, so a newer positive balance cannot cover a deduction that an older payout date would still hit.
  The task judges the ledger the same way, at every date from the deduction's balance on, or only at `payout_date` when one is given.
  `ledger_after_cents` is the whole unpaid ledger after this credit (at `payout_date` when given).
  `worst_ledger_cents` is the lowest ledger across the dates judged, and `negative_from` is the first date at which this credit's ledger or its payout group is below zero, or nil.
  `ends_negative` is true when that happens at any judged date, and `payout_held` when the ledger is at zero or below, or any payout group is below zero, at any judged date.
  Groups follow Payouts: Stripe-held balances group by merchant account and currency, and Gumroad-held balances join the payout account's group.
  The figures ignore Payouts' exception for currencies an account cannot pay out, so a flag can be raised for a group Payouts would not hold.
  They also count only unpaid balances: a balance a payout has just claimed (`processing`) is not counted, so a payout that starts while a batch runs can change the outcome.
  Treat them as a guide, not a guarantee, and check `payout_held` and `ends_negative` together.
  Check every row with either flag before running live.
- A transaction that an interrupted run already applied only gets linked to its credit.
  Its balance is not changed again, and its `balance_state` (`paid`, `processing`, or `unpaid`) is ignored, so a link to a paid balance does not reopen it.
  Such a credit adds nothing to the ledger, and `skip_negative` never skips it.
- With `skip_negative: true`, a credit whose new deduction would end the ledger or its payout group below zero (`ends_negative`, not a ledger of exactly zero) returns `skipped` with `ledger_after_cents` and stays unapplied.
  Later credits are judged without it.
  With `skip_negative: true`, a live run holds the seller lock while it judges and applies each credit, so a payout cannot move the balances in between.
  That lock, and the Credit and Balance locks taken inside it, are held until the seller's transaction ends, so keep batches small.
- `new_balance_date` is the date of the balance a live run opens when the seller has no unpaid one; every later row of the batch that lands on that balance repeats the first credit's date.
  The default applies every credit, negative or not; choosing between the two is a policy decision for the payout owner.
