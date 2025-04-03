# frozen_string_literal: true

class AddSubscriptionsLastPaymentOptionId < ActiveRecord::Migration
  def change
    add_column :subscriptions, :last_payment_option_id, :integer
  end
end
