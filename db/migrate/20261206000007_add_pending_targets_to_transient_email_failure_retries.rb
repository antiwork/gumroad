# frozen_string_literal: true

# Receipt retries need to know WHICH purchase/charge receipts failed so the
# retry job can re-send those exact emails. A single address can have several
# distinct receipts fail while one retry is pending (two purchases in quick
# succession to a temporarily-unreachable mailbox), so this is a JSON array of
# targets — e.g. [{"purchase_id": 123}, {"charge_id": 456}] — not a single
# pair of columns. Signup-confirmation retries leave it empty (the address
# alone identifies what to re-send). No FKs: this is a small operational
# bookkeeping table and each referenced record's existence is re-checked at
# send time anyway.
class AddPendingTargetsToTransientEmailFailureRetries < ActiveRecord::Migration[7.1]
  def change
    add_column :transient_email_failure_retries, :pending_targets, :json
  end
end
