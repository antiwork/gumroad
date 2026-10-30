# frozen_string_literal: true

class AddIsDirectAffiliateCreditToAffiliateCredits < ActiveRecord::Migration[8.1]
  def change
    add_column :affiliate_credits, :is_direct_affiliate_credit, :boolean, default: false, null: false
  end
end
