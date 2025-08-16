class AddDefaultDiscountParametersToDiscountCollections < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      execute "SET FOREIGN_KEY_CHECKS = 0"

      execute "ALTER TABLE discount_collections ADD COLUMN default_discount_type VARCHAR(255)"
      execute "ALTER TABLE discount_collections ADD COLUMN default_discount_value DECIMAL(10,2)"
      execute "ALTER TABLE discount_collections ADD COLUMN default_max_purchase_count INT"
      execute "ALTER TABLE discount_collections ADD COLUMN default_valid_at DATE"
      execute "ALTER TABLE discount_collections ADD COLUMN default_expires_at DATE"
      execute "ALTER TABLE discount_collections ADD COLUMN default_minimum_quantity INT"
      execute "ALTER TABLE discount_collections ADD COLUMN default_duration_in_billing_cycles INT"
      execute "ALTER TABLE discount_collections ADD COLUMN default_minimum_amount_cents INT"

      execute "SET FOREIGN_KEY_CHECKS = 1"
    end
  end
end
