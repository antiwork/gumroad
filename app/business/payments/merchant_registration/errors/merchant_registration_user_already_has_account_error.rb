# frozen_string_literal: true

class MerchantRegistrationUserAlreadyHasAccountError < GumroadRuntimeError
  def initialize(user_id, charge_processor_id)
    super("User #{user_id} already has a merchant account for charge processor #{charge_processor_id}.")
  end
end
