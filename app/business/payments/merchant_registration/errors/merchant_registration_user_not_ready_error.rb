# frozen_string_literal: true

class MerchantRegistrationUserNotReadyError < GumroadRuntimeError
  def initialize(user_id, message_why_not_ready)
    super("User #{user_id} #{message_why_not_ready}.")
  end
end
