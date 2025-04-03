# frozen_string_literal: true

class SetupIntent
  attr_accessor :id, :setup_intent, :client_secret

  def succeeded?
    true
  end

  def requires_action?
    false
  end

  def canceled?
    false
  end
end
