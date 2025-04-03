# frozen_string_literal: true

class BraintreeChargeRefund < ChargeRefund
  def initialize(braintree_transaction)
    self.charge_processor_id = BraintreeChargeProcessor.charge_processor_id
    self.id = braintree_transaction.id
    self.charge_id = braintree_transaction.refunded_transaction_id

    currency = Currency::USD
    amount_cents = -1 * (braintree_transaction.amount * 100).to_i
    self.flow_of_funds = FlowOfFunds.build_simple_flow_of_funds(currency, amount_cents)
  end
end
