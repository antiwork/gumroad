# frozen_string_literal: true

class AddRefundFundingFieldsToUsers < ActiveRecord::Migration[7.1]
  def change
    add_column :users, :refund_funding_card_name, :string
  end
end
