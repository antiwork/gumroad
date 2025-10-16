# frozen_string_literal: true

class AllowNullCardholderNameOnRefundPaymentMethods < ActiveRecord::Migration[7.1]
  def change
    change_column_null :refund_payment_methods, :cardholder_name, true
  end
end
