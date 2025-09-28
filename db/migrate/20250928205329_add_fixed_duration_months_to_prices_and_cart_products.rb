class AddFixedDurationMonthsToPricesAndCartProducts < ActiveRecord::Migration[7.1]
  def change
    add_column :prices, :fixed_duration_months, :integer
    add_column :cart_products, :fixed_duration_months, :integer

    add_check_constraint :prices,
                         "fixed_duration_months IS NULL OR fixed_duration_months > 0",
                         name: "prices_fixed_duration_months_gt_zero"

    add_check_constraint :cart_products,
                         "fixed_duration_months IS NULL OR fixed_duration_months > 0",
                         name: "cart_products_fixed_duration_months_gt_zero"
  end
end
