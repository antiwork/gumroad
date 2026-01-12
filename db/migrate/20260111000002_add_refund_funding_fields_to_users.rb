# frozen_string_literal: true

class AddRefundFundingFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    Alterity.disable do
      add_column :users, :refund_funding_card_name, :string
      add_column :users, :dismissed_refund_payment_method_banner, :boolean, default: false, null: false
    end
  end
end
