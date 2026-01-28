# frozen_string_literal: true

class AddInstallmentsIndexOnSellerAndProduct < ActiveRecord::Migration[4.2]
  def change
    add_index :installments, [:seller_id, :link_id]
  end
end
