# frozen_string_literal: true

class AddSellerIdToInstallments < ActiveRecord::Migration
  def change
    add_column :installments, :seller_id, :integer
  end
end
