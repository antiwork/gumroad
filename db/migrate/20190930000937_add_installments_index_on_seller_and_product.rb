# frozen_string_literal: true

class AddInstallmentsIndexOnSellerAndProduct < ActiveRecord::Migration
  def change
    add_index :installments, [:seller_id, :link_id]
  end
end
