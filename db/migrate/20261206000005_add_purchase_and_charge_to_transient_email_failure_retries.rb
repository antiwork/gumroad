# frozen_string_literal: true

# Receipt retries need to know WHICH purchase/charge's receipt failed so the
# retry job can re-send that exact email. Signup-confirmation retries leave
# both nil (the address alone identifies what to re-send). Plain bigint
# columns, no FK: this is a small operational bookkeeping table and the
# referenced record's existence is re-checked at send time anyway.
class AddPurchaseAndChargeToTransientEmailFailureRetries < ActiveRecord::Migration[7.1]
  def change
    change_table :transient_email_failure_retries, bulk: true do |t|
      t.bigint :purchase_id
      t.bigint :charge_id
    end
  end
end
