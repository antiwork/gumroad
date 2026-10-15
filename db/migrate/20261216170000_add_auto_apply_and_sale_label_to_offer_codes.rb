# frozen_string_literal: true

# No backfill: every existing code stays off (auto_apply false, no label).
class AddAutoApplyAndSaleLabelToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    change_table :offer_codes, bulk: true do |t|
      t.boolean :auto_apply, default: false, null: false
      t.string :sale_label
    end
  end
end
