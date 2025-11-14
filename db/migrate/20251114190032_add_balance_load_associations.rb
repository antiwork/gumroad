# frozen_string_literal: true

class AddBalanceLoadAssociations < ActiveRecord::Migration[7.1]
  def change
    # Add stripe_customer_id to users if not exists (for balance loading)
    unless column_exists?(:users, :stripe_customer_id_for_balance_loading)
      add_column :users, :stripe_customer_id_for_balance_loading, :string, limit: 191
      add_index :users, :stripe_customer_id_for_balance_loading, name: "index_users_on_stripe_customer_id_for_bl"
    end

    # Add balance_load_id to credits to track balance loads
    unless column_exists?(:credits, :balance_load_id)
      add_column :credits, :balance_load_id, :bigint
      add_index :credits, :balance_load_id
    end
  end
end
