# frozen_string_literal: true

class AddRefundFundingFieldsToUsers < ActiveRecord::Migration[7.1]
  # Originally added refund_funding_card_name and dismissed_refund_payment_method_banner to users.
  # Card holder name moved to credit_cards table. Banner dismissal uses FlagShihTzu flags column.
  def change
  end
end
