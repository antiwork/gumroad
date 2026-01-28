# frozen_string_literal: true

class AddProcessorPaymentMethodIdToCreditCard < ActiveRecord::Migration[4.2]
  def change
    add_column :credit_cards, :processor_payment_method_id, :string
  end
end
