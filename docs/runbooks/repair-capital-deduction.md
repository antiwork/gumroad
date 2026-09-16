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
