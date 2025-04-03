# frozen_string_literal: true

class ChargeRefund
  attr_accessor :charge_processor_id, :id, :charge_id, :flow_of_funds
  attr_reader :refund
end
