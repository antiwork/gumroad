# frozen_string_literal: true

# No backfill: every existing code stays off (auto_apply false, no label).
class AddAutoApplyAndSaleLabelToOfferCodes < ActiveRecord::Migration[7.1]
  def change
    add_column :offer_codes, :auto_apply, :boolean, default: false, null: false
    add_column :offer_codes, :sale_label, :string
  end
end
