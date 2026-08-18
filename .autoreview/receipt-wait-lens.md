# Domain lens: wait for all charge purchases to settle before sending receipt

This PR changes SendChargeReceiptJob so a multi-item charge does not send while any purchase is still in_progress. It retries on RETRY_DELAYS = [10s, 30s, 1m, 5m] then falls through and sends whatever has settled.

This is a money-adjacent receipt-timing change. Review the job + spec only.

Numbered checks:

1. **Does the deferral actually wait for the paid row?** The live bug is free+paid: the $0 row succeeds first, the job sends a combined free-only receipt, receipt_sent is set, the later Pro row never gets a purchase-scoped receipt. Confirm the new guard keys on charge.purchases.any?(&:in_progress?) and that a successful free + in_progress paid defers.

2. **Does receipt_sent still get set on a deferred attempt?** If the job marks receipt_sent then re-enqueues, the retry no-ops and the paid receipt is lost forever. The early return must happen BEFORE send_receipts and BEFORE charge.update!(receipt_sent: true).

3. **Bounded fallthrough.** After attempt exhausts RETRY_DELAYS, it must send with whatever has settled so ACH/Pix cannot hold a receipt for days. Confirm attempt indexing: perform(charge_id, attempt=0) uses RETRY_DELAYS[attempt], then attempt+1. Off-by-one that never falls through, or that skips the last delay, is a P1.

4. **Idempotency with the existing split path.** send_receipts still skips a purchase that already has CustomerEmailInfo receipt, and still uses single_purchase: true in split mode. A retry after a partial send must not duplicate the already-delivered receipt.

5. **Single-item / already-settled charges must be byte-identical to main.** No extra delay when no purchase is in_progress.

6. **Specs are load-bearing.** For each new example, name the mutation that must redden it (delete the in_progress guard; mark receipt_sent before re-enqueue; fall through one attempt early; stop deferring after settle). A spec that stays green under that mutation is vacuous.

Do NOT run the test suite. Static review only. Do not modify files. Produce READY-TO-MERGE or CHANGES-REQUIRED with P0/P1 file:line + one-line fix.
