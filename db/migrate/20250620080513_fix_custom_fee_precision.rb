class FixCustomFeePrecision < ActiveRecord::Migration[7.1]
  def change
    change_column :users, :custom_direct_fee_percentage, :decimal, precision: 5, scale: 2
    change_column :users, :custom_discover_fee_percentage, :decimal, precision: 5, scale: 2
  end
end
