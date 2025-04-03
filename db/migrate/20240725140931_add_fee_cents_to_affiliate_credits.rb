# frozen_string_literal: true

class AddFeeCentsToAffiliateCredits < ActiveRecord::Migration[7.1]
  def change
    add_column :affiliate_credits, :fee_cents, :bigint, default: 0, null: false
  end
end
