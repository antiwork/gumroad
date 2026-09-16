# Non-US refund fee write-offs

The recovery job writes off a fee when a non-US Stripe account has no safe transfer.
The job checks every page of transfers older than 120 days.
It also checks for unrecorded collections before the write-off.
Stripe lookup errors remain retryable.
Pinned transfers remain pending when their collection status is uncertain.

The write-off offsets the original ledger debit in USD and the holding currency.
The refund records the USD amount, UTC date, and reason.
The original credit and ledger debit remain available for audit.
The original fee remains in its payout history.
The write-off appears as a returned fee on its own payout.
The refund leaves the recovery job.

## Pending and capped refunds

Run this procedure after deployment through the approved production admin tool.
The procedure can collect a fee if a safe transfer now exists.
The procedure does not reset the attempt count.

1. Obtain the current refund IDs from the incident investigation.
2. Preview those IDs with the following command.

```ruby
Onetime::ReconcileNonUsRefundFees.process(refund_ids: ids)
```

The preview reads local records only.
The `eligible` field identifies non-US Stripe fees that still require reconciliation.
The preview does not prove that Stripe has no reversible transfer.

3. Check the IDs and the pending USD total.
4. Run the same IDs with writes enabled.

```ruby
Onetime::ReconcileNonUsRefundFees.process(refund_ids: ids, dry_run: false)
```

5. Check the returned collection IDs, write-offs, pending rows, and errors.
6. Run the preview again to confirm the final totals.

Completed rows do not collect again or create another ledger offset.
Keep the incident open until the returned pending total reaches zero or each remaining row has an assigned action.

## Aggregate write-offs

Use the refund timestamp to select a reporting period.
The following query returns the write-off count and total in USD cents.

```ruby
Refund.written_off_fee_retention
  .where("json_data->>'$.fee_retention_written_off_at' >= ? AND json_data->>'$.fee_retention_written_off_at' < ?",
         starts_at.utc.iso8601, ends_at.utc.iso8601)
  .pick(Arel.sql("COUNT(*)"), Arel.sql("SUM(CAST(json_data->>'$.fee_retention_written_off_cents' AS SIGNED))"))
```
