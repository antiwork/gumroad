class CustomFeeColumnsOnUser < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :custom_direct_fee_percentage, :integer, default: nil
    add_column :users, :custom_discover_fee_percentage, :integer, default: nil
  end
end
