# frozen_string_literal: true

class BaseProcessorCharge
  attr_accessor :charge_processor_id, :id, :status, :refunded, :disputed, :fee, :fee_currency,
                :card_fingerprint, :card_instance_id,
                :card_last4, :card_number_length, :card_expiry_month, :card_expiry_year, :card_zip_code,
                :card_type, :card_country, :zip_check_result,
                :flow_of_funds, :risk_level

  # Public: Access attributes of BaseProcessorCharge via charge[:attribute].
  # Historically the code base used the Stripe::Charge object which
  # supports accessing attributes via []. It required less changes to
  # support the same access with the new class.
  def [](attribute)
    send(attribute)
  end
end
