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
The task only accepts credit IDs from its `CREDIT_IDS` list.

```ruby
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch).process
Onetime::ApplySourcelessCapitalDeductions.new(credit_ids: batch, dry_run: false).process
```

For each credit it:

1. Reads the Stripe financing transaction, its linked payment, and that payment's source transfer.
   The financing transaction must be an automatic withholding in USD for the credit's amount and account, and the transfer must have no `source_transaction`.
2. Locks the credit and checks the USD Stripe merchant account, the never-charged purchase link, and any existing balance transaction.
3. In a dry run, returns the balance the deduction would land on (the earliest unpaid balance, or a new one dated to the Stripe deduction) with before/after amounts.
4. In a live run, clears the purchase link, records the Stripe payment and transfer IDs, and applies the deduction with `Credit#apply_financing_paydown!`.
   That reuses the existing balance transaction, or creates the missing one in USD.

Each credit returns `dry_run`, `applied`, `already_applied`, or `refused` with the reason; one refusal does not stop the batch.
A credit that already has a balance returns `already_applied`, and a credit left unlinked by an interrupted run resumes.
Run batches small enough to finish inside the console time limit, with the IDs written inline.
