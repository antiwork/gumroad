# frozen_string_literal: true

class AddDeliveredAtIndexToEmailInfos < ActiveRecord::Migration[8.1]
  INDEX = "index_email_infos_on_installment_id_and_delivered_at"

  # A delivery read filters one installment's rows by delivered_at (for example the marketing
  # holdout read, antiwork/gumroad-private#2723). The existing (installment_id, purchase_id)
  # index cannot answer that range, so MySQL reads every delivery the installment ever made and
  # throws most of them away: EXPLAIN on a 50-seller batch shows 137 rows per installment with
  # 1.11% kept, and the same read over a 90-day window now runs longer than the API read
  # timeout. Leading with delivered_at behind installment_id turns it into a range scan.
  #
  # Built by hand in production with pt-osc: at this table's size the copy cannot ride a deploy
  # (same shape as the consumption_events index, gumroad-private#4550), so the deploy only
  # records this version here.
  def up
    return if Rails.env.production?

    add_index :email_infos, [:installment_id, :delivered_at], name: INDEX
  end

  def down
    return if Rails.env.production?

    remove_index :email_infos, name: INDEX
  end
end
