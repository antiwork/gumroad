# frozen_string_literal: true

class AddPaypalBillingAgreementIdToCreditCard < ActiveRecord::Migration[4.2]
  def up
    add_column :credit_cards, :paypal_billing_agreement_id, :string
  end

  def down
    remove_column :credit_cards, :paypal_billing_agreement_id
  end
end
