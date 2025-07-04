class AddCustomFeeChagedColumnsOnPurchase < ActiveRecord::Migration[7.1]
  def change
    add_column :purchases, :custom_flat_fee_per_thousand_charged, :decimal, scale: 2, precision: 5, default: nil
    add_column :purchases, :custom_discover_fee_per_thousand_charged, :decimal, scale: 2, precision: 5, default: nil
  end
end
