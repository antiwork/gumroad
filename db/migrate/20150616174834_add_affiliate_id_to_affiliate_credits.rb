# frozen_string_literal: true

class AddAffiliateIdToAffiliateCredits < ActiveRecord::Migration[4.2]
  def change
    add_column :affiliate_credits, :affiliate_id, :integer
    add_index :affiliate_credits, :affiliate_id
  end
end
