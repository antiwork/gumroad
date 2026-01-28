# frozen_string_literal: true

class AddFeeCentsToAffiliatePartialRefunds < ActiveRecord::Migration[4.2]
  def change
    add_column :affiliate_partial_refunds, :fee_cents, :bigint, default: 0
  end
end
