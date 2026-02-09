# frozen_string_literal: true

class AddIdxAudienceOnSellerId < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      add_index :audience_members, :seller_id, name: "idx_audience_on_seller_id", algorithm: :inplace
    end
  end
end
