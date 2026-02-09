# frozen_string_literal: true

class AddIndexOnAudienceMembersSellerId < ActiveRecord::Migration[7.1]
  disable_ddl_transaction!

  def change
    add_index :audience_members, :seller_id, name: "idx_audience_on_seller_id", algorithm: :inplace
  end
end
